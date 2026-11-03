import CoreAudio
import XCTest
import MacToolsPluginKit
@testable import AppVolumePlugin
@testable import MacTools

@MainActor
final class AppVolumePluginTests: XCTestCase {

    func testChangingSliderRequestsAccessAndRoutesTarget() async throws {
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        let plugin = makePlugin(monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 51),
        ]))
        plugin.handleAction(.setDisclosureExpanded(true))
        let sliderID = try XCTUnwrap(plugin.rowState.detail?.controls.first?.id)

        plugin.handleAction(.setSlider(controlID: sliderID, value: 0.35, phase: .ended))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(router.accessRequestCount, 1)
        let target = try XCTUnwrap(router.lastTargets.first)
        XCTAssertEqual(target.id, "com.example.music")
        XCTAssertEqual(target.gain, 0.35, accuracy: 0.001)
        XCTAssertTrue(plugin.rowState.isOn)
    }

    func testReturningSliderToUnityStopsProcessing() async throws {
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        let plugin = makePlugin(monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 61),
        ]))
        plugin.handleAction(.setDisclosureExpanded(true))
        let sliderID = try XCTUnwrap(plugin.rowState.detail?.controls.first?.id)

        plugin.handleAction(.setSlider(controlID: sliderID, value: 0.5, phase: .ended))
        for _ in 0 ..< 100 {
            let control = plugin.rowState.detail?.controls.first
            if !router.updates.isEmpty,
               control?.sliderValue == 0.5,
               control?.isEnabled == true {
                break
            }
            await Task.yield()
        }
        plugin.handleAction(.setSlider(controlID: sliderID, value: 1, phase: .ended))
        for _ in 0 ..< 100 {
            if !plugin.rowState.isOn,
               plugin.rowState.detail?.controls.first?.isEnabled == true {
                break
            }
            await Task.yield()
        }

        XCTAssertTrue(router.lastTargets.isEmpty)
        XCTAssertFalse(plugin.rowState.isOn)
    }

    func testVolumePreferenceIsRestoredForMatchingApplication() async throws {
        let storage = AppVolumeStorageMock()
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock()
        let firstPlugin = makePlugin(storage: storage, monitor: monitor, router: router)
        firstPlugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 71),
        ]))
        firstPlugin.handleAction(.setDisclosureExpanded(true))
        let sliderID = try XCTUnwrap(firstPlugin.rowState.detail?.controls.first?.id)
        firstPlugin.handleAction(.setSlider(controlID: sliderID, value: 0.2, phase: .ended))
        for _ in 0 ..< 100 where router.updates.isEmpty {
            await Task.yield()
        }
        await Task.yield()

        let secondMonitor = AppVolumeMonitorMock()
        let secondPlugin = makePlugin(storage: storage, monitor: secondMonitor)
        secondPlugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        secondMonitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 72),
        ]))
        secondPlugin.handleAction(.setDisclosureExpanded(true))

        XCTAssertEqual(secondPlugin.rowState.detail?.controls.first?.sliderValue, 0.2)
    }

    func testDeactivationStopsMonitorAndRouter() {
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock()
        let plugin = makePlugin(monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))

        plugin.deactivate(reason: .disabled)

        XCTAssertFalse(monitor.isRunning)
        XCTAssertTrue(router.didStop)
        XCTAssertTrue(plugin.rowState.detail?.controls.isEmpty ?? true)
    }

    func testUnsupportedSystemDisablesPlugin() {
        let router = AppVolumeRouterMock(isSupported: false)
        let plugin = makePlugin(router: router)

        XCTAssertFalse(plugin.rowState.isEnabled)
        XCTAssertEqual(plugin.rowState.subtitle, "需要 macOS 15 或更高版本")
        XCTAssertTrue(plugin.permissionRequirements.isEmpty)
    }

    func testPermissionRefreshRechecksAfterUserDrivenSettingsRoundTrip() async {
        let router = AppVolumeRouterMock(accessResult: false)
        var openSettingsCount = 0
        let plugin = makePlugin(
            router: router,
            openSystemAudioPrivacySettings: { openSettingsCount += 1 }
        )

        plugin.handlePermissionAction(id: "system-audio-recording")
        for _ in 0 ..< 100 where openSettingsCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(router.accessRequestCount, 1)
        XCTAssertEqual(openSettingsCount, 1)
        XCTAssertFalse(plugin.permissionState(for: "system-audio-recording").isGranted)

        router.accessResult = true
        plugin.refresh()
        for _ in 0 ..< 100
            where !plugin.permissionState(for: "system-audio-recording").isGranted {
            await Task.yield()
        }

        XCTAssertEqual(router.accessRequestCount, 2)
        XCTAssertEqual(openSettingsCount, 1)
        XCTAssertTrue(plugin.permissionState(for: "system-audio-recording").isGranted)
    }

    func testCanonicalMuteRequestsAccessAndRoutesTheTarget() async throws {
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        let plugin = makePlugin(monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 92),
        ]))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(router.accessRequestCount, 1)
        XCTAssertEqual(router.lastTargets.first?.gain, 0)
    }

    func testCanonicalRouteFailureDoesNotPersistAndReappliesPreviousTargets() async throws {
        let storage = AppVolumeStorageMock()
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        router.applyResults = [.failed, .succeeded]
        let plugin = makePlugin(storage: storage, monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 94),
        ]))
        let updateCountBeforeAction = router.updates.count
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        guard case .failed = result else {
            return XCTFail("Expected routing failure, got \(result)")
        }
        XCTAssertEqual(router.updates.count, updateCountBeforeAction + 2)
        XCTAssertEqual(router.updates[updateCountBeforeAction].first?.gain, 0)
        XCTAssertEqual(router.updates[updateCountBeforeAction + 1].first?.gain, 1)
        plugin.handleAction(.setDisclosureExpanded(true))
        XCTAssertEqual(plugin.rowState.detail?.controls.first?.sliderValue, 1)

        let restoredMonitor = AppVolumeMonitorMock()
        let restored = makePlugin(storage: storage, monitor: restoredMonitor)
        restored.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        restoredMonitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 95),
        ]))
        restored.handleAction(.setDisclosureExpanded(true))
        XCTAssertEqual(restored.rowState.detail?.controls.first?.sliderValue, 1)
    }

    func testCanonicalPersistenceFailureRollsRouteBackAndKeepsPreviousVolume() async throws {
        let storage = AppVolumeStorageMock()
        storage.blockedSetKeys = ["applicationVolumes"]
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        let plugin = makePlugin(storage: storage, monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 100),
        ]))
        let updateCountBeforeAction = router.updates.count
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        guard case let .failed(message) = result else {
            return XCTFail("expected persistence failure, got \(result)")
        }
        XCTAssertTrue(message.contains("无法保存"))
        XCTAssertEqual(router.updates.count, updateCountBeforeAction + 2)
        XCTAssertEqual(router.updates[updateCountBeforeAction].first?.gain, 0)
        XCTAssertEqual(router.updates[updateCountBeforeAction + 1].first?.gain, 1)
        plugin.handleAction(.setDisclosureExpanded(true))
        XCTAssertEqual(plugin.rowState.detail?.controls.first?.sliderValue, 1)

        let restoredMonitor = AppVolumeMonitorMock()
        let restored = makePlugin(storage: storage, monitor: restoredMonitor)
        restored.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        restoredMonitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 101),
        ]))
        restored.handleAction(.setDisclosureExpanded(true))
        XCTAssertEqual(restored.rowState.detail?.controls.first?.sliderValue, 1)
    }

    func testDeactivationCancelsSuspendedCanonicalRouteWithoutPersisting() async throws {
        let storage = AppVolumeStorageMock()
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        router.suspendNextApply = true
        let plugin = makePlugin(storage: storage, monitor: monitor, router: router)
        let context = PluginRuntimeContext(pluginID: "app-volume")
        plugin.activate(context: context)
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 102),
        ]))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let resultTask = Task {
            try await plugin.beginAction(ActionInvocation(
                reference: reference,
                source: .test,
                mode: .background
            )).result()
        }
        for _ in 0 ..< 100 where !router.hasSuspendedApply {
            await Task.yield()
        }
        XCTAssertTrue(router.hasSuspendedApply)

        plugin.deactivate(reason: .updating)
        router.completeSuspendedApply(.succeeded)

        let result = try await resultTask.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(router.didStop)

        plugin.activate(context: context)
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 103),
        ]))
        XCTAssertTrue(plugin.actionAvailability(for: reference).isAvailable)

        let restoredMonitor = AppVolumeMonitorMock()
        let restored = makePlugin(storage: storage, monitor: restoredMonitor)
        restored.activate(context: context)
        restoredMonitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 104),
        ]))
        restored.handleAction(.setDisclosureExpanded(true))
        XCTAssertEqual(restored.rowState.detail?.controls.first?.sliderValue, 1)
    }

    func testCanonicalActionBecomesUnavailableWhenTheAppStopsPlaying() throws {
        let monitor = AppVolumeMonitorMock()
        let plugin = makePlugin(monitor: monitor)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        monitor.send(snapshot(applications: [
            application(id: "com.example.music", name: "Music", objectID: 93),
        ]))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        monitor.send(snapshot(applications: []))

        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
    }

    func testPortableRestorePreservesRunningAudioRouteAndSavesFuturePreference() async throws {
        let storage = AppVolumeStorageMock()
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        let plugin = makePlugin(storage: storage, monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        defer { plugin.deactivate(reason: .hostShutdown) }
        let apps = [application(id: "com.example.music", name: "Music", objectID: 51)]
        monitor.send(snapshot(applications: apps))
        plugin.handleAction(.setDisclosureExpanded(true))
        let sliderID = try XCTUnwrap(plugin.rowState.detail?.controls.first?.id)
        plugin.handleAction(.setSlider(controlID: sliderID, value: 0.4, phase: .ended))
        for _ in 0..<100 where router.lastTargets.first?.gain != 0.4 { await Task.yield() }
        XCTAssertEqual(router.lastTargets.first?.gain, 0.4)
        let updateCount = router.updates.count
        let accessCount = router.accessRequestCount
        let data = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "applications": ["com.example.music": 0.8]])
        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: data))
        XCTAssertEqual(router.updates.count, updateCount)
        XCTAssertEqual(router.accessRequestCount, accessCount)
        monitor.send(snapshot(applications: apps))
        await Task.yield()
        XCTAssertEqual(router.lastTargets.first?.gain, 0.4)
        monitor.send(snapshot(applications: []))
        monitor.send(snapshot(applications: [application(id: "com.example.music", name: "Music", objectID: 52)]))
        XCTAssertEqual(router.lastTargets.first?.gain, 0.8)
        let reloaded = makePlugin(storage: storage)
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(reloaded.makePortablePreferencesBackup())) as? [String: Any])
        XCTAssertEqual((exported["applications"] as? [String: Double])?["com.example.music"], 0.8)
    }

    func testImportAppliesToSilentAppsAndNewPlaybackProcesses() async throws {
        for transition in ["silentAtImport", "newApp", "replacementProcess"] {
            let storage = AppVolumeStorageMock()
            storage.setRawValue(try JSONEncoder().encode(["com.example.music": 0.4, "com.example.video": 0.2]),
                forKey: "applicationVolumes")
            let monitor = AppVolumeMonitorMock()
            let router = AppVolumeRouterMock(accessResult: true)
            let plugin = makePlugin(storage: storage, monitor: monitor, router: router)
            plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
            defer { plugin.deactivate(reason: .hostShutdown) }
            let music = application(id: "com.example.music", name: "Music", objectID: 51)
            monitor.send(snapshot(applications: [music]))
            plugin.handlePermissionAction(id: "system-audio-recording")
            for _ in 0..<100 where !plugin.permissionState(for: "system-audio-recording").isGranted { await Task.yield() }
            XCTAssertTrue(plugin.permissionState(for: "system-audio-recording").isGranted)
            if transition == "silentAtImport" { monitor.send(snapshot(applications: [])) }

            let data = try JSONSerialization.data(withJSONObject: ["formatVersion": 1,
                "applications": ["com.example.music": 0.8, "com.example.video": 0.9]])
            let updateCount = router.updates.count
            let accessCount = router.accessRequestCount
            XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: data))
            XCTAssertEqual(router.updates.count, updateCount)
            XCTAssertEqual(router.accessRequestCount, accessCount)

            let nextMusic = transition == "replacementProcess"
                ? application(id: "com.example.music", name: "Music", objectID: 61) : music
            monitor.send(snapshot(applications: [nextMusic,
                application(id: "com.example.video", name: "Video", objectID: 52)]))
            XCTAssertEqual(router.lastTargets.first { $0.id == music.id }?.gain,
                transition == "newApp" ? 0.4 : 0.8, transition)
            XCTAssertEqual(router.lastTargets.first { $0.id == "com.example.video" }?.gain, 0.9, transition)
        }
    }

    func testPlaybackTurnoverDuringSuspendedEditUsesImportedGainOnRollback() async throws {
        let storage = AppVolumeStorageMock()
        storage.setRawValue(try JSONEncoder().encode(["com.example.music": 0.4, "com.example.video": 0.2]),
            forKey: "applicationVolumes")
        let monitor = AppVolumeMonitorMock()
        let router = AppVolumeRouterMock(accessResult: true)
        let plugin = makePlugin(storage: storage, monitor: monitor, router: router)
        plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
        defer { plugin.deactivate(reason: .hostShutdown) }
        let video = application(id: "com.example.video", name: "Video", objectID: 52)
        monitor.send(snapshot(applications: [application(id: "com.example.music", name: "Music", objectID: 51), video]))
        let data = try JSONSerialization.data(withJSONObject: ["formatVersion": 1,
            "applications": ["com.example.music": 0.8, "com.example.video": 0.9]])
        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: data))
        router.suspendNextApply = true
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first {
            $0.reference.parameters["application"] == .string(video.id)
                && $0.reference.parameters["volume"] == .double(0.5)
        }?.reference)
        let task = Task { try await plugin.beginAction(ActionInvocation(
            reference: reference, source: .test, mode: .background)).result() }
        for _ in 0..<100 where !router.hasSuspendedApply { await Task.yield() }
        XCTAssertTrue(router.hasSuspendedApply)
        monitor.send(snapshot(applications: [application(id: "com.example.music", name: "Music", objectID: 61), video]))
        XCTAssertEqual(router.lastTargets.first { $0.id == "com.example.music" }?.gain, 0.8)
        router.completeSuspendedApply(.failed)
        let result = try await task.value
        if case .failed = result {} else { XCTFail("Expected route failure") }
        XCTAssertEqual(router.lastTargets.first { $0.id == "com.example.music" }?.gain, 0.8)
        XCTAssertEqual(router.lastTargets.first { $0.id == video.id }?.gain, 0.2)
    }

    func testPostImportVolumeEditPreservesOtherLiveGainsAndRollsBackFailures() async throws {
        for failure in ["none", "route", "storage"] {
            let storage = AppVolumeStorageMock()
            storage.setRawValue(try JSONEncoder().encode(["com.example.music": 0.4, "com.example.video": 0.2]),
                forKey: "applicationVolumes")
            let monitor = AppVolumeMonitorMock()
            let router = AppVolumeRouterMock(accessResult: true)
            let plugin = makePlugin(storage: storage, monitor: monitor, router: router)
            plugin.activate(context: PluginRuntimeContext(pluginID: "app-volume"))
            defer { plugin.deactivate(reason: .hostShutdown) }
            let apps = [application(id: "com.example.music", name: "Music", objectID: 51),
                        application(id: "com.example.video", name: "Video", objectID: 52)]
            monitor.send(snapshot(applications: apps))
            let incoming = try JSONSerialization.data(withJSONObject: ["formatVersion": 1,
                "applications": ["com.example.music": 0.8, "com.example.video": 0.9]])
            XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: incoming))
            if failure == "route" { router.applyResults = [.failed, .succeeded] }
            if failure == "storage" { storage.blockedSetKeys = ["applicationVolumes"] }
            let reference = try XCTUnwrap(plugin.actionCatalogEntries.first {
                $0.reference.parameters["application"] == .string("com.example.video")
                    && $0.reference.parameters["volume"] == .double(0.5)
            }?.reference)
            let result = try await plugin.beginAction(ActionInvocation(
                reference: reference, source: .test, mode: .background)).result()
            if failure == "none" { XCTAssertEqual(result, .succeeded()) }
            else if case .failed = result {} else { XCTFail("Expected \(failure) failure") }
            let expectedVideo = failure == "none" ? 0.5 : 0.2
            XCTAssertEqual(router.lastTargets.first { $0.id == "com.example.music" }?.gain, 0.4)
            XCTAssertEqual(router.lastTargets.first { $0.id == "com.example.video" }?.gain, expectedVideo)
            monitor.send(snapshot(applications: apps))
            XCTAssertEqual(router.lastTargets.first { $0.id == "com.example.music" }?.gain, 0.4)
            XCTAssertEqual(router.lastTargets.first { $0.id == "com.example.video" }?.gain, expectedVideo)
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(plugin.makePortablePreferencesBackup())) as? [String: Any])
            XCTAssertEqual(saved["applications"] as? [String: Double],
                ["com.example.music": 0.8, "com.example.video": failure == "none" ? 0.5 : 0.9])
        }
    }

    private func makePlugin(
        storage: AppVolumeStorageMock? = nil,
        monitor: AppVolumeMonitorMock? = nil,
        router: AppVolumeRouterMock? = nil,
        openSystemAudioPrivacySettings: @escaping () -> Void = {}
    ) -> AppVolumePlugin {
        AppVolumePlugin(
            storage: storage ?? AppVolumeStorageMock(),
            monitor: monitor ?? AppVolumeMonitorMock(),
            router: router ?? AppVolumeRouterMock(),
            openSystemAudioPrivacySettings: openSystemAudioPrivacySettings
        )
    }

    private func snapshot(applications: [AudioApplication]) -> AudioApplicationSnapshot {
        AudioApplicationSnapshot(
            applications: applications.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            },
            outputDeviceUID: "test-output"
        )
    }

    private func application(id: String, name: String, objectID: AudioObjectID) -> AudioApplication {
        AudioApplication(
            id: id,
            displayName: name,
            bundleIdentifier: id,
            processObjectIDs: [objectID]
        )
    }
}

