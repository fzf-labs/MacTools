import AppKit
import AVFoundation
import ScreenCaptureKit

struct RecordingWindowSelection: Sendable {
    let rect: CGRect
    let windowID: CGWindowID
    let processID: pid_t
}

struct RecordingAudioOptions: Equatable, Sendable {
    var systemAudio = false
    var microphone = false
    /// Nil follows the default input selected when capture starts.
    var microphoneID: String?
}

enum RecordingTarget: Equatable, Sendable {
    case region(CaptureRegion)
    case display(CaptureDisplay)
    case window(id: CGWindowID, processID: pid_t, display: CaptureDisplay)
    case application(processID: pid_t, bundleID: String, display: CaptureDisplay)

    var display: CaptureDisplay {
        switch self {
        case .region(let region): region.display
        case .display(let display), .window(_, _, let display), .application(_, _, let display): display
        }
    }

    var supportsAutoZoom: Bool {
        switch self { case .region, .display: true; case .window, .application: false }
    }

    @MainActor
    func controlRegion() throws -> CaptureRegion {
        if case .region(let region) = self { return region }
        return try CaptureRegion(selection: CGRect(origin: .zero, size: display.frame.size), display: display)
    }
}

struct RecordingRequest: Equatable, Sendable {
    let target: RecordingTarget
    var audio = RecordingAudioOptions()
    var autoZoom = false
}

enum RecordingRequestError: Error {
    case targetUnavailable, microphoneDenied, microphoneUnavailable, hostUpdateRequired
}

/// Uses the host's declared capability instead of guessing a future release version.
/// Older signed hosts must never request microphone access without a purpose string.
@MainActor
enum RecordingAuthorization {
    static var hostSupportsAudio: Bool {
        supportsAudio(infoDictionary: Bundle.main.infoDictionary)
    }

    static func supportsAudio(infoDictionary: [String: Any]?) -> Bool {
        guard infoDictionary?["MTScreenshotAudioRecordingSupported"] as? Bool == true,
              let purpose = infoDictionary?["NSMicrophoneUsageDescription"] as? String else { return false }
        return !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestMicrophone() async -> Bool {
        guard hostSupportsAudio else { return false }
        switch microphoneStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                         position: .unspecified).devices
    }

    static func validate(_ options: RecordingAudioOptions) throws {
        guard options.systemAudio || options.microphone else { return }
        guard hostSupportsAudio else { throw RecordingRequestError.hostUpdateRequired }
        if options.microphone {
            guard microphoneStatus == .authorized else { throw RecordingRequestError.microphoneDenied }
            let available = microphones()
            guard options.microphoneID.map({ id in available.contains { $0.uniqueID == id } })
                ?? (AVCaptureDevice.default(for: .audio) != nil)
            else { throw RecordingRequestError.microphoneUnavailable }
        }
    }
}

@MainActor
struct PreparedRecordingTarget {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    let processID: pid_t?
    let windowID: CGWindowID?

    static func prepare(_ request: RecordingRequest, controls: CaptureControls) async throws -> Self {
        let region = try request.target.controlRegion()
        try region.validate()
        controls.prepare()
        let content = try await CaptureSessionPreparation.content()
        try Task.checkCancellation()
        try region.validate()
        try RecordingAuthorization.validate(request.audio)
        guard let display = content.displays.first(where: { $0.displayID == region.display.id }) else {
            throw CaptureFailure.displayChanged
        }
        let excludedIDs = try controls.windowIDs(available: Set(content.windows.map(\.windowID)))
        let excluded = content.windows.filter { excludedIDs.contains($0.windowID) }
        let configuration = CaptureSessionPreparation.configuration(region: region, framesPerSecond: 30, showsCursor: true)
        let filter: SCContentFilter
        var processID: pid_t?
        var windowID: CGWindowID?
        switch request.target {
        case .region, .display:
            filter = SCContentFilter(display: display, excludingWindows: excluded)
        case .window(let id, let pid, _):
            guard pid != ProcessInfo.processInfo.processIdentifier,
                  let window = content.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID == pid })
            else { throw RecordingRequestError.targetUnavailable }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let size = filter.contentRect.size
            let scale = CGFloat(filter.pointPixelScale)
            let pixelWidth = size.width * scale, pixelHeight = size.height * scale
            guard pixelWidth.isFinite, pixelHeight.isFinite, scale.isFinite, scale > 0,
                  pixelWidth > 0, pixelHeight > 0,
                  pixelWidth <= CGFloat(Int32.max - 1), pixelHeight <= CGFloat(Int32.max - 1)
            else { throw RecordingRequestError.targetUnavailable }
            configuration.sourceRect = .zero
            configuration.width = max(2, Int(ceil(pixelWidth / 2)) * 2)
            configuration.height = max(2, Int(ceil(pixelHeight / 2)) * 2)
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            processID = pid
            windowID = id
        case .application(let pid, let bundleID, _):
            guard pid != ProcessInfo.processInfo.processIdentifier,
                  let app = content.applications.first(where: { $0.processID == pid && $0.bundleIdentifier == bundleID }),
                  content.windows.contains(where: { $0.owningApplication?.processID == pid && $0.frame.intersects(CGDisplayBounds(display.displayID)) })
            else { throw RecordingRequestError.targetUnavailable }
            // Exceptions invert application membership. Never pass our controls here.
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            processID = pid
        }
        configuration.capturesAudio = request.audio.systemAudio
        if #available(macOS 15, *) {
            configuration.captureMicrophone = request.audio.microphone
            configuration.microphoneCaptureDeviceID = request.audio.microphoneID
        }
        configuration.queueDepth = 5
        return Self(filter: filter, configuration: configuration, processID: processID, windowID: windowID)
    }
}
