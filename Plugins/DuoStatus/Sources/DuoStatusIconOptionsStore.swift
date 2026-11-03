import Foundation
import MacToolsPluginKit

// Adapted from Status Trio (https://github.com/lingyired/status-trio, Apache-2.0).

/// Persists `DuoStatusIconOptions` through the plugin's scoped storage.
/// Keys are stable and must not be renamed without a migration.
@MainActor
struct DuoStatusIconOptionsStore {
    enum Key {
        static let iconSize = "icon-size"
        static let bottomIndicator = "bottom-indicator"
        static let volumeStyle = "volume-style"
        static let showsBatteryPercentage = "shows-battery-percentage"
        static let showsPercentageWhenConnected = "shows-percentage-when-connected"
        static let showsChargingIndicator = "shows-charging-indicator"
        static let batteryColorPolicy = "battery-color-policy"
        static let legacyUsesBatteryStatusColors = "uses-battery-status-colors"
        static let batteryCriticalThreshold = "battery-critical-threshold"
        static let distinguishesNoInternet = "distinguishes-no-internet"
        static let distinguishesHotspot = "distinguishes-hotspot"
        static let distinguishesTemporaryNetwork = "distinguishes-temporary-network"
        static let distinguishesInternetSharing = "distinguishes-internet-sharing"
        static let showsBluetoothAudioGlyph = "shows-bluetooth-audio-glyph"
        static let bluetoothGlyphPrioritizesNetworkErrors = "bluetooth-glyph-prioritizes-network-errors"
    }

    static let criticalThresholdRange = 5...50
    static let criticalThresholdStep = 5

    private let storage: PluginStorage

    init(storage: PluginStorage) {
        self.storage = storage
        _ = Self.portableStore(storage: storage).recover()
    }

    /// A missing key keeps the default, so an option the user never touched
    /// always resolves to the shipping behaviour.
    func load() -> DuoStatusIconOptions {
        var options = DuoStatusIconOptions.default
        if let raw = storage.string(forKey: Key.iconSize),
           let size = DuoStatusIconSize(rawValue: raw) {
            options.iconSize = size
        }
        if let raw = storage.string(forKey: Key.bottomIndicator),
           let indicator = DuoStatusBottomIndicator(rawValue: raw) {
            options.bottomIndicator = indicator
        }
        if let raw = storage.string(forKey: Key.volumeStyle),
           let style = DuoStatusVolumeStyle(rawValue: raw) {
            options.volumeStyle = style
        }
        options.showsBatteryPercentage = bool(
            Key.showsBatteryPercentage, default: options.showsBatteryPercentage
        )
        options.showsPercentageWhenConnected = bool(
            Key.showsPercentageWhenConnected, default: options.showsPercentageWhenConnected
        )
        options.showsChargingIndicator = bool(
            Key.showsChargingIndicator, default: options.showsChargingIndicator
        )
        options.batteryColorPolicy = batteryColorPolicy(default: options.batteryColorPolicy)
        if let threshold = storage.object(forKey: Key.batteryCriticalThreshold) as? Int {
            options.batteryCriticalThreshold = Self.clampedThreshold(threshold)
        }
        options.distinguishesNoInternet = bool(
            Key.distinguishesNoInternet, default: options.distinguishesNoInternet
        )
        options.distinguishesHotspot = bool(
            Key.distinguishesHotspot, default: options.distinguishesHotspot
        )
        options.distinguishesTemporaryNetwork = bool(
            Key.distinguishesTemporaryNetwork, default: options.distinguishesTemporaryNetwork
        )
        options.distinguishesInternetSharing = bool(
            Key.distinguishesInternetSharing, default: options.distinguishesInternetSharing
        )
        options.showsBluetoothAudioGlyph = bool(
            Key.showsBluetoothAudioGlyph, default: options.showsBluetoothAudioGlyph
        )
        options.bluetoothGlyphPrioritizesNetworkErrors = bool(
            Key.bluetoothGlyphPrioritizesNetworkErrors,
            default: options.bluetoothGlyphPrioritizesNetworkErrors
        )
        return options
    }

