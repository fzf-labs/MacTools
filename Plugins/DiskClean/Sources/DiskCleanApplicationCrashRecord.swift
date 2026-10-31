import Darwin
import Foundation

/// Force-quit timestamps are app lifecycle metadata, not arbitrary crash attachments or user data.
struct DiskCleanApplicationCrashRecord: Equatable, Sendable {
    let home: String
    let executable: String

    func permits(_ path: String) -> Bool {
        guard !executable.isEmpty, !executable.contains("/"), !executable.contains(".."),
              !executable.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        let parent = DiskCleanPhysicalPath.resolve(home + "/Library/Application Support/CrashReporter")
        let url = URL(fileURLWithPath: path)
        guard DiskCleanPhysicalPath.resolve(url.deletingLastPathComponent().path) == parent else { return false }
        let name = url.lastPathComponent
        guard name.hasPrefix(executable + "_"), name.hasSuffix(".plist"),
              UUID(uuidString: String(name.dropFirst(executable.count + 1).dropLast(6))) != nil else { return false }
        var status = stat()
        guard lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size > 0, status.st_size <= 4096,
              let data = DiskCleanProjectRecognition.readSmallFile(path),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              value.count == 1, value["ForceQuitDate"] is Date else { return false }
        return true
    }

    func hasConflictingOwner(in applications: [DiskCleanInstalledApplication], excluding bundleID: String) -> Bool {
        applications.contains { $0.bundleID != bundleID && $0.executable?.caseInsensitiveCompare(executable) == .orderedSame }
    }
}
