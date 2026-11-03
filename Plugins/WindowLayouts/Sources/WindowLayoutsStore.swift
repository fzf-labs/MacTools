import CoreGraphics
import Foundation
import MacToolsPluginKit

@MainActor
final class WindowLayoutsStore {
    private enum StorageKey {
        static let gap = "gap"
        static let cyclesHalves = "cycles-halves"
        static let respectsStageManager = "respects-stage-manager"
        static let showsCommandFeedback = "shows-command-feedback"
        static let centeredGuidesEnabled = "centered-guides.enabled"
        static let modifierDragEnabled = "modifier-drag.enabled"
        static let modifierDragModifiers = "modifier-drag.modifiers"
        static let modifierDragShowsIndicator = "modifier-drag.shows-indicator"
        static let shortcutPreset = "shortcut-preset"
        static let library = "library.v1"
        static let quarantinedLibrary = "library.v1.quarantined"
        static let portableRestore = "portable-restore.v1"
    }

    private struct LibraryEnvelope: Codable {
        let formatVersion: Int
        let customCommands: [WindowCustomCommand]
    }

    private struct PortablePreferences: Codable, Equatable {
        let formatVersion: Int
        let gap: Double
        let cyclesHalves: Bool
        let respectsStageManager: Bool
        let showsCommandFeedback: Bool
        let centeredGuidesEnabled: Bool
        let modifierDragEnabled: Bool
        let modifierDragModifiers: ShortcutModifiers
        let modifierDragShowsIndicator: Bool
        let shortcutPreset: WindowShortcutPreset
        let customCommands: [WindowCustomCommand]
    }

    private static let portableKeys = [
        StorageKey.gap, StorageKey.cyclesHalves, StorageKey.respectsStageManager,
        StorageKey.showsCommandFeedback, StorageKey.centeredGuidesEnabled,
        StorageKey.modifierDragEnabled, StorageKey.modifierDragModifiers,
        StorageKey.modifierDragShowsIndicator, StorageKey.shortcutPreset, StorageKey.library,
    ]
    private static let maximumPortableBytes = 2 * 1_024 * 1_024

    static let gapRange: ClosedRange<Double> = 0...40
    static let defaultGap: Double = 0
    static let maximumCustomCommandCount = 32
    private static let maximumCustomCommandNameLength = 80
    private static let pointDimensionRange: ClosedRange<CGFloat> = 100...3_000
    private static let fractionDimensionRange: ClosedRange<CGFloat> = 0.05...1
    private static let offsetRange: ClosedRange<CGFloat> = -500...500

    private let storage: PluginStorage
    private(set) var gap: Double
    private(set) var cyclesHalves: Bool
    private(set) var respectsStageManager: Bool
    private(set) var showsCommandFeedback: Bool
    private(set) var centeredGuidesEnabled: Bool
    private(set) var modifierDragEnabled: Bool
    private(set) var modifierDragModifiers: ShortcutModifiers
    private(set) var modifierDragShowsIndicator: Bool
    private(set) var shortcutPreset: WindowShortcutPreset
    private(set) var customCommands: [WindowCustomCommand] = []
    private(set) var revision: UInt64 = 0
    var onMutation: (() -> Void)?
    var onSafetyPolicyMutation: (() -> Void)?

