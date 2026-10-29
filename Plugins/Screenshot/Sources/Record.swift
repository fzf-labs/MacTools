import AppKit
import AVFoundation
import ScreenCaptureKit
import VideoToolbox

@available(macOS 15, *)
@MainActor
final class Recorder: NSObject, SCRecordingOutputDelegate {
    var onFinish: ((Result<URL, Error>) -> Void)?
    /// Capture has ended and the movie is being processed; other capture modes may run.
    var onProcessing: (() -> Void)?
    let request: RecordingRequest
    let region: CaptureRegion
    let autoZoom: Bool
    private(set) var isProcessing = false
    private let environment: ScreenshotEnvironment
    private let panel: CaptureStatusPanel
    private let outline: CaptureRegionOutlineWindow
    private let controls: CaptureControls
    /// The file written by capture. With auto zoom, this is the recoverable original.
    private let url: URL
    /// The published movie.
    private let movieURL: URL
    private let clock = RecordingClock()
    private var activity: RecordingActivity?
    private var processingTask: Task<Void, Never>?
    private var session: CaptureStreamSession?
    private var output: SCRecordingOutput?
    private var startupTask: Task<Void, Never>?
    private var timer: Timer?
    private var sourceTask: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var interruption: Error?
    private var fileFinalized = false

    private var startedAt: ContinuousClock.Instant?
    private lazy var lifecycle = RecordingLifecycle { [weak self] in self?.session?.stop() }

    init(request: RecordingRequest, environment: ScreenshotEnvironment) throws {
        self.request = request
        let region = try request.target.controlRegion()
        self.region = region
        self.environment = environment
        let autoZoom = request.autoZoom && request.target.supportsAutoZoom
        self.autoZoom = autoZoom
        // Use a name whose movie and original are both unused, so neither can replace an existing file.
        let preferred = environment.fileURL(prefix: environment.string("record.filename", "录屏"), ext: "mov")
        let suffix = environment.string("record.originalSuffix", "原始")
        func original(_ movie: URL) -> URL {
            movie.deletingLastPathComponent()
                .appendingPathComponent("\(movie.deletingPathExtension().lastPathComponent) \(suffix).mov")
        }
        let files = FileManager.default
        var index = 1
        var candidate = preferred
        while files.fileExists(atPath: candidate.path) || files.fileExists(atPath: original(candidate).path) {
            index += 1
            candidate = ScreenshotImageEncoder.numbered(preferred, index)
        }
        movieURL = candidate
        url = autoZoom || request.audio.systemAudio || request.audio.microphone ? original(candidate) : candidate
        panel = CaptureStatusPanel(primaryTitle: environment.string("record.stop", "停止"), indicatorColor: .systemRed)
        outline = CaptureRegionOutlineWindow(region: region)
        controls = CaptureControls([outline, panel])
        super.init()
        panel.onPrimary = { [weak self] in self?.stop() }
    }