@MainActor
private final class AppVolumeMonitorMock: AudioApplicationMonitoring {
    var onUpdate: ((AudioApplicationSnapshot) -> Void)?
    private(set) var isRunning = false

    func start() {
        isRunning = true
    }

    func refresh() {}

    func stop() {
        isRunning = false
    }

    func send(_ snapshot: AudioApplicationSnapshot) {
        onUpdate?(snapshot)
    }
}

@MainActor
private final class AppVolumeRouterMock: ApplicationVolumeRouting {
    let isSupported: Bool
    var accessResult: Bool
    private(set) var accessRequestCount = 0
    private(set) var updates: [[ApplicationVolumeTarget]] = []
    private(set) var didStop = false
    var applyResults: [ApplicationVolumeRouteResult] = []
    var suspendNextApply = false
    var suspendNextAccessRequest = false
    private var suspendedApplyContinuation:
        CheckedContinuation<ApplicationVolumeRouteResult, Never>?
    private var suspendedAccessContinuation: CheckedContinuation<Bool, Never>?

    var hasSuspendedApply: Bool {
        suspendedApplyContinuation != nil
    }

    var hasSuspendedAccessRequest: Bool {
        suspendedAccessContinuation != nil
    }

    var lastTargets: [ApplicationVolumeTarget] {
        updates.last ?? []
    }

