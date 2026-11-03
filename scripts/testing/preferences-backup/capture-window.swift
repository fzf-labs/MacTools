import AppKit
import ApplicationServices
import Foundation

guard CommandLine.arguments.count == 2 else { exit(64) }
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let requestURL = directory.appendingPathComponent("capture-request.json")
let expectedNames: Set<String> = ["export-en", "export-zh-Hans", "export-de", "export-ar", "right-click-unresolved"]
var completed = Set<String>()
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}
func tree(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 25 else { return [] }
    return [element] + ((attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).flatMap { tree($0, depth: depth + 1) }
}
let deadline = Date().addingTimeInterval(300)
while completed.count < expectedNames.count, Date() < deadline {
    guard let data = try? Data(contentsOf: requestURL),
          let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let name = request["name"] as? String, expectedNames.contains(name), !completed.contains(name),
          let pid = request["pid"] as? Int32, let windowID = request["windowID"] as? UInt32 else {
        Thread.sleep(forTimeInterval: 0.05); continue
    }
    let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]]) ?? []
    guard info.contains(where: { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }) else { exit(2) }
    let application = AXUIElementCreateApplication(pid)
    NSRunningApplication(processIdentifier: pid)?.activate()
    Thread.sleep(forTimeInterval: 0.15)
    let nodes = tree(application)
    var report: [String: Any] = ["pid": pid, "windowID": windowID, "accessibilityGranted": AXIsProcessTrusted()]
    report["elements"] = nodes.map { node in
        ["role": attribute(node, kAXRoleAttribute) as? String ?? "", "title": attribute(node, kAXTitleAttribute) as? String ?? "", "description": attribute(node, kAXDescriptionAttribute) as? String ?? "", "value": attribute(node, kAXValueAttribute) as? String ?? ""]
    }
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(windowID), directory.appendingPathComponent(name + ".png").path]
    try capture.run(); capture.waitUntilExit()
    report["captureStatus"] = capture.terminationStatus
    var focus: [[String: String]] = []
    for _ in 0..<3 {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true)!
        event.postToPid(pid)
        CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: false)?.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.1)
        if let element = attribute(application, kAXFocusedUIElementAttribute), CFGetTypeID(element) == AXUIElementGetTypeID() {
            let focused = element as! AXUIElement
            focus.append(["role": attribute(focused, kAXRoleAttribute) as? String ?? "", "title": attribute(focused, kAXTitleAttribute) as? String ?? "", "description": attribute(focused, kAXDescriptionAttribute) as? String ?? ""])
        }
    }
    report["keyboardFocus"] = focus
    for key: CGKeyCode in [36, 53] {
        CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)?.postToPid(pid)
        CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)?.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.1)
    }
    if let disclosure = nodes.first(where: { attribute($0, kAXRoleAttribute) as? String == kAXDisclosureTriangleRole }) {
        report["disclosurePress"] = AXUIElementPerformAction(disclosure, kAXPressAction as CFString).rawValue
        Thread.sleep(forTimeInterval: 0.15)
        let scrollbars = tree(application).filter { attribute($0, kAXRoleAttribute) as? String == kAXScrollBarRole }
        for bar in scrollbars { _ = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: 1.0)) }
        Thread.sleep(forTimeInterval: 0.15)
        let expanded = Process(); expanded.executableURL = capture.executableURL
        expanded.arguments = ["-x", "-o", "-l", String(windowID), directory.appendingPathComponent(name + "-expanded.png").path]
        try expanded.run(); expanded.waitUntilExit()
    }
    let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try reportData.write(to: directory.appendingPathComponent(name + "-ax.json"), options: .atomic)
    try Data(String(capture.terminationStatus).utf8).write(to: directory.appendingPathComponent(name + ".done"), options: .atomic)
    completed.insert(name)
}
exit(completed.count == expectedNames.count ? 0 : 1)
