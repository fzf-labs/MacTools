import AppKit
import Combine
import SwiftUI
import MacToolsPluginKit

@MainActor
final class LauncherPanel: NSPanel {
    var command: ((NSEvent) -> Bool)?
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if command?(event) == true { return true }; return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class LauncherWindowController: NSObject {
    let model: LauncherModel
    private let panel: LauncherPanel
    private let monitor = PluginPanelDismissalMonitor()
    private let restoration = PluginPanelFocusRestoration()
    private let defaults: UserDefaults
    private var localeObserver: AnyCancellable?
    private var sizeObserver: AnyCancellable?
    private var appearanceObserver: NSObjectProtocol?
    private var positionObserver: NSObjectProtocol?
    init(host: PluginHost, defaults: UserDefaults, showSettings: @escaping () -> Void) {
        self.defaults = defaults
        model = LauncherModel(host: host, defaults: defaults)
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                             styleMask: PluginPanelPresentation.styleMask, backing: .buffered, defer: false)
        super.init()
        PluginPanelPresentation.configure(panel); panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.isMovableByWindowBackground = false
        model.dismiss = { [weak self] in self?.dismiss() }
        model.hideForHandoff = { [weak self] in self?.monitor.stop(); self?.panel.orderOut(nil) }
        model.onCompletion = { [weak self] in self?.showRetained() }
        model.showSettings = { [weak self] in self?.dismiss(); showSettings() }
        let hostingView = NSHostingView(rootView: LauncherRootView(model: model))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.onEscape = { [weak model] in model?.back() }
        panel.command = { [weak self] event in
            guard let self else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if modifiers == .command {
                if event.charactersIgnoringModifiers == "k" { model.actionsVisible.toggle(); return true }
                if event.charactersIgnoringModifiers == "," { model.showSettings(); return true }
                if let value = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(value) { model.quickSelect(value); return true }
            }
            return false
        }
        sizeObserver = Publishers.CombineLatest(model.$results, model.$feedback).sink { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.resizeToContent() }
        }
        localeObserver = PluginRuntimeLocalization.source.$revision.sink { [weak self] _ in self?.panel.setAccessibilityTitle(LauncherText.title) }
        appearanceObserver = NotificationCenter.default.addObserver(forName: AppAppearancePreference.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
        positionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.defaults.set(NSStringFromPoint(self.panel.frame.origin), forKey: "launcher.window.origin")
                self.defaults.set(self.panel.frame.height, forKey: "launcher.window.height")
            }
        }
    }
    isolated deinit {
        if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
        if let positionObserver { NotificationCenter.default.removeObserver(positionObserver) }
    }
    func toggle() { if panel.isVisible { dismiss() } else { show() } }
    private func show() {
        model.present(); restoration.prepareForPresentation()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let width = min(680, visible.width - 32), height = min(contentHeight, visible.height - 32)
            let saved = defaults.string(forKey: "launcher.window.origin").map { value in
                let point = NSPointFromString(value)
                let oldHeight = defaults.object(forKey: "launcher.window.height") as? Double ?? 520
                return NSPoint(x: point.x, y: point.y + oldHeight - height)
            }
            let origin = saved.flatMap { point in NSScreen.screens.contains { $0.visibleFrame.intersects(NSRect(origin: point, size: NSSize(width: width, height: height))) } ? point : nil }
                ?? NSPoint(x: visible.midX - width / 2, y: visible.maxY - height - visible.height * 0.15)
            panel.setFrame(NSRect(x: min(max(origin.x, visible.minX), visible.maxX - width),
                                  y: min(max(origin.y, visible.minY), visible.maxY - height), width: width, height: height), display: true)
        }
        showRetained()
    }
    private var contentHeight: CGFloat {
        min(520, max(210, 136 + CGFloat(min(model.results.count, 8)) * 48 + (model.feedback == nil ? 0 : 64)))
    }
    private func resizeToContent() {
        guard panel.isVisible, panel.attachedSheet == nil else { return }
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let height = min(contentHeight, visible.height - 32)
        guard abs(panel.frame.height - height) > 1 else { return }
        var frame = panel.frame
        frame.origin.y = max(visible.minY, frame.maxY - height)
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }
    private func applyAppearance() {
        let appearance = AppAppearancePreference.stored(in: defaults)
        appearance.apply(to: panel); appearance.apply(to: panel.contentView)
    }
    private func showRetained() {
        applyAppearance()
        monitor.start(for: panel, isSuspended: { [weak model] in model?.isSuspended == true || model?.isBusy == true },
                      onDismiss: { [weak self] in
            self?.dismiss(restoringFocus: false)
        })
        PluginPanelPresentation.present(panel)
    }
    func dismiss(restoringFocus: Bool = true) {
        monitor.stop(); let visible = panel.isVisible
        panel.orderOut(nil); model.reset()
        restoration.dismiss(wasVisible: visible, restoringFocus: restoringFocus)
    }
}
