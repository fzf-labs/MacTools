import AppKit
import MacToolsPluginKit
import QuartzCore

enum CaptureEntry: String, CaseIterable, Sendable {
    case capture, quickCapture = "quick-capture", text = "extract-text", scroll = "scrolling-capture", record = "record"

    var mode: Mode {
        switch self {
        case .capture, .quickCapture: .shot
        case .text: .ocr
        case .scroll: .scroll
        case .record: .record
        }
    }
}

/// Acquires a fresh desktop before presenting any capture UI, without activating the host.
@MainActor
final class CaptureController {
    var onFinish: (() -> Void)?
    var onError: ((String) -> Void)?
    var onRecord: ((RecordingRequest) -> Void)?
    var onScroll: ((CaptureRegion) -> Void)?

    private let entry: CaptureEntry
    private let environment: ScreenshotEnvironment
    private let pool: CaptureOverlayPool
    private var overlays: [OverlayWindow] = []
    private var pointerTracker: CapturePointerTracker?
    private var startTask: Task<Void, Never>?
    private var cursorPushed = false
    private var finished = false
    private var suspended = false
    private let recordingGate = RecordingStartGate()

    private nonisolated static let standardPanelLevels: Set<Int> = [
        Int(CGWindowLevelForKey(.normalWindow)),
        Int(CGWindowLevelForKey(.floatingWindow)),
        Int(CGWindowLevelForKey(.modalPanelWindow)),
        Int(CGWindowLevelForKey(.utilityWindow)),
    ]
    private nonisolated static let menuPanelLevels = Int(CGWindowLevelForKey(.mainMenuWindow))
        ... Int(CGWindowLevelForKey(.popUpMenuWindow))

    init(entry: CaptureEntry, environment: ScreenshotEnvironment, pool: CaptureOverlayPool) {
        self.entry = entry
        self.environment = environment
        self.pool = pool
    }

    func start() {
        guard !finished, startTask == nil else { return }
        let displays = CaptureDisplay.current()
        let windowTask = Task.detached(priority: .userInitiated) { Self.onScreenWindows() }
        startTask = Task { [weak self] in
            guard let self else { windowTask.cancel(); return }
            defer { windowTask.cancel(); startTask = nil }
            do {
                let images = try await CapturePipeline.capture(displays)
                try Task.checkCancellation()
                guard !finished else { return }
                let (windows, recordingWindows) = await windowTask.value
                try Task.checkCancellation()
                guard displays == CaptureDisplay.current() else { throw CaptureFailure.displayChanged }

                pool.prepare()
                for display in displays {
                    guard let screen = NSScreen.screens.first(where: {
                        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
                    }), let image = images[display.id], let overlay = pool.window(for: display) else {
                        throw CaptureFailure.displayChanged
                    }
                    let localWindows = windows
                        .map { $0.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }
                        .filter { $0.intersects(NSRect(origin: .zero, size: display.frame.size)) }
                    overlay.prepare(screen: screen, frozen: image, windows: localWindows,
                                    quick: entry == .quickCapture, initialMode: entry.mode)
                    configure(overlay, display: display)
                    (overlay.contentView as? OverlayView)?.recordingWindows = recordingWindows.compactMap { window in
                        let rect = window.rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                            .intersection(NSRect(origin: .zero, size: display.frame.size))
                        guard !rect.isEmpty else { return nil }
                        return RecordingWindowSelection(rect: rect, windowID: window.windowID, processID: window.processID)
                    }
                    overlays.append(overlay)
                }

                // The overlay owns this cursor until every capture exit path dismisses it.
                NSCursor.crosshair.push()
                cursorPushed = true
                let pointerTracker = CapturePointerTracker(overlays: overlays)
                self.pointerTracker = pointerTracker
                pointerTracker.update()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for overlay in overlays { overlay.prepareForPresentation() }
                CATransaction.commit()
                CATransaction.flush()
                PluginPresentationSafety.prepareForWindowOrdering()
                for overlay in overlays { overlay.orderFrontRegardless() }
                pointerTracker.update()
            } catch {
                guard !finished, !Task.isCancelled else { return }
                onError?(environment.format("capture.failed", "截图失败：%@", environment.captureErrorDescription(error)))
                dismiss()
            }
        }
    }

