import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import WindowLayoutsPlugin
@testable import RightClickPlugin

/// On-demand native UI evidence; full CI skips this desktop-dependent check.
@MainActor
final class PreferencesBackupDesktopEvidenceTests: XCTestCase {
    func testCaptureIsolatedBackupFlowAndNativeCoverage() async throws {
        guard let path = ProcessInfo.processInfo.environment["MACTOOLS_BACKUP_EVIDENCE_DIR"] else {
            throw XCTSkip("Set MACTOOLS_BACKUP_EVIDENCE_DIR for isolated desktop evidence.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let sourceName = "org.mactools.backup-evidence.source.\(token)"
        let destinationName = "org.mactools.backup-evidence.destination.\(token)"
        let sourceDefaults = try XCTUnwrap(UserDefaults(suiteName: sourceName))
        let destinationDefaults = try XCTUnwrap(UserDefaults(suiteName: destinationName))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceName)
            destinationDefaults.removePersistentDomain(forName: destinationName)
            PluginRuntimeLocalization.source.setPreference(UserDefaults.standard.string(forKey: AppLanguagePreference.userDefaultsKey))
        }
        let storage = UserDefaultsPluginStorage(pluginID: "window-layouts", userDefaults: sourceDefaults)
        let store = WindowLayoutsStore(storage: storage)
        store.setGap(8)
        store.setCyclesHalves(false)
        store.setRespectsStageManager(false)
        store.setShowsCommandFeedback(false)
        store.setCenteredGuidesEnabled(true)
        store.setModifierDragEnabled(true)
        store.setModifierDragModifiers([.control, .option, .command])
        let command = try XCTUnwrap(store.addCustomCommand(name: "Synthetic reading layout"))
        let sourcePlugin = WindowLayoutsPlugin(context: .init(pluginID: "window-layouts", storage: storage), accessibilityTrusted: { false }, requestAccessibilityTrust: { _ in XCTFail("Unexpected permission prompt"); return false })
        let sourceHost = makeHost(plugin: sourcePlugin, defaults: sourceDefaults)
        defer { sourceHost.deactivateAllPlugins() }
        let reference = ActionReference(key: .init(providerID: "window-layouts", actionID: command.actionID))
        guard case .success = sourceHost.setActionShortcutBinding(.init(keyCode: 80, modifiers: [.command, .control, .option, .shift]), to: reference) else {
            return XCTFail("Unable to set synthetic shortcut")
        }
        let backup = try sourceHost.makePreferencesBackupExport().requiringSuccessfulSelection()
        let data = try JSONEncoder().encode(backup)
        try data.write(to: directory.appendingPathComponent("synthetic-format7.json"), options: .atomic)
        let destinationStorage = UserDefaultsPluginStorage(pluginID: "window-layouts", userDefaults: destinationDefaults)
        WindowLayoutsStore(storage: destinationStorage).setGap(3)
        let destinationPlugin = WindowLayoutsPlugin(context: .init(pluginID: "window-layouts", storage: destinationStorage), accessibilityTrusted: { false }, requestAccessibilityTrust: { _ in XCTFail("Unexpected permission prompt"); return false })
        let destinationHost = makeHost(plugin: destinationPlugin, defaults: destinationDefaults)
        defer { destinationHost.deactivateAllPlugins() }
        let result = try destinationHost.importPreferences(try JSONDecoder().decode(PreferencesBackup.self, from: data))
        XCTAssertTrue(result.shortcutErrors.isEmpty)
        XCTAssertEqual(result.pluginOutcomes.first?.status, "needsAttention")
        XCTAssertEqual(destinationHost.shortcutAssignmentService.assignment(for: reference)?.reference, reference)
        let reloaded = WindowLayoutsStore(storage: destinationStorage)
        XCTAssertEqual(reloaded.gap, 8)
        XCTAssertTrue(reloaded.centeredGuidesEnabled)
        XCTAssertTrue(reloaded.modifierDragEnabled)
        XCTAssertEqual(reloaded.modifierDragModifiers, [.control, .option, .command])
        XCTAssertEqual(reloaded.customCommands.first?.id, command.id)
        let coverage: [PreferencesPluginBackupDiagnostic] = [
            .init(pluginID: "window-layouts", status: "partial", exclusions: ["permissions", "external-authorization"]),
            .init(pluginID: "ai-assistant", status: "partial", exclusions: ["credentials", "private-content"]),
            .init(pluginID: "disk-clean", status: "localOnly", exclusions: ["local-policy"]),
            .init(pluginID: "appearance", status: "none", exclusions: []),
            .init(pluginID: "missing", status: "unavailable", exclusions: []),
        ]
        let options = [PreferencesPluginOption(id: "window-layouts", title: "Window Layouts"), .init(id: "ai-assistant", title: "AI Assistant"), .init(id: "disk-clean", title: "Disk Clean"), .init(id: "appearance", title: "Appearance"), .init(id: "missing", title: "Unavailable Plugin")]
        var accessibilityReport: [String: [String]] = [:]
        for language in ["en", "zh-Hans", "de", "ar"] {
            PluginRuntimeLocalization.source.setPreference(language)
            var exports = 0
            var cancellations = 0
            let root = PreferencesExportSelectionSheet(selection: .constant(.all(pluginPreferenceIDs: ["window-layouts", "ai-assistant", "missing"])), pluginOptions: Array(options.prefix(2)) + [options[4]], coverage: coverage, coverageOptions: options, exportFailure: nil, deviceLocalAutomationRuleCount: 0, onCancel: { cancellations += 1 }, onExport: { exports += 1 })
                .environment(\.locale, Locale(identifier: language))
                .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight)
            accessibilityReport[language] = try await capture(root, name: "export-\(language)", in: directory)
            XCTAssertEqual(exports, 1, "Return must invoke the default export action")
            XCTAssertEqual(cancellations, 1, "Escape must invoke Cancel")
        }
        PluginRuntimeLocalization.source.setPreference("en")
        let rightClickBundle = try XCTUnwrap(Bundle(url: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("RightClick.bundle")))
        let rightClickSession = RightClickSettingsSession(
            configuration: .init(openWithApps: [.init(name: "Missing Editor", appPath: "", fileExtensions: ["txt"])]),
            fileURL: directory.appendingPathComponent("synthetic-right-click.json"))
        let rightClickView = RightClickResourceEditor(session: rightClickSession,
            localization: PluginLocalization(bundle: rightClickBundle), kind: .applications)
            .padding()
            .environment(\.locale, Locale(identifier: "en"))
        accessibilityReport["right-click-unresolved"] = try await capture(rightClickView, name: "right-click-unresolved", in: directory) {
            var restored = rightClickSession.configuration
            restored.openWithApps[0].name = "Restored Editor"
            let fileURL = directory.appendingPathComponent("synthetic-right-click.json")
            let encoder = JSONEncoder()
            try encoder.encode(restored).write(to: fileURL, options: .atomic)
            rightClickSession.reload()
        }
        let rightClickReport = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("right-click-unresolved-ax.json"))) as? [String: Any])
        let elements = try XCTUnwrap(rightClickReport["elements"] as? [[String: String]])
        XCTAssertTrue(elements.contains { ($0["value"] ?? "").contains("Restored Editor") || ($0["label"] ?? "").contains("Restored Editor") },
                      "The resource list must show restored data for the same application UUID")
        try JSONEncoder().encode(accessibilityReport).write(to: directory.appendingPathComponent("native-accessibility.json"), options: .atomic)
    }

    private func makeHost(plugin: WindowLayoutsPlugin, defaults: UserDefaults) -> PluginHost {
        PluginHost(plugins: [plugin], shortcutStore: .init(userDefaults: defaults), pluginOrderingStore: .init(userDefaults: defaults), preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults), globalShortcutManager: .init())
    }

    private func capture<Content: View>(_ content: Content, name: String, in directory: URL,
                                       afterAppearance: (() throws -> Void)? = nil) async throws -> [String] {
        let view = NSHostingView(rootView: content)
        let size = NSSize(width: 520, height: 720)
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "MacTools synthetic backup evidence"
        window.contentView = view
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        if let afterAppearance {
            try afterAppearance()
            try await Task.sleep(for: .milliseconds(200))
            view.layoutSubtreeIfNeeded()
        }
        var labels: [String] = []
        func inspect(_ element: any NSAccessibilityProtocol, depth: Int = 0) {
            guard depth < 30 else { return }
            if let label = element.accessibilityLabel(), !label.isEmpty { labels.append(label) }
            if let title = element.accessibilityTitle(), !title.isEmpty { labels.append(title) }
            for child in element.accessibilityChildren() ?? [] {
                if let child = child as? any NSAccessibilityProtocol { inspect(child, depth: depth + 1) }
            }
        }
        inspect(window)
        window.selectNextKeyView(nil)
        labels.append("Keyboard first responder: \(String(describing: window.firstResponder))")
        let done = directory.appendingPathComponent(name + ".done")
        try? FileManager.default.removeItem(at: done)
        let request: [String: Any] = ["name": name, "pid": ProcessInfo.processInfo.processIdentifier, "windowID": window.windowNumber]
        try JSONSerialization.data(withJSONObject: request).write(to: directory.appendingPathComponent("capture-request.json"), options: .atomic)
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: done.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(try String(contentsOf: done, encoding: .utf8), "0", "Run the isolated capture helper alongside this on-demand check")
        return labels
    }
}
