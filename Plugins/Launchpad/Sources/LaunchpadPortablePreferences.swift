import CryptoKit
import Foundation
import MacToolsPluginKit

/// One journal covers both observable stores and unresolved application identities.
@MainActor
final class LaunchpadPortablePreferences {
    private struct Application: Codable {
        let id: String
        let name: String
        let reference: PortableApplicationReference
    }
    private struct Payload: Codable {
        let formatVersion: Int
        let settings: [String: PortablePreferenceValue]
        let applications: [Application]
        let hiddenApplicationIDs: [String]
        let layout: LaunchpadLayout?
    }
    private static let bindingsKey = "portable-app-bindings.v1"
    private typealias K = LaunchpadPreferences.Keys
    private let storage: any PluginStorage
    private let preferences: LaunchpadPreferences
    private let layoutStore: LaunchpadLayoutStore
    private let beforePublishing: () -> Void
    private(set) var isRestoring = false
    var onPersistentPreferencesChange: (() -> Void)?

    init(storage: any PluginStorage, preferences: LaunchpadPreferences, layoutStore: LaunchpadLayoutStore, beforePublishing: @escaping () -> Void) {
        self.storage = storage; self.preferences = preferences; self.layoutStore = layoutStore; self.beforePublishing = beforePublishing
        preferences.onPersistentPreferencesChange = { [weak self] in self?.onPersistentPreferencesChange?() }
        layoutStore.onPersistentPreferencesChange = { [weak self] in self?.onPersistentPreferencesChange?() }
    }
    private static var settingsFields: [String: PortablePreferenceField] {
        [
            K.windowMode: .choice("fullscreen", allowed: LaunchpadPreferences.WindowMode.allCases.map(\.rawValue)),
            K.columns: PortablePreferenceField(fallback: .integer(0)) { if case let .integer(value) = $0 { value == 0 || (4...12).contains(value) } else { false } },
            K.hotCorner: .choice("off", allowed: LaunchpadPreferences.HotCorner.allCases.map(\.rawValue)),
            K.iconSize: PortablePreferenceField(fallback: .integer(64)) { if case let .integer(value) = $0 { (48...96).contains(value) && value % 4 == 0 } else { false } },
            K.hidesAppNames: .boolean(false), K.compactScalePercent: .integer(72, range: 55...90),
            K.labelColor: .choice("automatic", allowed: LaunchpadLabelColor.allCases.map(\.rawValue)),
            K.labelWeight: .choice("regular", allowed: LaunchpadLabelWeight.allCases.map(\.rawValue)),
            K.labelSize: .choice("medium", allowed: LaunchpadLabelSize.allCases.map(\.rawValue)),
            K.backgroundStyle: .choice("standard", allowed: LaunchpadBackgroundStyle.allCases.map(\.rawValue)),
            K.backgroundMaterial: .choice("launchpad", allowed: LaunchpadGlassMaterial.allCases.map(\.rawValue)),
            K.backgroundDimPercent: .integer(LaunchpadBackgroundDim.defaultPercent, range: LaunchpadBackgroundDim.percentRange)
        ]
    }
    static func store(storage: any PluginStorage) -> PortablePreferencesStore {
        var fields = settingsFields
        fields[K.hidden] = .strings(maximumCount: 1_024, maximumStringBytes: 2_048)
        fields[LaunchpadLayoutStore.Keys.customLayout] = .data(try! JSONEncoder().encode(LaunchpadLayout(nodes: [])), maximumBytes: 1_024 * 1_024) {
            guard let layout = try? JSONDecoder().decode(LaunchpadLayout.self, from: $0) else { return false }
            return layout.version == LaunchpadLayout.currentVersion && LaunchpadLayoutStore.isSemanticallyValid(layout)
        }
        fields[bindingsKey] = .data(Data("{}".utf8), maximumBytes: 1_024 * 1_024) {
            (try? JSONDecoder().decode([String: Application].self, from: $0)).map { $0.count <= 1_024 } == true
        }
        return PortablePreferencesStore(storage: storage, fields: fields)
    }
    private func bindings() -> [String: Application] {
        storage.data(forKey: Self.bindingsKey).flatMap { try? JSONDecoder().decode([String: Application].self, from: $0) } ?? [:]
    }
    private func mapLayout(_ layout: LaunchpadLayout?, ids: [String: String]) -> LaunchpadLayout? {
        layout.map { layout in
            LaunchpadLayout(nodes: layout.nodes.map { node in
                func app(_ ref: LaunchpadAppRef) -> LaunchpadAppRef { LaunchpadAppRef(id: ids[ref.id]!, name: ref.name) }
                switch node {
                case let .app(ref): return .app(app(ref))
                case let .folder(id, name, children): return .folder(id: id, name: name, children: children.map(app))
                }
            })
        }
    }
    func backup() -> Data? {
        guard let values = Self.store(storage: storage).currentValues(), Self.store(storage: storage).backup() != nil else { return nil }
        let layout = layoutStore.layout
        let used = Set((layout?.nodes.flatMap(\.appIDs) ?? [])).union(preferences.hiddenAppIDs)
        guard used.count <= 1_024 else { return nil }
        let previous = bindings()
        let references = (layout?.nodes.flatMap { node -> [LaunchpadAppRef] in
            switch node { case let .app(ref): [ref]; case let .folder(_, _, children): children }
        } ?? [])
        var tokenByID: [String: String] = [:]
        var applications: [Application] = []
        for id in used.sorted() {
            let retained = previous[id]
            let token = retained?.id ?? "app-" + SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
            let url = id.hasPrefix("/") ? URL(fileURLWithPath: id) : nil
            let name = retained?.name ?? references.first { $0.id == id }?.name ?? url?.deletingPathExtension().lastPathComponent ?? "Unavailable"
            let application = retained ?? Application(id: token, name: name, reference: PortableApplicationReference(url: url))
            tokenByID[id] = token
            applications.append(application)
        }
        let payload = Payload(formatVersion: 1, settings: values.filter { Self.settingsFields[$0.key] != nil }, applications: applications.sorted { $0.id < $1.id },
            hiddenApplicationIDs: preferences.hiddenAppIDs.compactMap { tokenByID[$0] }.sorted(), layout: mapLayout(layout, ids: tokenByID))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload), decode(data) != nil else { return nil }
        return data
    }
    private func decode(_ data: Data) -> Payload? {
        guard data.count <= 2 * 1_024 * 1_024, let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.formatVersion == 1,
              Set(payload.settings.keys) == Set(Self.settingsFields.keys), payload.settings.allSatisfy({ Self.settingsFields[$0.key]?.accepts($0.value) == true }),
              payload.applications.count <= 1_024, Set(payload.applications.map(\.id)).count == payload.applications.count,
              payload.applications.allSatisfy({ $0.id.hasPrefix("app-") && PortablePreferencesValidation.identifier($0.id)
                  && PortablePreferencesValidation.text($0.name, maximumBytes: 256) && $0.reference.isValid }),
              Set(payload.hiddenApplicationIDs).count == payload.hiddenApplicationIDs.count else { return nil }
        let ids = Set(payload.applications.map(\.id))
        guard Set(payload.hiddenApplicationIDs).isSubset(of: ids) else { return nil }
        if let layout = payload.layout {
            guard layout.version == LaunchpadLayout.currentVersion, layout.nodes.count <= 1_280, LaunchpadLayoutStore.isSemanticallyValid(layout),
                  Set(layout.nodes.flatMap(\.appIDs)).isSubset(of: ids) else { return nil }
            let refs = layout.nodes.flatMap { node -> [LaunchpadAppRef] in
                switch node { case let .app(ref): [ref]; case let .folder(_, _, children): children }
            }
            guard refs.allSatisfy({ PortablePreferencesValidation.text($0.name, maximumBytes: 256) }) else { return nil }
            var folders = 0
            for node in layout.nodes {
                if case let .folder(id, name, _) = node {
                    folders += 1
                    guard UUID(uuidString: id) != nil, PortablePreferencesValidation.text(name, maximumBytes: 256) else { return nil }
                }
            }
            guard folders <= 256 else { return nil }
        }
        return payload
    }
    func restore(_ data: Data, dismissOverlay: Bool = true, signalsChange: Bool = true) -> Bool {
        guard let payload = decode(data) else { return false }
        let previous = backup()
        var localIDs: [String: String] = [:]
        var claimed = Set<String>()
        var metadata: [String: Application] = [:]
        for app in payload.applications {
            let id = app.reference.resolvedURL()?.resolvingSymlinksInPath().path ?? "portable-app:" + app.id
            guard claimed.insert(id).inserted else { return false }
            localIDs[app.id] = id; metadata[id] = app
        }
        let layout = mapLayout(payload.layout, ids: localIDs)
        var candidate = payload.settings
        candidate[K.hidden] = .strings(payload.hiddenApplicationIDs.compactMap { localIDs[$0] }.sorted())
        guard let bindingsData = try? JSONEncoder().encode(metadata) else { return false }
        candidate[Self.bindingsKey] = .data(bindingsData)
        var removing = Set<String>()
        if let layout {
            guard let data = try? JSONEncoder().encode(layout) else { return false }
            candidate[LaunchpadLayoutStore.Keys.customLayout] = .data(data)
        } else { removing.insert(LaunchpadLayoutStore.Keys.customLayout) }
        guard Self.store(storage: storage).commit(candidate, removing: removing) else { return false }
        isRestoring = true
        if dismissOverlay { beforePublishing() }
        preferences.reloadCommittedSnapshot()
        layoutStore.reloadCommittedSnapshot()
        isRestoring = false
        if signalsChange, previous != backup() { onPersistentPreferencesChange?() }
        return true
    }
    func applicationName(for id: String) -> String? { bindings()[id]?.name }

    func rebindAvailableApplications() {
        guard bindings().contains(where: { $0.key.hasPrefix("portable-app:") && $0.value.reference.resolvedURL() != nil }),
              let data = backup() else { return }
        _ = restore(data, dismissOverlay: false, signalsChange: false)
    }
}
