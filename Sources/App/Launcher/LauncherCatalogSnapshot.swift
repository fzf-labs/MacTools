import AppKit
import MacToolsPluginKit

@MainActor
enum LauncherCatalogSnapshot {
    static func make(host: PluginHost, category: LauncherCategory? = nil,
                     settings: (() -> [LauncherSystemSetting])? = nil) -> [LauncherResult] {
        var output: [LauncherResult] = []
        if category == nil || category == .applications {
            let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path })
            output += host.applicationCatalog.items.map { app in
                .init(id: "application." + app.id, title: app.name,
                      subtitle: running.contains(app.id) ? LauncherText.running : app.url.deletingLastPathComponent().path,
                      systemImage: "app", keywords: app.alternateNames, category: .applications, pluginID: nil, target: .application(app))
            }
        }
        if category == nil || category == .systemSettings {
            output += (settings?() ?? host.systemSettingsCatalog.items).map { page in
                .init(id: "system-setting." + page.id, title: page.title, subtitle: "", systemImage: page.systemImage,
                      keywords: page.keywords, category: .systemSettings, pluginID: nil, target: .systemSetting(page))
            }
        }
        if category == nil || category == .systemOperations || category == .pluginFeatures {
            output += host.actionCatalogEntries.compactMap { entry in
                guard let role = host.launcherRole(for: entry.reference) else { return nil }
                let kind: LauncherCategory = role == .systemOperation ? .systemOperations : .pluginFeatures
                guard category == nil || category == kind,
                      let definition = host.actionRegistry.definition(for: entry.reference.key),
                      ActionRegistry.parameterValidationFailure(entry.reference.parameters, for: definition) == nil,
                      let pluginTitle = host.launcherPluginTitle(entry.reference.key.providerID) else { return nil }
                return .init(id: LauncherIdentity.action(entry.reference), title: entry.title, subtitle: pluginTitle,
                             systemImage: definition.systemImage, keywords: definition.keywords + [pluginTitle],
                             category: kind, pluginID: entry.reference.key.providerID, target: .action(entry.reference))
            }
            output += host.actionInputRegistry.items.compactMap { item in
                guard let role = host.launcherRole(for: .init(key: item.id)) else { return nil }
                let kind: LauncherCategory = role == .systemOperation ? .systemOperations : .pluginFeatures
                guard category == nil || category == kind,
                      let pluginTitle = host.launcherPluginTitle(item.id.providerID) else { return nil }
                return .init(id: "input." + item.id.id, title: item.definition.title, subtitle: pluginTitle,
                             systemImage: item.definition.systemImage, keywords: item.definition.keywords + item.descriptor.aliases + [pluginTitle],
                             category: kind, pluginID: item.id.providerID, target: .input(item))
            }
        }
        if category == nil || category == .pluginFeatures {
            output += host.launcherWorkspaces.map { page in
                .init(id: "workspace." + page.id, title: page.title, subtitle: "", systemImage: page.iconName,
                      keywords: [], category: .pluginFeatures, pluginID: page.id, target: .workspace(page.id))
            }
        }
        var seen = Set<String>()
        return output.filter { seen.insert($0.id).inserted }
    }
}
