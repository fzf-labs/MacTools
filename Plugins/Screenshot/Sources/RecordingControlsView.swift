import AppKit
import AVFoundation
import MacToolsPluginKit

struct RecordingMicrophoneSnapshot {
    struct Device { let id: String; let name: String }
    let devices: [Device]
    let defaultName: String?

    @MainActor static func current() -> Self {
        Self(devices: RecordingAuthorization.microphones().map { Device(id: $0.uniqueID, name: $0.localizedName) },
             defaultName: AVCaptureDevice.default(for: .audio)?.localizedName)
    }
}

/// Inline recording preparation controls for every capture target.
@MainActor
final class RecordingControlsView: NSView, NSMenuDelegate {
    enum TargetKind: Int { case region, display, window, application }
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    var onTargetChange: ((TargetKind) -> Void)?
    var onChooseFolder: (() -> Void)?
    var onLayoutChange: (() -> Void)?
    let applications: RecordingApplicationPicker
    private let environment: ScreenshotEnvironment
    private let discoverMicrophones: @MainActor () -> RecordingMicrophoneSnapshot
    private var microphoneSnapshot = RecordingMicrophoneSnapshot(devices: [], defaultName: nil)
    let targetPicker = NSPopUpButton()
    let systemAudio = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let microphone = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let startButton = NSButton()
    let devices = NSPopUpButton(frame: .zero, pullsDown: true)
    private let more = NSPopUpButton(frame: .zero, pullsDown: true)
    private let cancelButton = NSButton()
    private let sourceRow = NSStackView()
    private let audioRow = NSStackView()
    private let actionRow = NSStackView()
    private let buttonRows = NSStackView()
    private var body: NSView!
    private let message = NSTextField(wrappingLabelWithString: "")
    private var canStart = false
    private var active = false
    private var observers: [NSObjectProtocol] = []
    private var microphoneNames: [String: String] = [:]
    private var defaultMicrophoneName: String?
    var targetKind: TargetKind { TargetKind(rawValue: targetPicker.indexOfSelectedItem) ?? .region }

    init(environment: ScreenshotEnvironment,
         discoverMicrophones: @escaping @MainActor () -> RecordingMicrophoneSnapshot = { .current() },
         discoverApplications: @escaping @MainActor () async throws -> RecordingApplicationCatalog = { try await .current() }) {
        self.environment = environment
        self.discoverMicrophones = discoverMicrophones
        applications = RecordingApplicationPicker(environment: environment, discover: discoverApplications)
        super.init(frame: .zero)
        targetPicker.addItems(withTitles: [environment.string("record.target.region", "区域"),
                                          environment.string("record.target.display", "显示器"),
                                          environment.string("record.target.window", "窗口"),
                                          environment.string("record.target.application", "应用")])
        targetPicker.target = self
        targetPicker.action = #selector(changeTarget)
        targetPicker.setAccessibilityLabel(environment.string("record.target.title", "录制目标"))
        targetPicker.setAccessibilityIdentifier("screenshot.record.target")
        systemAudio.title = environment.string("record.audio.system", "系统声音")
        microphone.title = environment.string("record.audio.microphone", "麦克风")
        for (button, identifier) in [(systemAudio, "systemAudio"), (microphone, "microphone")] {
            button.font = PluginTypography.body.nsFont
            button.target = self
            button.action = #selector(changeAudio)
            button.setAccessibilityIdentifier("screenshot.record.\(identifier)")
        }
        devices.widthAnchor.constraint(equalToConstant: 200).isActive = true
        devices.cell?.lineBreakMode = .byTruncatingMiddle
        devices.setAccessibilityIdentifier("screenshot.record.microphoneDevice")
        devices.menu?.autoenablesItems = false
        devices.menu?.delegate = self
        more.menu?.delegate = self
        startButton.title = environment.string("overlay.record.start", "开始录制")
        startButton.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        startButton.imagePosition = .imageLeading
        startButton.contentTintColor = .systemRed
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(start)
        startButton.setAccessibilityLabel(startButton.title)
        startButton.setAccessibilityIdentifier("screenshot.record.start")
        cancelButton.title = environment.string("overlay.action.cancel", "取消")
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        for button in [targetPicker, devices, more, startButton, cancelButton] {
            CaptureActionBar.configure(button, isPrimary: button === startButton)
        }
        for view in [targetPicker, systemAudio, microphone] { sourceRow.addArrangedSubview(view) }
        for view in [sourceRow, devices] { audioRow.addArrangedSubview(view) }
        for view in [startButton, more, cancelButton] { actionRow.addArrangedSubview(view) }
        for view in [audioRow, actionRow] { buttonRows.addArrangedSubview(view) }
        for row in [sourceRow, audioRow, actionRow, buttonRows] {
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
        }
        body = CaptureActionBar.content([buttonRows])
        message.font = PluginTypography.detail.nsFont
        message.textColor = .secondaryLabelColor
        message.isHidden = true
        message.widthAnchor.constraint(lessThanOrEqualToConstant: 620).isActive = true
        applications.isHidden = true
        applications.onChange = { [weak self] in
            guard let self else { return }
            refresh()
            onLayoutChange?()
        }
        let stack = NSStackView(views: [applications, body, message])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor),
                                     stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func selectTarget(_ kind: TargetKind, canStart: Bool) {
        targetPicker.selectItem(at: kind.rawValue)
        applications.isHidden = kind != .application
        if kind != .application { applications.stop() }
        self.canStart = canStart
        refresh()
    }

