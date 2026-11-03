import Foundation
import IOKit.hid
import IOKit.ps
import LocalAuthentication

struct LauncherSettingsHardware: Hashable, Sendable {
    var hasBattery = false
    var hasMouse = false
    var hasTrackpad = false
    var hasTouchID = false

    static func read(includingBiometry: Bool = true) -> Self {
        var result = Self()
        if let power = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(power)?.takeRetainedValue() as? [CFTypeRef] {
            result.hasBattery = sources.contains { source in
                let info = IOPSGetPowerSourceDescription(power, source)?.takeUnretainedValue() as? [String: Any]
                return info?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            }
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        // Enumerate metadata only: do not open devices, capture input, or request input-monitoring access.
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in devices {
                let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "").lowercased()
                let trackpad = IOHIDDeviceConformsTo(device, 0x0D, 0x05)
                    || product.contains("trackpad") || product.contains("touchpad")
                result.hasTrackpad = result.hasTrackpad || trackpad
                result.hasMouse = result.hasMouse || (!trackpad && IOHIDDeviceConformsTo(device, 0x01, 0x02))
            }
        }
        if includingBiometry {
            let authentication = LAContext()
            _ = authentication.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            result.hasTouchID = authentication.biometryType == .touchID
            authentication.invalidate()
        }
        return result
    }
}

/// A scan cache contains metadata snapshots only, never account state or setting values.
enum LauncherSystemSettingsScanner {
    static let directory = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions", isDirectory: true)
    static let extensionPoint = "com.apple.Settings.extension.ui"

    struct Cache: Sendable {
        let directory: URL
        let modified: Date
        let languages: [String]
        let hardware: LauncherSettingsHardware
        let systemVersion: String
        let fallbackTitles: [String]
        let items: [LauncherSystemSetting]
    }
    struct Snapshot: Sendable {
        let items: [LauncherSystemSetting]
        let cache: Cache?
        let usedFallback: Bool
    }

