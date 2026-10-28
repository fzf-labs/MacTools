import Foundation

/// Shared state for the MacTools Finder right-click menu.
///
/// The host app writes both user preferences and the lightweight lifecycle gate
/// (`menuEnabled`). The sandboxed extension reads the same file to decide
/// whether to show anything, then which items to include.
///
/// This type is compiled into BOTH the host app and the extension targets (they
/// can't import each other); the JSON written by one is decoded by the other.
struct RightClickConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3
    var schemaVersion = Self.currentSchemaVersion
    var menuEnabled = false
    var preferredLanguages: [String]?
    var undoAvailable = false
    var enabledActions: Set<RightClickAction> = [
        .newFolder, .newFile, .terminal, .openWith,
        .copyName, .copyPath, .copyRelative, .copyShell, .copyURL,
        .copyTo, .moveTo, .goTo, .undo
    ]
    var categoryOrder = RightClickCategory.allCases
    var actionOrder = RightClickAction.allCases
    var locations = RightClickLocation.defaults
    var resources: [RightClickResource] = []
    var openWithApps: [RightClickOpenWithApp] = []
    var preferredAppID: UUID?
    var terminal = RightClickTerminal.terminal
    var terminalNewTab = false
    var enabledFileExtensions = RightClickNewFile.supportedExtensions
    var showIcons = true
    var askForName = false
    var openAfterCreating = false

    func isEnabled(_ action: RightClickAction) -> Bool { enabledActions.contains(action) }

    mutating func setEnabled(_ action: RightClickAction, _ value: Bool) {
        if value { enabledActions.insert(action) } else { enabledActions.remove(action) }
    }

    var orderedCategories: [RightClickCategory] { Self.unique(categoryOrder + RightClickCategory.allCases) }
    var orderedActions: [RightClickAction] { Self.unique(actionOrder + RightClickAction.allCases) }
    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    /// Missing or invalid configuration keeps Finder menus inactive.
    static let inactiveDefault = RightClickConfiguration()
    static let activeDefault = RightClickConfiguration(menuEnabled: true)
}

/// A user-configured "open with" application entry.
struct RightClickOpenWithApp: Codable, Equatable, Identifiable, Sendable {
    var scope: RightClickAppScope = .all
    var id: UUID
    var name: String
    var appPath: String
    /// Lowercased file extensions this entry applies to; empty = all files.
    var fileExtensions: [String]

    init(id: UUID = UUID(), name: String, appPath: String, fileExtensions: [String] = []) {
        self.id = id
        self.name = name
        self.appPath = appPath
        self.fileExtensions = fileExtensions
    }

    func matches(_ item: RightClickSelectionItem) -> Bool {
        if scope == .files && item.isDirectory { return false }
        if scope == .folders && !item.isDirectory { return false }
        return matches(fileExtension: item.url.pathExtension)
    }

    /// Whether this entry should appear for a file with the given (lowercased)
    /// extension. An empty `fileExtensions` matches everything.
    func matches(fileExtension ext: String) -> Bool {
        fileExtensions.isEmpty || fileExtensions.contains(ext.lowercased())
    }
}

/// Reads/writes `RightClickConfiguration` via a JSON file under the user's real
/// home directory.
///
/// Why a plain file at the real home — and neither an app group nor
/// `UserDefaults(suiteName:)`: the non-sandboxed host app is denied write access
/// to the app group container (containermanagerd), and the host's cfprefsd
/// domain is separate from the sandboxed extension's, so neither bridges the
/// boundary. The host writes a file it can write (its real Application Support),
/// and the sandboxed extension reads it through a read-only
/// `temporary-exception.files.home-relative-path` entitlement. Both sides resolve
/// the real home via `getpwuid` and read the same relative path from Info.plist,
/// so Release and Debug builds do not accidentally share Finder Sync settings.
enum RightClickConfigurationStore {
    /// Real user home directory, bypassing the sandbox container redirection so
    /// the host app and the sandboxed extension resolve the exact same file.
    private static let realHomeDirectory: String = {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return String(cString: home)
        }
        return NSHomeDirectory()
    }()

    /// File path relative to the real home. The extension's read-only
    /// `home-relative-path` entitlement must stay in sync with this build setting.
    static var configFileHomeRelativePath: String {
        if let path = Bundle.main.object(forInfoDictionaryKey: "MTRightClickConfigurationHomeRelativePath") as? String,
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return path
        }
        return "Library/Application Support/MacTools/right-click-menu.json"
    }

    static var configFileURL: URL {
        URL(fileURLWithPath: realHomeDirectory)
            .appendingPathComponent(configFileHomeRelativePath)
    }

    static func load(from fileURL: URL = configFileURL) -> RightClickConfiguration {
        guard let data = try? Data(contentsOf: fileURL),
              let configuration = try? JSONDecoder().decode(RightClickConfiguration.self, from: data),
              configuration.schemaVersion == RightClickConfiguration.currentSchemaVersion
        else {
            return .inactiveDefault
        }
        return configuration
    }

    static func setMenuEnabled(_ enabled: Bool, fileURL: URL = configFileURL) {
        var configuration = load(from: fileURL)
        if enabled, configuration == .inactiveDefault {
            configuration = .activeDefault
        }
        configuration.undoAvailable = false
        configuration.menuEnabled = enabled
        _ = save(configuration, to: fileURL)
    }

    @discardableResult
    static func save(_ configuration: RightClickConfiguration, to fileURL: URL = configFileURL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(configuration)
            try data.write(to: fileURL, options: .atomic)
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("MacTools.RightClickConfigurationChanged"), object: fileURL.path, userInfo: nil, deliverImmediately: true
            )
            return true
        } catch {
            return false
        }
    }
}