    init(storage: PluginStorage) {
        self.storage = storage
        _ = Self.recoverPortableRestore(storage: storage)
        let storedGap = (storage.object(forKey: StorageKey.gap) as? NSNumber)?.doubleValue
            ?? Self.defaultGap
        self.gap = Self.clampedGap(storedGap)
        self.cyclesHalves = (storage.object(forKey: StorageKey.cyclesHalves) as? NSNumber)?.boolValue ?? false
        self.respectsStageManager = (storage.object(forKey: StorageKey.respectsStageManager) as? NSNumber)?.boolValue ?? true
        self.showsCommandFeedback = (storage.object(forKey: StorageKey.showsCommandFeedback) as? NSNumber)?.boolValue ?? false
        self.centeredGuidesEnabled = (storage.object(forKey: StorageKey.centeredGuidesEnabled) as? NSNumber)?.boolValue ?? false
        self.modifierDragEnabled = (storage.object(forKey: StorageKey.modifierDragEnabled) as? NSNumber)?.boolValue ?? false
        self.modifierDragShowsIndicator = (storage.object(forKey: StorageKey.modifierDragShowsIndicator) as? NSNumber)?.boolValue ?? true
        let storedModifierRawValue = (storage.object(forKey: StorageKey.modifierDragModifiers) as? NSNumber)?.uint8Value
        let storedModifiers = storedModifierRawValue.map(ShortcutModifiers.init(rawValue:))
        if let storedModifiers,
           storedModifiers.containsOnlySupportedValues,
           !storedModifiers.isEmpty {
            self.modifierDragModifiers = storedModifiers
        } else {
            self.modifierDragModifiers = Self.defaultModifierDragModifiers
        }
        let storedShortcutPreset = storage.string(forKey: StorageKey.shortcutPreset)
        self.shortcutPreset = WindowShortcutPreset(storedValue: storedShortcutPreset)
        if storedShortcutPreset == "raycast" || storedShortcutPreset == "rectangle" {
            storage.set(shortcutPreset.rawValue, forKey: StorageKey.shortcutPreset)
        }
        reloadLibrary()
    }

    static let defaultModifierDragModifiers: ShortcutModifiers = [.control, .option]

    func portableBackup() -> Data? {
        guard storage.object(forKey: StorageKey.portableRestore) == nil else { return nil }
        let payload = portablePreferences
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard isValid(payload), let data = try? encoder.encode(payload),
              data.count <= Self.maximumPortableBytes else { return nil }
        return data
    }

    func customActionIDs(inPortableBackup data: Data) -> [String]? {
        decodedPortablePreferences(data)?.customCommands.map(\.actionID)
    }

    @discardableResult
    func restorePortableBackup(_ data: Data) -> Bool {
        guard let payload = decodedPortablePreferences(data),
              Self.recoverPortableRestore(storage: storage) else { return false }
        guard payload != portablePreferences else { return true }
        guard let library = try? JSONEncoder().encode(LibraryEnvelope(
            formatVersion: 1, customCommands: payload.customCommands
        )) else { return false }
        let candidate: [String: Any] = [
            StorageKey.gap: payload.gap,
            StorageKey.cyclesHalves: payload.cyclesHalves,
            StorageKey.respectsStageManager: payload.respectsStageManager,
            StorageKey.showsCommandFeedback: payload.showsCommandFeedback,
            StorageKey.centeredGuidesEnabled: payload.centeredGuidesEnabled,
            StorageKey.modifierDragEnabled: payload.modifierDragEnabled,
            StorageKey.modifierDragModifiers: payload.modifierDragModifiers.rawValue,
            StorageKey.modifierDragShowsIndicator: payload.modifierDragShowsIndicator,
            StorageKey.shortcutPreset: payload.shortcutPreset.rawValue,
            StorageKey.library: library,
        ]
        guard persistValues(candidate) else { return false }
        gap = payload.gap
        cyclesHalves = payload.cyclesHalves
        respectsStageManager = payload.respectsStageManager
        showsCommandFeedback = payload.showsCommandFeedback
        centeredGuidesEnabled = payload.centeredGuidesEnabled
        modifierDragEnabled = payload.modifierDragEnabled
        modifierDragModifiers = payload.modifierDragModifiers
        modifierDragShowsIndicator = payload.modifierDragShowsIndicator
        shortcutPreset = payload.shortcutPreset
        customCommands = payload.customCommands
        recordMutation()
        onSafetyPolicyMutation?()
        return true
    }

    private var portablePreferences: PortablePreferences {
        PortablePreferences(
            formatVersion: 1, gap: gap, cyclesHalves: cyclesHalves,
            respectsStageManager: respectsStageManager, showsCommandFeedback: showsCommandFeedback,
            centeredGuidesEnabled: centeredGuidesEnabled, modifierDragEnabled: modifierDragEnabled,
            modifierDragModifiers: modifierDragModifiers, modifierDragShowsIndicator: modifierDragShowsIndicator,
            shortcutPreset: shortcutPreset, customCommands: customCommands.map { command in
                var copy = command
                copy.allowExternalInvocation = false
                return copy
            }
        )
    }

