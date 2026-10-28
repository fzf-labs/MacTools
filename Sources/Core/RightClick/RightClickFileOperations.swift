import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class RightClickCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func check() throws { if isCancelled { throw CancellationError() } }
}

enum RightClickCollision: String, CaseIterable, Sendable { case keepBoth, skip, replace }
struct RightClickRenameOptions: Sendable {
    var find = ""
    var replacement = ""
    var prefix = ""
    var suffix = ""
    var numbered = false
    var start = 1
    var preserveExtension = true
    func name(for url: URL, index: Int) -> String {
        let ext = preserveExtension ? url.pathExtension : ""
        var name = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        if !find.isEmpty { name = name.replacingOccurrences(of: find, with: replacement) }
        name = prefix + name + suffix + (numbered ? " \(start + index)" : "")
        return ext.isEmpty ? name : name + "." + ext
    }
}

struct RightClickFilePlan: Sendable {
    var action: RightClickAction
    var sources: [URL]
    var destination: URL?
    var collision: RightClickCollision = .keepBoth
    var name = ""
    var fileExtension: String?
    var templateURL: URL?
    var rename = RightClickRenameOptions()
    var imageFormat = "png"
    var maximumDimension = 1600
    var iconURL: URL?
}

struct RightClickFileStamp: Equatable, Sendable {
    let inode: UInt64
    let size: UInt64
    let modified: Date
    let changed: Date
    let descendants: Data?
    init(_ url: URL, includeDescendants: Bool = true) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        modified = attributes[.modificationDate] as? Date ?? .distantPast
        var statInfo = stat()
        guard lstat(url.path, &statInfo) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        changed = Date(timeIntervalSince1970: Double(statInfo.st_ctimespec.tv_sec) + Double(statInfo.st_ctimespec.tv_nsec) / 1e9)
        if includeDescendants && attributes[.type] as? FileAttributeType == .typeDirectory {
            var entries: [String] = []
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                errorHandler: { _, error in enumerationError = error; return false }) else {
                throw RightClickFailure(message: "Cannot read folder.", path: url.path)
            }
            for case let child as URL in enumerator {
                var childStat = stat()
                guard lstat(child.path, &childStat) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
                let relative = String(child.path.dropFirst(url.path.count))
                entries.append("\(relative)|\(childStat.st_ino)|\(childStat.st_size)|\(childStat.st_mtimespec.tv_sec):\(childStat.st_mtimespec.tv_nsec)|\(childStat.st_ctimespec.tv_sec):\(childStat.st_ctimespec.tv_nsec)")
            }
            if let enumerationError { throw enumerationError }
            descendants = Data(SHA256.hash(data: Data(entries.sorted().joined(separator: "\n").utf8)))
        } else { descendants = nil }
    }
}

struct RightClickUndoMove: Sendable {
    var current: URL
    var original: URL
    var stamp: RightClickFileStamp
    /// Trashed replacement restored after reversing the transfer.
    var replacement: URL?
    var replacementStamp: RightClickFileStamp?
}
struct RightClickFileResult: Sendable {
    var outputs: [URL] = []
    var failures: [String] = []
    var skipped = 0
    var cancelled = false
    var undo: [RightClickUndoMove] = []
    var createdFolders: [URL] = []
}

/// All mutating work passes through one worker, including undo.
actor RightClickFileWorker {
    private let operations = RightClickFileOperations()
    private var undoMoves: [RightClickUndoMove] = []
    private var createdFolders: [URL] = []
    func capture(_ selection: RightClickSelection) throws -> RightClickSelection {
        try RightClickSelection.capture(urls: selection.urls, directory: selection.directory, relativeBase: selection.relativeBase)
    }
    func hasCollision(_ sources: [URL], directory: URL) -> Bool {
        sources.contains { operations.exists(directory.appendingPathComponent($0.lastPathComponent)) }
    }
    func perform(_ plan: RightClickFilePlan, cancellation: RightClickCancellation,
                 progress: @escaping @Sendable (Int, Int) -> Void) -> RightClickFileResult {
        let result = operations.perform(plan, cancellation: cancellation, progress: progress)
        if !result.undo.isEmpty { undoMoves = result.undo; createdFolders = result.createdFolders }
        return result
    }
    func undo(cancellation: RightClickCancellation) -> RightClickFileResult {
        let result = operations.undo(undoMoves, cancellation: cancellation, createdFolders: createdFolders)
        if result.failures.isEmpty && !result.cancelled { undoMoves = []; createdFolders = [] }
        return result
    }
    func undoPaths() -> [String] { undoMoves.map { $0.current.path + " → " + $0.original.path } }
    func invalidateUndo() { undoMoves = []; createdFolders = [] }
}

