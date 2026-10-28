import AppKit
import UniformTypeIdentifiers
import MacToolsPluginKit

@MainActor
struct RightClickResourceCommands {
    let session: RightClickSettingsSession
    let localization: PluginLocalization
    var store: RightClickResourceStore {
        RightClickResourceStore(root: session.fileURL.deletingLastPathComponent().appendingPathComponent("RightClickResources", isDirectory: true))
    }
    private func text(_ key: String) -> String { localization.string(key, defaultValue: key) }
    func chooseFile(directory: Bool = false, application: Bool = false, image: Bool = false, package: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory || package
        panel.canChooseFiles = !directory
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        if application { panel.allowedContentTypes = [.application] }
        if image { panel.allowedContentTypes = [.image] }
        PluginPresentationSafety.prepareForWindowOrdering()
        return panel.runModal() == .OK ? panel.url : nil
    }
    func addResource(_ kind: RightClickResourceEditorKind) {
        switch kind {
        case .locations:
            guard let url = chooseFile(directory: true), !session.configuration.locations.contains(where: { $0.path == url.path }) else { return }
            session.configuration.locations.append(RightClickLocation(name: url.lastPathComponent, path: url.path))
        case .applications:
            guard let url = chooseFile(application: true) else { return }
            let displayName = FileManager.default.displayName(atPath: url.path)
            let name = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
            session.configuration.openWithApps.append(RightClickOpenWithApp(name: name, appPath: url.path))
        case .terminal: return
        case .icons, .templates:
            let resourceKind: RightClickResource.Kind = kind == .icons ? .icon : .template
            guard let url = chooseFile(image: resourceKind == .icon, package: resourceKind == .template) else { return }
            if resourceKind == .icon, NSImage(contentsOf: url) == nil { session.error = "Cannot decode image."; return }
            session.isWorking = true
            let store = store
            Task { @MainActor in
                defer { session.isWorking = false }
                do {
                    let resource = try await Task.detached(priority: .userInitiated) { try store.importResource(from: url, kind: resourceKind) }.value
                    session.configuration.resources.append(resource)
                } catch { session.error = error.localizedDescription }
            }
        }
    }
    func removeResource(_ resource: RightClickResource) {
        let alert = NSAlert()
        alert.messageText = text("Remove managed resource?")
        alert.informativeText = text("The original imported file is not changed.")
        alert.addButton(withTitle: text("Cancel")); alert.addButton(withTitle: text("Remove"))
        PluginPresentationSafety.prepareForWindowOrdering()
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let previous = session.configuration.resources
        session.configuration.resources.removeAll { $0.id == resource.id }
        guard session.error == nil else { return }
        do { try store.remove(resource) }
        catch { session.configuration.resources = previous; session.error = error.localizedDescription }
    }
    func importPackage() {
        guard let url = chooseFile() else { return }
        session.isWorking = true
        let metadata = session.configuration.resources
        let store = store
        Task { @MainActor in
            defer { session.isWorking = false }
            do {
                let resources = try await Task.detached(priority: .userInitiated) { try store.importArchive(from: url, restoring: metadata) }.value
                // Match restored metadata before appending new resources. Imported IDs
                // are intentionally fresh to preserve an existing installation.
                for resource in resources {
                    if let index = session.configuration.resources.firstIndex(where: { $0.id == resource.id }) {
                        session.configuration.resources[index] = resource
                    } else { session.configuration.resources.append(resource) }
                }
            } catch { session.error = error.localizedDescription }
        }
    }
    func exportPackage() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RightClick.mactoolsresources"
        PluginPresentationSafety.prepareForWindowOrdering()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let resources = session.configuration.resources
        let store = store
        session.isWorking = true
        Task { @MainActor in
            defer { session.isWorking = false }
            do {
                try await Task.detached(priority: .userInitiated) { try store.exportArchive(resources: resources, to: url) }.value
            } catch { session.error = error.localizedDescription }
        }
    }
}
