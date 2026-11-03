import AppKit
import ApplicationServices
import Foundation
import MacToolsPluginKit
@testable import WindowLayoutsPlugin

@main @MainActor
struct Acceptance {
    enum Failure: Error { case check(String) }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure.check(message) } }
    static let directory = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/dev/null")
    static var report: [String: Any] = [:]
    static func writeReport(_ name: String) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
        }
    }
    static func main() {
        guard CommandLine.arguments.count == 3, ["granted", "relaunch", "denied", "cleanup"].contains(CommandLine.arguments[1]) else { exit(64) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let mode = CommandLine.arguments.dropFirst().first ?? "granted"
            do {
                try await run(mode)
                report["result"] = "passed"
                writeReport("desktop-" + mode)
                print("PASS " + mode)
                exit(0)
            } catch {
                report["result"] = "failed"
                report["failure"] = String(describing: error)
                writeReport("desktop-" + mode)
                print("FAIL " + mode + ": " + String(describing: error))
                exit(1)
            }
        }
        app.run()
    }
    static func run(_ mode: String) async throws {
        report["accessibilityGranted"] = AXIsProcessTrusted()
        report["screenCaptureGranted"] = CGPreflightScreenCaptureAccess()
        report["processID"] = ProcessInfo.processInfo.processIdentifier
        let token = try String(contentsOf: directory.appendingPathComponent("suite-name.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try require(UUID(uuidString: token) != nil, "Invalid evidence suite token")
        let suite = "org.mactools.backup-acceptance." + token
        let defaults = UserDefaults(suiteName: suite)!
        if mode == "cleanup" { defaults.removePersistentDomain(forName: suite); return }
        let storage = UserDefaultsPluginStorage(pluginID: "window-layouts", userDefaults: defaults)
        let context = PluginRuntimeContext(pluginID: "window-layouts", storage: storage)
        if mode != "relaunch" { defaults.removePersistentDomain(forName: suite) }
        if mode == "granted" { WindowLayoutsStore(storage: storage).setGap(3) }
        let payloadObject = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("native/synthetic-format7.json"))) as! [String: Any]
        let encoded = (payloadObject["pluginPreferences"] as! [String: String])["window-layouts"]!
        let payload = Data(base64Encoded: encoded)!
        var promptCalls = 0
        let plugin = WindowLayoutsPlugin(context: context, requestAccessibilityTrust: { _ in promptCalls += 1; return false })
        if mode != "relaunch" { try require(plugin.restorePortablePreferencesReportingResult(from: payload), "Restore failed") }
        let reloaded = WindowLayoutsStore(storage: storage)
        try require(reloaded.gap == 8 && reloaded.centeredGuidesEnabled && reloaded.modifierDragEnabled, "Restored settings differ")
        try require(reloaded.modifierDragModifiers == [.control, .option, .command], "Modifier combination differs")
        try require(!reloaded.showsCommandFeedback && !reloaded.cyclesHalves, "Behavior differs")
        try require(reloaded.customCommands.count == 1, "Custom layout missing")
        report["settings"] = ["gap": reloaded.gap, "guides": reloaded.centeredGuidesEnabled, "modifierDrag": reloaded.modifierDragEnabled,
            "modifiers": reloaded.modifierDragModifiers.rawValue, "customCommandID": reloaded.customCommands[0].id.uuidString]
        try require(promptCalls == 0, "Import requested permission")
        if mode == "relaunch" { return }
        plugin.activate(context: context)
        defer { plugin.deactivate(reason: .hostShutdown) }
        if mode == "denied" {
            try require(!AXIsProcessTrusted(), "Denied test identity unexpectedly has Accessibility")
            try require(!plugin.permissionState(for: "accessibility").isGranted, "Denied permission reported granted")
            try require(plugin.isModifierDragEnabled, "Denied permission erased requested setting")
            return
        }
        try require(AXIsProcessTrusted(), "Granted desktop acceptance needs Accessibility")
        try require(CGEventSource.flagsState(.combinedSessionState).intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]).isEmpty, "User is holding a modifier")
        let previousApp = NSWorkspace.shared.frontmostApplication
        let oldPointer = CGEvent(source: nil)!.location
        let target = Process()
        target.executableURL = directory.appendingPathComponent("target-window")
        try target.run()
        var mouseIsDown = false
        defer {
            if mouseIsDown {
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGEvent(source: nil)!.location, mouseButton: .left)?.postToPid(target.processIdentifier)
            }
            let release = CGEvent(source: nil)!
            release.type = .flagsChanged
            release.flags = []
            release.postToPid(target.processIdentifier)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: oldPointer, mouseButton: .left)?.post(tap: .cghidEventTap)
                previousApp?.activate()
            }
            if target.isRunning { target.terminate() }
        }
        var windows: CFTypeRef?
        let application = AXUIElementCreateApplication(target.processIdentifier)
        for _ in 0..<40 {
            _ = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
            if let items = windows as? [AXUIElement], !items.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let window = (windows as? [AXUIElement])?.first else { throw Failure.check("No owned target window") }
        NSRunningApplication(processIdentifier: target.processIdentifier)?.activate()
        try await Task.sleep(for: .milliseconds(200))
        func owned() throws { try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier, "Target lost focus; stop desktop input") }
        func frame() throws -> CGRect {
            var position: CFTypeRef?; var size: CFTypeRef?
            try require(AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success, "Read target position")
            try require(AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success, "Read target size")
            var p = CGPoint.zero; var s = CGSize.zero
            try require(AXValueGetValue(position as! AXValue, .cgPoint, &p) && AXValueGetValue(size as! AXValue, .cgSize, &s), "Decode target frame")
            return CGRect(origin: p, size: s)
        }
        func post(_ type: CGEventType, _ point: CGPoint, flags: CGEventFlags = []) throws {
            try owned()
            let event: CGEvent
            if type == .flagsChanged {
                event = CGEvent(source: nil)!
                event.type = .flagsChanged
                event.location = point
                event.setIntegerValueField(.keyboardEventKeycode, value: 55)
            } else { event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)! }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        let initial = try frame()
        let inside = CGPoint(x: initial.midX, y: initial.midY)
        try post(.mouseMoved, inside)
        try await Task.sleep(for: .milliseconds(80))
        let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        try post(.flagsChanged, inside, flags: flags)
        try await Task.sleep(for: .milliseconds(350))
        for step in 1...5 {
            try post(.mouseMoved, CGPoint(x: inside.x + CGFloat(step * 16), y: inside.y + CGFloat(step * 10)), flags: flags)
            try await Task.sleep(for: .milliseconds(70))
        }
        try post(.flagsChanged, CGPoint(x: inside.x + 80, y: inside.y + 50))
        try await Task.sleep(for: .milliseconds(200))
        let moved = try frame()
        report["modifierDragDelta"] = ["x": moved.minX - initial.minX, "y": moved.minY - initial.minY]
        try require(abs(moved.minX - initial.minX - 80) < 3 && abs(moved.minY - initial.minY - 50) < 3, "Actual modifier drag did not reposition the owned window")
        let anchor = NSScreen.screens.map(\.frame.maxY).max()!
        let visible = NSScreen.main!.visibleFrame
        let usable = CGRect(x: visible.minX, y: anchor - visible.maxY, width: visible.width, height: visible.height)
        let centered = WindowSnapGeometry.defaultFrame(contentSize: moved.size, visibleFrame: usable)
        let titlePoint = CGPoint(x: moved.midX, y: moved.minY + 12)
        let delta = CGPoint(x: centered.minX + 6 - moved.minX, y: centered.minY + 7 - moved.minY)
        try post(.mouseMoved, titlePoint)
        try await Task.sleep(for: .milliseconds(100))
        try post(.leftMouseDown, titlePoint)
        mouseIsDown = true
        for step in 1...12 {
            try post(.leftMouseDragged, CGPoint(x: titlePoint.x + delta.x * CGFloat(step) / 12, y: titlePoint.y + delta.y * CGFloat(step) / 12))
            try await Task.sleep(for: .milliseconds(60))
        }
        try await Task.sleep(for: .milliseconds(200))
        report["guideOverlayVisible"] = NSApp.windows.contains { $0.isVisible && $0 is NSPanel }
        try post(.leftMouseUp, CGPoint(x: titlePoint.x + delta.x, y: titlePoint.y + delta.y))
        mouseIsDown = false
        try await Task.sleep(for: .milliseconds(400))
        let snapped = try frame()
        report["centeredGuideFinalOffset"] = ["x": snapped.minX - centered.minX, "y": snapped.minY - centered.minY]
        try require(abs(snapped.minX - centered.minX) < 2 && abs(snapped.minY - centered.minY) < 2, "Actual centered guide release did not snap")
        try require(report["guideOverlayVisible"] as? Bool == true, "Centered guide overlay not visible during drag")
    }
}
