import Foundation
import MacToolsPluginKit

/// Pure, thread-safe application enumeration.
///
/// Design notes (validated on macOS 26.5.1 + cross-reviewed):
/// - Recursive directory scan, NOT Spotlight (`NSMetadataQuery` is unreliable when
///   Spotlight is disabled/excluded/reindexing) and NOT any private LaunchServices API
///   (no public "list all apps" API exists). Requires the host to be non-sandboxed.
/// - Includes `/System/Cryptexes/App/System/Applications` so cryptex-delivered system
///   apps (Safari, etc.) are not missed.
/// - `.skipsPackageDescendants` stops the enumerator from descending into `.app`
///   bundles; the `isNestedInsideAnotherApp` guard is cheap belt-and-suspenders for
///   helper/XPC apps embedded in another bundle.
/// - No name / bundle-id / "com.apple" denylist: only nested helpers and non-package
///   directories are excluded, so legitimately-named apps (including Tahoe's
///   `com.apple.apps.launcher`) are kept.
/// - Validity check uses `isDirectory` (a real `.app` is a package directory) instead
///   of `NSWorkspace`, keeping this type free of main-actor isolation so the scan can
///   run off the main thread.
enum ApplicationScanner {
    /// Standard install locations. Non-existent roots are skipped.
    static let defaultSearchRoots: [String] = [
        "/Applications",
        NSHomeDirectory() + "/Applications",
        "/System/Applications",
        "/System/Cryptexes/App/System/Applications",
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
        "/System/Library/CoreServices/Applications",
        "/System/Library/CoreServices/Finder.app",
    ]

