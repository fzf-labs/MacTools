import AppKit
import MacToolsPluginKit

/// Owns preferences and auxiliary windows for one enabled plugin instance.
@MainActor
final class ScreenshotEnvironment: NSObject {
    let storage: any PluginStorage
    private let localization: PluginLocalization
    private var pins: [PinWindow] = []
    private var toast: NSPanel?
    private var toastTask: Task<Void, Never>?
    private var toastFile: URL?
    var savePanel: NSSavePanel?
    var onPreferencesChange: (() -> Void)?
    private(set) var presentationGeneration: UInt64 = 0

    convenience init(context: PluginRuntimeContext) {
        self.init(storage: context.storage, localization: PluginLocalization(bundle: context.resourceBundle))
    }

    init(storage: any PluginStorage, localization: PluginLocalization) {
        self.storage = storage
        self.localization = localization
        super.init()
    }

    var saveFolder: URL {
        get {
            if let path = storage.string(forKey: "saveFolder"), path.hasPrefix("/") {
                return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            }
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Desktop", isDirectory: true)
            return desktop.appendingPathComponent("screenshot", isDirectory: true)
        }
        set {
            guard newValue.isFileURL else { return }
            storage.set(newValue.standardizedFileURL.path, forKey: "saveFolder")
            onPreferencesChange?()
        }
    }

    /// Recording auto zoom is on by default; the record bar and settings share this preference.
    var recordingAutoZoom: Bool {
        get { storage.object(forKey: "recordingAutoZoom") as? Bool ?? true }
        set {
            guard newValue != recordingAutoZoom else { return }
            storage.set(newValue, forKey: "recordingAutoZoom")
            onPreferencesChange?()
        }
    }

    var recordingAudio: RecordingAudioOptions {
        get {
            RecordingAudioOptions(systemAudio: storage.object(forKey: "recordingSystemAudio") as? Bool ?? false,
                                  microphone: storage.object(forKey: "recordingMicrophone") as? Bool ?? false,
                                  microphoneID: storage.string(forKey: "recordingMicrophoneID"))
        }
        set {
            guard newValue != recordingAudio else { return }
            storage.set(newValue.systemAudio, forKey: "recordingSystemAudio")
            storage.set(newValue.microphone, forKey: "recordingMicrophone")
            storage.set(newValue.microphoneID, forKey: "recordingMicrophoneID")
            onPreferencesChange?()
        }
    }

    func recordingErrorDescription(_ error: Error) -> String {
        switch error {
        case RecordingRequestError.targetUnavailable:
            return string("record.target.unavailable", "录制目标已关闭或不可用，请重新选择")
        case RecordingRequestError.microphoneDenied:
            return string("record.microphone.denied", "请在系统设置 → 隐私与安全性 → 麦克风中允许 MacTools 访问，或关闭麦克风录制")
        case RecordingRequestError.microphoneUnavailable:
            return string("record.microphone.unavailable", "所选麦克风已断开，请重新选择")
        case RecordingRequestError.hostUpdateRequired:
            return string("record.audio.hostUpdate", "当前版本的 MacTools 不支持录音，请更新主程序后使用。仍可无声录屏。")
        default: return captureErrorDescription(error)
        }
    }

    var saveFolderDisplayName: String { FileManager.default.displayName(atPath: saveFolder.path) }

    func string(_ key: String, _ defaultValue: String) -> String {
        localization.string(key, defaultValue: defaultValue)
    }

    func format(_ key: String, _ defaultValue: String, _ arguments: CVarArg...) -> String {
        String(format: string(key, defaultValue), locale: PluginRuntimeLocalization.locale, arguments: arguments)
    }

    func captureErrorDescription(_ error: Error) -> String {
        switch error {
        case CaptureFailure.unavailable:
            return string("capture.unavailable", "无法获取屏幕图像，请检查录屏权限后重试")
        case CaptureFailure.timedOut:
            return string("capture.timedOut", "获取屏幕图像超时，请重试")
        case CaptureFailure.displayChanged:
            return string("capture.displayChanged", "显示器配置已变化，请重新截图")
        case CaptureFailure.invalidRegion:
            return string("capture.invalidRegion", "截图区域无效，请重新选择")
        case is ScreenshotControlError:
            return string("capture.controlsNotReady", "截图控制窗口尚未就绪，请重试")
        default: return error.localizedDescription
        }
    }

    func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        return formatter.string(from: Date())
    }

    func fileURL(prefix: String, ext: String) -> URL {
        saveFolder.appendingPathComponent("\(prefix) \(stamp()).\(ext)")
    }

    func pin(_ png: Data, at frame: NSRect, bakedShadow: Bool, name: String, isResult: Bool = false) {
        pins.removeAll { !$0.isVisible }
        let window = PinWindow(png: png, at: frame, name: name, isResult: isResult, environment: self)
        window.hasShadow = !bakedShadow
        pins.append(window)
        PluginPresentationSafety.prepareForWindowOrdering(window)
        window.orderFrontRegardless()
        window.makeKey()
    }

    func showRecordingSaved(_ url: URL, message: String) {
        showToast(message, file: url)
    }

    func showToast(_ message: String, file: URL? = nil) {
        toastFile = file
        toastTask?.cancel()
        toast?.orderOut(nil)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let box = NSStackView()
        box.orientation = .horizontal
        box.spacing = 8
        box.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 18)
        if let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil) {
            let icon = NSImageView(image: image)
            icon.contentTintColor = .labelColor
            icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
            box.addArrangedSubview(icon)
        }
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        box.addArrangedSubview(label)
        if file != nil {
            let button = NSButton(title: string("record.showFile", "显示文件"), target: self, action: #selector(showToastFile))
            CaptureActionBar.configure(button)
            box.addArrangedSubview(button)
        }
        let size = box.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = file == nil
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = Glass.wrap(box, radius: size.height / 2, blending: .behindWindow)
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                                     y: screen.visibleFrame.minY + 80))
        toast = panel
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        panel.orderFrontRegardless()
        toastTask = Task { [weak self, weak panel] in
            do { try await Task.sleep(for: .seconds(file == nil ? 1.8 : 10)) }
            catch { return }
            panel?.orderOut(nil)
            if self?.toast === panel { self?.toast = nil }
        }
    }

    @objc private func showToastFile() {
        guard let toastFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([toastFile])
        toast?.orderOut(nil)
        toastTask?.cancel()
        toast = nil
        self.toastFile = nil
    }

    func closeAll() {
        toastFile = nil
        presentationGeneration &+= 1
        toastTask?.cancel()
        toastTask = nil
        toast?.orderOut(nil)
        toast = nil
        savePanel?.cancel(nil)
        savePanel = nil
        for pin in pins { pin.close() }
        pins.removeAll()
    }
}