    private func decodedPortablePreferences(_ data: Data) -> PortablePreferences? {
        guard data.count <= Self.maximumPortableBytes,
              let payload = try? JSONDecoder().decode(PortablePreferences.self, from: data),
              isValid(payload) else { return nil }
        return payload
    }

    private func isValid(_ payload: PortablePreferences) -> Bool {
        payload.formatVersion == 1 && payload.gap.isFinite && Self.gapRange.contains(payload.gap)
            && !payload.modifierDragModifiers.isEmpty && payload.modifierDragModifiers.containsOnlySupportedValues
            && payload.customCommands.count <= Self.maximumCustomCommandCount
            && normalizedCommands(payload.customCommands) == payload.customCommands
            && payload.customCommands.allSatisfy { !$0.allowExternalInvocation }
    }

    private static func matches(_ values: [String: Any], storage: PluginStorage) -> Bool {
        portableKeys.allSatisfy { key in
            switch (values[key] as? NSObject, storage.object(forKey: key) as? NSObject) {
            case (nil, nil): true
            case let (expected?, actual?): expected.isEqual(actual)
            default: false
            }
        }
    }

    private static func recoverPortableRestore(storage: PluginStorage) -> Bool {
        guard let rawJournal = storage.object(forKey: StorageKey.portableRestore) else { return true }
        guard let data = rawJournal as? Data, data.count <= maximumPortableBytes,
              let previous = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              Set(previous.keys).isSubset(of: Set(portableKeys)) else { return false }
        for key in portableKeys {
            if let value = previous[key] { storage.set(value, forKey: key) }
            else { storage.removeObject(forKey: key) }
        }
        guard matches(previous, storage: storage) else { return false }
        storage.removeObject(forKey: StorageKey.portableRestore)
        return storage.object(forKey: StorageKey.portableRestore) == nil
    }

    func setGap(_ gap: Double) {
        let gap = Self.clampedGap(gap)
        guard self.gap != gap, persistValues([StorageKey.gap: gap]) else { return }
        self.gap = gap
        recordMutation()
    }

    func setCyclesHalves(_ enabled: Bool) {
        guard cyclesHalves != enabled, persistValues([StorageKey.cyclesHalves: enabled]) else { return }
        cyclesHalves = enabled
        recordMutation()
    }

    func setRespectsStageManager(_ enabled: Bool) {
        guard respectsStageManager != enabled, persistValues([StorageKey.respectsStageManager: enabled]) else { return }
        respectsStageManager = enabled
        recordMutation()
    }

    func setShowsCommandFeedback(_ enabled: Bool) {
        guard showsCommandFeedback != enabled, persistValues([StorageKey.showsCommandFeedback: enabled]) else { return }
        showsCommandFeedback = enabled
        recordMutation()
    }

    func setCenteredGuidesEnabled(_ enabled: Bool) {
        guard centeredGuidesEnabled != enabled, persistValues([StorageKey.centeredGuidesEnabled: enabled]) else { return }
        centeredGuidesEnabled = enabled
        recordMutation()
    }

    func setModifierDragEnabled(_ enabled: Bool) {
        guard modifierDragEnabled != enabled, persistValues([StorageKey.modifierDragEnabled: enabled]) else { return }
        modifierDragEnabled = enabled
        recordMutation()
    }

    func setModifierDragModifiers(_ modifiers: ShortcutModifiers) {
        guard !modifiers.isEmpty, modifiers.containsOnlySupportedValues else { return }
        guard modifierDragModifiers != modifiers, persistValues([StorageKey.modifierDragModifiers: modifiers.rawValue]) else { return }
        modifierDragModifiers = modifiers
        recordMutation()
    }

    func setModifierDragShowsIndicator(_ enabled: Bool) {
        guard modifierDragShowsIndicator != enabled, persistValues([StorageKey.modifierDragShowsIndicator: enabled]) else { return }
        modifierDragShowsIndicator = enabled
        recordMutation()
    }

