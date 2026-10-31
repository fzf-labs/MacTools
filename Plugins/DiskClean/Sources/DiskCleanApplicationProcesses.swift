import AppKit
import Darwin
import Foundation

struct DiskCleanApplicationProcessScope: Sendable {
    let bundleID: String
    let applicationPaths: [String]
    var programPaths: Set<String> = []

    func contains(executable: String) -> Bool {
        programPaths.contains(executable) || applicationPaths.contains { executable.hasPrefix($0 + "/Contents/") }
    }
}

protocol DiskCleanApplicationQuitting: Sendable {
    func quit(_ scope: DiskCleanApplicationProcessScope, force: Bool) async throws -> Bool
}

struct DiskCleanApplicationProcesses: DiskCleanApplicationQuitting {
    var runner: any DiskCleanSubprocessRunning = LocalDiskCleanSubprocessRunner()

    func quit(_ scope: DiskCleanApplicationProcessScope, force: Bool) async throws -> Bool {
        let runningCopies = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app -> String? in
                guard app.processIdentifier != getpid(),
                      app.bundleIdentifier?.caseInsensitiveCompare(scope.bundleID) == .orderedSame,
                      let path = app.bundleURL?.path else { return nil }
                return DiskCleanPhysicalPath.resolve(path)
            }
        }
        let activeScope = DiskCleanApplicationProcessScope(bundleID: scope.bundleID,
            applicationPaths: Array(Set(scope.applicationPaths + runningCopies)), programPaths: scope.programPaths)
        let pids = try await matchingProcesses(activeScope)
        for pid in pids {
            try Task.checkCancellation()
            let handled = await MainActor.run {
                guard let app = NSRunningApplication(processIdentifier: pid),
                      let executable = app.executableURL?.path, activeScope.contains(executable: executable) else { return false }
                return force ? app.forceTerminate() : app.terminate()
            }
            if !handled, currentExecutable(pid).map(activeScope.contains(executable:)) == true {
                guard kill(pid, force ? SIGKILL : SIGTERM) == 0 || errno == ESRCH else {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
        }
        let deadline = Date().addingTimeInterval(force ? 4 : 8)
        repeat {
            try Task.checkCancellation()
            if try await matchingProcesses(activeScope).isEmpty { return true }
            try await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline
        return false
    }

    private func matchingProcesses(_ scope: DiskCleanApplicationProcessScope) async throws -> [pid_t] {
        let result = try await runner.run(executablePath: "/bin/ps", arguments: ["-axo", "pid=,uid=,comm="], timeout: .seconds(3))
        guard result.exitCode == 0 else { throw CocoaError(.fileReadUnknown) }
        return String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, let pid = pid_t(fields[0]), pid != getpid(),
                  uid_t(fields[1]) == getuid(), scope.contains(executable: String(fields[2])),
                  let executable = currentExecutable(pid), scope.contains(executable: executable) else { return nil }
            return pid
        }
    }

    private func currentExecutable(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
