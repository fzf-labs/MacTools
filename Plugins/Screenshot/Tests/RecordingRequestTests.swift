import AppKit
import MacToolsPluginKit
import XCTest
@testable import ScreenshotPlugin

@MainActor
final class RecordingRequestTests: XCTestCase {
    func testAudioRequiresHostOptInAndANonemptyMicrophonePurpose() {
        XCTAssertFalse(RecordingAuthorization.supportsAudio(infoDictionary: nil))
        XCTAssertFalse(RecordingAuthorization.supportsAudio(infoDictionary: [
            "NSMicrophoneUsageDescription": "A microphone purpose",
        ]))
        for purpose in [nil, "", " \n"] as [String?] {
            var info: [String: Any] = ["MTScreenshotAudioRecordingSupported": true]
            info["NSMicrophoneUsageDescription"] = purpose
            XCTAssertFalse(RecordingAuthorization.supportsAudio(infoDictionary: info))
        }
        XCTAssertTrue(RecordingAuthorization.supportsAudio(infoDictionary: [
            "MTScreenshotAudioRecordingSupported": true,
            "NSMicrophoneUsageDescription": "A microphone purpose",
        ]))
    }
    func testDeniedMicrophoneCanRetryTheSameTargetWithoutMicrophone() async throws {
        let gate = RecordingStartGate()
        let region = try makeRegion()
        let denied = expectation(description: "Microphone denial returned")
        let request = RecordingRequest(target: .region(region), audio: .init(microphone: true))
        gate.start(request, authorize: { false }, validate: { _ in XCTFail("Denied input must not proceed") }) { result in
            guard case .failure(RecordingRequestError.microphoneDenied) = result else { return XCTFail("Expected denial") }
            denied.fulfill()
        }
        await fulfillment(of: [denied], timeout: 2)
        let started = expectation(description: "Same target starts without microphone")
        let retry = RecordingRequest(target: request.target)
        gate.start(retry, authorize: { XCTFail("Silent recording needs no microphone permission"); return false },
                   validate: { XCTAssertFalse($0.microphone) }) { result in
            XCTAssertEqual(try? result.get(), retry)
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
    }

    func testCancellationRejectsALateMicrophoneAuthorizationAndAllowsANewRequest() async throws {
        let gate = RecordingStartGate()
        let entered = expectation(description: "Authorization pending")
        let returned = expectation(description: "Authorization returned")
        var continuation: CheckedContinuation<Bool, Never>?
        var completions = 0
        let request = RecordingRequest(target: .region(try makeRegion()), audio: .init(microphone: true))
        gate.start(request, authorize: {
            let granted = await withCheckedContinuation { continuation = $0; entered.fulfill() }
            returned.fulfill()
            return granted
        }, validate: { _ in XCTFail("Cancelled request must not validate") }) { _ in completions += 1 }
        await fulfillment(of: [entered], timeout: 2)
        gate.cancel()
        continuation?.resume(returning: true)
        await fulfillment(of: [returned], timeout: 2)
        let restarted = expectation(description: "Next preparation starts")
        gate.start(RecordingRequest(target: request.target), validate: { _ in }) { _ in restarted.fulfill() }
        await fulfillment(of: [restarted], timeout: 2)
        XCTAssertEqual(completions, 0)
    }

    func testRecordingToolbarStartsDirectlyAndPreferencesSurviveCancellation() {
        let storage = ScreenshotTestStorage()
        let environment = ScreenshotEnvironment(context: PluginRuntimeContext(pluginID: "screenshot", storage: storage))
        let controls = RecordingControlsView(environment: environment)
        var starts = 0
        var cancellations = 0
        controls.onStart = { starts += 1 }
        controls.onCancel = { cancellations += 1 }
        controls.selectTarget(.region, canStart: true)
        // The XCTest host has no audio capability; invoke the control action without requesting any hardware permission.
        controls.systemAudio.state = .on
        controls.systemAudio.sendAction(controls.systemAudio.action!, to: controls.systemAudio.target)
        controls.microphone.state = .on
        controls.microphone.sendAction(controls.microphone.action!, to: controls.microphone.target)
        controls.startButton.performClick(nil)
        XCTAssertEqual(starts, 1)
        controls.onCancel?()
        XCTAssertEqual(cancellations, 1)
        let reopened = ScreenshotEnvironment(context: PluginRuntimeContext(pluginID: "screenshot", storage: storage))
        XCTAssertTrue(reopened.recordingAudio.systemAudio)
        XCTAssertTrue(reopened.recordingAudio.microphone)
        controls.selectTarget(.region, canStart: false)
        controls.startButton.performClick(nil)
        XCTAssertEqual(starts, 1)
    }

    func testMicrophoneCaptionFollowsTheSelectedDeviceWithoutEnablingRecording() throws {
        let environment = ScreenshotEnvironment(context: PluginRuntimeContext(pluginID: "screenshot", storage: ScreenshotTestStorage()))
        environment.recordingAudio = .init(microphoneID: "input-1")
        let controls = RecordingControlsView(environment: environment, discoverMicrophones: {
            .init(devices: [.init(id: "input-1", name: "Studio Input"), .init(id: "input-2", name: "USB Input")],
                  defaultName: "Built-in Input")
        })
        controls.activate()
        defer { controls.deactivate() }
        XCTAssertEqual(controls.devices.itemTitle(at: 0), "Studio Input")
        controls.menuWillOpen(try XCTUnwrap(controls.devices.menu))
        let choice = try XCTUnwrap(controls.devices.itemArray.first { $0.representedObject as? String == "input-2" })
        NSApp.sendAction(try XCTUnwrap(choice.action), to: choice.target, from: choice)
        XCTAssertEqual(environment.recordingAudio.microphoneID, "input-2")
        XCTAssertFalse(environment.recordingAudio.microphone)
        XCTAssertEqual(controls.devices.itemTitle(at: 0), "USB Input")
        XCTAssertEqual(controls.devices.toolTip, "USB Input")
    }

    func testInlineApplicationSelectionStartsItsExactTargetAndRejectsAClosedApp() async throws {
        let environment = ScreenshotEnvironment(context: PluginRuntimeContext(pluginID: "screenshot", storage: ScreenshotTestStorage()))
        let display = try makeRegion().display
        let first = RecordingTarget.application(processID: 41, bundleID: "example.first", display: display)
        let second = RecordingTarget.application(processID: 42, bundleID: "example.second", display: display)
        let catalog = RecordingCatalogFixture(.init(displays: [.init(display: display, name: "Test Display")],
            applications: [.init(target: first, name: "Same Name"), .init(target: second, name: "Same Name")]))
        let controls = RecordingControlsView(environment: environment, discoverApplications: { catalog.value })
        let picker = controls.applications
        let loaded = expectation(description: "Inline applications loaded")
        let change = picker.onChange
        var didLoad = false
        picker.onChange = {
            change?()
            if !picker.isLoading, !didLoad { didLoad = true; loaded.fulfill() }
        }
        controls.showApplications(displayID: display.id)
        defer { controls.deactivate() }
        await fulfillment(of: [loaded], timeout: 2)
        XCTAssertTrue(picker.isDescendant(of: controls))
        XCTAssertFalse(picker.isHidden)
        XCTAssertEqual(picker.collectionView.numberOfItems(inSection: 0), 2)
        XCTAssertNil(picker.selectedTarget)
        XCTAssertFalse(controls.startButton.isEnabled)
        picker.selectApplication(second)
        var started: RecordingTarget?
        controls.onStart = { started = picker.selectedTarget }
        controls.startButton.performClick(nil)
        XCTAssertEqual(started, second)

        catalog.value = .init(displays: catalog.value.displays, applications: [.init(target: first, name: "Same Name")])
        let refreshed = expectation(description: "Closed app removed")
        picker.onChange = { change?(); if !picker.isLoading { refreshed.fulfill() } }
        picker.refresh()
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertNil(picker.selectedTarget)
        XCTAssertFalse(controls.startButton.isEnabled)
        controls.selectTarget(.region, canStart: true)
        XCTAssertTrue(picker.isHidden)
        XCTAssertTrue(controls.startButton.isEnabled)
    }

    func testLeavingApplicationModeRejectsLateDiscovery() async throws {
        let environment = ScreenshotEnvironment(context: PluginRuntimeContext(pluginID: "screenshot", storage: ScreenshotTestStorage()))
        let display = try makeRegion().display
        let entered = expectation(description: "Application discovery pending")
        let returned = expectation(description: "Application discovery returned")
        var continuation: CheckedContinuation<RecordingApplicationCatalog, Never>?
        let picker = RecordingApplicationPicker(environment: environment, discover: {
            let result = await withCheckedContinuation { continuation = $0; entered.fulfill() }
            returned.fulfill()
            return result
        })
        var changes = 0
        picker.onChange = { changes += 1 }
        picker.activate(displayID: display.id)
        await fulfillment(of: [entered], timeout: 2)
        picker.stop()
        let previousChanges = changes
        continuation?.resume(returning: .init(displays: [.init(display: display, name: "Test Display")], applications: []))
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertNil(picker.selectedTarget)
        XCTAssertEqual(changes, previousChanges)
    }

    func testApplicationRefreshKeepsChangesThatArriveDuringDiscovery() async throws {
        let environment = ScreenshotEnvironment(context: PluginRuntimeContext(pluginID: "screenshot", storage: ScreenshotTestStorage()))
        let display = try makeRegion().display
        let entered = expectation(description: "First discovery pending")
        let updated = expectation(description: "Queued discovery completed")
        var continuation: CheckedContinuation<RecordingApplicationCatalog, Never>?
        var calls = 0
        let picker = RecordingApplicationPicker(environment: environment, discover: {
            calls += 1
            if calls == 1 { return await withCheckedContinuation { continuation = $0; entered.fulfill() } }
            return .init(displays: [.init(display: display, name: "Test Display")], applications: [])
        })
        picker.onChange = { if calls == 2, !picker.isLoading { updated.fulfill() } }
        picker.activate(displayID: display.id)
        defer { picker.stop() }
        await fulfillment(of: [entered], timeout: 2)
        picker.refresh()
        continuation?.resume(returning: .init(displays: [.init(display: display, name: "Test Display")],
            applications: [.init(target: .application(processID: 41, bundleID: "example.app", display: display), name: "Example")]))
        await fulfillment(of: [updated], timeout: 2)
        XCTAssertEqual(picker.collectionView.numberOfItems(inSection: 0), 0)
        XCTAssertNil(picker.selectedTarget)
    }

    private func makeRegion() throws -> CaptureRegion {
        let display = CaptureDisplay(id: 7, frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                     captureRect: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 1)
        return try CaptureRegion(selection: CGRect(x: 100, y: 100, width: 500, height: 400), display: display)
    }

}

@MainActor
private final class RecordingCatalogFixture {
    var value: RecordingApplicationCatalog
    init(_ value: RecordingApplicationCatalog) { self.value = value }
}