    func setShortcutPreset(_ preset: WindowShortcutPreset) {
        guard shortcutPreset != preset, persistValues([StorageKey.shortcutPreset: preset.rawValue]) else { return }
        shortcutPreset = preset
        recordMutation()
    }

    func reset() {
        let keys = Set(Self.portableKeys).subtracting([StorageKey.shortcutPreset, StorageKey.library])
        guard persistValues([:], removing: keys) else { return }
        gap = Self.defaultGap
        cyclesHalves = false
        respectsStageManager = true
        showsCommandFeedback = false
        centeredGuidesEnabled = false
        modifierDragEnabled = false
        modifierDragModifiers = Self.defaultModifierDragModifiers
        modifierDragShowsIndicator = true
        recordMutation()
    }

    private func persistValues(_ candidate: [String: Any], removing: Set<String> = []) -> Bool {
        guard Self.recoverPortableRestore(storage: storage) else { return false }
        var previous: [String: Any] = [:]
        for key in Self.portableKeys { previous[key] = storage.object(forKey: key) }
        guard let journal = try? PropertyListSerialization.data(
            fromPropertyList: previous, format: .binary, options: 0
        ), journal.count <= Self.maximumPortableBytes else { return false }
        storage.set(journal, forKey: StorageKey.portableRestore)
        guard storage.data(forKey: StorageKey.portableRestore) == journal else { return false }
        for (key, value) in candidate { storage.set(value, forKey: key) }
        for key in removing { storage.removeObject(forKey: key) }
        let expected = previous.merging(candidate, uniquingKeysWith: { _, incoming in incoming })
            .filter { !removing.contains($0.key) }
        guard Self.matches(expected, storage: storage) else {
            _ = Self.recoverPortableRestore(storage: storage)
            return false
        }
        storage.removeObject(forKey: StorageKey.portableRestore)
        guard storage.object(forKey: StorageKey.portableRestore) == nil else {
            _ = Self.recoverPortableRestore(storage: storage)
            return false
        }
        return true
    }

    @discardableResult
    func addCustomCommand(name: String) -> WindowCustomCommand? {
        guard customCommands.count < Self.maximumCustomCommandCount else { return nil }
        let command = WindowCustomCommand(name: normalizedName(name, fallback: "Custom Layout"))
        var updated = customCommands
        updated.append(command)
        guard persist(customCommands: updated) else { return nil }
        customCommands = updated
        recordMutation()
        return command
    }

    @discardableResult
    func updateCustomCommand(_ command: WindowCustomCommand) -> Bool {
        guard let index = customCommands.firstIndex(where: { $0.id == command.id })
        else { return false }
        guard let normalized = normalizedCommand(command) else { return false }
        let externalInvocationPolicyChanged =
            customCommands[index].allowExternalInvocation != normalized.allowExternalInvocation
        var updated = customCommands
        updated[index] = normalized
        guard persist(customCommands: updated) else { return false }
        customCommands = updated
        recordMutation()
        if externalInvocationPolicyChanged {
            onSafetyPolicyMutation?()
        }
        return true
    }

    @discardableResult
    func duplicateCustomCommand(id: UUID, copySuffix: String) -> WindowCustomCommand? {
        guard let source = customCommands.first(where: { $0.id == id }),
              customCommands.count < Self.maximumCustomCommandCount
        else { return nil }
        let copy = WindowCustomCommand(
            name: duplicateName(source.name, copySuffix: copySuffix),
            width: source.width,
            height: source.height,
            anchor: source.anchor,
            offsetX: source.offsetX,
            offsetY: source.offsetY,
            allowExternalInvocation: source.allowExternalInvocation
        )
        var updated = customCommands
        updated.append(copy)
        guard persist(customCommands: updated) else { return nil }
        customCommands = updated
        recordMutation()
        return copy
    }