    private static func portableStore(storage: any PluginStorage) -> PortablePreferencesStore {
        PortablePreferencesStore(storage: storage, fields: [
            Key.iconSize: .choice("small", allowed: DuoStatusIconSize.allCases.map(\.rawValue)),
            Key.bottomIndicator: .choice("wifi", allowed: DuoStatusBottomIndicator.allCases.map(\.rawValue)),
            Key.volumeStyle: .choice("dots", allowed: DuoStatusVolumeStyle.allCases.map(\.rawValue)),
            Key.batteryColorPolicy: .choice("legacy", allowed: DuoStatusBatteryColorPolicy.allCases.map(\.rawValue)),
            Key.showsBatteryPercentage: .boolean(false),
            Key.showsPercentageWhenConnected: .boolean(false),
            Key.showsChargingIndicator: .boolean(true),
            Key.distinguishesNoInternet: .boolean(false),
            Key.distinguishesHotspot: .boolean(false),
            Key.distinguishesTemporaryNetwork: .boolean(false),
            Key.distinguishesInternetSharing: .boolean(false),
            Key.showsBluetoothAudioGlyph: .boolean(false),
            Key.bluetoothGlyphPrioritizesNetworkErrors: .boolean(true),
            Key.batteryCriticalThreshold: PortablePreferenceField(fallback: .integer(20)) {
                if case let .integer(value) = $0 { (5...50).contains(value) && value % 5 == 0 } else { false }
            }
        ])
    }
    private var portableStore: PortablePreferencesStore { Self.portableStore(storage: storage) }
    func portableBackup() -> Data? {
        // Read through the legacy color-policy adapter without mutating old storage.
        let options = load()
        return portableStore.backup(overriding: values(options))
    }
    func restorePortableBackup(_ data: Data) -> Bool { portableStore.restore(data) }

    @discardableResult
    func save(_ options: DuoStatusIconOptions) -> Bool { portableStore.commit(values(options)) }

    private func values(_ options: DuoStatusIconOptions) -> [String: PortablePreferenceValue] {
        [
            Key.iconSize: .string(options.iconSize.rawValue),
            Key.bottomIndicator: .string(options.bottomIndicator.rawValue),
            Key.volumeStyle: .string(options.volumeStyle.rawValue),
            Key.batteryColorPolicy: .string(options.batteryColorPolicy.rawValue),
            Key.showsBatteryPercentage: .boolean(options.showsBatteryPercentage),
            Key.showsPercentageWhenConnected: .boolean(options.showsPercentageWhenConnected),
            Key.showsChargingIndicator: .boolean(options.showsChargingIndicator),
            Key.distinguishesNoInternet: .boolean(options.distinguishesNoInternet),
            Key.distinguishesHotspot: .boolean(options.distinguishesHotspot),
            Key.distinguishesTemporaryNetwork: .boolean(options.distinguishesTemporaryNetwork),
            Key.distinguishesInternetSharing: .boolean(options.distinguishesInternetSharing),
            Key.showsBluetoothAudioGlyph: .boolean(options.showsBluetoothAudioGlyph),
            Key.bluetoothGlyphPrioritizesNetworkErrors: .boolean(options.bluetoothGlyphPrioritizesNetworkErrors),
            Key.batteryCriticalThreshold: .integer(Self.clampedThreshold(options.batteryCriticalThreshold))
        ]
    }

    /// Snaps to the slider's step and clamps to its range so a stored value from
    /// another build can never drive the warning colour outside the shown range.
    static func clampedThreshold(_ value: Int) -> Int {
        let step = criticalThresholdStep
        let bounded = min(criticalThresholdRange.upperBound,
                          max(criticalThresholdRange.lowerBound, value))
        let snapped = Int((Double(bounded) / Double(step)).rounded()) * step
        return min(criticalThresholdRange.upperBound,
                   max(criticalThresholdRange.lowerBound, snapped))
    }

    /// Keep values written by PR builds meaningful while the final default
    /// remains the policy shipped by the current Duo Status release.
    private func batteryColorPolicy(
        default defaultValue: DuoStatusBatteryColorPolicy
    ) -> DuoStatusBatteryColorPolicy {
        if let raw = storage.string(forKey: Key.batteryColorPolicy),
           let policy = DuoStatusBatteryColorPolicy(rawValue: raw) {
            return policy
        }
        guard let legacyEnabled = storage.object(
            forKey: Key.legacyUsesBatteryStatusColors
        ) as? Bool else {
            return defaultValue
        }
        return legacyEnabled ? .enhanced : .monochrome
    }

    private func bool(_ key: String, default defaultValue: Bool) -> Bool {
        storage.object(forKey: key) as? Bool ?? defaultValue
    }
}
