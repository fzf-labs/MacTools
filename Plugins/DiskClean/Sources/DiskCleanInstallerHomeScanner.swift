import Darwin
import Foundation

struct DiskCleanInstallerHomeScan: Sendable {
    var candidates: [DiskCleanInstallerCandidate] = []
    var limitations: [DiskCleanScanLimitation] = []
    var reservedRoots: [String] = []
}

/// Bounded, metadata-only discovery. Every directory is opened without following symlinks.
struct DiskCleanInstallerHomeScanner: Sendable {
    struct Limits: Sendable {
        var maximumDepth = 6
        var maximumEntries = 60_000
        var maximumCandidates = 5_000
        var timeout: TimeInterval = 30
    }

    let home: String
    var limits = Limits()
    var sourceFactory: any DiskCleanDirectoryEntrySourceFactory = DiskCleanDiscoveryEntrySourceFactory()
    var now: @Sendable () -> Date = Date.init
    var isCancelled: @Sendable () -> Bool = { Task.isCancelled }

    private struct Directory {
        let path: String
        let depth: Int
        let downloads: Bool
        let identity: DiskCleanRootIdentity
    }

    func scan(onDiscovery: @Sendable ([DiskCleanInstallerCandidate]) -> Void = { _ in }) -> DiskCleanInstallerHomeScan {
        let path = DiskCleanPhysicalPath.realpath(of: home) ?? home
        var report = DiskCleanInstallerHomeScan(reservedRoots: [path])
        guard path != "/", DiskCleanSafetyPolicy(homeDirectory: path).validatePathShape(path).isCleanable else {
            report.limitations.append(.scanRootUnreadable(path: path, reason: .walkError)); return report
        }
        if (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) == false {
            report.limitations.append(.volumeSkipped(path: path)); return report
        }
        let observedAt = now()
        let deadline = observedAt.addingTimeInterval(limits.timeout)
        let opener = DiskCleanRootOpener()
        let homeIdentity: DiskCleanRootIdentity
        switch opener.open(path: path) {
        case let .directory(fd, identity): homeIdentity = identity; close(fd)
        case let .failed(reason):
            report.limitations.append(.scanRootUnreadable(path: path, reason: reason)); return report
        case .resolved:
            report.limitations.append(.scanRootUnreadable(path: path, reason: .walkError)); return report
        }
        let priorityNames = ["Downloads", "Desktop", "Documents"]
        var priority: [Directory] = []
        for name in priorityNames {
            let child = path + "/" + name
            var status = stat()
            guard lstat(child, &status) == 0 else {
                let code = errno
                if code != ENOENT {
                    report.limitations.append(.scanRootUnreadable(path: child,
                        reason: code == EPERM || code == EACCES ? .permissionDenied : .walkError))
                }
                continue
            }
            guard status.st_mode & S_IFMT == S_IFDIR,
                  status.st_dev == dev_t(truncatingIfNeeded: homeIdentity.devid),
                  status.st_flags & UInt32(SF_DATALESS) == 0,
                  !excluded(path: child, name: name) else { continue }
            priority.append(.init(path: child, depth: 1, downloads: name == "Downloads", identity: .init(stat: status)))
        }
        var other = [Directory(path: path, depth: 0, downloads: false, identity: homeIdentity)]
        var priorityIndex = 0
        var otherIndex = 0
        var visited = Set<String>()
        var remaining = limits.maximumEntries
        var limited = false
        let classifier = DiskCleanInstallerScanner(now: now)
        let policy = DiskCleanSafetyPolicy(homeDirectory: path)

        while priorityIndex < priority.count || otherIndex < other.count {
            guard !isCancelled(), now() < deadline, remaining > 0,
                  report.candidates.count < limits.maximumCandidates else { limited = true; break }
            let directory: Directory
            if priorityIndex < priority.count { directory = priority[priorityIndex]; priorityIndex += 1 }
            else { directory = other[otherIndex]; otherIndex += 1 }
            let source: any DiskCleanDirectoryEntrySource
            switch opener.open(path: directory.path) {
            case let .directory(fd, identity):
                guard identity.devid == homeIdentity.devid, identity.devid == directory.identity.devid,
                      identity.fileID == directory.identity.fileID else {
                    close(fd)
                    append(.scanRootUnreadable(path: directory.path, reason: .walkError), to: &report, limited: &limited)
                    continue
                }
                var openedStatus = stat()
                guard fstat(fd, &openedStatus) == 0 else {
                    close(fd)
                    append(.scanRootUnreadable(path: directory.path, reason: .walkError), to: &report, limited: &limited)
                    continue
                }
                guard openedStatus.st_flags & UInt32(SF_DATALESS) == 0 else { close(fd); continue }
                guard visited.insert("\(identity.devid):\(identity.fileID)").inserted else { close(fd); continue }
                do { source = try sourceFactory.makeSource(fileDescriptor: fd) }
                catch {
                    close(fd)
                    append(.scanRootUnreadable(path: directory.path, reason: reason(error)), to: &report, limited: &limited)
                    continue
                }
            case let .failed(reason):
                append(.scanRootUnreadable(path: directory.path, reason: reason), to: &report, limited: &limited)
                continue
            case .resolved:
                append(.scanRootUnreadable(path: directory.path, reason: .walkError), to: &report, limited: &limited)
                continue
            }
            var batchCandidates: [DiskCleanInstallerCandidate] = []
            do {
                directoryLoop: while let batch = try source.nextBatch() {
                    for entry in batch {
                        guard !isCancelled(), now() < deadline, remaining > 0,
                              report.candidates.count < limits.maximumCandidates else { limited = true; break directoryLoop }
                        remaining -= 1
                        if case let .unresolved(code) = entry {
                            if code != ENOENT { throw DiskCleanPOSIXError(code: code) }
                            continue
                        }
                        guard case let .resolved(value) = entry, let name = DiskCleanInstallerScanner.name(of: value),
                              !name.hasPrefix(".") else { continue }
                        let child = directory.path + "/" + name
                        if directory.depth == 0 && priorityNames.contains(name) { continue }
                        var status = stat()
                        guard fstatat(source.directoryFileDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                            if errno != ENOENT { throw DiskCleanPOSIXError(code: errno) }
                            continue
                        }
                        guard status.st_dev == dev_t(truncatingIfNeeded: homeIdentity.devid),
                              status.st_flags & UInt32(SF_DATALESS) == 0 else { continue }
                        let type = status.st_mode & S_IFMT
                        guard type == S_IFREG || type == S_IFDIR else { continue }
                        if type == S_IFDIR {
                            guard !excluded(path: child, name: name), policy.safetyStatus(for: child).isCleanable else { continue }
                        } else {
                            guard DiskCleanInstallerKind.byExtension[(name as NSString).pathExtension.lowercased()] != nil,
                                  !cloudOrAlias(path: child) else { continue }
                        }
                        if let candidate = classifier.candidate(name: name, directoryPath: directory.path, status: status,
                            observedAt: observedAt, allowsDefaultSelection: directory.downloads) {
                            report.candidates.append(candidate)
                            batchCandidates.append(candidate)
                        } else if type == S_IFDIR {
                            let ext = (name as NSString).pathExtension.lowercased()
                            guard !["pkg", "mpkg"].contains(ext) else { continue }
                            guard directory.depth < limits.maximumDepth else { limited = true; continue }
                            let childDirectory = Directory(path: child, depth: directory.depth + 1,
                                downloads: directory.downloads, identity: .init(stat: status))
                            if directory.downloads || directory.path == path + "/Desktop" || directory.path.hasPrefix(path + "/Desktop/") || directory.path == path + "/Documents" || directory.path.hasPrefix(path + "/Documents/") {
                                priority.append(childDirectory)
                            } else { other.append(childDirectory) }
                        }
                        if batchCandidates.count >= 64 { onDiscovery(batchCandidates); batchCandidates = [] }
                    }
                }
            } catch {
                append(.scanRootUnreadable(path: directory.path, reason: reason(error)), to: &report, limited: &limited)
            }
            source.close()
            if !batchCandidates.isEmpty { onDiscovery(batchCandidates) }
        }
        if limited { report.limitations.append(.installerSearchLimited) }
        return report
    }