    @discardableResult
    func removeCustomCommand(id: UUID) -> Bool {
        var updated = customCommands
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return false }
        updated.remove(at: index)
        guard persist(customCommands: updated) else { return false }
        customCommands = updated
        recordMutation()
        return true
    }

    func customCommand(actionID: String) -> WindowCustomCommand? {
        customCommands.first { $0.actionID == actionID }
    }

    func customCommand(id: UUID) -> WindowCustomCommand? {
        customCommands.first { $0.id == id }
    }

    private func reloadLibrary() {
        guard let data = storage.data(forKey: StorageKey.library) else { return }
        guard data.count <= 2 * 1_024 * 1_024,
              let envelope = try? JSONDecoder().decode(LibraryEnvelope.self, from: data),
              envelope.formatVersion == 1,
              envelope.customCommands.count <= Self.maximumCustomCommandCount,
              let normalizedCommands = normalizedCommands(envelope.customCommands)
        else {
            quarantine(data)
            return
        }
        if normalizedCommands != envelope.customCommands,
           !persist(customCommands: normalizedCommands) {
            quarantine(data)
            return
        }
        customCommands = normalizedCommands
    }

    private func persist(customCommands: [WindowCustomCommand]) -> Bool {
        guard customCommands.count <= Self.maximumCustomCommandCount,
              let normalizedCommands = normalizedCommands(customCommands),
              normalizedCommands == customCommands,
              let data = try? JSONEncoder().encode(LibraryEnvelope(
            formatVersion: 1,
            customCommands: customCommands
        )), data.count <= 2 * 1_024 * 1_024 else {
            return false
        }
        return persistValues([StorageKey.library: data])
    }

    private func normalizedCommands(
        _ commands: [WindowCustomCommand]
    ) -> [WindowCustomCommand]? {
        var seenIDs: Set<UUID> = []
        var result: [WindowCustomCommand] = []
        result.reserveCapacity(commands.count)
        for command in commands {
            guard seenIDs.insert(command.id).inserted,
                  let normalized = normalizedCommand(command)
            else {
                return nil
            }
            result.append(normalized)
        }
        return result
    }

    private func normalizedCommand(_ command: WindowCustomCommand) -> WindowCustomCommand? {
        guard let width = normalizedDimension(command.width),
              let height = normalizedDimension(command.height),
              command.offsetX.isFinite,
              command.offsetY.isFinite
        else {
            return nil
        }
        var normalized = command
        normalized.name = normalizedName(command.name, fallback: "Custom Layout")
        normalized.width = width
        normalized.height = height
        normalized.offsetX = min(max(command.offsetX, Self.offsetRange.lowerBound), Self.offsetRange.upperBound)
        normalized.offsetY = min(max(command.offsetY, Self.offsetRange.lowerBound), Self.offsetRange.upperBound)
        return normalized
    }

    private func normalizedDimension(
        _ dimension: WindowLayoutDimension
    ) -> WindowLayoutDimension? {
        switch dimension {
        case .current:
            return .current
        case let .points(value):
            guard value.isFinite else { return nil }
            return .points(min(max(value, Self.pointDimensionRange.lowerBound), Self.pointDimensionRange.upperBound))
        case let .fraction(value):
            guard value.isFinite else { return nil }
            return .fraction(min(max(value, Self.fractionDimensionRange.lowerBound), Self.fractionDimensionRange.upperBound))
        }
    }

    private func quarantine(_ data: Data) {
        storage.set(data, forKey: StorageKey.quarantinedLibrary)
        storage.removeObject(forKey: StorageKey.library)
    }

    private func normalizedName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(Self.maximumCustomCommandNameLength))
    }

    private func duplicateName(_ sourceName: String, copySuffix: String) -> String {
        let trimmedSuffix = copySuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSuffix.isEmpty else {
            return normalizedName(sourceName, fallback: "Custom Layout")
        }
        let boundedSuffix = String(trimmedSuffix.prefix(Self.maximumCustomCommandNameLength - 2))
        let suffix = " \(boundedSuffix)"
        let sourceLength = max(1, Self.maximumCustomCommandNameLength - suffix.count)
        let source = String(sourceName.prefix(sourceLength))
        return normalizedName(source + suffix, fallback: "Custom Layout")
    }

    private func recordMutation() {
        revision &+= 1
        onMutation?()
    }

    private static func clampedGap(_ gap: Double) -> Double {
        guard gap.isFinite else { return defaultGap }
        return min(max(gap, gapRange.lowerBound), gapRange.upperBound)
    }
}
