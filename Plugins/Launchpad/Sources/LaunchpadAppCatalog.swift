import AppKit
import Combine
import MacToolsPluginKit

/// Owns the app list + icon cache for the launcher UI.
///
/// - `reload()` runs the (pure, off-main) scan and publishes the result, guarded by a
///   generation token so a slow earlier scan can't overwrite a newer one (Codex #9).
/// - `icon(for:)` is a synchronous, cached `NSWorkspace.icon(forFile:)` lookup. The
///   real-machine measurement (~47ms for 147 icons) showed sync loading is fine at v1
///   scale; `NSCache` (memory-pressure aware) avoids re-decoding on every open.
@MainActor
final class LaunchpadAppCatalog: ObservableObject {
    @Published private(set) var apps: [LaunchpadAppItem] = []
    @Published private(set) var isLoading = false

    private let iconCache = NSCache<NSString, NSImage>()
    private var reloadGeneration = 0

    init() {
        iconCache.countLimit = 512
    }

    /// Rescans installed apps. Call right before showing the launcher.
    var hostContext: ApplicationCatalogHostContext?
    func reload() {
        hostContext?.refresh()
        receiveHostSnapshot()
    }
    func receiveHostSnapshot() {
        guard let hostContext else { return }
        apps = hostContext.snapshot().map { .init(id: $0.id, name: $0.name, url: $0.url) }
        isLoading = apps.isEmpty
    }

    func icon(for app: LaunchpadAppItem) -> NSImage {
        let key = app.id as NSString
        if let cached = iconCache.object(forKey: key) {
            return cached
        }
        // Don't mutate `.size`: `icon(forFile:)` can hand back a shared NSImage and the
        // mutation would leak across callers (Codex P2). The cell scales via SwiftUI
        // `.resizable().frame(...)` instead.
        let image = NSWorkspace.shared.icon(forFile: app.url.path)
        iconCache.setObject(image, forKey: key)
        return image
    }
}
