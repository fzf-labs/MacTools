import Combine
import Foundation
import OSLog
import MacToolsPluginKit

/// Owns the persisted custom layout and republishes it so the (otherwise non-reactive)
/// overlay grid re-renders on change.
///
/// `ObservableObject` is load-bearing: the overlay grid's only other reactive source is the
/// catalog, and it does NOT observe `onStateChange`, so the grid must inject this store as
/// `@ObservedObject` to ever see a reorder (design §5.5 / risk R1). Persistence mirrors
/// `AppHotkeyStore`'s `JSONEncoder` + `data(forKey:)` write-through; decode failures fall
/// back to alphabetical (`nil`) and never crash.
@MainActor
final class LaunchpadLayoutStore: ObservableObject {
    enum Keys {
        static let customLayout = "customLayout"
    }

    /// `nil` == no custom layout == alphabetical order. Non-nil == custom-sort mode.
    @Published private(set) var layout: LaunchpadLayout?

    private let storage: PluginStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "LaunchpadLayoutStore"
    )

    init(storage: PluginStorage) {
        self.storage = storage
        _ = LaunchpadPortablePreferences.store(storage: storage).recover()
        self.layout = Self.loadLayout(from: storage, decoder: decoder, logger: logger)
    }

    /// On the first user reorder, freeze the current alphabetical sequence into an all-`.app`
    /// layout so subsequent moves are relative to a stable snapshot. No-op once a layout
    /// exists (design §5.3). The caller must pass the frozen drag-session snapshot, NOT a live
    /// `filtered` read, to avoid racing an async catalog reload.
    func materializeIfNeeded(from apps: [LaunchpadAppItem]) {
        guard layout == nil else { return }
        setLayout(LaunchpadLayout(nodes: apps.map(Self.node(for:))))
    }

    /// Ensure the layout exists and references every currently-visible app, so a following
    /// `move` can target any of them — including reconcile-appended new installs that aren't
    /// yet in the layout (Codex P2). Materializes the full snapshot when none exists;
    /// otherwise appends the missing visible apps at the tail, preserving existing order and
    /// any offscreen/orphan entries (the tolerance window).
    func captureVisibleOrder(_ apps: [LaunchpadAppItem]) {
        materializeIfNeeded(from: apps)
        guard let current = layout else { return }
        let present = Set(current.nodes.flatMap(\.appIDs))
        let missing = apps.filter { !present.contains($0.id) }
        guard !missing.isEmpty else { return }
        setLayout(LaunchpadLayout(version: current.version, nodes: current.nodes + missing.map(Self.node(for:))))
    }

    private static func node(for app: LaunchpadAppItem) -> LaunchpadLayoutNode {
        .app(LaunchpadAppRef(id: app.id, name: app.name))
    }

    /// Move `id` to immediately before `targetID` in the root node order.
    func move(id: String, before targetID: String) {
        reorder(id: id, relativeTo: targetID, placeAfter: false)
    }

    /// Move `id` to immediately after `targetID` in the root node order.
    func move(id: String, after targetID: String) {
        reorder(id: id, relativeTo: targetID, placeAfter: true)
    }

    /// Drop the custom layout entirely → back to alphabetical (design §5.4). No-op (and no
    /// write) when already alphabetical.
    func resetToAlphabetical() {
        guard layout != nil else { return }
        guard LaunchpadPortablePreferences.store(storage: storage).commit([:], removing: [Keys.customLayout]) else { return }
        layout = nil
        onPersistentPreferencesChange?()
    }

    // MARK: - Folders (19b)

    /// Stack two root apps into a new folder occupying `targetID`'s slot, carrying both apps;
    /// the dragged app is removed from the root. The apps must already be root nodes (the
    /// caller captures the visible order first, exactly as for a reorder). `id` is injectable
    /// for deterministic tests; production passes a fresh UUID.
    func makeFolder(target targetID: String, dragged draggedID: String,
                    name: String, id: String = UUID().uuidString) {
        guard let current = layout, targetID != draggedID else { return }
        var nodes = current.nodes
        guard let targetIndex = nodes.firstIndex(where: { $0.rootID == targetID }),
              case .app(let targetRef) = nodes[targetIndex],
              let draggedNode = nodes.first(where: { $0.rootID == draggedID }),
              case .app(let draggedRef) = draggedNode
        else { return }
        nodes[targetIndex] = .folder(id: id, name: name, children: [targetRef, draggedRef])
        nodes.removeAll { $0.rootID == draggedID }   // drop the now-foldered dragged app from root
        setLayout(LaunchpadLayout(version: current.version, nodes: nodes))
    }

    /// Move a root app into an existing folder (appended to its children, removed from root).
    func addToFolder(_ folderID: String, app appID: String) {
        guard let current = layout else { return }
        var nodes = current.nodes
        guard let folderIndex = nodes.firstIndex(where: { $0.rootID == folderID }),
              case .folder(let fid, let fname, var children) = nodes[folderIndex],
              let appNode = nodes.first(where: { $0.rootID == appID }),
              case .app(let appRef) = appNode,
              !children.contains(where: { $0.id == appID })
        else { return }
        children.append(appRef)
        nodes[folderIndex] = .folder(id: fid, name: fname, children: children)
        nodes.removeAll { $0.rootID == appID }
        setLayout(LaunchpadLayout(version: current.version, nodes: nodes))
    }

    /// Remove an app from a folder back to the root tail. Dropping to a single remaining child
    /// auto-dissolves the folder, lifting the survivor back into the folder's slot (design §7).
    func removeFromFolder(_ folderID: String, app appID: String) {
        guard let current = layout else { return }
        var nodes = current.nodes
        guard let folderIndex = nodes.firstIndex(where: { $0.rootID == folderID }),
              case .folder(let fid, let fname, var children) = nodes[folderIndex],
              let childIndex = children.firstIndex(where: { $0.id == appID })
        else { return }
        let removed = children.remove(at: childIndex)
        if children.count <= 1 {
            // Auto-dissolve: survivor(s) take the folder's slot, removed app goes to the tail.
            nodes.replaceSubrange(folderIndex...folderIndex, with: children.map(LaunchpadLayoutNode.app))
        } else {
            nodes[folderIndex] = .folder(id: fid, name: fname, children: children)
        }
        nodes.append(.app(removed))
        setLayout(LaunchpadLayout(version: current.version, nodes: nodes))
    }

    /// Move an app OUT of a folder and drop it at a chosen ROOT position (iOS finger-bound exit) —
    /// not the tail. Auto-dissolve still applies (a single remaining child lifts the survivor into
    /// the folder's slot); a target that referenced the dissolving folder's own tile follows the
    /// survivor that takes its slot. `target == nil`, or a target whose id no longer resolves,
    /// falls back to the tail (the app is never lost).
    func moveOutOfFolder(_ folderID: String, app appID: String, to target: LaunchpadDropTarget?) {
        guard let current = layout else { return }
        var nodes = current.nodes
        guard let folderIndex = nodes.firstIndex(where: { $0.rootID == folderID }),
              case .folder(let fid, let fname, var children) = nodes[folderIndex],
              let childIndex = children.firstIndex(where: { $0.id == appID })
        else { return }
        let removed = children.remove(at: childIndex)
        var resolvedTarget = target
        if children.count <= 1 {
            // Dropping "beside the folder" from a 2-app folder: the folder id vanishes with the
            // dissolve, so redirect the target to the survivor occupying its slot — otherwise the
            // stale id would send the app to the tail instead of where the user dropped it.
            if let survivor = children.first {
                switch target {
                case .before(let id) where id == folderID: resolvedTarget = .before(survivor.id)
                case .after(let id) where id == folderID: resolvedTarget = .after(survivor.id)
                default: break
                }
            }
            nodes.replaceSubrange(folderIndex...folderIndex, with: children.map(LaunchpadLayoutNode.app))
        } else {
            nodes[folderIndex] = .folder(id: fid, name: fname, children: children)
        }
        insert(.app(removed), relativeTo: resolvedTarget, into: &nodes)
        setLayout(LaunchpadLayout(version: current.version, nodes: nodes))
    }

    /// Insert a node at a root drop target (before/after an existing root id); a nil or stale
    /// target appends at the tail.
    private func insert(_ node: LaunchpadLayoutNode, relativeTo target: LaunchpadDropTarget?,
                        into nodes: inout [LaunchpadLayoutNode]) {
        switch target {
        case .none:
            nodes.append(node)
        case .before(let id):
            if let i = nodes.firstIndex(where: { $0.rootID == id }) { nodes.insert(node, at: i) }
            else { nodes.append(node) }
        case .after(let id):
            if let i = nodes.firstIndex(where: { $0.rootID == id }) { nodes.insert(node, at: i + 1) }
            else { nodes.append(node) }
        }
    }

    /// Eject `app` from its `source` folder AND fold it into a NEW folder occupying `target`'s root
    /// slot — in ONE mutation (no intermediate tail hop / double render). Auto-dissolve of the now
    /// smaller source still applies. Falls back to a tail insert (app never lost) if the target no
    /// longer resolves to a root app after the source dissolves.
    func ejectIntoNewFolder(source: String, app appID: String, target targetID: String, name: String, id: String) {
        guard let current = layout, targetID != source, appID != targetID else { return }
        var nodes = current.nodes
        guard let removed = detachChild(appID, fromFolder: source, in: &nodes) else { return }
        guard let targetIndex = nodes.firstIndex(where: { $0.rootID == targetID }),
              case .app(let targetRef) = nodes[targetIndex] else {
            nodes.append(.app(removed))
            setLayout(LaunchpadLayout(version: current.version, nodes: nodes)); return
        }
        nodes[targetIndex] = .folder(id: id, name: name, children: [targetRef, removed])
        setLayout(LaunchpadLayout(version: current.version, nodes: nodes))
    }

    /// Eject `app` from its `source` folder AND append it to existing `destination` folder — one
    /// mutation. Falls back to a tail insert if the destination no longer resolves to a folder.
    func ejectIntoFolder(source: String, app appID: String, destination destID: String) {
        guard let current = layout, destID != source else { return }
        var nodes = current.nodes
        guard let removed = detachChild(appID, fromFolder: source, in: &nodes) else { return }
        guard let destIndex = nodes.firstIndex(where: { $0.rootID == destID }),
              case .folder(let dfid, let dfname, var dchildren) = nodes[destIndex],
              !dchildren.contains(where: { $0.id == appID }) else {
            nodes.append(.app(removed))
            setLayout(LaunchpadLayout(version: current.version, nodes: nodes)); return
        }
        dchildren.append(removed)
        nodes[destIndex] = .folder(id: dfid, name: dfname, children: dchildren)
        setLayout(LaunchpadLayout(version: current.version, nodes: nodes))
    }

    /// Remove `appID` from `folderID`'s children, auto-dissolving the folder in place when ≤1 child
    /// remains. Returns the detached app, or nil if it can't be resolved. Mutates `nodes` only.
    private func detachChild(_ appID: String, fromFolder folderID: String,
                             in nodes: inout [LaunchpadLayoutNode]) -> LaunchpadAppRef? {
        guard let folderIndex = nodes.firstIndex(where: { $0.rootID == folderID }),
              case .folder(let fid, let fname, var children) = nodes[folderIndex],
              let childIndex = children.firstIndex(where: { $0.id == appID })
        else { return nil }
        let removed = children.remove(at: childIndex)
        if children.count <= 1 {
            nodes.replaceSubrange(folderIndex...folderIndex, with: children.map(LaunchpadLayoutNode.app))
        } else {
            nodes[folderIndex] = .folder(id: fid, name: fname, children: children)
        }
        return removed
    }

    /// Rename a folder. An empty (or whitespace-only) name falls back to `fallback` so a folder
    /// is never nameless; callers pass the localized default. Renaming to the current name —
    /// including the trim-equivalent of it — is a no-op and writes nothing (the blur-commits
    /// rename UI hits this on every "click in, click away" pass; same discipline as
    /// `reorderChild`). The folder id never changes.
    func renameFolder(_ folderID: String, name: String, fallback: String = "Untitled") {
        guard let current = layout else { return }
        var nodes = current.nodes
        guard let folderIndex = nodes.firstIndex(where: { $0.rootID == folderID }),
              case .folder(let fid, let currentName, let children) = nodes[folderIndex]
        else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Trim the fallback too: a whitespace-only fallback (e.g. a bad localization
        // payload) would otherwise persist a visually blank folder name. Fall back once
        // more to a hard default so a folder is never left nameless.
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? (trimmedFallback.isEmpty ? "Untitled" : trimmedFallback) : trimmed
        guard resolved != currentName else { return }   // no visible change → no write
        nodes[folderIndex] = .folder(id: fid, name: resolved, children: children)
        setLayout(LaunchpadLayout(version: current.version, nodes: nodes))
    }

    /// Reorder a child WITHIN a folder: move `appID` to immediately before `siblingID` in that
    /// folder's children. No-op (no write) when the folder/child/sibling can't be resolved, when
    /// they're the same, or when nothing changes — and, unlike the root reorder, a missing sibling
    /// is a no-op rather than an append (the child stays put; design: in-folder order is explicit).
    func moveChildWithinFolder(_ folderID: String, child appID: String, before siblingID: String) {
        reorderChild(in: folderID, child: appID, relativeTo: siblingID, placeAfter: false)
    }

    /// Reorder a child WITHIN a folder: move `appID` to immediately after `siblingID`.
    func moveChildWithinFolder(_ folderID: String, child appID: String, after siblingID: String) {
        reorderChild(in: folderID, child: appID, relativeTo: siblingID, placeAfter: true)
    }

    private func reorderChild(in folderID: String, child appID: String, relativeTo siblingID: String, placeAfter: Bool) {
        guard let current = layout, appID != siblingID,
              let folderIndex = current.nodes.firstIndex(where: { $0.rootID == folderID }),
              case .folder(let fid, let fname, var children) = current.nodes[folderIndex],
              let sourceIndex = children.firstIndex(where: { $0.id == appID })
        else { return }
        let moved = children.remove(at: sourceIndex)
        guard let targetIndex = children.firstIndex(where: { $0.id == siblingID }) else { return }  // stale sibling → no-op
        children.insert(moved, at: placeAfter ? targetIndex + 1 : targetIndex)

        var nodes = current.nodes
        let updated = LaunchpadLayoutNode.folder(id: fid, name: fname, children: children)
        guard updated != nodes[folderIndex] else { return }   // dropped in place → no write (R8)
        nodes[folderIndex] = updated
        setLayout(LaunchpadLayout(version: current.version, nodes: nodes))
    }

    /// Explicitly dissolve a folder: release all its children back to the root, in place.
    func dissolveFolder(_ folderID: String) {
        guard let current = layout else { return }
        var nodes = current.nodes
        guard let folderIndex = nodes.firstIndex(where: { $0.rootID == folderID }),
              case .folder(_, _, let children) = nodes[folderIndex]
        else { return }
        nodes.replaceSubrange(folderIndex...folderIndex, with: children.map(LaunchpadLayoutNode.app))
        setLayout(LaunchpadLayout(version: current.version, nodes: nodes))
    }

    // MARK: - Loading

    /// Decode the stored layout, tolerating absence and corruption.
    /// Missing key → `nil` (alphabetical — the zero-migration default for upgrading users).
    /// Decode failure or version mismatch → `nil` + a warning, never a crash.
    private static func loadLayout(
        from storage: PluginStorage,
        decoder: JSONDecoder,
        logger: Logger
    ) -> LaunchpadLayout? {
        guard let data = storage.data(forKey: Keys.customLayout) else { return nil }
        guard let decoded = try? decoder.decode(LaunchpadLayout.self, from: data) else {
            logger.warning("Failed to decode custom layout; falling back to alphabetical order.")
            return nil
        }
        // Exact-version match only. Older formats never shipped; a NEWER version (downgraded app)
        // may carry fields this build's Codable silently drops — loading it and re-stamping the
        // future version onto v2-shaped data on the next save would corrupt it for the newer build.
        guard decoded.version == LaunchpadLayout.currentVersion else {
            logger.warning(
                "Custom layout version \(decoded.version, privacy: .public) != supported \(LaunchpadLayout.currentVersion, privacy: .public); falling back to alphabetical order."
            )
            return nil
        }
        guard isSemanticallyValid(decoded) else {
            logger.warning("Custom layout failed semantic validation; falling back to alphabetical order.")
            return nil
        }
        return decoded
    }

    /// Reject persisted blobs that decode but break the store's structural assumptions: every
    /// mutation looks nodes up by `rootID` and assumes an app lives in exactly one place, so a
    /// duplicate root id or an app referenced twice would make moves target the wrong node and
    /// then persist that corruption back. (Empty folders stay valid — the reconcile tolerance
    /// window keeps them around deliberately.)
    static func isSemanticallyValid(_ layout: LaunchpadLayout) -> Bool {
        var rootIDs = Set<String>()
        var appIDs = Set<String>()
        for node in layout.nodes {
            guard rootIDs.insert(node.rootID).inserted else { return false }
            for id in node.appIDs {
                guard appIDs.insert(id).inserted else { return false }
            }
        }
        return true
    }

    // MARK: - Mutation

    private func reorder(id: String, relativeTo targetID: String, placeAfter: Bool) {
        guard let current = layout,
              id != targetID,
              let sourceIndex = current.nodes.firstIndex(where: { $0.rootID == id })
        else { return }

        var nodes = current.nodes
        let moved = nodes.remove(at: sourceIndex)
        if let targetIndex = nodes.firstIndex(where: { $0.rootID == targetID }) {
            nodes.insert(moved, at: placeAfter ? targetIndex + 1 : targetIndex)
        } else {
            // Target not in the layout yet (e.g. a freshly-installed app rendered at the tail
            // but not yet persisted) → fall back to appending at the end.
            nodes.append(moved)
        }

        guard nodes != current.nodes else { return }   // dropping in place writes nothing (R8)
        setLayout(LaunchpadLayout(version: current.version, nodes: nodes))
    }

    var onPersistentPreferencesChange: (() -> Void)?
    func reloadCommittedSnapshot() { layout = Self.loadLayout(from: storage, decoder: decoder, logger: logger) }

    private func setLayout(_ newLayout: LaunchpadLayout) {
        guard newLayout != layout, Self.isSemanticallyValid(newLayout),
              let data = try? encoder.encode(newLayout),
              LaunchpadPortablePreferences.store(storage: storage).commit([Keys.customLayout: .data(data)]) else { return }
        layout = newLayout
        onPersistentPreferencesChange?()
    }
}
