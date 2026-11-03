import Foundation
import MacToolsPluginKit

@MainActor
final class DeviceBatteryStore: ObservableObject {
    private enum Key {
        static let layoutMode = "layout-mode"
        static let showInternalBattery = "show-internal-battery"
        static let showBluetoothDevices = "show-bluetooth-devices"
        static let showAppleMobileDevices = "show-apple-mobile-devices"
        static let showVendorHIDDevices = "show-rapoo-devices"  // storage key kept for backward compatibility
        static let lowBatteryNotificationEnabled = "low-battery-notification-enabled"
        static let lowBatteryNotificationThreshold = "low-battery-notification-threshold"
    }

    @Published private(set) var layoutMode: DeviceBatteryLayoutMode
    @Published private(set) var showInternalBattery: Bool
    @Published private(set) var showBluetoothDevices: Bool
    @Published private(set) var showAppleMobileDevices: Bool
    @Published private(set) var showVendorHIDDevices: Bool
    @Published private(set) var lowBatteryNotificationEnabled: Bool
    @Published private(set) var lowBatteryNotificationThreshold: Int

    private let storage: any PluginStorage

    init(storage: any PluginStorage) {
        self.storage = storage
        _ = Self.portableStore(storage: storage).recover()
        layoutMode = DeviceBatteryLayoutMode(
            rawValue: storage.string(forKey: Key.layoutMode) ?? DeviceBatteryLayoutMode.grid.rawValue
        ) ?? .grid
        showInternalBattery = Self.boolValue(storage, key: Key.showInternalBattery, defaultValue: true)
        showBluetoothDevices = Self.boolValue(storage, key: Key.showBluetoothDevices, defaultValue: true)
        showAppleMobileDevices = Self.boolValue(storage, key: Key.showAppleMobileDevices, defaultValue: true)
        showVendorHIDDevices = Self.boolValue(storage, key: Key.showVendorHIDDevices, defaultValue: true)
        lowBatteryNotificationEnabled = Self.boolValue(
            storage,
            key: Key.lowBatteryNotificationEnabled,
            defaultValue: false
        )
        lowBatteryNotificationThreshold = Self.normalizedLowBatteryNotificationThreshold(
            storage.object(forKey: Key.lowBatteryNotificationThreshold) == nil
                ? DeviceBatteryLowBatteryThresholds.defaultValue
                : storage.integer(forKey: Key.lowBatteryNotificationThreshold)
        )
    }

    var onPersistentPreferencesChange: (() -> Void)?
    private static func portableStore(storage: any PluginStorage) -> PortablePreferencesStore {
        PortablePreferencesStore(storage: storage, fields: [
            Key.layoutMode: .choice("grid", allowed: DeviceBatteryLayoutMode.allCases.map(\.rawValue)),
            Key.showInternalBattery: .boolean(true),
            Key.showBluetoothDevices: .boolean(true),
            Key.showAppleMobileDevices: .boolean(true),
            Key.showVendorHIDDevices: .boolean(true),
            Key.lowBatteryNotificationEnabled: .boolean(false),
            Key.lowBatteryNotificationThreshold: .integer(DeviceBatteryLowBatteryThresholds.defaultValue, range: 1...99)
        ])
    }
    private var portableStore: PortablePreferencesStore { Self.portableStore(storage: storage) }
    func portableBackup() -> Data? { portableStore.backup() }
    func restorePortableBackup(_ data: Data) -> Bool {
        let previous = portableStore.currentValues()
        guard portableStore.restore(data) else { return false }
        layoutMode = storage.string(forKey: Key.layoutMode).flatMap(DeviceBatteryLayoutMode.init(rawValue:)) ?? .grid
        showInternalBattery = storage.object(forKey: Key.showInternalBattery) as? Bool ?? true
        showBluetoothDevices = storage.object(forKey: Key.showBluetoothDevices) as? Bool ?? true
        showAppleMobileDevices = storage.object(forKey: Key.showAppleMobileDevices) as? Bool ?? true
        showVendorHIDDevices = storage.object(forKey: Key.showVendorHIDDevices) as? Bool ?? true
        lowBatteryNotificationEnabled = storage.object(forKey: Key.lowBatteryNotificationEnabled) as? Bool ?? false
        lowBatteryNotificationThreshold = storage.object(forKey: Key.lowBatteryNotificationThreshold) as? Int ?? DeviceBatteryLowBatteryThresholds.defaultValue
        if previous != portableStore.currentValues() { onPersistentPreferencesChange?() }
        return true
    }

    func setLayoutMode(_ mode: DeviceBatteryLayoutMode) {
        guard layoutMode != mode else {
            return
        }

        guard portableStore.commit([Key.layoutMode: .string(mode.rawValue)]) else { return }
        layoutMode = mode
        onPersistentPreferencesChange?()
    }

    func setShowInternalBattery(_ isShown: Bool) {
        guard showInternalBattery != isShown else {
            return
        }

        guard portableStore.commit([Key.showInternalBattery: .boolean(isShown)]) else { return }
        showInternalBattery = isShown
        onPersistentPreferencesChange?()
    }

    func setShowBluetoothDevices(_ isShown: Bool) {
        guard showBluetoothDevices != isShown else {
            return
        }

        guard portableStore.commit([Key.showBluetoothDevices: .boolean(isShown)]) else { return }
        showBluetoothDevices = isShown
        onPersistentPreferencesChange?()
    }

    func setShowAppleMobileDevices(_ isShown: Bool) {
        guard showAppleMobileDevices != isShown else {
            return
        }

        guard portableStore.commit([Key.showAppleMobileDevices: .boolean(isShown)]) else { return }
        showAppleMobileDevices = isShown
        onPersistentPreferencesChange?()
    }

    func setShowVendorHIDDevices(_ isShown: Bool) {
        guard showVendorHIDDevices != isShown else {
            return
        }

        guard portableStore.commit([Key.showVendorHIDDevices: .boolean(isShown)]) else { return }
        showVendorHIDDevices = isShown
        onPersistentPreferencesChange?()
    }

    func setLowBatteryNotificationEnabled(_ isEnabled: Bool) {
        guard lowBatteryNotificationEnabled != isEnabled else {
            return
        }

        guard portableStore.commit([Key.lowBatteryNotificationEnabled: .boolean(isEnabled)]) else { return }
        lowBatteryNotificationEnabled = isEnabled
        onPersistentPreferencesChange?()
    }

    func setLowBatteryNotificationThreshold(_ threshold: Int) {
        let normalizedThreshold = Self.normalizedLowBatteryNotificationThreshold(threshold)
        guard lowBatteryNotificationThreshold != normalizedThreshold else {
            return
        }

        guard portableStore.commit([Key.lowBatteryNotificationThreshold: .integer(normalizedThreshold)]) else { return }
        lowBatteryNotificationThreshold = normalizedThreshold
        onPersistentPreferencesChange?()
    }

    static func normalizedLowBatteryNotificationThreshold(_ threshold: Int) -> Int {
        DeviceBatteryLowBatteryThresholds.normalized(threshold)
    }

    private static func boolValue(
        _ storage: any PluginStorage,
        key: String,
        defaultValue: Bool
    ) -> Bool {
        guard storage.object(forKey: key) != nil else {
            return defaultValue
        }

        return storage.bool(forKey: key)
    }
}