    /// Wrap groups before allowing any ordinary control to leave the display.
    func constrain(to available: NSSize) {
        let width = max(260, available.width)
        for row in [sourceRow, audioRow, actionRow, buttonRows] { row.orientation = .horizontal; row.alignment = .centerY }
        if body.fittingSize.width > width {
            buttonRows.orientation = .vertical
            buttonRows.alignment = .centerX
            if audioRow.fittingSize.width > width - 20 {
                audioRow.orientation = .vertical
                audioRow.alignment = .centerX
            }
            if actionRow.fittingSize.width > width - 20 {
                actionRow.orientation = .vertical
                actionRow.alignment = .centerX
            }
            if sourceRow.fittingSize.width > width - 20 {
                sourceRow.orientation = .vertical
                sourceRow.alignment = .centerX
            }
        }
        message.preferredMaxLayoutWidth = min(620, width - 20)
        applications.constrain(to: NSSize(width: min(width, max(600, body.fittingSize.width)), height: max(100, available.height - body.fittingSize.height - 40)))
    }

    func moveKeyboardFocus(backwards: Bool) {
        guard let window else { return }
        if let view = window.firstResponder as? NSView, view.isDescendant(of: self) {
            if backwards { window.selectPreviousKeyView(nil) } else { window.selectNextKeyView(nil) }
        } else {
            window.makeFirstResponder(backwards ? cancelButton : (targetKind == .application ? applications.displayPicker : targetPicker))
        }
    }

    private func configureKeyLoop() {
        var views: [NSView] = [targetPicker, systemAudio, microphone, devices, startButton, more, cancelButton]
        if targetKind == .application {
            views = [applications.displayPicker, applications.refreshButton, applications.collectionView] + views
        }
        for index in views.indices { views[index].nextKeyView = views[(index + 1) % views.count] }
    }

    func setError(_ text: String?) {
        guard message.stringValue != (text ?? "") || message.isHidden != (text == nil) else { return }
        message.stringValue = text ?? ""
        message.isHidden = text == nil
        onLayoutChange?()
    }