    func start() {
        guard startupTask == nil, session == nil, lifecycle.result == nil else { return }
        // Retain the session through native stop and file-finalization callbacks, including host teardown.
        lifecycle.onFinish = { [self] result in finish(result) }
        lifecycle.onPhaseChange = { [weak self] phase in self?.update(phase) }
        update(.starting)
        startupTask = Task { [self] in
            defer { startupTask = nil }
            do {
                let folder = url.deletingLastPathComponent()
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                }.value
                try Task.checkCancellation()
                let prepared = try await PreparedRecordingTarget.prepare(request, controls: controls)
                try Task.checkCancellation()
                let configuration = prepared.configuration
                let recording = SCRecordingOutputConfiguration()
                recording.outputURL = url
                recording.outputFileType = .mov
                let width = configuration.width, height = configuration.height
                recording.videoCodecType = try await Task.detached(priority: .userInitiated) {
                    try RecordingEncoding.codec(width: width, height: height)
                }.value
                try Task.checkCancellation()
                try region.validate()
                guard recording.availableVideoCodecTypes.contains(recording.videoCodecType),
                      recording.availableOutputFileTypes.contains(.mov) else {
                    throw RecordingError.unsupportedResolution
                }
                let session = CaptureStreamSession(filter: prepared.filter, configuration: configuration)
                self.session = session
                session.onStopped = { [weak self, weak session] result in
                    guard let self else { return }
                    outline.orderOut(nil)
                    stopObservingSources()
                    if interruption == nil, case .failure(let error) = result { interruption = error }
                    if session?.failedToStart == true, case .failure(let error) = result {
                        lifecycle.failBeforeCapture(error)
                    } else { lifecycle.captureStopped(result) }
                }
                session.onWaiting = { [weak self] in self?.lifecycle.waitingForCapture() }
                let output = SCRecordingOutput(configuration: recording, delegate: self)
                self.output = output
                try session.stream.addRecordingOutput(output)
                if autoZoom {
                    // The first encoded frame's clock aligns pointer events with the movie timeline.
                    try session.stream.addStreamOutput(clock, type: .screen,
                                                       sampleHandlerQueue: DispatchQueue(label: "cc.ggbond.mactools.screenshot.recording-clock"))
                    let activity = RecordingActivity(displayBounds: CGDisplayBounds(region.display.id),
                                                     sourceRect: region.sourceRect)
                    self.activity = activity
                    guard activity.start() else { throw RecordingZoomError.pointerMonitorUnavailable }
                }
                observeSources(prepared)
                if request.target.supportsAutoZoom { outline.show() }
                panel.show(near: region.globalRect, displayID: region.display.id)
                session.start()
            } catch {
                if let session {
                    lifecycle.fileCompleted(.failure(error))
                    session.stop()
                } else { lifecycle.failBeforeCapture(error) }
            }
        }
    }

    func stop() {
        guard session != nil else { cancel(); return }
        lifecycle.stop()
    }

    func cancel() {
        // Cancelling processing keeps the finished original.
        processingTask?.cancel()
        startupTask?.cancel()
        if session == nil { lifecycle.failBeforeCapture(CancellationError()) }
        else { lifecycle.cancel() }
    }

    func displayTopologyChanged() {
        do { try region.validate() } catch {
            outline.orderOut(nil)
            stop()
        }
    }

    private func interrupt(_ error: Error) {
        guard interruption == nil, lifecycle.result == nil else { return }
        interruption = error
        stop()
    }

    private func observeSources(_ prepared: PreparedRecordingTarget) {
        func observe(_ center: NotificationCenter, _ name: Notification.Name,
                     matching: @escaping @Sendable (Notification) -> Bool = { _ in true },
                     handler: @escaping @MainActor () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard matching(notification) else { return }
                MainActor.assumeIsolated { handler() }
            }
            observers.append((center, token))
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { [weak self] in
            self?.stop()
        }
        if let pid = prepared.processID {
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didTerminateApplicationNotification, matching: { notification in
                (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier == pid
            }) { [weak self] in self?.interrupt(RecordingRequestError.targetUnavailable) }
        }
        if request.audio.microphone {
            let deviceID = request.audio.microphoneID ?? AVCaptureDevice.default(for: .audio)?.uniqueID
            observe(.default, AVCaptureDevice.wasDisconnectedNotification, matching: { notification in
                (notification.object as? AVCaptureDevice)?.uniqueID == deviceID
            }) { [weak self] in self?.interrupt(RecordingRequestError.microphoneUnavailable) }
        }
        // ScreenCaptureKit has no public window-closed observer on macOS 15.0.
        // Check only while recording, with one bounded discovery in flight.
        guard prepared.windowID != nil || request.audio.systemAudio || request.audio.microphone else { return }
        sourceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, lifecycle.result == nil else { return }
                do {
                    try RecordingAuthorization.validate(request.audio)
                    if let id = prepared.windowID {
                        let content = try await CaptureSessionPreparation.content()
                        try Task.checkCancellation()
                        guard content.windows.contains(where: { $0.windowID == id && $0.owningApplication?.processID == prepared.processID }) else {
                            throw RecordingRequestError.targetUnavailable
                        }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    interrupt(error)
                    return
                }
            }
        }
    }

    private func update(_ phase: RecordingLifecycle.Phase) {
        if phase != .recording { timer?.invalidate(); timer = nil }
        switch phase {
        case .starting:
            panel.update(environment.string("capture.preparing", "正在准备…"))
        case .recording:
            startedAt = .now
            panel.update("00:00")
            timer = Timer(timeInterval: 1, target: self, selector: #selector(updateElapsed), userInfo: nil, repeats: true)
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        case .stopping:
            panel.update(environment.string("capture.stopping", "正在停止…"), primaryEnabled: false)
        case .finalizing:
            panel.update(environment.string("record.saving", "正在保存…"), primaryEnabled: false)
        case .waiting:
            let stopped = session?.isStopped == true
            panel.update(environment.string(stopped ? "record.savingSlowly" : "capture.stoppingSlowly",
                                            stopped ? "正在保存，请稍候…" : "正在等待屏幕采集停止…"),
                         primaryEnabled: session?.canRetryStop == true)
        case .finished: break
        }
    }

    @objc private func updateElapsed() {
        let duration = output?.recordedDuration.seconds ?? 0
        let seconds = duration.isFinite && duration >= 0
            ? Int(duration) : Int(startedAt?.duration(to: .now).components.seconds ?? 0)
        panel.update(String(format: "%02d:%02d", seconds / 60, seconds % 60))
    }

    private func stopObservingSources() {
        sourceTask?.cancel()
        sourceTask = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    private func finish(_ result: Result<URL, Error>) {
        stopObservingSources()
        timer?.invalidate()
        timer = nil
        activity?.stop()
        if let output, let session {
            try? session.stream.removeRecordingOutput(output)
            if autoZoom { try? session.stream.removeStreamOutput(clock, type: .screen) }
        }
        output = nil
        session = nil
        let activity = activity
        self.activity = nil
        if let interruption, fileFinalized {
            controls.hide()
            deliver(.failure(RecordingInterruptedError(original: url, cause: interruption)))
            return
        }
        guard case .success(let source) = result else {
            controls.hide()
            deliver(result)
            return
        }
        guard activity != nil || request.audio.systemAudio || request.audio.microphone else {
            controls.hide()
            deliver(result)
            return
        }
        // Without a frame clock no event can be aligned, so the original becomes the movie unchanged.
        let events = clock.startTime.flatMap { time in activity.map { $0.snapshot(startTime: time) } } ?? []
        process(source, events: events)
    }

    private func process(_ source: URL, events: [RecordingZoomEvent]) {
        isProcessing = true
        outline.orderOut(nil)
        panel.setPrimary(title: environment.string("record.keepOriginal", "保留原片"), indicatorColor: .controlAccentColor)
        panel.onPrimary = { [weak self] in self?.processingTask?.cancel() }
        updateProcessing(0)
        onProcessing?()
        let destination = movieURL
        let report: @Sendable (Double) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in self?.updateProcessing(progress) }
        }
        processingTask = Task { [weak self] in
            let result: Result<URL, Error>
            do {
                result = .success(try await Self.render(source: source, destination: destination, events: events,
                                                        progress: report))
            } catch {
                result = .failure(RecordingProcessingError(original: source, cause: error))
            }
            guard let self else { return }
            processingTask = nil
            isProcessing = false
            controls.hide()
            deliver(result)
        }
    }

    private nonisolated static func render(source: URL, destination: URL, events: [RecordingZoomEvent],
                                           progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        // A clip without zoom or separate audio sources keeps its original bytes.
        let audioTracks = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)
        guard events.contains(where: { $0.kind == .click || $0.kind == .scroll }) || audioTracks.count > 1 else {
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
        try await RecordingZoomExporter.export(source: source, destination: destination, events: events, progress: progress)
        try Task.checkCancellation()
        // The complete movie exists before the recoverable original is removed.
        try? FileManager.default.removeItem(at: source)
        return destination
    }

    private func updateProcessing(_ progress: Double) {
        guard isProcessing else { return }
        let percent = Int(min(1, max(0, progress)) * 100)
        panel.update(environment.format("record.processingMovie", "正在处理录屏 %@", "\(percent)%"))
    }

    private func deliver(_ result: Result<URL, Error>) {
        let completion = onFinish
        onFinish = nil
        completion?(result)
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in lifecycle.recordingStarted() }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            fileFinalized = true
            lifecycle.fileCompleted(.success(url))
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in lifecycle.fileCompleted(.failure(error)) }
    }
}

enum RecordingError: Error { case unsupportedResolution }

enum RecordingZoomError: Error { case pointerMonitorUnavailable }

/// Capture was interrupted, but native output finalized a recoverable movie at `original`.
struct RecordingInterruptedError: Error {
    let original: URL
    let cause: Error
}

/// Processing failed or was cancelled after capture; the original movie remains at `original`.
struct RecordingProcessingError: Error {
    let original: URL
    let cause: Error
}

enum RecordingEncoding {
    static func codec(width: Int, height: Int) throws -> AVVideoCodecType {
        if supports(kCMVideoCodecType_H264, width: width, height: height) { return .h264 }
        if supports(kCMVideoCodecType_HEVC, width: width, height: height) { return .hevc }
        throw RecordingError.unsupportedResolution
    }

    private static func supports(_ codec: CMVideoCodecType, width: Int, height: Int) -> Bool {
        guard let width = Int32(exactly: width), let height = Int32(exactly: height), width > 0, height > 0 else { return false }
        var encoder: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: width, height: height,
            codecType: codec,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &encoder)
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        return status == noErr
    }
}
