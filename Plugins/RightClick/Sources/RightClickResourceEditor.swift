import AppKit
import SwiftUI
import MacToolsPluginKit

/// Each entry point edits the same session; resources are never copied into action-local drafts.
struct RightClickResourceEditor: View {
    @ObservedObject var session: RightClickSettingsSession
    let localization: PluginLocalization
    let kind: RightClickResourceEditorKind
    @State private var expandedResource: UUID?
    private typealias Spacing = PluginSettingsTheme.Spacing
    private typealias Typography = PluginSettingsTheme.Typography
    private func text(_ key: String) -> String { localization.string(key, defaultValue: key) }
    private var commands: RightClickResourceCommands { .init(session: session, localization: localization) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sectionHeaderContent) {
            if kind != .terminal {
                HStack(spacing: Spacing.controlCluster) {
                    RightClickSectionHeader(title: text(kind.title), symbol: kind.symbol)
                    Button { commands.addResource(kind) } label: { Label(text(kind.addTitle), systemImage: "plus") }
                        .fixedSize()
                }
            }
            switch kind {
            case .locations: locations
            case .applications: applications
            case .terminal: terminal
            case .templates: managedResources(.template)
            case .icons: managedResources(.icon)
            }
        }
        .font(Typography.rowDescription)
    }

    private var locations: some View {
        VStack(alignment: .leading, spacing: Spacing.sectionHeaderContent) {
            Text(text("Locations are shared by Go To, Copy To and Move To.")).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if session.configuration.locations.isEmpty {
                emptyState(symbol: "folder.badge.plus")
            } else {
                VStack(spacing: 0) {
                    ForEach(session.configuration.locations) { location in
                        let value = binding(for: location, in: \.locations)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: Spacing.rowContentControl) {
                                disclosure(id: location.id, name: location.name, subtitle: location.path,
                                           icon: NSWorkspace.shared.icon(forFile: location.path), unavailable: !FileManager.default.fileExists(atPath: location.path))
                                itemMenu(location, name: location.name, values: session.configuration.locations,
                                         move: { move(location, in: \.locations, by: $0) },
                                         remove: { session.configuration.locations.removeAll { $0.id == location.id } })
                            }.pluginSettingsListRowPadding(interactive: true)
                            if expandedResource == location.id {
                                VStack(alignment: .leading, spacing: Spacing.sectionHeaderContent) {
                                    nameField(value.name)
                                    HStack(spacing: Spacing.controlCluster) {
                                        Text(location.path).textSelection(.enabled).lineLimit(2).truncationMode(.middle).foregroundStyle(.secondary)
                                        Spacer(minLength: 0)
                                        Button(text("Relocate")) { if let url = commands.chooseFile(directory: true) { value.wrappedValue.path = url.path } }
                                    }
                                    if !FileManager.default.fileExists(atPath: location.path) { warning("Location is unavailable. Update it in settings.") }
                                }
                                .padding(.horizontal, Spacing.rowHorizontal).padding(.bottom, Spacing.rowVertical)
                            }
                        }
                        if location.id != session.configuration.locations.last?.id { PluginSettingsListDivider() }
                    }
                }.pluginSettingsCardBackground(.recessed)
            }
        }
    }

    private var applications: some View {
        VStack(alignment: .leading, spacing: Spacing.sectionHeaderContent) {
            HStack(spacing: Spacing.rowContentControl) {
                Text(text("Preferred Application"))
                Spacer(minLength: 0)
                Picker(text("Preferred Application"), selection: $session.configuration.preferredAppID) {
                    Text(text("Not Set")).tag(Optional<UUID>.none)
                    ForEach(session.configuration.openWithApps) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(minWidth: 100, idealWidth: 180, maxWidth: 240)
            }
            if session.configuration.openWithApps.isEmpty {
                emptyState(symbol: "app.badge")
            } else {
                VStack(spacing: 0) {
                    ForEach(session.configuration.openWithApps) { app in
                        let value = binding(for: app, in: \.openWithApps)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: Spacing.rowContentControl) {
                                disclosure(id: app.id, name: app.name, subtitle: app.appPath,
                                           icon: NSWorkspace.shared.icon(forFile: app.appPath), unavailable: !FileManager.default.fileExists(atPath: app.appPath))
                                itemMenu(app, name: app.name, values: session.configuration.openWithApps,
                                         move: { move(app, in: \.openWithApps, by: $0) }, remove: { removeApplication(app) })
                            }.pluginSettingsListRowPadding(interactive: true)
                            if expandedResource == app.id {
                                VStack(alignment: .leading, spacing: Spacing.sectionHeaderContent) {
                                    nameField(value.name)
                                    HStack(spacing: Spacing.rowContentControl) {
                                        Text(text("Applies To"))
                                        Spacer(minLength: 0)
                                        Picker(text("Applies To"), selection: value.scope) {
                                            Text(text("All")).tag(RightClickAppScope.all)
                                            Text(text("Files")).tag(RightClickAppScope.files)
                                            Text(text("Folders")).tag(RightClickAppScope.folders)
                                        }.labelsHidden().frame(minWidth: 100, idealWidth: 160, maxWidth: 200)
                                    }
                                    TextField(text("Extensions, separated by commas"), text: Binding(get: { value.wrappedValue.fileExtensions.joined(separator: ", ") }, set: { input in
                                        value.wrappedValue.fileExtensions = input.split(separator: ",").map {
                                            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                                        }.filter { !$0.isEmpty }
                                    })).textFieldStyle(.roundedBorder).accessibilityLabel(text("Extensions, separated by commas"))
                                    HStack {
                                        if !FileManager.default.fileExists(atPath: app.appPath) { warning("Application is unavailable.") }
                                        Spacer(minLength: 0)
                                        Button(text("Relocate")) { if let url = commands.chooseFile(application: true) { value.wrappedValue.appPath = url.path } }
                                    }
                                }
                                .padding(.horizontal, Spacing.rowHorizontal).padding(.bottom, Spacing.rowVertical)
                            }
                        }
                        if app.id != session.configuration.openWithApps.last?.id { PluginSettingsListDivider() }
                    }
                }.pluginSettingsCardBackground(.recessed)
            }
        }
    }

    private var terminal: some View {
        VStack(alignment: .leading, spacing: Spacing.sectionHeaderContent) {
            HStack(spacing: Spacing.rowContentControl) {
                Text(text("Preferred Terminal"))
                Spacer(minLength: 0)
                Picker(text("Preferred Terminal"), selection: $session.configuration.terminal) {
                    ForEach(RightClickTerminal.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(minWidth: 100, idealWidth: 180, maxWidth: 240)
            }
            if session.configuration.terminal != .terminal {
                HStack(spacing: Spacing.rowContentControl) {
                    Text(text("Open in New Tab"))
                    Spacer(minLength: 0)
                    Toggle(text("Open in New Tab"), isOn: $session.configuration.terminalNewTab).labelsHidden().toggleStyle(.switch)
                }
            }
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: session.configuration.terminal.bundleID) == nil {
                warning("Terminal application is not installed.")
            }
        }
    }

    private func managedResources(_ resourceKind: RightClickResource.Kind) -> some View {
        let resources = session.configuration.resources.filter { $0.kind == resourceKind }
        return VStack(alignment: .leading, spacing: Spacing.sectionHeaderContent) {
            Text(text(resourceKind == .template ? "Imported files are copied into managed storage. Office documents require a valid template." : "Import an image to customize a folder icon."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if resources.isEmpty {
                emptyState(symbol: resourceKind == .template ? "doc.badge.plus" : "photo.badge.plus")
            } else {
                VStack(spacing: 0) {
                    ForEach(resources) { resource in
                        let value = binding(for: resource, in: \.resources)
                        let url = try? commands.store.url(for: resource)
                        let missing = url.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: Spacing.rowContentControl) {
                                disclosure(id: resource.id, name: resource.name, subtitle: resourceSubtitle(resource),
                                           icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) },
                                           thumbnailURL: resourceKind == .icon ? url : nil, unavailable: missing)
                                Toggle(text("Enabled") + ": " + resource.name, isOn: value.enabled).labelsHidden().toggleStyle(.switch)
                                itemMenu(resource, name: resource.name, values: resources,
                                         move: { move(resource, in: \.resources, by: $0, matching: { $0.kind == resourceKind }) },
                                         remove: { commands.removeResource(resource) })
                            }.pluginSettingsListRowPadding(interactive: true)
                            if expandedResource == resource.id {
                                VStack(alignment: .leading, spacing: Spacing.sectionHeaderContent) {
                                    nameField(value.name)
                                    if missing {
                                        warning("Resource is missing. Import its resource package.")
                                        Button(text("Import Templates and Icons")) { commands.importPackage() }
                                    }
                                }
                                .padding(.horizontal, Spacing.rowHorizontal).padding(.bottom, Spacing.rowVertical)
                            }
                        }
                        if resource.id != resources.last?.id { PluginSettingsListDivider() }
                    }
                }.pluginSettingsCardBackground(.recessed)
            }
        }
    }

    // Resolve the current item by identity on every read and write, including while rows disappear or reorder.
    private func binding<Item: Identifiable>(for item: Item, in keyPath: WritableKeyPath<RightClickConfiguration, [Item]>) -> Binding<Item> {
        Binding(get: { session.configuration[keyPath: keyPath].first { $0.id == item.id } ?? item }, set: { value in
            guard let index = session.configuration[keyPath: keyPath].firstIndex(where: { $0.id == item.id }) else { return }
            session.configuration[keyPath: keyPath][index] = value
        })
    }

    private func move<Item: Identifiable>(_ item: Item, in keyPath: WritableKeyPath<RightClickConfiguration, [Item]>, by delta: Int, matching: (Item) -> Bool = { _ in true }) {
        let values = session.configuration[keyPath: keyPath]
        let indices = values.indices.filter { matching(values[$0]) }
        guard let position = indices.firstIndex(where: { values[$0].id == item.id }), indices.indices.contains(position + delta) else { return }
        session.configuration[keyPath: keyPath].swapAt(indices[position], indices[position + delta])
    }

    private func nameField(_ name: Binding<String>) -> some View {
        HStack(spacing: Spacing.rowContentControl) {
            Text(text("Name"))
            Spacer(minLength: 0)
            TextField(text("Name"), text: name).labelsHidden().textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, idealWidth: 220, maxWidth: 280).accessibilityLabel(text("Name"))
        }
    }

    private func disclosure(id: UUID, name: String, subtitle: String, icon: NSImage?, thumbnailURL: URL? = nil, unavailable: Bool) -> some View {
        Button { expandedResource = expandedResource == id ? nil : id } label: {
            HStack(spacing: Spacing.rowContentControl) {
                if let thumbnailURL { RightClickIconThumbnail(url: thumbnailURL, fallback: icon) }
                else if let icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: PluginSettingsTheme.Size.controlHeight, height: PluginSettingsTheme.Size.controlHeight) }
                VStack(alignment: .leading, spacing: Spacing.rowTitleDescription) {
                    HStack(spacing: Spacing.controlCluster) {
                        Text(name).font(Typography.rowTitle).foregroundStyle(.primary).lineLimit(1)
                        if unavailable { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }
                    Text(subtitle).font(Typography.rowDescription).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: expandedResource == id ? "chevron.down" : "chevron.right").font(Typography.statusBadge).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(text("Configure"))
        .accessibilityValue(text(expandedResource == id ? "Expanded" : "Collapsed"))
    }

    private func itemMenu<Item: Identifiable>(_ item: Item, name: String, values: [Item], move: @escaping (Int) -> Void, remove: @escaping () -> Void) -> some View {
        Menu {
            Button(text("Move Up")) { move(-1) }.disabled(values.first?.id == item.id)
            Button(text("Move Down")) { move(1) }.disabled(values.last?.id == item.id)
            Divider()
            Button(text("Remove"), role: .destructive, action: remove)
        } label: { Image(systemName: "ellipsis") }
        .menuIndicator(.hidden).fixedSize().accessibilityLabel(text("Configure") + ": " + name)
    }
    private func warning(_ key: String) -> some View {
        Label(text(key), systemImage: "exclamationmark.circle").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func resourceSubtitle(_ resource: RightClickResource) -> String {
        if resource.kind == .icon { return text("Images") }
        let fileExtension = URL(fileURLWithPath: resource.filename).pathExtension
        return fileExtension.isEmpty ? text("Templates") : "." + fileExtension
    }
    private func emptyState(symbol: String) -> some View {
        RightClickEmptyState(title: text("No items yet."), symbol: symbol, description: text(emptyDescription))
    }
    private var emptyDescription: String {
        switch kind {
        case .locations: "Add a location to get started."
        case .applications: "Add an application to get started."
        case .icons: "Import an image to get started."
        default: "Import a template to get started."
        }
    }
    private func removeApplication(_ app: RightClickOpenWithApp) {
        session.configuration.openWithApps.removeAll { $0.id == app.id }
        if session.configuration.preferredAppID == app.id { session.configuration.preferredAppID = nil }
    }
}
