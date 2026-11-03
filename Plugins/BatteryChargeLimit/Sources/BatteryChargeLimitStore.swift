import Foundation
import MacToolsPluginKit

struct BatteryChargeLimitState: Equatable {
    var isEnabled: Bool
    var limitPercent: Int
    var mode: BatteryChargeMode
}

enum BatteryChargeLimitStoreCommitResult: Equatable {
    case committed
    case rejected(rollbackSucceeded: Bool)
}

/// Persists user-controlled state for the battery charge-limit plugin:
/// whether it's enabled, the charge ceiling, and the last mode.
@MainActor
final class BatteryChargeLimitStore: ObservableObject {
    private enum Key {
        static let isEnabled = "is-enabled"
        static let limitPercent = "limit-percent"
        static let mode = "mode"
    }

    private let storage: PluginStorage

    @Published private(set) var isEnabled: Bool
    @Published private(set) var limitPercent: Int
    @Published private(set) var mode: BatteryChargeMode

    var state: BatteryChargeLimitState {
        BatteryChargeLimitState(
            isEnabled: isEnabled,
            limitPercent: limitPercent,
            mode: mode
        )
    }

    init(storage: PluginStorage) {
        self.storage = storage
        _ = Self.portableStore(storage: storage).recover()

        // isEnabled — default off; user must opt in. We store the inverse of
        // "explicitly disabled" so the first launch is a clean disabled state.
        let storedIsEnabled = storage.object(forKey: Key.isEnabled) as? Bool
        self.isEnabled = storedIsEnabled ?? false

        // limitPercent — clamp to the supported range.
        let storedLimit = storage.object(forKey: Key.limitPercent) as? Int
        let initial = storedLimit ?? BatteryChargeLimits.defaultPercent
        self.limitPercent = max(
            BatteryChargeLimits.minimumPercent,
            min(BatteryChargeLimits.maximumPercent, initial)
        )

        // mode — default to .holdAtLimit (the plugin's main mode).
        if let raw = storage.string(forKey: Key.mode),
           let parsed = BatteryChargeMode(rawValue: raw) {
            self.mode = parsed
        } else {
            self.mode = .holdAtLimit
        }
    }

    var onPersistentPreferencesChange: (() -> Void)?
    private static func portableStore(storage: any PluginStorage) -> PortablePreferencesStore {
        PortablePreferencesStore(storage: storage, fields: [
            Key.limitPercent: .integer(BatteryChargeLimits.defaultPercent, range: BatteryChargeLimits.minimumPercent...BatteryChargeLimits.maximumPercent),
            Key.mode: .choice("holdAtLimit", allowed: ["holdAtLimit", "charging", "discharging"])
        ])
    }
    private var portableStore: PortablePreferencesStore { Self.portableStore(storage: storage) }
    func portableBackup() -> Data? { portableStore.backup() }
    func restorePortableBackup(_ data: Data) -> Bool {
        // An active session reads these values on timer/wake events. Preserve it until locally disabled.
        guard !isEnabled else { return false }
        let previous = portableStore.currentValues()
        guard portableStore.restore(data) else { return false }
        limitPercent = storage.object(forKey: Key.limitPercent) as? Int ?? BatteryChargeLimits.defaultPercent
        mode = storage.string(forKey: Key.mode).flatMap(BatteryChargeMode.init(rawValue:)) ?? .holdAtLimit
        if previous != portableStore.currentValues() { onPersistentPreferencesChange?() }
        return true
    }

    // MARK: - Mutators

    @discardableResult
    func setEnabled(_ value: Bool) -> BatteryChargeLimitStoreCommitResult {
        var candidate = state
        candidate.isEnabled = value
        return commit(candidate)
    }

    @discardableResult
    func setLimitPercent(_ value: Int) -> BatteryChargeLimitStoreCommitResult {
        var candidate = state
        candidate.limitPercent = value
        return commit(candidate)
    }

    @discardableResult
    func setMode(_ value: BatteryChargeMode) -> BatteryChargeLimitStoreCommitResult {
        var candidate = state
        candidate.mode = value
        return commit(candidate)
    }

    @discardableResult
    func commit(_ candidate: BatteryChargeLimitState) -> BatteryChargeLimitStoreCommitResult {
        let normalized = BatteryChargeLimitState(
            isEnabled: candidate.isEnabled,
            limitPercent: max(
            BatteryChargeLimits.minimumPercent,
                min(BatteryChargeLimits.maximumPercent, candidate.limitPercent)
            ),
            mode: candidate.mode
        )
        let previousRaw = RawState(
            isEnabled: storage.object(forKey: Key.isEnabled),
            limitPercent: storage.object(forKey: Key.limitPercent),
            mode: storage.object(forKey: Key.mode)
        )

        write(normalized)
        guard persistedStateMatches(normalized) else {
            restore(previousRaw)
            return .rejected(rollbackSucceeded: rawStateMatches(previousRaw))
        }

        let portableChanged = limitPercent != normalized.limitPercent || mode != normalized.mode
        isEnabled = normalized.isEnabled
        limitPercent = normalized.limitPercent
        mode = normalized.mode
        if portableChanged { onPersistentPreferencesChange?() }
        return .committed
    }

    private struct RawState {
        let isEnabled: Any?
        let limitPercent: Any?
        let mode: Any?
    }

    private func write(_ state: BatteryChargeLimitState) {
        storage.set(state.isEnabled, forKey: Key.isEnabled)
        storage.set(state.limitPercent, forKey: Key.limitPercent)
        storage.set(state.mode.rawValue, forKey: Key.mode)
    }

    private func persistedStateMatches(_ state: BatteryChargeLimitState) -> Bool {
        (storage.object(forKey: Key.isEnabled) as? Bool) == state.isEnabled
            && (storage.object(forKey: Key.limitPercent) as? Int) == state.limitPercent
            && storage.string(forKey: Key.mode) == state.mode.rawValue
    }

    private func restore(_ raw: RawState) {
        restore(raw.isEnabled, forKey: Key.isEnabled)
        restore(raw.limitPercent, forKey: Key.limitPercent)
        restore(raw.mode, forKey: Key.mode)
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            storage.set(value, forKey: key)
        } else {
            storage.removeObject(forKey: key)
        }
    }

    private func rawStateMatches(_ raw: RawState) -> Bool {
        rawValue(storage.object(forKey: Key.isEnabled), equals: raw.isEnabled)
            && rawValue(storage.object(forKey: Key.limitPercent), equals: raw.limitPercent)
            && rawValue(storage.object(forKey: Key.mode), equals: raw.mode)
    }

    private func rawValue(_ lhs: Any?, equals rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs as NSObject, rhs as NSObject): lhs.isEqual(rhs)
        default: false
        }
    }
}
