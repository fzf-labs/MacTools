import AppKit
import Foundation

struct LauncherSystemSetting: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    let extensionName: String
    let bundleID: String
    let keywords: [String]
    let minimumMajorVersion: Int
    var anchor: String? = nil
    var bundleURL: URL? = nil
    var url: URL {
        let destination = anchor == nil ? bundleID : "com.apple.preference.security"
        return URL(string: "x-apple.systempreferences:" + destination + (anchor.map { "?" + $0 } ?? ""))!
    }
}

/// Compatibility identities, fallback entries, and explicit permission links for the discovered catalog.
enum LauncherSystemSettings {
    static var entries: [LauncherSystemSetting] {
        [
            page("wifi", LauncherText.wifi, "wifi", "Wi-Fi", "com.apple.wifi-settings-extension", ["Wi-Fi", "WLAN", "无线网络"]),
            page("bluetooth", LauncherText.bluetooth, "bluetooth", "Bluetooth", "com.apple.BluetoothSettings", ["Bluetooth", "蓝牙"]),
            page("network", LauncherText.network, "network", "Network", "com.apple.Network-Settings.extension", ["Network", "网络", "VPN"]),
            page("sound", LauncherText.sound, "speaker.wave.2", "Sound", "com.apple.Sound-Settings.extension", ["Sound", "声音", "音频"]),
            page("notifications", LauncherText.notifications, "bell.badge", "NotificationsSettings", "com.apple.Notifications-Settings.extension", ["Notifications", "通知"]),
            page("displays", LauncherText.displays, "display", "DisplaysExt", "com.apple.Displays-Settings.extension", ["Displays", "显示器", "屏幕"]),
            page("appearance", LauncherText.appearance, "circle.lefthalf.filled", "Appearance", "com.apple.Appearance-Settings.extension", ["Appearance", "外观"]),
            page("accessibility", LauncherText.accessibility, "accessibility", "AccessibilitySettingsExtension", "com.apple.Accessibility-Settings.extension", ["Accessibility", "辅助功能"]),
            page("keyboard", LauncherText.keyboard, "keyboard", "KeyboardSettings", "com.apple.Keyboard-Settings.extension", ["Keyboard", "键盘"]),
            page("mouse", LauncherText.mouse, "computermouse", "MouseExtension", "com.apple.Mouse-Settings.extension", ["Mouse", "鼠标"]),
            page("trackpad", LauncherText.trackpad, "hand.draw", "TrackpadExtension", "com.apple.Trackpad-Settings.extension", ["Trackpad", "触控板"]),
            page("battery", LauncherText.battery, "battery.100", "PowerPreferences", "com.apple.Battery-Settings.extension", ["Battery", "电池"]),
            page("privacy-security", LauncherText.privacySecurity, "hand.raised", "SecurityPrivacyExtension", "com.apple.settings.PrivacySecurity.extension", ["Privacy", "Security", "隐私", "安全性", "权限"]),
            page("general", LauncherText.general, "gearshape", "GeneralSettings", "com.apple.systempreferences.GeneralSettings", ["General", "通用"]),
            page("about", LauncherText.about, "info.circle", "AboutExtension", "com.apple.SystemProfiler.AboutExtension", ["About", "关于本机", "通用"]),
            page("software-update", LauncherText.softwareUpdate, "gear.badge", "SoftwareUpdateSettingsExtension", "com.apple.Software-Update-Settings.extension", ["Software Update", "软件更新", "通用"]),
            page("storage", LauncherText.storage, "internaldrive", "Storage", "com.apple.settings.Storage", ["Storage", "存储空间", "通用"]),
            page("login-items", LauncherText.loginItems, "person.crop.circle.badge.checkmark", "LoginItems", "com.apple.LoginItems-Settings.extension", ["Login Items", "登录项", "启动项", "通用"]),
            page("sharing", LauncherText.sharing, "square.and.arrow.up", "Sharing", "com.apple.Sharing-Settings.extension", ["Sharing", "共享", "通用"]),
            page("date-time", LauncherText.dateTime, "clock", "DateAndTime Extension", "com.apple.Date-Time-Settings.extension", ["Date", "Time", "日期", "时间", "通用"]),
        ]
    }
    static var permissionLinks: [LauncherSystemSetting] {
        let definitions = [
            ("camera", LauncherText.camera, "camera", "Privacy_Camera"),
            ("microphone", LauncherText.microphone, "mic", "Privacy_Microphone"),
            ("screen-recording", LauncherText.screenRecording, "record.circle", "Privacy_ScreenCapture"),
            ("accessibility", LauncherText.accessibility, "accessibility", "Privacy_Accessibility"),
            ("full-disk-access", LauncherText.fullDiskAccess, "internaldrive", "Privacy_AllFiles"),
            ("input-monitoring", LauncherText.inputMonitoring, "keyboard", "Privacy_ListenEvent"),
            ("automation", LauncherText.automation, "gearshape.2", "Privacy_Automation"),
        ]
        return definitions.map { id, title, icon, anchor in
            let extraKeywords: [String] = switch id {
            case "camera": ["摄像头"]
            case "screen-recording": ["屏幕录制", "屏幕与系统音频录制", "Screen Capture"]
            case "accessibility": ["无障碍", "设备控制和数据访问", "设备控制与数据访问", "Device Control", "Data Access"]
            default: []
            }
            return .init(id: "privacy-security." + id, title: LauncherText.privacySecurity + " · " + title,
                systemImage: icon, extensionName: "SecurityPrivacyExtension", bundleID: "com.apple.settings.PrivacySecurity.extension",
                keywords: [title, id.replacingOccurrences(of: "-", with: " "), anchor, "Privacy", "Permissions", "隐私", "权限"] + extraKeywords,
                minimumMajorVersion: 14, anchor: anchor)
        }
    }

    private static func page(_ id: String, _ title: String, _ icon: String, _ extensionName: String, _ bundleID: String, _ keywords: [String]) -> LauncherSystemSetting {
        .init(id: id, title: title, systemImage: icon, extensionName: extensionName, bundleID: bundleID, keywords: keywords, minimumMajorVersion: 14)
    }
    static func availableEntries(majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                                 extensionExists: (String) -> Bool = { name in
                                     FileManager.default.fileExists(atPath: "/System/Library/ExtensionKit/Extensions/\(name).appex")
                                 }) -> [LauncherSystemSetting] {
        entries.filter { majorVersion >= $0.minimumMajorVersion && extensionExists($0.extensionName) }
    }
    @MainActor
    static func open(_ page: LauncherSystemSetting, using opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        opener(page.url)
    }
}