    private func configure(_ overlay: OverlayWindow, display: CaptureDisplay) {
        overlay.onComplete = { [weak self] png, mode in
            guard let self, !finished else { return }
            guard mode == .ask else {
                dismiss()
                ScreenshotOutput.save(png, mode: mode, environment: environment)
                return
            }
            // Keep the selection and annotations until the file is written; cancelling or a write
            // failure returns to them.
            suspend()
            let chosen = ScreenshotOutput.saveAs(png, suggestedName: ScreenshotOutput.suggestedScreenshotName(environment),
                                                 environment: environment) { [weak self] written in
                guard let self, !finished else { return }
                if written {
                    ScreenshotOutput.copyToPasteboard(png)
                    dismiss()
                } else {
                    resume()
                }
            }
            if !chosen, !finished { resume() }
        }
        (overlay.contentView as? OverlayView)?.recordingDisplay = display
        overlay.onCancel = { [weak self] in self?.dismiss() }
        overlay.onRecord = { [weak self, weak overlay] rect, kind in
            guard let self, !finished, let region = makeRegion(rect, display: display) else { return }
            let target: RecordingTarget
            if kind == .window {
                guard let window = (overlay?.contentView as? OverlayView)?.selectedRecordingWindow else { return }
                target = .window(id: window.windowID, processID: window.processID, display: display)
            } else if kind == .application {
                guard let application = (overlay?.contentView as? OverlayView)?.selectedRecordingApplication else { return }
                target = application
            } else { target = kind == .display ? .display(display) : .region(region) }
            beginRecording(RecordingRequest(target: target, audio: environment.recordingAudio,
                                            autoZoom: environment.recordingAutoZoom), overlay: overlay)
        }
        overlay.onWindowSelection = { [weak self] in
            guard let self, !finished else { return }
            for overlay in overlays { (overlay.contentView as? OverlayView)?.beginWindowSelection() }
        }
        overlay.onRecordingFolder = { [weak self] in self?.chooseRecordingFolder() }
        overlay.onScroll = { [weak self] rect in
            guard let self, !finished else { return }
            guard let request = makeRegion(rect, display: display) else { return }
            dismiss()
            onScroll?(request)
        }
        overlay.onPin = { [weak self] png, frame, shadowed in
            guard let self, !finished else { return }
            dismiss()
            environment.pin(png, at: frame, bakedShadow: shadowed,
                            name: "\(environment.string("output.screenshotName", "截图")) \(environment.stamp()).png")
            environment.showToast(environment.string("pin.created", "已钉在屏幕上，双击或 Esc 关闭"))
        }
    }

    private func beginRecording(_ request: RecordingRequest, overlay: OverlayWindow?) {
        guard !finished, !recordingGate.isPreparing else { return }
        suspend()
        // The system permission prompt must not be covered by a screen-saver-level overlay.
        recordingGate.start(request) { [weak self, weak overlay] result in
            guard let self, !finished else { return }
            switch result {
            case .success(let request):
                dismiss()
                onRecord?(request)
            case .failure(let error):
                let message = environment.recordingErrorDescription(error)
                (overlay?.contentView as? OverlayView)?.showRecordingError(message)
                resume()
            }
        }
    }

    private func chooseRecordingFolder() {
        guard !finished, !recordingGate.isPreparing, environment.savePanel == nil else { return }
        suspend()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = environment.saveFolder
        environment.savePanel = panel
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        panel.begin { [weak self] response in
            guard let self, !finished else { return }
            environment.savePanel = nil
            if response == .OK, let url = panel.url { environment.saveFolder = url }
            resume()
        }
    }

    /// Hides the capture surfaces without discarding their session state.
    private func suspend() {
        suspended = true
        pointerTracker?.stop()
        for overlay in overlays { overlay.orderOut(nil) }
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }

    private func resume() {
        suspended = false
        NSCursor.crosshair.push()
        cursorPushed = true
        PluginPresentationSafety.prepareForWindowOrdering()
        for overlay in overlays { overlay.orderFrontRegardless() }
        let tracker = CapturePointerTracker(overlays: overlays)
        pointerTracker = tracker
        // Keyboard focus follows the pointer's display, as when capture first appears.
        tracker.update()
    }

    func focus() {
        guard !finished, !suspended else { return }
        pointerTracker?.update()
    }

