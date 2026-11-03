import Foundation
import MacToolsPluginKit

/// Stores one app-to-shortcut binding.
struct AppShortcutEntry: Codable, Identifiable, Equatable {
    let id: UUID
    /// The `.app` bundle's `file://` URL string.
    var bundleURLString: String
    var displayName: String
    var shortcut: ShortcutBinding?
    var portableApplicationReference: PortableApplicationReference?

    var bundleURL: URL? {
        guard !bundleURLString.isEmpty, let url = URL(string: bundleURLString), url.isFileURL,
              url.pathExtension == "app" else { return nil }
        return url
    }

    init(
        id: UUID = UUID(),
        bundleURL: URL?,
        displayName: String,
        shortcut: ShortcutBinding? = nil
    ) {
        self.id = id
        self.bundleURLString = bundleURL?.absoluteString ?? ""
        self.displayName = displayName
        self.shortcut = shortcut
        self.portableApplicationReference = nil
    }
}
