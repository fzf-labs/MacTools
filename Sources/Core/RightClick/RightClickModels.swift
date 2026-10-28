import Foundation

/// New-file types the right-click menu may create. A strict allow list keeps the
/// feature to its intended types and — because the host's URL scheme can be
/// invoked by any process — prevents path traversal through the `ext` parameter.
enum RightClickNewFile {
    /// Keep this list concise because every entry appears in the Finder submenu.
    /// Binary media and template-based formats are intentionally omitted because
    /// this feature creates zero-byte files rather than usable encoded content.
    static let supportedExtensions: [String] = [
        "txt", "md", "csv",
        "json", "yaml", "yml", "xml",
        "html", "css", "js", "ts",
        "sh", "py"
    ]

    static func isSupportedExtension(_ ext: String) -> Bool {
        supportedExtensions.contains(ext.lowercased())
    }
}

enum RightClickCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case create, organize, open, copy, tools
    var id: String { rawValue }
    var title: String {
        switch self {
        case .create: "Create"
        case .organize: "Organize Files"
        case .open: "Open and Go"
        case .copy: "Copy Information"
        case .tools: "File Tools"
        }
    }
    var symbol: String {
        switch self {
        case .create: "doc.badge.plus"
        case .organize: "folder"
        case .open: "arrow.up.forward.app"
        case .copy: "doc.on.doc"
        case .tools: "wrench.and.screwdriver"
        }
    }
}

enum RightClickAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case newFolder = "new-folder", newFile = "new-file"
    case copyTo = "copy-to", moveTo = "move-to", cut, paste, folderFromName = "folder-from-name"
    case dissolve, rename, alias, undo
    case openPreferred = "open-preferred", openWith = "open-with", terminal = "open-terminal"
    case goTo = "go-to", addLocation = "add-location"
    case copyName = "copy-file-name", copyPath = "copy-absolute-path", copyRelative = "copy-relative-path"
    case copyShell = "copy-shell-escaped-path", copyURL = "copy-file-url"
    case info, hide, unhide, hideExtension = "hide-extension", showExtension = "show-extension"
    case convertImage = "convert-image", resizeImage = "resize-image", setIcon = "set-icon", restoreIcon = "restore-icon"
    case zip, extract
    var id: String { rawValue }
    var category: RightClickCategory {
        switch self {
        case .newFolder, .newFile: .create
        case .copyTo, .moveTo, .cut, .paste, .folderFromName, .dissolve, .rename, .alias, .undo: .organize
        case .openPreferred, .openWith, .terminal, .goTo, .addLocation: .open
        case .copyName, .copyPath, .copyRelative, .copyShell, .copyURL: .copy
        default: .tools
        }
    }
    var title: String {
        switch self {
        case .newFolder: "New Folder"
        case .newFile: "New File"
        case .copyTo: "Copy To"
        case .moveTo: "Move To"
        case .cut: "Cut Files"
        case .paste: "Move Here"
        case .folderFromName: "Create Folder from Name"
        case .dissolve: "Dissolve Folder"
        case .rename: "Batch Rename"
        case .alias: "Create Alias"
        case .undo: "Undo Last File Operation"
        case .openPreferred: "Open with Preferred App"
        case .openWith: "Open With"
        case .terminal: "Open in Terminal"
        case .goTo: "Go to Location"
        case .addLocation: "Add to Locations"
        case .copyName: "Copy File Name"
        case .copyPath: "Copy Absolute Path"
        case .copyRelative: "Copy Relative Path"
        case .copyShell: "Copy Shell-Escaped Path"
        case .copyURL: "Copy File URL"
        case .info: "File Information"
        case .hide: "Hide Selected Items"
        case .unhide: "Unhide Selected Items"
        case .hideExtension: "Hide Extension"
        case .showExtension: "Show Extension"
        case .convertImage: "Convert Images"
        case .resizeImage: "Resize Images"
        case .setIcon: "Set Folder Icon"
        case .restoreIcon: "Restore Folder Icon"
        case .zip: "Compress to ZIP"
        case .extract: "Open in Archive Utility"
        }
    }
    var symbol: String {
        switch self {
        case .newFile: "doc.badge.plus"
        case .newFolder, .folderFromName: "folder.badge.plus"
        case .copyTo, .copyName, .copyPath, .copyRelative, .copyShell, .copyURL: "doc.on.doc"
        case .moveTo, .paste: "arrow.right"
        case .cut: "scissors"
        case .undo: "arrow.uturn.backward"
        case .rename: "pencil"
        case .dissolve: "folder.badge.minus"
        case .alias: "arrowshape.turn.up.right"
        case .terminal: "terminal"
        case .openPreferred, .openWith: "app"
        case .goTo: "folder"
        case .addLocation: "folder.badge.plus"
        case .info: "info.circle"
        case .hide, .hideExtension: "eye.slash"
        case .unhide, .showExtension: "eye"
        case .convertImage, .resizeImage: "photo"
        case .setIcon, .restoreIcon: "folder.fill"
        case .zip, .extract: "archivebox"
        }
    }
    var isCopyInformation: Bool { category == .copy }
    var requiresConfirmation: Bool {
        [.moveTo, .paste, .folderFromName, .dissolve, .rename, .hide, .unhide,
         .hideExtension, .showExtension, .setIcon, .restoreIcon, .undo].contains(self)
    }
}

