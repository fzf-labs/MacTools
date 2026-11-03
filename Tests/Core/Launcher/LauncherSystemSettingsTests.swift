import Foundation
import XCTest
import MacToolsPluginKit
@testable import MacTools

final class LauncherSystemSettingsTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LauncherSettingsTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func pane(_ root: URL, name: String, bundleID: String, attributes: [String: Any] = [:],
                      extensionPoint: String = LauncherSystemSettingsScanner.extensionPoint) throws -> URL {
        let url = root.appendingPathComponent(name + ".appex")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleDevelopmentRegion": "en",
            "EXAppExtensionAttributes": ["EXExtensionPointIdentifier": extensionPoint,
                "SettingsExtensionAttributes": ["allowsXAppleSystemPreferencesURLScheme": true].merging(attributes) { _, value in value }]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }

    func testDiscoveryUsesLocalizedNamesAndKeepsExistingPersonalizationIdentities() throws {
        let root = try directory()
        let wifi = try pane(root, name: "Wi-Fi", bundleID: "com.apple.wifi-settings-extension")
        let table = ["zh_CN": ["CFBundleDisplayName": "测试无线网络"], "en": ["CFBundleDisplayName": "Fixture Wi-Fi"]]
        try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0)
            .write(to: wifi.appendingPathComponent("Contents/Resources/InfoPlist.loctable"))
        try pane(root, name: "Wallpaper", bundleID: "com.apple.Wallpaper-Settings.extension")
        try pane(root, name: "Another Copy", bundleID: "com.apple.Wallpaper-Settings.extension")
        try pane(root, name: "Other Plugin", bundleID: "com.apple.other", extensionPoint: "unrelated.extension")
        try pane(root, name: "Bad Identifier", bundleID: "com.apple.settings?unexpected")
        let outside = try directory()
        let escaped = try pane(outside, name: "Escaped", bundleID: "com.apple.escaped")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Escaped.appex"), withDestinationURL: escaped)
        let snapshot = LauncherSystemSettingsScanner.scan(directory: root, languages: ["zh-Hans"], hardware: .init(),
            fallback: LauncherSystemSettings.entries)
        XCTAssertFalse(snapshot.usedFallback)
        XCTAssertEqual(Set(snapshot.items.map(\.id)), ["wifi", "com.apple.Wallpaper-Settings.extension"])
        let entry = try XCTUnwrap(snapshot.items.first { $0.id == "wifi" })
        XCTAssertEqual(entry.title, "测试无线网络")
        XCTAssertTrue(entry.keywords.contains("Fixture Wi-Fi"))
        XCTAssertEqual(entry.url.absoluteString, "x-apple.systempreferences:com.apple.wifi-settings-extension")
    }

    func testAvailabilityFiltersHardwareAndContextualOrNonNavigablePanes() throws {
        let root = try directory()
        try pane(root, name: "Normal", bundleID: "com.apple.normal")
        try pane(root, name: "Mouse", bundleID: "com.apple.Mouse-Settings.extension", attributes: ["providesAvailabilityCheck": true])
        try pane(root, name: "Trackpad", bundleID: "com.apple.Trackpad-Settings.extension", attributes: ["providesAvailabilityCheck": true])
        try pane(root, name: "Follow Up", bundleID: "com.apple.FollowUpSettings.FollowUpSettingsExtension")
        try pane(root, name: "Headphones", bundleID: "com.apple.HeadphoneSettings")
        try pane(root, name: "Conditional", bundleID: "com.apple.conditional", attributes: ["providesAvailabilityCheck": true])
        try pane(root, name: "Account Conditional", bundleID: "com.apple.account-conditional", attributes: ["requiresAppleIDSignIn": true])
        try pane(root, name: "Hidden", bundleID: "com.apple.hidden", attributes: ["representations": [["hidden": true]]])
        try pane(root, name: "Denied", bundleID: "com.apple.denied", attributes: ["allowsXAppleSystemPreferencesURLScheme": false])
        let first = LauncherSystemSettingsScanner.scan(directory: root, languages: ["en"], hardware: .init(), fallback: [])
        XCTAssertEqual(first.items.map(\.id), ["com.apple.normal"])
        let second = LauncherSystemSettingsScanner.scan(directory: root, languages: ["en"],
            hardware: .init(hasMouse: true, hasTrackpad: true), fallback: LauncherSystemSettings.entries, cache: first.cache)
        XCTAssertEqual(Set(second.items.map(\.id)), ["com.apple.normal", "mouse", "trackpad"])
    }

    func testCacheRefreshesNamesAndPagesWhenLanguageHardwareOrDirectoryChanges() throws {
        let root = try directory()
        let wifi = try pane(root, name: "Wi-Fi", bundleID: "com.apple.wifi-settings-extension")
        let table = ["zh_CN": ["CFBundleDisplayName": "测试网络"], "en": ["CFBundleDisplayName": "Fixture Network"]]
        try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0)
            .write(to: wifi.appendingPathComponent("Contents/Resources/InfoPlist.loctable"))
        let first = LauncherSystemSettingsScanner.scan(directory: root, languages: ["en"], hardware: .init(), fallback: [])
        XCTAssertEqual(first.items.first?.title, "Fixture Network")
        let translated = LauncherSystemSettingsScanner.scan(directory: root, languages: ["zh-Hans"], hardware: .init(), fallback: [], cache: first.cache)
        XCTAssertEqual(translated.items.first?.title, "测试网络")
        try pane(root, name: "Spotlight", bundleID: "com.apple.Spotlight-Settings.extension")
        let changed = try XCTUnwrap(first.cache?.modified).addingTimeInterval(2)
        try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: root.path)
        let refreshed = LauncherSystemSettingsScanner.scan(directory: root, languages: ["zh-Hans"], hardware: .init(), fallback: [], cache: translated.cache)
        XCTAssertEqual(refreshed.items.count, 2)
        XCTAssertNotNil(refreshed.cache)
    }

    func testCompatibilityFallbackUsesInstalledPagesAndPermissionLinksNeedTheirParent() throws {
        let root = try directory()
        try pane(root, name: "Wi-Fi", bundleID: "com.apple.wifi-settings-extension")
        let fallback = LauncherSystemSettingsScanner.scan(directory: root, languages: ["en"], hardware: .init(),
            fallback: LauncherSystemSettings.entries, permissionLinks: LauncherSystemSettings.permissionLinks,
            fileManager: UnlistableSettingsDirectory())
        XCTAssertTrue(fallback.usedFallback)
        XCTAssertNil(fallback.cache)
        XCTAssertEqual(fallback.items.map(\.id), ["wifi"])
        let privacy = try pane(root, name: "SecurityPrivacyExtension", bundleID: "com.apple.settings.PrivacySecurity.extension")
        let discovered = LauncherSystemSettingsScanner.scan(directory: root, languages: ["en"], hardware: .init(),
            fallback: LauncherSystemSettings.entries, permissionLinks: LauncherSystemSettings.permissionLinks)
        let microphone = try XCTUnwrap(discovered.items.first { $0.id == "privacy-security.microphone" })
        XCTAssertEqual(microphone.bundleURL?.resolvingSymlinksInPath().path, privacy.resolvingSymlinksInPath().path)
        XCTAssertEqual(microphone.url.absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        let screenRecording = try XCTUnwrap(discovered.items.first { $0.id == "privacy-security.screen-recording" })
        let profile = LauncherSearchProfile(title: screenRecording.title, keywords: screenRecording.keywords)
        XCTAssertNotNil(LauncherSearch.tier(query: "screen recording", profile: profile, alias: nil))
        XCTAssertNotNil(LauncherSearch.tier(query: "屏幕录制", profile: profile, alias: nil))
        XCTAssertTrue(LauncherSystemSettingsScanner.isAvailable(microphone, hardware: .init()))
        try FileManager.default.removeItem(at: privacy)
        XCTAssertFalse(LauncherSystemSettingsScanner.isAvailable(microphone, hardware: .init()))
    }

    func testHardwareSpecificNamesAndUnsupportedSystemVersion() throws {
        let root = try directory()
        try pane(root, name: "PowerPreferences", bundleID: "com.apple.Battery-Settings.extension")
        try pane(root, name: "Touch ID & Password", bundleID: "com.apple.Touch-ID-Settings.extension")
        let snapshot = LauncherSystemSettingsScanner.scan(directory: root, languages: ["en"], hardware: .init(),
            fallback: LauncherSystemSettings.entries, nameOverrides: ["energy": "Fixture Energy", "login-password": "Fixture Password"])
        XCTAssertEqual(Set(snapshot.items.map(\.title)), ["Fixture Energy", "Fixture Password"])
        let unsupported = LauncherSystemSettingsScanner.scan(directory: root, languages: ["en"], hardware: .init(), fallback: [], majorVersion: 13)
        XCTAssertTrue(unsupported.items.isEmpty)
    }

    @MainActor
    func testAsyncCatalogUpdatesLauncherAndSettingsWithoutReplacingPreferences() async throws {
        let root = try directory()
        try pane(root, name: "Wi-Fi", bundleID: "com.apple.wifi-settings-extension")
        let suite = "LauncherSettingsIntegration-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = LauncherPreferences(defaults: defaults)
        preferences.update { $0.disabledSources = ["applications"]; $0.aliases["system-setting.wifi"] = "fixture-network" }
        let catalog = LauncherSystemSettingsCatalog(directory: root, observesChanges: false, scan: { request in
            LauncherSystemSettingsScanner.scan(directory: request.directory, languages: ["en"], hardware: .init(),
                fallback: request.fallback, permissionLinks: request.permissionLinks, cache: request.cache)
        }, validate: { LauncherSystemSettingsScanner.isAvailable($0, hardware: .init()) })
        let host = PluginHost(plugins: [], shortcutStore: .init(userDefaults: defaults),
            pluginOrderingStore: .init(userDefaults: defaults), preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar()))
        host.systemSettingsCatalog = catalog
        let settings = LauncherSettingsModel(host: host, defaults: defaults)
        XCTAssertTrue(settings.results(for: .systemSettings).isEmpty)
        let launcher = LauncherModel(host: host, defaults: defaults)
        launcher.present()
        launcher.query = "fixture-network"
        await catalog.waitForRefreshForTests()
        await settings.waitForScheduledRefreshForTests()
        await Task.yield()
        XCTAssertEqual(launcher.results.map(\.id), ["system-setting.wifi"])
        XCTAssertTrue(settings.results(for: .systemSettings).contains { $0.id == "system-setting.wifi" })
        XCTAssertFalse(catalog.loadIfNeeded())
        let page = try XCTUnwrap(catalog.items.first { $0.id == "wifi" })
        let available = await catalog.canOpen(page)
        XCTAssertTrue(available)
        try FileManager.default.removeItem(at: try XCTUnwrap(page.bundleURL))
        let missing = await catalog.canOpen(page)
        XCTAssertFalse(missing)
        catalog.refresh(force: true)
        await catalog.waitForRefreshForTests()
        await settings.waitForScheduledRefreshForTests()
        await Task.yield()
        XCTAssertTrue(launcher.results.isEmpty)
        XCTAssertTrue(settings.results(for: .systemSettings).isEmpty)
        XCTAssertEqual(LauncherPreferences(defaults: defaults).personalization.aliases["system-setting.wifi"], "fixture-network")
        launcher.reset()
    }
}

private final class UnlistableSettingsDirectory: FileManager, @unchecked Sendable {
    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                     options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        throw CocoaError(.fileReadNoPermission)
    }
}