    func dismiss() {
        guard !finished else { return }
        finished = true
        recordingGate.cancel()
        environment.savePanel?.cancel(nil)
        environment.savePanel = nil
        startTask?.cancel()
        startTask = nil
        pointerTracker?.stop()
        pointerTracker = nil
        for overlay in overlays { overlay.dismiss() }
        overlays.removeAll()
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        onFinish?()
    }

    private func makeRegion(_ rect: NSRect, display: CaptureDisplay) -> CaptureRegion? {
        do { return try CaptureRegion(selection: rect, display: display) }
        catch { onError?(environment.captureErrorDescription(error)); return nil }
    }

    private nonisolated static func onScreenWindows() -> ([NSRect], [RecordingWindowSelection]) {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let recording = windows.compactMap { window -> RecordingWindowSelection? in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let rect = selectableWindowRects(from: [window], primaryHeight: primaryHeight).first else { return nil }
            return RecordingWindowSelection(rect: rect, windowID: id, processID: pid)
        }
        return (selectableWindowRects(from: windows, primaryHeight: primaryHeight), recording)
    }

    nonisolated static func selectableWindowRects(from windows: [[String: Any]], primaryHeight: CGFloat) -> [NSRect] {
        windows.compactMap { window in
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  isSelectableWindowLayer(layer),
                  ((window[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 1, frame.height > 1
            else { return nil }
            return NSRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        }
    }

    nonisolated static func isSelectableWindowLayer(_ layer: Int) -> Bool {
        if standardPanelLevels.contains(layer) { return true }
        // Menu bar popovers can use levels between the public menu and pop-up menu levels.
        return menuPanelLevels.contains(layer)
    }
}

/// Resolves one pointer owner for the capture session, independently of tracking-event order.
@MainActor
final class CapturePointerTracker {
    private let overlays: [OverlayWindow]
    private let mouseLocation: () -> NSPoint
    private weak var activeOverlay: OverlayWindow?
    private(set) weak var selectionOwner: OverlayWindow?
    private var stopped = false

    init(overlays: [OverlayWindow], mouseLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation }) {
        self.overlays = overlays
        self.mouseLocation = mouseLocation
        selectionOwner = overlays.first { ($0.contentView as? OverlayView)?.hasSelection == true }
        for overlay in overlays {
            let view = overlay.contentView as? OverlayView
            view?.onPointerActivity = { [weak self] in self?.update() }
            view?.onSelectionClaim = { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                claimSelection(on: overlay)
            }
            view?.onModeChange = { [weak self, weak overlay] mode in
                guard let self else { return }
                for other in self.overlays where other !== overlay { (other.contentView as? OverlayView)?.synchronizeMode(mode) }
            }
        }
    }

    private func claimSelection(on overlay: OverlayWindow) {
        guard !stopped else { return }
        if selectionOwner !== overlay {
            for other in overlays where other !== overlay { (other.contentView as? OverlayView)?.discardSelectionForTransfer() }
            selectionOwner = overlay
        }
        for other in overlays { (other.contentView as? OverlayView)?.setControlsOwner(other === overlay) }
        if overlay.isVisible { overlay.makeKey() }
    }

    func update() {
        guard !stopped else { return }
        // Tracking events can arrive late; their type and saved coordinates are not ownership.
        let point = mouseLocation()
        let next = overlays.first { NSMouseInRect(point, $0.frame, false) }
        if let selectionOwner, (selectionOwner.contentView as? OverlayView)?.hasSelection != true { self.selectionOwner = nil }
        for overlay in overlays {
            (overlay.contentView as? OverlayView)?.setControlsOwner(overlay === (selectionOwner ?? next))
        }
        if activeOverlay !== next {
            (activeOverlay?.contentView as? OverlayView)?.updatePointer(at: nil)
            activeOverlay = next
        }
        guard let next, let view = next.contentView as? OverlayView else { return }
        let keyboardOwner = selectionOwner ?? next
        if keyboardOwner.isVisible, !keyboardOwner.isKeyWindow { keyboardOwner.makeKey() }
        view.updatePointer(at: view.convert(next.convertPoint(fromScreen: point), from: nil))
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        for overlay in overlays {
            guard let view = overlay.contentView as? OverlayView else { continue }
            view.onPointerActivity = nil
            view.onSelectionClaim = nil
            view.onModeChange = nil
            view.updatePointer(at: nil)
        }
        activeOverlay = nil
    }
}
