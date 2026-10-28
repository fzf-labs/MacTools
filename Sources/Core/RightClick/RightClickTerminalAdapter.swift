import AppKit
import Foundation

struct RightClickTerminalAdapter {
    static func warpURL(directory: URL, newTab: Bool) -> URL? {
        var components = URLComponents()
        components.scheme = "warp"
        components.host = "action"
        components.path = newTab ? "/new_tab" : "/new_window"
        components.queryItems = [URLQueryItem(name: "path", value: directory.path)]
        return components.url
    }

    @MainActor
    func open(_ terminal: RightClickTerminal, directory: URL, newTab: Bool) async throws {
        guard (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleID) else {
            throw RightClickFailure(message: "Folder or terminal application is unavailable.", path: directory.path)
        }
        switch terminal {
        case .terminal:
            _ = try await NSWorkspace.shared.open([directory], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        case .warp:
            guard let url = Self.warpURL(directory: directory, newTab: newTab) else { throw RightClickFailure(message: "Invalid file path.") }
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        case .iterm:
            try await Task.detached(priority: .userInitiated) { try Self.openITerm(directory: directory, newTab: newTab) }.value
        }
    }

    /// Arguments are passed separately and quoted by AppleScript; file names never
    /// become AppleScript source. This is a fixed adapter, not a script executor.
    private static func openITerm(directory: URL, newTab: Bool) throws {
        let script = """
        on run argv
            set folderPath to item 1 of argv
            set useTab to item 2 of argv
            with timeout of 15 seconds
                tell application id "com.googlecode.iterm2"
                    activate
                    if useTab is "true" and (count of windows) > 0 then
                        tell current window
                            set targetTab to (create tab with default profile)
                            tell current session of targetTab to write text ("cd -- " & quoted form of folderPath)
                        end tell
                    else
                        set targetWindow to (create window with default profile)
                        tell current session of targetWindow to write text ("cd -- " & quoted form of folderPath)
                    end if
                end tell
            end timeout
        end run
        """
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, directory.path, newTab ? "true" : "false"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < terminationDeadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        let error = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            if error.contains("-1743") || error.contains("not authorized") {
                throw RightClickFailure(message: "Allow MacTools to control iTerm2 in System Settings > Privacy & Security > Automation.")
            }
            throw RightClickFailure(message: "Cannot open iTerm2. Check its automation permission and try again.")
        }
    }
}