    private func append(_ limitation: DiskCleanScanLimitation, to report: inout DiskCleanInstallerHomeScan, limited: inout Bool) {
        if report.limitations.count < 32 { report.limitations.append(limitation) }
        else { limited = true }
    }

    private func reason(_ error: Error) -> DiskCleanScanCompleteness.PartialReason {
        let code = (error as? DiskCleanPOSIXError)?.code
        return code == EPERM || code == EACCES ? .permissionDenied : .walkError
    }

    private func excluded(path: String, name: String) -> Bool {
        let lower = name.lowercased()
        let excludedNames: Set<String> = ["library", "applications", "node_modules", "vendor", "pods", "carthage", "target", "build", "dist", "venv", "__pycache__", "bower_components", "dropbox", "box", "google drive", "googledrive", "icloud drive", "cloudstorage", "volumes"]
        let excludedExtensions: Set<String> = ["app", "framework", "bundle", "plugin", "appex", "xpc", "xcassets", "xcodeproj", "xcworkspace", "photoslibrary", "photolibrary", "musiclibrary", "sparsebundle", "backupbundle", "vmwarevm", "pvm", "utm"]
        guard !excludedNames.contains(lower), !lower.hasPrefix("onedrive"), !lower.hasPrefix("dropbox"), !lower.hasPrefix("google drive"), !lower.hasPrefix("icloud"),
              !excludedExtensions.contains((lower as NSString).pathExtension) else { return true }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey, .volumeIsInternalKey])
        return (values?.isPackage == true && !["pkg", "mpkg"].contains((lower as NSString).pathExtension)) || values?.volumeIsInternal == false || cloudOrAlias(path: path)
    }

    private func cloudOrAlias(path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey, .isAliasFileKey])
        return values?.isUbiquitousItem == true || values?.isAliasFile == true
    }
}
