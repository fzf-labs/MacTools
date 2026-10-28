import AppKit
import CryptoKit
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

@MainActor
final class RightClickURLRouter {
    static let shared = RightClickURLRouter()
    private let worker = RightClickFileWorker()
    private lazy var acceptedURLSchemes = Self.bundleURLSchemes()
    private var tail: Task<Void, Never>?
    private var queuedCount = 0
    private var presentation: RightClickTaskPresentation?
    private var cutFiles: (urls: [URL], changeCount: Int)?
    private var configurationObserver: NSObjectProtocol?
    private var iconUndo: [IconUndo] = []
    private var lastUndoIsIcon = false

    private init() {
        publishUndo(false)
        configurationObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("MacTools.RightClickConfigurationChanged"),
            object: RightClickConfigurationStore.configFileURL.path, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !RightClickConfigurationStore.load().menuEnabled else { return }
                self.presentation?.cancellation.cancel()
                self.cutFiles = nil
                self.iconUndo = []
                self.lastUndoIsIcon = false
                await self.worker.invalidateUndo()
            }
        }
    }

    func handle(_ urls: [URL]) { for url in urls { handle(url) } }
    func handle(_ url: URL) {
        guard let scheme = url.scheme, acceptedURLSchemes.contains(scheme), url.host == "right-click" else { return }
        guard queuedCount < 8 else { RightClickDialogs.error(RightClickFailure(message: "Another file operation is in progress.")); return }
        let previous = tail
        queuedCount += 1
        tail = Task { [self] in
            await previous?.value
            defer { queuedCount -= 1; if queuedCount == 0 { tail = nil } }
            do {
                let configuration = RightClickConfigurationStore.load()
                guard configuration.menuEnabled else { throw RightClickFailure(message: "Right Click is disabled.") }
                guard let request = RightClickRequest.decode(url) else {
                    throw RightClickFailure(message: "Invalid operation request.")
                }
                try await perform(request)
            } catch {
                AppLog.actionExecution.error("Right-click operation failed: \(error.localizedDescription, privacy: .private)")
                RightClickDialogs.error(error)
            }
        }
    }

    private func perform(_ request: RightClickRequest) async throws {
        var configuration = RightClickConfigurationStore.load()
        guard configuration.menuEnabled, configuration.isEnabled(request.action) else { throw RightClickFailure(message: "Operation is disabled.") }
        var selection = try await worker.capture(request.selection)
        guard RightClickMenuBuilder.applicable(request.action, selection: selection) else {
            throw RightClickFailure(message: "Operation is not available for this selection.")
        }
        if request.action == .paste {
            guard let cut = cutFiles, cut.changeCount == NSPasteboard.general.changeCount else {
                cutFiles = nil
                throw RightClickFailure(message: "Cut files are no longer available. Cut them again.")
            }
            selection = try await worker.capture(RightClickSelection(items: cut.urls.map { .init(url: $0, isDirectory: false) }, directory: selection.directory))
        }
        let confirmationDestination = request.action == .moveTo
            ? configuration.locations.first(where: { $0.id == request.resourceID }).map { URL(fileURLWithPath: $0.path) }
            : request.action == .paste ? selection.directory : nil
        if request.action != .undo && request.action.requiresConfirmation && !RightClickDialogs.confirm(request.action, selection: selection, destination: confirmationDestination) { return }
        switch request.action {
        case .terminal:
            guard let directory = selection.terminalDirectory else { throw RightClickFailure(message: "Folder is unavailable.") }
            try await RightClickTerminalAdapter().open(configuration.terminal, directory: directory, newTab: configuration.terminalNewTab)
        case .openWith, .openPreferred:
            let appID = request.action == .openPreferred ? configuration.preferredAppID : request.resourceID
            guard let app = configuration.openWithApps.first(where: { $0.id == appID }) else { throw RightClickFailure(message: "Application is unavailable.") }
            var targets = selection.items
            if targets.isEmpty, let directory = selection.directory { targets = [RightClickSelectionItem(url: directory, isDirectory: true)] }
            let urls = targets.filter { app.matches($0) }.map(\.url)
            guard !urls.isEmpty, Self.isApplicationBundleOnDisk(app.appPath) else { throw RightClickFailure(message: "Application or matching files are unavailable.", path: app.appPath) }
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: app.appPath), configuration: NSWorkspace.OpenConfiguration())
        case .goTo:
            guard let location = configuration.locations.first(where: { $0.id == request.resourceID }),
                  (try URL(fileURLWithPath: location.path).resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                  NSWorkspace.shared.open(URL(fileURLWithPath: location.path)) else { throw RightClickFailure(message: "Location is unavailable. Update it in settings.") }
        case .addLocation:
            guard let url = selection.urls.first else { return }
            if !configuration.locations.contains(where: { $0.path == url.path }) {
                configuration.locations.append(RightClickLocation(name: url.lastPathComponent, path: url.path))
                guard RightClickConfigurationStore.save(configuration) else { throw RightClickFailure(message: "Cannot save settings. Your changes are kept for retry.") }
            }
        case .cut:
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects(selection.urls.map { $0 as NSURL }) else { throw RightClickFailure(message: "Cannot update the clipboard.") }
            NSPasteboard.general.setString(UUID().uuidString, forType: NSPasteboard.PasteboardType("com.mactools.right-click.cut"))
            cutFiles = (selection.urls, NSPasteboard.general.changeCount)
        case .copyName, .copyPath, .copyRelative, .copyShell, .copyURL:
            let urls = selection.urls.isEmpty ? selection.directory.map { [$0] } ?? [] : selection.urls
            let text: String
            switch request.action {
            case .copyName: text = RightClickPathFormatter.joinedFileNames(urls)
            case .copyRelative: text = RightClickPathFormatter.joinedRelativePaths(urls, base: selection.relativeBase)
            case .copyShell: text = RightClickPathFormatter.joinedShellEscapedPaths(urls)
            case .copyURL: text = RightClickPathFormatter.joinedFileURLs(urls)
            default: text = RightClickPathFormatter.joinedPaths(urls)
            }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(text, forType: .string) else { throw RightClickFailure(message: "Cannot update the clipboard.") }
        case .info: try await showInformation(selection)
        case .extract:
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.archiveutility") else {
                throw RightClickFailure(message: "Archive Utility is unavailable.")
            }
            _ = try await NSWorkspace.shared.open(selection.urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        case .setIcon, .restoreIcon: try await changeIcons(request, selection: selection, configuration: configuration)
        case .undo:
            let paths: [String]
            if lastUndoIsIcon { paths = iconUndo.map(\.path) }
            else { paths = await worker.undoPaths() }
            guard !paths.isEmpty else { throw RightClickFailure(message: "There is no operation to undo.") }
            guard RightClickDialogs.confirm(.undo, selection: selection, paths: paths) else { return }
            if lastUndoIsIcon { try undoIcons(); publishUndo(false); await worker.invalidateUndo() }
            else {
                let progress = RightClickTaskPresentation()
                presentation = progress
                progress.show(title: RightClickStrings.text(request.action.title))
                let result = await worker.undo(cancellation: progress.cancellation)
                if result.failures.isEmpty && !result.cancelled { publishUndo(false) }
                progress.finish(result)
                presentation = nil
            }
        default:
            var plan = RightClickFilePlan(action: request.action, sources: selection.urls, destination: selection.directory)
            switch request.action {
            case .newFile, .newFolder:
                plan.fileExtension = request.fileExtension
                if let id = request.resourceID {
                    guard let resource = configuration.resources.first(where: { $0.id == id && $0.kind == .template && $0.enabled }) else { throw RightClickFailure(message: "Template is unavailable.") }
                    plan.templateURL = try RightClickResourceStore().url(for: resource)
                    plan.fileExtension = URL(fileURLWithPath: resource.filename).pathExtension
                } else if request.action == .newFile {
                    guard let ext = request.fileExtension, configuration.enabledFileExtensions.contains(ext), RightClickNewFile.isSupportedExtension(ext) else {
                        throw RightClickFailure(message: "Unsupported file type.")
                    }
                }
                if configuration.askForName {
                    guard let name = RightClickDialogs.name(title: request.action.title,
                        initial: RightClickStrings.text(request.action == .newFolder ? "New Folder" : "Untitled")) else { return }
                    plan.name = name
                }
            case .copyTo, .moveTo:
                guard let location = configuration.locations.first(where: { $0.id == request.resourceID }) else { throw RightClickFailure(message: "Location is unavailable. Update it in settings.") }
                plan.destination = URL(fileURLWithPath: location.path)
            case .zip:
                plan.destination = selection.urls.first?.deletingLastPathComponent()
            case .rename:
                guard let options = RightClickDialogs.rename(selection.urls) else { return }
                plan.rename = options
            case .convertImage:
                guard let format = chooseImageFormat() else { return }
                plan.imageFormat = format
            case .resizeImage:
                guard let value = RightClickDialogs.name(title: "Maximum Pixel Dimension", initial: "1600") else { return }
                guard let bound = Int(value), (1...32768).contains(bound) else { throw RightClickFailure(message: "Enter a value between 1 and 32768.") }
                plan.maximumDimension = bound
            default: break
            }
            if [.copyTo, .moveTo, .paste].contains(request.action), let destination = plan.destination,
               await worker.hasCollision(selection.urls, directory: destination) {
                guard let collision = RightClickDialogs.collision(destination: destination, sources: selection.urls) else { return }
                plan.collision = collision
            }
            if request.action == .dissolve {
                // A batch may encounter collisions later; choosing a policy is explicit.
                guard let collision = RightClickDialogs.collision(destination: selection.urls.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/"), title: "Dissolve Folder", sources: selection.urls) else { return }
                plan.collision = collision
            }
            let progress = RightClickTaskPresentation()
            presentation = progress
            let presentationTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                if !Task.isCancelled && !progress.finished { progress.show(title: RightClickStrings.text(request.action.title)) }
            }
            let result = await worker.perform(plan, cancellation: progress.cancellation) { [weak progress] count, total in
                Task { @MainActor in progress?.update(count, total: total) }
            }
            presentationTask.cancel()
            progress.finish(result)
            if !result.failures.isEmpty || result.cancelled || result.skipped > 0 { progress.show(title: RightClickStrings.text(request.action.title)) }
            presentation = nil
            if !result.undo.isEmpty { lastUndoIsIcon = false; publishUndo(true) }
            if request.action == .paste { cutFiles = nil }
            if [.newFile, .newFolder, .alias].contains(request.action), !result.outputs.isEmpty {
                if request.action == .newFile && configuration.openAfterCreating {
                    for url in result.outputs { NSWorkspace.shared.open(url) }
                } else { NSWorkspace.shared.activateFileViewerSelecting(result.outputs) }
            }
        }
    }

    private func publishUndo(_ available: Bool) {
        var configuration = RightClickConfigurationStore.load()
        guard configuration.undoAvailable != available else { return }
        configuration.undoAvailable = available
        _ = RightClickConfigurationStore.save(configuration)
    }

    private func chooseImageFormat() -> String? {
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        picker.addItems(withTitles: ["PNG", "JPEG", "HEIC", "TIFF"])
        let alert = NSAlert()
        alert.messageText = RightClickStrings.text("Convert Images")
        alert.informativeText = RightClickStrings.text("Original files are kept.")
        alert.accessoryView = picker
        alert.addButton(withTitle: RightClickStrings.text("Continue"))
        alert.addButton(withTitle: RightClickStrings.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return ["png", "jpg", "heic", "tiff"][picker.indexOfSelectedItem]
    }

    private func showInformation(_ selection: RightClickSelection) async throws {
        let details = try await Task.detached(priority: .userInitiated) {
        var lines: [String] = []
        for url in selection.urls {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey, .isDirectoryKey])
            lines.append(url.path)
            lines.append(values.localizedTypeDescription ?? "")
            if values.isDirectory != true { lines.append(ByteCountFormatter.string(fromByteCount: Int64(values.fileSize ?? 0), countStyle: .file)) }
            if let date = values.creationDate { lines.append(RightClickStrings.text("Created") + ": " + date.formatted()) }
            if let date = values.contentModificationDate { lines.append(RightClickStrings.text("Modified") + ": " + date.formatted()) }
            lines.append("")
        }
        return lines.joined(separator: "\n")
        }.value
        let model = RightClickTaskPresentation()
        model.finished = true
        model.details = details
        model.show(title: RightClickStrings.text("File Information"))
        // The hosting view retains the model until its window is closed.
    }

    private struct IconUndo: Codable {
        var path: String
        var previous: Data?
        var expected: RightClickFileStampValue?
    }
    private struct RightClickFileStampValue: Codable {
        var inode: UInt64
        var modified: Date
        var changed: Date
        var size: UInt64
        init(_ stamp: RightClickFileStamp) { inode = stamp.inode; modified = stamp.modified; changed = stamp.changed; size = stamp.size }
        func matches(_ stamp: RightClickFileStamp) -> Bool { inode == stamp.inode && modified == stamp.modified && changed == stamp.changed && size == stamp.size }
    }
    private func iconBackupURL(_ url: URL) throws -> URL {
        let root = RightClickResourceStore().root.appendingPathComponent("OriginalIcons", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(hash + ".json")
    }
    private func captureIcon(_ url: URL) -> Data? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = getxattr(url.path, "com.apple.FinderInfo", &bytes, bytes.count, 0, XATTR_NOFOLLOW)
        let custom = count >= 10 && (UInt16(bytes[8]) << 8 | UInt16(bytes[9])) & 0x0400 != 0
        return custom ? NSWorkspace.shared.icon(forFile: url.path).tiffRepresentation : nil
    }
    private func changeIcons(_ request: RightClickRequest, selection: RightClickSelection, configuration: RightClickConfiguration) async throws {
        var image: NSImage?
        if request.action == .setIcon {
            let icons = configuration.resources.filter { $0.kind == .icon && $0.enabled }
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
            picker.addItems(withTitles: icons.map(\.name))
            guard !icons.isEmpty else { throw RightClickFailure(message: "Import a folder icon in Resources first.") }
            let alert = NSAlert()
            alert.messageText = RightClickStrings.text("Set Folder Icon")
            alert.accessoryView = picker
            alert.addButton(withTitle: RightClickStrings.text("Continue"))
            alert.addButton(withTitle: RightClickStrings.text("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let url = try RightClickResourceStore().url(for: icons[picker.indexOfSelectedItem])
            let data = try await Task.detached(priority: .userInitiated) { try Self.iconData(url) }.value
            image = NSImage(data: data)
            guard image != nil else { throw RightClickFailure(message: "Cannot decode image.") }
        }
        let progress = RightClickTaskPresentation()
        presentation = progress
        let showTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled && !progress.finished { progress.show(title: RightClickStrings.text(request.action.title)) }
        }
        var steps: [IconUndo] = []
        var result = RightClickFileResult()
        for (index, url) in selection.urls.enumerated() {
            await Task.yield()
            if progress.cancellation.isCancelled || !RightClickConfigurationStore.load().menuEnabled { result.cancelled = true; break }
            progress.update(index, total: selection.urls.count)
            do {
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw RightClickFailure(message: "Symbolic links are not supported here.") }
                let previous = captureIcon(url)
                let backupURL = try iconBackupURL(url)
                if !FileManager.default.fileExists(atPath: backupURL.path) && request.action == .setIcon {
                    try JSONEncoder().encode(IconUndo(path: url.path, previous: previous, expected: RightClickFileStampValue(try RightClickFileStamp(url, includeDescendants: false)))).write(to: backupURL, options: .withoutOverwriting)
                }
                var replacement = image
                if request.action == .restoreIcon, let data = try? Data(contentsOf: backupURL),
                   let backup = try? JSONDecoder().decode(IconUndo.self, from: data), backup.path == url.path,
                   backup.expected?.inode == (try RightClickFileStamp(url, includeDescendants: false)).inode {
                    replacement = backup.previous.flatMap(NSImage.init(data:))
                }
                guard NSWorkspace.shared.setIcon(replacement, forFile: url.path, options: []) else { throw RightClickFailure(message: "Cannot change folder icon.") }
                steps.append(IconUndo(path: url.path, previous: previous, expected: RightClickFileStampValue(try RightClickFileStamp(url, includeDescendants: false))))
                result.outputs.append(url)
            } catch { result.failures.append(url.lastPathComponent + ": " + error.localizedDescription) }
            progress.update(index + 1, total: selection.urls.count)
        }
        showTask.cancel()
        if !steps.isEmpty { iconUndo = steps; lastUndoIsIcon = true; publishUndo(true) }
        progress.finish(result)
        if !result.failures.isEmpty || result.cancelled { progress.show(title: RightClickStrings.text(request.action.title)) }
        presentation = nil
    }
    nonisolated private static func iconData(_ url: URL) throws -> Data {
        guard let input = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(input) == 1,
              let image = CGImageSourceCreateThumbnailAtIndex(input, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else { throw RightClickFailure(message: "Cannot decode image.") }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RightClickFailure(message: "Cannot encode image.")
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw RightClickFailure(message: "Cannot encode image.") }
        return data as Data
    }

    private func undoIcons() throws {
        guard !iconUndo.isEmpty else { throw RightClickFailure(message: "There is no operation to undo.") }
        for step in iconUndo {
            guard try step.expected?.matches(RightClickFileStamp(URL(fileURLWithPath: step.path), includeDescendants: false)) == true else {
                throw RightClickFailure(message: "Undo stopped because files changed or a path is occupied.", path: step.path)
            }
        }
        for step in iconUndo.reversed() {
            guard NSWorkspace.shared.setIcon(step.previous.flatMap(NSImage.init(data:)), forFile: step.path, options: []) else {
                throw RightClickFailure(message: "Cannot change folder icon.", path: step.path)
            }
            iconUndo.removeAll { $0.path == step.path }
        }
        iconUndo = []
        lastUndoIsIcon = false
    }

    nonisolated private static func isApplicationBundleOnDisk(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return path.hasSuffix(".app") && FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
    nonisolated static func bundleURLSchemes(bundle: Bundle = .main) -> Set<String> {
        guard let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else { return ["mactools"] }
        return Set(types.compactMap { $0["CFBundleURLSchemes"] as? [String] }.flatMap { $0 })
    }
}