struct RightClickLocation: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var path: String
    static var defaults: [Self] {
        [("Desktop", "Desktop"), ("Downloads", "Downloads"), ("Documents", "Documents")].map {
            Self(name: RightClickStrings.text($0.0), path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0.1).path)
        }
    }
}

enum RightClickAppScope: String, Codable, CaseIterable, Sendable { case all, files, folders }
enum RightClickTerminal: String, Codable, CaseIterable, Sendable {
    case terminal, warp, iterm
    var title: String { switch self { case .terminal: "Terminal"; case .warp: "Warp"; case .iterm: "iTerm2" } }
    var bundleID: String {
        switch self { case .terminal: "com.apple.Terminal"; case .warp: "dev.warp.Warp-Stable"; case .iterm: "com.googlecode.iterm2" }
    }
}

struct RightClickResource: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case template, icon }
    var id = UUID()
    var name: String
    var kind: Kind
    var filename: String
    var enabled = true
}

struct RightClickSelectionItem: Codable, Equatable, Sendable {
    var url: URL
    var isDirectory: Bool
    var isPackage: Bool = false
    var isImage: Bool = false
}

struct RightClickSelection: Codable, Equatable, Sendable {
    var items: [RightClickSelectionItem] = []
    var directory: URL?
    var relativeBase: URL?
    var urls: [URL] { items.map(\.url) }
    var allFolders: Bool { !items.isEmpty && items.allSatisfy { $0.isDirectory && !$0.isPackage } }
    var allImages: Bool { !items.isEmpty && items.allSatisfy(\.isImage) }
    var terminalDirectory: URL? {
        if items.count == 1, let item = items.first {
            return item.isDirectory && !item.isPackage ? item.url : item.url.deletingLastPathComponent()
        }
        return directory
    }
}

struct RightClickRequest: Codable, Equatable, Sendable {
    static let currentVersion = 2
    var version = Self.currentVersion
    var action: RightClickAction
    var selection: RightClickSelection
    var resourceID: UUID?
    var fileExtension: String?
    func url(scheme: String) -> URL? {
        guard let data = try? JSONEncoder().encode(self), data.count <= 262_144 else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "right-click"
        parts.path = "/perform"
        parts.queryItems = [URLQueryItem(name: "request", value: data.base64EncodedString())]
        return parts.url
    }
    static func decode(_ url: URL) -> Self? {
        guard url.host == "right-click", url.path == "/perform",
              url.absoluteString.utf8.count <= 400_000,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "request" })?.value,
              let data = Data(base64Encoded: value), data.count <= 262_144,
              let request = try? JSONDecoder().decode(Self.self, from: data), request.version == Self.currentVersion,
              request.selection.items.count <= 1000,
              request.selection.items.allSatisfy({ validFileURL($0.url) }),
              request.selection.directory.map(validFileURL) ?? true,
              request.selection.relativeBase.map(validFileURL) ?? true
        else { return nil }
        return request
    }
    private static func validFileURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
            && url.path.hasPrefix("/") && !url.path.utf8.contains(0)
    }
}