    static func scan(directory: URL = LauncherSystemSettingsScanner.directory, languages: [String], hardware: LauncherSettingsHardware,
                     fallback: [LauncherSystemSetting], permissionLinks: [LauncherSystemSetting] = [],
                     nameOverrides: [String: String] = [:], cache: Cache? = nil, majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                     systemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
                     fileManager: FileManager = .default) -> Snapshot {
        guard majorVersion >= 14 else { return .init(items: [], cache: nil, usedFallback: false) }
        // URL resource values can retain a stale modification date across refreshes.
        let modified = (try? fileManager.attributesOfItem(atPath: directory.path)[.modificationDate]) as? Date
        let titles = (fallback + permissionLinks).map(\.title) + nameOverrides.sorted { $0.key < $1.key }.map(\.value)
        if let cache, let modified, cache.directory == directory, cache.modified == modified,
           cache.languages == languages, cache.hardware == hardware, cache.systemVersion == systemVersion,
           cache.fallbackTitles == titles {
            return .init(items: cache.items, cache: cache, usedFallback: false)
        }
        guard let urls = try? fileManager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return fallbackSnapshot(directory: directory, fallback: fallback, permissionLinks: permissionLinks,
                hardware: hardware, nameOverrides: nameOverrides, fileManager: fileManager)
        }
        let known = Dictionary(uniqueKeysWithValues: fallback.map { ($0.bundleID, $0) })
        var items: [LauncherSystemSetting] = []
        var seen = Set<String>()
        var foundSettingsMetadata = false
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "appex" {
            guard url.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath(),
                  let info = info(at: url), isSettingsPane(info), let bundleID = info["CFBundleIdentifier"] as? String,
                  validBundleID(bundleID) else { continue }
            foundSettingsMetadata = true
            guard allowsNavigation(info, bundleID: bundleID, hardware: hardware, legacyNavigationAllowed: known[bundleID] != nil), seen.insert(bundleID).inserted else { continue }
            let base = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
            let names = LauncherBundleNames.read(for: url, fallbackName: base, preferredLanguages: languages, fileManager: fileManager)
            let existing = known[bundleID]
            var title = names.name
            if bundleID == "com.apple.Battery-Settings.extension" {
                title = hardware.hasBattery ? (existing?.title ?? names.name) : (nameOverrides["energy"] ?? names.name)
            } else if bundleID == "com.apple.Touch-ID-Settings.extension", !hardware.hasTouchID {
                title = nameOverrides["login-password"] ?? names.name
            } else if title == base, let existing, base.hasSuffix("Extension") || base.hasSuffix("Settings") || base == "PowerPreferences" {
                title = existing.title
            }
            items.append(.init(id: existing?.id ?? bundleID, title: title,
                systemImage: existing?.systemImage ?? symbol(for: bundleID), extensionName: url.deletingPathExtension().lastPathComponent,
                bundleID: bundleID, keywords: Array(Set(names.alternates + [base] + (existing?.keywords ?? []))).sorted(),
                minimumMajorVersion: 14, bundleURL: url))
        }
        guard foundSettingsMetadata else {
            return fallbackSnapshot(directory: directory, fallback: fallback, permissionLinks: permissionLinks,
                hardware: hardware, nameOverrides: nameOverrides, fileManager: fileManager)
        }
        items = addingPermissionLinks(permissionLinks, to: items)
        let updated = modified.map { Cache(directory: directory, modified: $0, languages: languages, hardware: hardware,
            systemVersion: systemVersion, fallbackTitles: titles, items: items) }
        return .init(items: items, cache: updated, usedFallback: false)
    }

    static func info(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
    static func isAvailable(_ page: LauncherSystemSetting, hardware: LauncherSettingsHardware) -> Bool {
        guard let url = page.bundleURL, let info = info(at: url),
              info["CFBundleIdentifier"] as? String == page.bundleID, isSettingsPane(info) else { return false }
        return allowsNavigation(info, bundleID: page.bundleID, hardware: hardware, legacyNavigationAllowed: page.id != page.bundleID)
    }
    private static func validBundleID(_ value: String) -> Bool {
        value.hasPrefix("com.apple.") && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }
    }
    static func isSettingsPane(_ info: [String: Any]) -> Bool {
        (info["EXAppExtensionAttributes"] as? [String: Any])?["EXExtensionPointIdentifier"] as? String == extensionPoint
            || (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == extensionPoint
    }
    static func allowsNavigation(_ info: [String: Any], bundleID: String, hardware: LauncherSettingsHardware,
                                 legacyNavigationAllowed: Bool = false) -> Bool {
        let extensionAttributes = (info["EXAppExtensionAttributes"] as? [String: Any])
            ?? ((info["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any]) ?? [:]
        let attributes = extensionAttributes["SettingsExtensionAttributes"] as? [String: Any] ?? [:]
        let navigationAllowed = attributes["allowsXAppleSystemPreferencesURLScheme"] as? Bool
        guard navigationAllowed == true || (navigationAllowed == nil && legacyNavigationAllowed) else { return false }
        // These are contextual surfaces, not independent destinations. Unknown availability callbacks are not invoked.
        guard bundleID != "com.apple.FollowUpSettings.FollowUpSettingsExtension",
              bundleID != "com.apple.HeadphoneSettings" else { return false }
        if bundleID == "com.apple.Mouse-Settings.extension" { return hardware.hasMouse }
        if bundleID == "com.apple.Trackpad-Settings.extension" { return hardware.hasTrackpad }
        if attributes["providesAvailabilityCheck"] as? Bool == true || attributes["requiresAppleIDSignIn"] as? Bool == true { return false }
        let representations = attributes["representations"] as? [[String: Any]] ?? []
        return !representations.contains { $0["hidden"] as? Bool == true && $0["predicate"] == nil }
    }

    private static func fallbackSnapshot(directory: URL, fallback: [LauncherSystemSetting], permissionLinks: [LauncherSystemSetting],
                                         hardware: LauncherSettingsHardware, nameOverrides: [String: String], fileManager: FileManager) -> Snapshot {
        let items = fallback.compactMap { page -> LauncherSystemSetting? in
            let url = directory.appendingPathComponent(page.extensionName + ".appex")
            guard fileManager.fileExists(atPath: url.path),
                  page.bundleID != "com.apple.Mouse-Settings.extension" || hardware.hasMouse,
                  page.bundleID != "com.apple.Trackpad-Settings.extension" || hardware.hasTrackpad else { return nil }
            if let info = info(at: url) {
                guard info["CFBundleIdentifier"] as? String == page.bundleID,
                      isSettingsPane(info), allowsNavigation(info, bundleID: page.bundleID, hardware: hardware, legacyNavigationAllowed: true) else { return nil }
            }
            var page = page
            page.bundleURL = url
            if page.bundleID == "com.apple.Battery-Settings.extension", !hardware.hasBattery {
                page = .init(id: page.id, title: nameOverrides["energy"] ?? page.title, systemImage: page.systemImage,
                    extensionName: page.extensionName, bundleID: page.bundleID, keywords: page.keywords,
                    minimumMajorVersion: page.minimumMajorVersion, bundleURL: url)
            }
            return page
        }
        return .init(items: addingPermissionLinks(permissionLinks, to: items), cache: nil, usedFallback: true)
    }

    private static func addingPermissionLinks(_ links: [LauncherSystemSetting], to items: [LauncherSystemSetting]) -> [LauncherSystemSetting] {
        var result = items
        if let privacy = items.first(where: { $0.bundleID == "com.apple.settings.PrivacySecurity.extension" }) {
            result += links.map { link in
                .init(id: link.id, title: link.title, systemImage: link.systemImage, extensionName: privacy.extensionName,
                    bundleID: privacy.bundleID, keywords: link.keywords, minimumMajorVersion: link.minimumMajorVersion,
                    anchor: link.anchor, bundleURL: privacy.bundleURL)
            }
        }
        return result.sorted { $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func symbol(for bundleID: String) -> String {
        switch bundleID {
        case "com.apple.Wallpaper-Settings.extension": "photo"
        case "com.apple.Desktop-Settings.extension": "dock.rectangle"
        case "com.apple.Spotlight-Settings.extension": "magnifyingglass"
        case "com.apple.Focus-Settings.extension": "moon"
        case "com.apple.Lock-Screen-Settings.extension": "lock"
        case "com.apple.Screen-Time-Settings.extension": "hourglass"
        case "com.apple.Time-Machine-Settings.extension": "clock.arrow.circlepath"
        case "com.apple.Users-Groups-Settings.extension": "person.2"
        case "com.apple.Print-Scan-Settings.extension": "printer"
        case "com.apple.Localization-Settings.extension": "globe"
        case "com.apple.Touch-ID-Settings.extension": "touchid"
        case "com.apple.systempreferences.AppleIDSettings": "person.crop.circle"
        default: "gearshape"
        }
    }
}
