import AppKit
import Foundation
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 160, y: 240, width: 500, height: 320), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "MacTools Backup Synthetic Target"
window.isReleasedWhenClosed = false
window.contentView = NSTextField(labelWithString: "Disposable window for backup acceptance. No user documents.")
window.makeKeyAndOrderFront(nil)
application.activate(ignoringOtherApps: true)
Timer.scheduledTimer(withTimeInterval: 40, repeats: false) { _ in application.terminate(nil) }
application.run()