struct RightClickMenuEntry: Equatable, Sendable {
    var title: String
    var symbol: String
    var request: RightClickRequest?
    var children: [Self] = []
    var category: RightClickCategory?
}

/// Pure menu derivation also drives settings previews; it never scans disk.
enum RightClickMenuBuilder {
    static func entries(configuration: RightClickConfiguration, selection: RightClickSelection,
                        localize: (String) -> String = { $0 }) -> [RightClickMenuEntry] {
        guard configuration.menuEnabled else { return [] }
        var groups: [RightClickMenuEntry] = []
        for category in configuration.orderedCategories {
            var children: [RightClickMenuEntry] = []
            for action in configuration.orderedActions where action.category == category {
                guard configuration.isEnabled(action),
                      applicable(action, selection: selection) else { continue }
                if action == .undo && !configuration.undoAvailable { continue }
                var entry = RightClickMenuEntry(title: localize(action.title), symbol: action.symbol,
                    request: RightClickRequest(action: action, selection: selection), category: category)
                switch action {
                case .newFile:
                    entry.children = configuration.enabledFileExtensions.map { ext in
                        RightClickMenuEntry(title: ".\(ext)", symbol: "doc", request: RightClickRequest(action: action, selection: selection, fileExtension: ext))
                    }
                    entry.children += configuration.resources.filter { $0.kind == .template && $0.enabled }.map {
                        RightClickMenuEntry(title: $0.name, symbol: "doc", request: RightClickRequest(action: action, selection: selection, resourceID: $0.id))
                    }
                case .copyTo, .moveTo, .goTo:
                    entry.children = configuration.locations.map {
                        RightClickMenuEntry(title: $0.name, symbol: "folder", request: RightClickRequest(action: action, selection: selection, resourceID: $0.id))
                    }
                case .openWith, .openPreferred:
                    let targets = selection.items.isEmpty ? selection.directory.map { [RightClickSelectionItem(url: $0, isDirectory: true)] } ?? [] : selection.items
                    let apps = configuration.openWithApps.filter { app in targets.contains { app.matches($0) } }
                    if action == .openPreferred {
                        guard let app = apps.first(where: { $0.id == configuration.preferredAppID }) else { continue }
                        entry.request?.resourceID = app.id
                    } else {
                        entry.children = apps.map {
                            RightClickMenuEntry(title: $0.name, symbol: "app", request: RightClickRequest(action: action, selection: selection, resourceID: $0.id))
                        }
                    }
                default: break
                }
                if [.newFile, .copyTo, .moveTo, .goTo, .openWith].contains(action), entry.children.isEmpty { continue }
                if !entry.children.isEmpty { entry.request = nil }
                children.append(entry)
            }
            if !children.isEmpty {
                groups.append(RightClickMenuEntry(title: localize(category.title), symbol: category.symbol,
                    children: children, category: category))
            }
        }
        return groups
    }
    static func applicable(_ action: RightClickAction, selection: RightClickSelection) -> Bool {
        switch action {
        case .newFile, .newFolder, .paste: selection.directory != nil
        case .terminal: selection.terminalDirectory != nil
        case .goTo, .undo: selection.directory != nil || !selection.items.isEmpty
        case .copyName, .copyTo, .moveTo, .cut, .rename, .folderFromName, .alias, .info, .zip, .hide, .unhide:
            !selection.items.isEmpty
        case .copyPath, .copyRelative, .copyShell, .copyURL: selection.directory != nil || !selection.items.isEmpty
        case .openPreferred, .openWith: !selection.items.isEmpty || selection.directory != nil
        case .dissolve, .setIcon, .restoreIcon: selection.allFolders
        case .addLocation: selection.allFolders && selection.items.count == 1
        case .convertImage, .resizeImage: selection.allImages
        case .hideExtension, .showExtension: !selection.items.isEmpty && selection.items.allSatisfy { !$0.isDirectory }
        case .extract: !selection.items.isEmpty && selection.items.allSatisfy { !$0.isDirectory && ["zip", "tar", "gz", "bz2", "xz"].contains($0.url.pathExtension.lowercased()) }
        }
    }
}