    init(isSupported: Bool = true, accessResult: Bool = true) {
        self.isSupported = isSupported
        self.accessResult = accessResult
    }

    func update(targets: [ApplicationVolumeTarget], outputDeviceUID: String?) {
        updates.append(targets)
    }

    func applyAndWait(
        targets: [ApplicationVolumeTarget],
        outputDeviceUID: String?
    ) async -> ApplicationVolumeRouteResult {
        update(targets: targets, outputDeviceUID: outputDeviceUID)
        if suspendNextApply {
            suspendNextApply = false
            return await withCheckedContinuation { continuation in
                suspendedApplyContinuation = continuation
            }
        }
        return applyResults.isEmpty ? .succeeded : applyResults.removeFirst()
    }

    func completeSuspendedApply(_ result: ApplicationVolumeRouteResult) {
        let continuation = suspendedApplyContinuation
        suspendedApplyContinuation = nil
        continuation?.resume(returning: result)
    }

    func requestSystemAudioAccess() async -> Bool {
        accessRequestCount += 1
        if suspendNextAccessRequest {
            suspendNextAccessRequest = false
            return await withCheckedContinuation { continuation in
                suspendedAccessContinuation = continuation
            }
        }
        return accessResult
    }

    func completeSuspendedAccessRequest(_ result: Bool) {
        let continuation = suspendedAccessContinuation
        suspendedAccessContinuation = nil
        continuation?.resume(returning: result)
    }

    func stop() {
        didStop = true
    }
}

@MainActor
private final class AppVolumeStorageMock: PluginStorage {
    private var values: [String: Any] = [:]
    var blockedSetKeys: Set<String> = []

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) {
        guard !blockedSetKeys.contains(key) else { return }
        values[key] = value
    }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}

    func setRawValue(_ value: Any, forKey key: String) {
        values[key] = value
    }

    func rawValue(forKey key: String) -> Any? {
        values[key]
    }
}