/// Synchronous filesystem primitives are confined to RightClickFileWorker in production.
struct RightClickFileOperations {
    var fileManager: FileManager = .default
    var copyItem: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    var trashItem: (URL) throws -> URL = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw RightClickFailure(message: "Cannot move item to Trash.", path: url.path) }
        return result as URL
    }
    var forceCopyForMove = false

    func perform(_ plan: RightClickFilePlan, cancellation: RightClickCancellation = RightClickCancellation(),
                 progress: (Int, Int) -> Void = { _, _ in }) -> RightClickFileResult {
        var result = RightClickFileResult()
        do {
            try cancellation.check()
            if plan.action == .rename { return try rename(plan, cancellation: cancellation, progress: progress) }
            if [.newFile, .newFolder].contains(plan.action) {
                let output = try create(plan)
                result.outputs = [output]
                return result
            }
            if plan.action == .zip {
                result.outputs = [try compress(plan, cancellation: cancellation)]
                return result
            }
            let sources = try normalizedSources(plan.sources)
            for (index, source) in sources.enumerated() {
                if cancellation.isCancelled { result.cancelled = true; break }
                progress(index, sources.count)
                do {
                    switch plan.action {
                    case .copyTo, .moveTo, .paste:
                        guard let directory = plan.destination else { throw RightClickFailure(message: "Choose a destination folder.") }
                        let moved = plan.action != .copyTo
                        if let transfer = try transfer(source, into: directory, collision: plan.collision,
                                                       move: moved, cancellation: cancellation) {
                            result.outputs.append(transfer.current)
                            if moved { result.undo.append(transfer) }
                        } else { result.skipped += 1 }
                    case .folderFromName:
                        let parent = source.deletingLastPathComponent()
                        let folder = availableURL(in: parent, name: source.deletingPathExtension().lastPathComponent)
                        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
                        do {
                            if let move = try transfer(source, into: folder, collision: .keepBoth, move: true, cancellation: cancellation) {
                                result.outputs.append(folder)
                                result.createdFolders.append(folder)
                                result.undo.append(move)
                            }
                        } catch {
                            if (try? fileManager.contentsOfDirectory(atPath: folder.path).isEmpty) == true { try? fileManager.removeItem(at: folder) }
                            throw error
                        }
                    case .dissolve:
                        try requireOrdinaryFolder(source)
                        let children = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                        var complete = true
                        for child in children {
                            if let move = try transfer(child, into: source.deletingLastPathComponent(), collision: plan.collision,
                                                       move: true, cancellation: cancellation) {
                                result.outputs.append(move.current)
                                result.undo.append(move)
                            } else { result.skipped += 1; complete = false }
                        }
                        if complete, try fileManager.contentsOfDirectory(atPath: source.path).isEmpty {
                            let trashed = try trashItem(source)
                            result.undo.append(RightClickUndoMove(current: trashed, original: source, stamp: try RightClickFileStamp(trashed)))
                        }
                    case .alias:
                        try rejectSymbolicLink(source)
                        let output = availableURL(in: source.deletingLastPathComponent(), name: source.lastPathComponent + " alias")
                        let bookmark = try source.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                        try URL.writeBookmarkData(bookmark, to: output)
                        result.outputs.append(output)
                    case .hide, .unhide, .hideExtension, .showExtension:
                        try rejectSymbolicLink(source)
                        var url = source
                        var values = URLResourceValues()
                        if plan.action == .hide || plan.action == .unhide { values.isHidden = plan.action == .hide }
                        else { values.hasHiddenExtension = plan.action == .hideExtension }
                        try url.setResourceValues(values)
                        result.outputs.append(source)
                    case .convertImage, .resizeImage:
                        result.outputs.append(try convertImage(source, plan: plan, cancellation: cancellation))
                    default: throw RightClickFailure(message: "Operation is not available.")
                    }
                } catch is CancellationError { result.cancelled = true; break }
                catch { result.failures.append("\(source.lastPathComponent): \(error.localizedDescription)") }
                progress(index + 1, sources.count)
            }
        } catch is CancellationError { result.cancelled = true }
        catch { result.failures.append(error.localizedDescription) }
        return result
    }

    func normalizedSources(_ urls: [URL]) throws -> [URL] {
        var result: [URL] = []
        for url in urls {
            guard url.isFileURL, url.path != "/", url.path.hasPrefix("/"), !url.path.utf8.contains(0) else {
                throw RightClickFailure(message: "Invalid file path.")
            }
            let value = url.standardizedFileURL
            _ = try RightClickFileStamp(value)
            if !result.contains(value) { result.append(value) }
        }
        // Selecting both a folder and its child must not transfer that child twice.
        return result.filter { item in
            !result.contains { parent in
                parent != item && isOrdinaryDirectory(parent) && item.path.hasPrefix(parent.path + "/")
            }
        }
    }

    func transfer(_ source: URL, into directory: URL, collision: RightClickCollision, move: Bool,
                  cancellation: RightClickCancellation = RightClickCancellation()) throws -> RightClickUndoMove? {
        try cancellation.check()
        try requireDirectory(directory)
        let sourceStamp = try RightClickFileStamp(source)
        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
        let targetPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard targetPath != sourcePath, !targetPath.hasPrefix(sourcePath + "/") else {
            throw RightClickFailure(message: "A folder cannot be placed inside itself.", path: source.path)
        }
        var destination = directory.appendingPathComponent(source.lastPathComponent)
        if move && destination.standardizedFileURL == source.standardizedFileURL {
            throw RightClickFailure(message: "The item is already in this folder.", path: source.path)
        }
        var replacement: URL?
        if exists(destination) {
            switch collision {
            case .skip: return nil
            case .keepBoth: destination = availableURL(in: directory, name: source.lastPathComponent)
            case .replace:
                guard destination.standardizedFileURL.resolvingSymlinksInPath() != source.standardizedFileURL.resolvingSymlinksInPath() else {
                    throw RightClickFailure(message: "Cannot replace an item with itself.")
                }
                replacement = try trashItem(destination)
            }
        }
        let staging = directory.appendingPathComponent(".mactools-transfer-\(UUID().uuidString)")
        var staged = false
        var committed = false
        do {
            try cancellation.check()
            if move && !forceCopyForMove && sameVolume(source, directory) {
                try fileManager.moveItem(at: source, to: staging)
                staged = true
                do { try cancellation.check(); try fileManager.moveItem(at: staging, to: destination); committed = true }
                catch {
                    try fileManager.moveItem(at: staging, to: source)
                    staged = false
                    throw error
                }
            } else {
                try copyItem(source, staging)
                staged = true
                try cancellation.check()
                guard try RightClickFileStamp(source) == sourceStamp else {
                    throw RightClickFailure(message: "The source changed during the operation.", path: source.path)
                }
                try fileManager.moveItem(at: staging, to: destination)
                committed = true
                if move {
                    do { try fileManager.removeItem(at: source) }
                    catch {
                        // The complete copy remains available if source cleanup fails.
                        throw RightClickFailure(message: "Copied, but could not remove the source. Both copies were kept.", path: destination.path)
                    }
                }
            }
            return RightClickUndoMove(current: destination, original: source, stamp: try RightClickFileStamp(destination), replacement: replacement,
                replacementStamp: try replacement.map { try RightClickFileStamp($0) })
        } catch {
            if staged && !committed && exists(staging) {
                // A same-volume move is restored rather than deleting the only copy.
                if move && !exists(source) { try? fileManager.moveItem(at: staging, to: source) }
                else { try? fileManager.removeItem(at: staging) }
            } else if !staged && exists(staging) {
                // copyItem may have left a partial destination before throwing.
                try? fileManager.removeItem(at: staging)
            }
            if let replacement, !committed {
                do { try fileManager.moveItem(at: replacement, to: destination) }
                catch {
                    throw RightClickFailure(message: "Operation failed. The previous destination is still in Trash.", path: replacement.path)
                }
            }
            throw error
        }
    }

    func undo(_ moves: [RightClickUndoMove], cancellation: RightClickCancellation = RightClickCancellation(),
              createdFolders: [URL] = []) -> RightClickFileResult {
        var result = RightClickFileResult()
        guard !moves.isEmpty else { result.failures = [RightClickStrings.text("There is no operation to undo.")]; return result }
        var staged: [(step: RightClickUndoMove, temporary: URL)] = []
        var committed: [(step: RightClickUndoMove, temporary: URL)] = []
        do {
            try cancellation.check()
            let currentPaths = Set(moves.map(\.current))
            let restoredDirectories = Set(moves.filter { isOrdinaryDirectory($0.current) }.map(\.original))
            for step in moves {
                guard try RightClickFileStamp(step.current) == step.stamp,
                      !exists(step.original) || currentPaths.contains(step.original) else {
                    throw RightClickFailure(message: "Undo stopped because files changed or a path is occupied.", path: step.original.path)
                }
                let parent = step.original.deletingLastPathComponent()
                guard isOrdinaryDirectory(parent) || restoredDirectories.contains(parent) else {
                    throw RightClickFailure(message: "The original folder is unavailable.", path: parent.path)
                }
                if let replaced = step.replacement {
                    guard try RightClickFileStamp(replaced) == step.replacementStamp else {
                        throw RightClickFailure(message: "Undo stopped because files changed or a path is occupied.", path: replaced.path)
                    }
                }
            }
            // Stage all current names before restoration, so rename cycles are safe.
            for step in moves {
                try cancellation.check()
                guard try RightClickFileStamp(step.current) == step.stamp else {
                    throw RightClickFailure(message: "Undo stopped because files changed or a path is occupied.", path: step.current.path)
                }
                let temporary = step.current.deletingLastPathComponent().appendingPathComponent(".mactools-undo-\(UUID().uuidString)")
                try fileManager.moveItem(at: step.current, to: temporary)
                staged.append((step, temporary))
            }
            // Restore dissolved parent folders before returning their children.
            for item in staged.sorted(by: { $0.step.original.pathComponents.count < $1.step.original.pathComponents.count }) {
                try cancellation.check()
                guard !exists(item.step.original) else {
                    throw RightClickFailure(message: "Undo stopped because files changed or a path is occupied.", path: item.step.original.path)
                }
                try fileManager.moveItem(at: item.temporary, to: item.step.original)
                committed.append(item)
                result.outputs.append(item.step.original)
            }
            for item in staged {
                if let replaced = item.step.replacement { try fileManager.moveItem(at: replaced, to: item.step.current) }
            }
            for folder in createdFolders where (try? fileManager.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                try fileManager.removeItem(at: folder)
            }
        } catch {
            // Recover staged or partially restored items without overwriting anything.
            var recovery: [String] = []
            for item in committed.reversed() {
                do { try fileManager.moveItem(at: item.step.original, to: item.temporary) }
                catch { recovery.append(item.step.original.path) }
            }
            for item in staged where exists(item.temporary) {
                do { try fileManager.moveItem(at: item.temporary, to: item.step.current) }
                catch { recovery.append(item.temporary.path) }
            }
            result.outputs = []
            if error is CancellationError { result.cancelled = true }
            else { result.failures.append(error.localizedDescription) }
            if !recovery.isEmpty {
                result.failures.append(RightClickStrings.text("Some files could not be restored. Review these paths.") + "\n" + recovery.joined(separator: "\n"))
            }
        }
        return result
    }

    func renamePreview(_ sources: [URL], options: RightClickRenameOptions) throws -> [(URL, URL)] {
        let sources = try normalizedSources(sources)
        let pairs = sources.enumerated().map { index, url in
            (url, url.deletingLastPathComponent().appendingPathComponent(options.name(for: url, index: index)))
        }
        var targets: Set<URL> = []
        let sourceSet = Set(sources)
        for (source, target) in pairs {
            guard RightClickResourceStore.safeComponent(target.lastPathComponent),
                  target.deletingLastPathComponent() == source.deletingLastPathComponent(),
                  targets.insert(target).inserted, !exists(target) || sourceSet.contains(target) else {
                throw RightClickFailure(message: "Resolve duplicate or invalid names before renaming.", path: target.lastPathComponent)
            }
        }
        return pairs
    }

    private func rename(_ plan: RightClickFilePlan, cancellation: RightClickCancellation,
                        progress: (Int, Int) -> Void) throws -> RightClickFileResult {
        let pairs = try renamePreview(plan.sources, options: plan.rename).filter { $0.0 != $0.1 }
        var staged: [(source: URL, temporary: URL, target: URL)] = []
        var committed: [(source: URL, target: URL)] = []
        do {
            for (index, pair) in pairs.enumerated() {
                try cancellation.check()
                let temporary = pair.0.deletingLastPathComponent().appendingPathComponent(".mactools-rename-\(UUID().uuidString)")
                try fileManager.moveItem(at: pair.0, to: temporary)
                staged.append((pair.0, temporary, pair.1))
                progress(index, pairs.count)
            }
            for item in staged {
                try cancellation.check()
                try fileManager.moveItem(at: item.temporary, to: item.target)
                committed.append((item.source, item.target))
                progress(committed.count, pairs.count)
            }
        } catch {
            // Return all committed names to their temporary paths first, allowing swaps.
            var recoveryFailures: [String] = []
            for item in staged where committed.contains(where: { $0.target == item.target }) {
                do { try fileManager.moveItem(at: item.target, to: item.temporary) }
                catch { recoveryFailures.append(item.target.path) }
            }
            for item in staged where exists(item.temporary) {
                do { try fileManager.moveItem(at: item.temporary, to: item.source) }
                catch { recoveryFailures.append(item.temporary.path) }
            }
            if !recoveryFailures.isEmpty {
                throw RightClickFailure(message: "Some files could not be restored. Review these paths.", path: recoveryFailures.joined(separator: "\n"))
            }
            throw error
        }
        return RightClickFileResult(outputs: committed.map(\.target), undo: try committed.map {
            RightClickUndoMove(current: $0.target, original: $0.source, stamp: try RightClickFileStamp($0.target))
        })
    }

    private func create(_ plan: RightClickFilePlan) throws -> URL {
        guard let directory = plan.destination else { throw RightClickFailure(message: "Choose a destination folder.") }
        try requireDirectory(directory)
        let name = plan.name.isEmpty ? RightClickStrings.text(plan.action == .newFolder ? "New Folder" : "Untitled") : plan.name
        guard RightClickResourceStore.safeComponent(name), name.utf8.count <= 240 else { throw RightClickFailure(message: "Enter a valid file name.") }
        var filename = name
        if plan.action == .newFile, let ext = plan.fileExtension {
            guard RightClickNewFile.isSupportedExtension(ext) || plan.templateURL != nil else {
                throw RightClickFailure(message: "Unsupported file type.")
            }
            if !ext.isEmpty && !filename.lowercased().hasSuffix("." + ext.lowercased()) { filename += "." + ext }
        }
        let target = availableURL(in: directory, name: filename)
        if plan.action == .newFolder {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
        } else if let template = plan.templateURL {
            try rejectSymbolicLink(template)
            let values = try template.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values.isDirectory != true || values.isPackage == true else {
                throw RightClickFailure(message: "Choose a file or a document package.")
            }
            let temporary = directory.appendingPathComponent(".mactools-create-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: temporary) }
            try fileManager.copyItem(at: template, to: temporary)
            try fileManager.moveItem(at: temporary, to: target)
        } else { try Data().write(to: target, options: .withoutOverwriting) }
        return target
    }

    private func convertImage(_ source: URL, plan: RightClickFilePlan, cancellation: RightClickCancellation) throws -> URL {
        try rejectSymbolicLink(source)
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(input) == 1 else {
            throw RightClickFailure(message: "Choose a supported single-frame image.")
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32768, height <= 32768,
              Int64(width) * Int64(height) <= 100_000_000 else {
            throw RightClickFailure(message: "Image dimensions are not supported.")
        }
        let format = plan.action == .resizeImage ? source.pathExtension.lowercased() : plan.imageFormat
        let type: UTType
        switch format {
        case "png": type = .png
        case "jpg", "jpeg": type = .jpeg
        case "heic": type = .heic
        case "tif", "tiff": type = .tiff
        default: throw RightClickFailure(message: "Unsupported output format.")
        }
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(type.identifier) == true else {
            throw RightClickFailure(message: "This image encoder is unavailable.")
        }
        try cancellation.check()
        let bound = plan.action == .resizeImage ? min(max(width, height), max(1, plan.maximumDimension)) : max(width, height)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: bound]
        guard var image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else {
            throw RightClickFailure(message: "Cannot decode image.")
        }
        if type == .jpeg, let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.fill(rect); context.draw(image, in: rect)
            if let flattened = context.makeImage() { image = flattened }
        }
        let suffix = plan.action == .resizeImage ? "-resized" : "-converted"
        let target = availableURL(in: source.deletingLastPathComponent(), name: source.deletingPathExtension().lastPathComponent + suffix + "." + format)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".mactools-image-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        guard let output = CGImageDestinationCreateWithURL(temporary as CFURL, type.identifier as CFString, 1, nil) else {
            throw RightClickFailure(message: "Cannot create image.")
        }
        var metadata = properties
        metadata[kCGImagePropertyOrientation] = 1
        metadata[kCGImagePropertyPixelWidth] = image.width
        metadata[kCGImagePropertyPixelHeight] = image.height
        if var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        metadata[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImage(output, image, metadata as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw RightClickFailure(message: "Cannot encode image.") }
        try cancellation.check()
        try fileManager.moveItem(at: temporary, to: target)
        return target
    }

    private func compress(_ plan: RightClickFilePlan, cancellation: RightClickCancellation) throws -> URL {
        let sources = try normalizedSources(plan.sources)
        guard !sources.isEmpty else { throw RightClickFailure(message: "Select files first.") }
        let directory = plan.destination ?? sources[0].deletingLastPathComponent()
        try requireDirectory(directory)
        let archiveName = plan.name.isEmpty ? RightClickStrings.text("Archive") : plan.name
        guard RightClickResourceStore.safeComponent(archiveName) else { throw RightClickFailure(message: "Enter a valid file name.") }
        let directoryPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard !sources.contains(where: {
            let path = $0.standardizedFileURL.resolvingSymlinksInPath().path
            return directoryPath == path || directoryPath.hasPrefix(path + "/")
        }) else { throw RightClickFailure(message: "A folder cannot be placed inside itself.") }
        let target = availableURL(in: directory, name: archiveName + ".zip")
        let stagingRoot = directory.appendingPathComponent(".mactools-zip-\(UUID().uuidString)", isDirectory: true)
        let staging = stagingRoot.appendingPathComponent("Archive", isDirectory: true)
        let temporary = directory.appendingPathComponent(".mactools-zip-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingRoot); try? fileManager.removeItem(at: temporary) }
        for source in sources {
            try cancellation.check()
            try fileManager.copyItem(at: source, to: availableURL(in: staging, name: source.lastPathComponent))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, temporary.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(600)
        while process.isRunning {
            if cancellation.isCancelled || Date() >= deadline {
                process.terminate()
                let terminationDeadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < terminationDeadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                if cancellation.isCancelled { throw CancellationError() }
                throw RightClickFailure(message: "Compression timed out.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.terminationStatus == 0 else { throw RightClickFailure(message: "Cannot create ZIP archive.") }
        try cancellation.check()
        try fileManager.moveItem(at: temporary, to: target)
        return target
    }

    func availableURL(in directory: URL, name: String) -> URL {
        let path = URL(fileURLWithPath: name)
        let ext = path.pathExtension
        let stem = ext.isEmpty ? name : path.deletingPathExtension().lastPathComponent
        var result = directory.appendingPathComponent(name)
        var index = 2
        while exists(result) {
            result = directory.appendingPathComponent(stem + " \(index)" + (ext.isEmpty ? "" : ".\(ext)"))
            index += 1
        }
        return result
    }
    func exists(_ url: URL) -> Bool { (try? fileManager.attributesOfItem(atPath: url.path)) != nil }
    private func sameVolume(_ source: URL, _ target: URL) -> Bool {
        let a = try? fileManager.attributesOfItem(atPath: source.path)[.systemNumber] as? NSNumber
        let b = try? fileManager.attributesOfItem(atPath: target.path)[.systemNumber] as? NSNumber
        return a != nil && a == b
    }
    private func isOrdinaryDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }
    private func requireDirectory(_ url: URL) throws {
        guard isOrdinaryDirectory(url), (try url.resourceValues(forKeys: [.isPackageKey])).isPackage != true else { throw RightClickFailure(message: "Folder is unavailable.", path: url.path) }
    }
    private func requireOrdinaryFolder(_ url: URL) throws {
        try requireDirectory(url)
        guard try url.resourceValues(forKeys: [.isPackageKey]).isPackage != true else {
            throw RightClickFailure(message: "Document packages cannot be dissolved.", path: url.path)
        }
    }
    private func rejectSymbolicLink(_ url: URL) throws {
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw RightClickFailure(message: "Symbolic links are not supported here.", path: url.path)
        }
    }
}