    func activate() {
        guard !active else { return }
        active = true
        refreshMicrophones()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification,
                     NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMicrophones() }
            })
        }
    }

    func deactivate() {
        active = false
        applications.stop()
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
    }

    func showApplications(displayID: CGDirectDisplayID) {
        selectTarget(.application, canStart: false)
        applications.activate(displayID: displayID)
    }

    private func refreshMicrophones() {
        microphoneSnapshot = discoverMicrophones()
        microphoneNames = Dictionary(microphoneSnapshot.devices.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        defaultMicrophoneName = microphoneSnapshot.defaultName
        refresh()
        onLayoutChange?()
    }

    func refresh() {
        let audio = environment.recordingAudio
        systemAudio.state = audio.systemAudio ? .on : .off
        microphone.state = audio.microphone ? .on : .off
        systemAudio.isEnabled = RecordingAuthorization.hostSupportsAudio || audio.systemAudio
        microphone.isEnabled = RecordingAuthorization.hostSupportsAudio || audio.microphone
        devices.isEnabled = RecordingAuthorization.hostSupportsAudio && audio.microphone
        startButton.isEnabled = targetKind == .application ? applications.selectedTarget != nil : canStart
        if startButton.isEnabled { startButton.toolTip = nil }
        else if targetKind == .application {
            startButton.toolTip = applications.isLoading ? environment.string("capture.preparing", "正在准备…")
                : environment.string("record.application.choose", "选择要录制的应用")
        } else {
            startButton.toolTip = environment.string("record.target.choose", "先选择录制区域或窗口")
        }
        let name: String
        if let id = audio.microphoneID {
            name = microphoneNames[id] ?? environment.string("record.microphone.unavailable", "所选麦克风已断开，请重新选择")
        } else {
            let label = environment.string("record.audio.default", "系统默认")
            name = defaultMicrophoneName.map { "\(label) · \($0)" } ?? label
        }
        // The first pull-down item is its visible caption, independent of microphone enablement.
        if devices.numberOfItems == 0 { devices.addItem(withTitle: name) }
        else { devices.item(at: 0)?.title = name }
        devices.setAccessibilityLabel(environment.string("record.microphone.device", "选择麦克风"))
        devices.setAccessibilityValue(name)
        devices.toolTip = name
        rebuildMoreMenu()
        configureKeyLoop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === devices.menu {
            refreshMicrophones()
            let caption = devices.itemTitle(at: 0)
            devices.removeAllItems()
            devices.addItem(withTitle: caption)
            let audio = environment.recordingAudio
            let available = microphoneSnapshot.devices
            let defaults = NSMenuItem(title: environment.string("record.audio.default", "系统默认"),
                                      action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            defaults.target = self
            defaults.state = audio.microphoneID == nil ? .on : .off
            menu.addItem(defaults)
            for device in available {
                let item = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.id
                item.state = audio.microphoneID == device.id ? .on : .off
                menu.addItem(item)
            }
            if let id = audio.microphoneID, !available.contains(where: { $0.id == id }) {
                let item = NSMenuItem(title: environment.string("record.microphone.unavailable", "所选麦克风已断开，请重新选择"), action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        } else { rebuildMoreMenu() }
    }

    private func rebuildMoreMenu() {
        more.removeAllItems()
        more.addItem(withTitle: environment.string("record.more", "更多"))
        more.menu?.autoenablesItems = false
        let zoom = NSMenuItem(title: environment.string("overlay.record.autoZoom", "自动缩放"), action: #selector(toggleZoom), keyEquivalent: "")
        zoom.target = self
        let supportsZoom = targetKind == .region || targetKind == .display
        zoom.state = supportsZoom && environment.recordingAutoZoom ? .on : .off
        zoom.isEnabled = supportsZoom
        zoom.toolTip = environment.string("settings.autoZoom.description", "仅区域和显示器录制可用。点击或滚动时放大该位置，随后恢复全景。")
        if !supportsZoom { zoom.toolTip = environment.string("record.autoZoom.unsupported", "仅区域和显示器录制支持自动缩放") }
        more.menu?.addItem(zoom)
        let folder = NSMenuItem(title: environment.string("settings.folder.choose", "选择文件夹…"), action: #selector(chooseFolder), keyEquivalent: "")
        folder.target = self
        folder.toolTip = environment.saveFolder.path
        more.menu?.addItem(folder)
    }

    @objc private func changeTarget() { onTargetChange?(targetKind) }
    @objc private func changeAudio() {
        var audio = environment.recordingAudio
        audio.systemAudio = systemAudio.state == .on
        audio.microphone = microphone.state == .on
        environment.recordingAudio = audio
        setError(nil)
        refresh()
    }
    @objc private func selectMicrophone(_ item: NSMenuItem) {
        var audio = environment.recordingAudio
        audio.microphoneID = item.representedObject as? String
        environment.recordingAudio = audio
        setError(nil)
        refresh()
        onLayoutChange?()
    }
    @objc private func toggleZoom() { environment.recordingAutoZoom.toggle() }
    @objc private func chooseFolder() { onChooseFolder?() }
    @objc private func start() { guard startButton.isEnabled else { return }; setError(nil); onStart?() }
    @objc private func cancel() { onCancel?() }
}