    static func scan(
        roots: [String] = defaultSearchRoots,
        fileManager: FileManager = .default
    ) -> [ApplicationCatalogItem] {
        var seen = Set<String>()
        var items: [ApplicationCatalogItem] = []

        for root in roots where fileManager.fileExists(atPath: root) {
            let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
            if rootURL.pathExtension == "app" {
                if isValidAppBundle(at: rootURL.path, fileManager: fileManager), seen.insert(rootURL.path).inserted {
                    let names = applicationNames(for: rootURL, fileManager: fileManager)
                    items.append(.init(id: rootURL.path, name: names.name, url: rootURL, alternateNames: names.alternates))
                }
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                // Keep scanning past unreadable/transient entries instead of aborting.
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension == "app" {
                let resolved = url.resolvingSymlinksInPath()
                let path = resolved.path
                guard isValidAppBundle(at: path, fileManager: fileManager),
                      !isNestedInsideAnotherApp(resolved),
                      seen.insert(path).inserted else { continue }
                let names = applicationNames(for: resolved, fileManager: fileManager)
                items.append(ApplicationCatalogItem(id: path, name: names.name, url: resolved, alternateNames: names.alternates))
            }
        }

        // Sort by localized name; tie-break on the stable path id so apps with the
        // same display name (e.g. one in /Applications, one in ~/Applications) keep a
        // deterministic order (Swift's sort is not guaranteed stable).
        return items.sorted {
            switch $0.name.localizedCaseInsensitiveCompare($1.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return $0.id < $1.id
            }
        }
    }

    /// A real `.app` is a package directory that contains `Contents/Info.plist`.
    /// Requiring the Info.plist (which every real bundle has) rejects corrupt or
    /// placeholder directories merely named `X.app`, without dropping legitimate apps
    /// — and stays main-actor-free (no `NSWorkspace`) so the scan runs off-main.
    static func isValidAppBundle(at path: String, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return fileManager.fileExists(atPath: (path as NSString).appendingPathComponent("Contents/Info.plist"))
    }

    /// Excludes helper/XPC/login-item apps embedded inside another `.app`
    /// (e.g. `Foo.app/Contents/.../Bar.app` has two `.app` path segments).
    static func isNestedInsideAnotherApp(_ url: URL) -> Bool {
        url.pathComponents.filter { $0.hasSuffix(".app") }.count > 1
    }

    static func displayName(for url: URL, fileManager: FileManager = .default) -> String {
        strippedAppSuffix(fileManager.displayName(atPath: url.path))
    }

    /// System apps commonly keep localized names in loctables rather than InfoPlist.strings.
    /// Read only preferred system languages plus English; other installed translations are not search aliases.
    static func applicationNames(for url: URL, preferredLanguages: [String]? = nil,
                                 fileManager: FileManager = .default) -> (name: String, alternates: [String]) {
        LauncherBundleNames.read(for: url, fallbackName: displayName(for: url, fileManager: fileManager),
            preferredLanguages: preferredLanguages, fileManager: fileManager)
    }

    /// Removes only a trailing `.app` suffix — NOT every occurrence — so an app whose
    /// localized name legitimately contains ".app" is not mangled.
    static func strippedAppSuffix(_ name: String) -> String {
        name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}


import AppKit
import Combine
import CoreServices

@MainActor
final class ApplicationCatalog: ObservableObject {
    @Published private(set) var items: [ApplicationCatalogItem] = []
    @Published private(set) var isRefreshing = false
    private var task: Task<Void, Never>?
    private var generation = 0
    private var hasLoadedSnapshot = false
    private var stream: FSEventStreamRef?
    private let defaults: UserDefaults
    private let defaultSearchRoots: [String]
    private let scan: @Sendable ([String]) -> [ApplicationCatalogItem]
    private let observesChanges: Bool
    @Published private(set) var additionalSearchRoots: [String]
    static let scopesKey = "launcher.application-search-scopes.v1"
    init(defaults: UserDefaults = .standard, defaultSearchRoots: [String] = ApplicationScanner.defaultSearchRoots,
         observesChanges: Bool = true,
         scan: @escaping @Sendable ([String]) -> [ApplicationCatalogItem] = { ApplicationScanner.scan(roots: $0) }) {
        self.defaults = defaults
        self.defaultSearchRoots = defaultSearchRoots
        self.observesChanges = observesChanges
        self.scan = scan
        additionalSearchRoots = defaults.stringArray(forKey: Self.scopesKey) ?? []
    }
    var searchRoots: [String] { defaultSearchRoots + additionalSearchRoots }
    @discardableResult
    func addSearchRoot(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue,
              url.pathExtension != "app" || ApplicationScanner.isValidAppBundle(at: path) else { return false }
        guard !searchRoots.contains(path) else { return true }
        additionalSearchRoots.append(path)
        persistScopes(); return true
    }
    func removeSearchRoot(_ path: String) {
        additionalSearchRoots.removeAll { $0 == path }; persistScopes()
    }
    private func persistScopes() {
        defaults.set(additionalSearchRoots, forKey: Self.scopesKey)
        stopWatching(); if isObserving { startWatching() }; refresh()
    }
    private var observers: [NSObjectProtocol] = []
    private let icons = NSCache<NSString, NSImage>()
    func icon(for application: ApplicationCatalogItem) -> NSImage {
        let key = application.id as NSString
        if let image = icons.object(forKey: key) { return image }
        let image = NSWorkspace.shared.icon(forFile: application.url.path)
        icons.countLimit = 512; icons.setObject(image, forKey: key); return image
    }
    var onChange: (() -> Void)?

    private var isObserving = false
    private func startObserving() {
        guard observesChanges, !isObserving else { return }; isObserving = true
        startWatching()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() }
            })
        }
    }
    private func startWatching() {
        let paths = searchRoots.map { path in
            path.hasSuffix(".app") ? URL(fileURLWithPath: path).deletingLastPathComponent().path : path
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            MainActor.assumeIsolated {
                Unmanaged<ApplicationCatalog>.fromOpaque(info).takeUnretainedValue().refresh()
            }
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if !FSEventStreamStart(stream) { stopWatching() }
        }
    }
    private func stopWatching() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil
    }
    isolated deinit {
        task?.cancel(); stopWatching()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
    /// Page navigation consumes the existing snapshot; only first use, explicit refresh, or filesystem events scan.
    @discardableResult
    func loadIfNeeded() -> Bool {
        guard !hasLoadedSnapshot, task == nil else { return false }
        refresh()
        return true
    }
    func refresh() {
        startObserving()
        generation += 1; let revision = generation; task?.cancel()
        isRefreshing = true
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let roots = searchRoots, scan = scan
            let items = await Task.detached { scan(roots) }.value
            guard !Task.isCancelled, revision == generation else { return }
            icons.removeAllObjects(); hasLoadedSnapshot = true; task = nil; self.items = items
            isRefreshing = false; onChange?()
        }
    }
    var context: ApplicationCatalogHostContext {
        .init(snapshot: { [weak self] in self?.items ?? [] }, refresh: { [weak self] in self?.refresh() })
    }
}
