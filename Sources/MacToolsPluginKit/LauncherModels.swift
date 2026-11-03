import Foundation

/// The semantic role of an existing canonical action in launcher search.
public enum LauncherActionRole: String, Hashable, Sendable {
    case systemOperation
    case pluginFeature
}

/// Optional, read-only discovery. Return nil for configuration and internal actions.
/// Implementations must not execute work or access the pasteboard while classifying.
@MainActor
public protocol PluginLauncherActionProviding: AnyObject {
    func launcherRole(for reference: ActionReference) -> LauncherActionRole?
}

public struct ApplicationCatalogItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    public let alternateNames: [String]
    public init(id: String, name: String, url: URL, alternateNames: [String] = []) {
        self.id = id; self.name = name; self.url = url; self.alternateNames = alternateNames
    }
}

@MainActor
public struct ApplicationCatalogHostContext {
    public let snapshot: () -> [ApplicationCatalogItem]
    public let refresh: () -> Void
    public init(snapshot: @escaping () -> [ApplicationCatalogItem], refresh: @escaping () -> Void) {
        self.snapshot = snapshot; self.refresh = refresh
    }
}

@MainActor
public protocol ApplicationCatalogHostContextConsuming: AnyObject {
    var applicationCatalogHostContext: ApplicationCatalogHostContext? { get set }
    func applicationCatalogDidChange()
}
