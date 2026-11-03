import AppKit
import ApplicationServices
import CoreServices
import IOKit.pwr_mgt
import MacToolsPluginKit

@MainActor
enum LauncherSystemActionRunner {
    static func run(_ command: LauncherSystemAction, previousApplication: NSRunningApplication?) async -> ActionExecutionResult {
        do {
            switch command {
            case .lockScreen:
                try await worker {
                    let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
                    guard let library = dlopen(path, RTLD_NOW) else { throw Failure.unavailable }
                    defer { dlclose(library) }
                    guard let symbol = dlsym(library, "SACLockScreenImmediate") else { throw Failure.unavailable }
                    let lock = unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
                    guard lock() == 0 else { throw Failure.unavailable }
                }
            case .sleep:
                try await worker {
                    let connection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
                    guard connection != IO_OBJECT_NULL else { throw Failure.unavailable }
                    defer { IOServiceClose(connection) }
                    guard IOPMSleepSystem(connection) == kIOReturnSuccess else { throw Failure.unavailable }
                }
            case .sleepDisplays:
                try await worker { try process("/usr/bin/pmset", ["displaysleepnow"]) }
            case .restart, .shutDown, .logOut:
                try await worker {
                    // ActionExecutor has already confirmed; macOS still owns application save prompts.
                    let eventID: AEEventID = command == .restart ? AEEventID(kAERestart)
                        : command == .shutDown ? AEEventID(kAEShutDown) : AEEventID(kAELogOut)
                    let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: eventID,
                        targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow"),
                        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                    do { _ = try event.sendEvent(options: [.noReply, .alwaysInteract, .canSwitchLayer], timeout: 10) }
                    catch { if (error as NSError).code == Int(errAEEventNotPermitted) { throw Failure.automation }; throw error }
                }
            case .screenSaver:
                _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"), configuration: .init())
            case .missionControl, .showDesktop:
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.arguments = command == .showDesktop ? ["1"] : []
                _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"), configuration: configuration)
            case .playPause, .nextTrack, .previousTrack:
                guard AXIsProcessTrusted() else { throw Failure.accessibility }
                let key: Int = command == .playPause ? 16 : command == .nextTrack ? 17 : 18
                for state in [0xA, 0xB] {
                    guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 8,
                        data1: (key << 16) | (state << 8), data2: -1)?.cgEvent else { throw Failure.unavailable }
                    event.post(tap: .cghidEventTap)
                }
            case .toggleMute, .toggleMicrophoneMute, .volumeUp, .volumeDown, .volume0, .volume25, .volume50, .volume75, .volume100:
                try await worker { try LauncherSystemAudio.perform(command) }
            case .toggleAppearance:
                try await worker { try script("tell application id \"com.apple.systemevents\" to tell appearance preferences to set dark mode to not dark mode") }
            case .openTrash:
                guard NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")) else { throw Failure.unavailable }
            case .emptyTrash:
                try await worker { try script("tell application id \"com.apple.finder\"\nif (count items of trash) > 0 then empty trash\nend tell") }
            case .hideOtherApps:
                // Never hide everything if the application captured before presentation has exited.
                guard let previousApplication, !previousApplication.isTerminated,
                      previousApplication.activationPolicy == .regular else { throw Failure.unavailable }
                for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
                    && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
                    && app.processIdentifier != previousApplication.processIdentifier {
                    _ = app.hide()
                }
                previousApplication.unhide()
                _ = previousApplication.activate(options: [])
            case .unhideAllApps:
                for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.isHidden { app.unhide() }
            }
            return .succeeded()
        } catch is CancellationError { return .cancelled }
        catch Failure.accessibility { return .failed(message: LauncherText.accessibilityRequired) }
        catch Failure.automation { return .failed(message: LauncherText.automationRequired) }
        catch is LauncherSystemAudio.Failure { return .failed(message: LauncherText.audioUnavailable) }
        catch { return .failed(message: LauncherText.systemActionFailed) }
    }
    private enum Failure: Error { case unavailable, automation, accessibility }
    nonisolated private static func worker(_ operation: @escaping @Sendable () throws -> Void) async throws {
        let task = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); try operation() }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    /// Only fixed, compiled-in scripts are accepted. Search text never becomes executable source.
    nonisolated private static func script(_ source: String) throws {
        try process("/usr/bin/osascript", ["-e", "with timeout of 10 seconds\n" + source + "\nend timeout"])
    }
    nonisolated private static func process(_ executable: String, _ arguments: [String]) throws {
        try Task.checkCancellation()
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline && !Task.isCancelled { Thread.sleep(forTimeInterval: 0.025) }
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if message.contains("-1743") { throw Failure.automation }
            if message.contains("-128") { throw CancellationError() }
            throw Failure.unavailable
        }
    }
}
