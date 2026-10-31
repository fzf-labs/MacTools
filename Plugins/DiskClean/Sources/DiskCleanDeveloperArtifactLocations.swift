import Darwin
import Foundation

/// Finds bounded project roots by manifest evidence, without treating Home itself as a purge root.
struct DiskCleanDeveloperArtifactLocations: Sendable {
    struct Limits: Sendable {
        var maximumDepth = 8
        var maximumEntries = 60_000
        var maximumProjects = 100
        var timeout: TimeInterval = 15
    }

    let home: String
    var limits = Limits()
    var sourceFactory: any DiskCleanDirectoryEntrySourceFactory = DiskCleanDiscoveryEntrySourceFactory()
    var now: @Sendable () -> Date = Date.init
    var isCancelled: @Sendable () -> Bool = { Task.isCancelled }

    struct Resolution: Sendable {
        var roots: [String] = []
        var repositories: [String: String] = [:]
        var reservedRoots: [String] = []
        var limitations: [DiskCleanScanLimitation] = []
    }

    private struct Directory {
        let path: String
        let depth: Int
        let identity: DiskCleanRootIdentity
        var repository: String?
    }

    func resolve() -> Resolution {
        let path = DiskCleanPhysicalPath.realpath(of: home) ?? home
        var result = Resolution(reservedRoots: [path])
        guard path != "/", DiskCleanSafetyPolicy(homeDirectory: path).validatePathShape(path).isCleanable else {
            result.limitations.append(.scanRootUnreadable(path: path, reason: .walkError)); return result
        }
        if (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) == false {
            result.limitations.append(.volumeSkipped(path: path)); return result
        }
        let deadline = now().addingTimeInterval(limits.timeout)
        let opener = DiskCleanRootOpener()
        let homeIdentity: DiskCleanRootIdentity
        switch opener.open(path: path) {
        case let .directory(fd, identity): homeIdentity = identity; close(fd)
        case let .failed(reason):
            result.limitations.append(.scanRootUnreadable(path: path, reason: reason)); return result
        case .resolved:
            result.limitations.append(.scanRootUnreadable(path: path, reason: .walkError)); return result
        }
        var queue = [Directory(path: path, depth: 0, identity: homeIdentity)]
        var index = 0
        var remaining = limits.maximumEntries
        var visited = Set<String>()
        var limited = false
        let policy = DiskCleanSafetyPolicy(homeDirectory: path)
        while index < queue.count {
            guard !isCancelled(), now() < deadline, remaining > 0,
                  result.roots.count < limits.maximumProjects else { limited = true; break }
            let directory = queue[index]
            index += 1
            let source: any DiskCleanDirectoryEntrySource
            switch opener.open(path: directory.path) {
            case let .directory(fd, identity):
                var status = stat()
                guard identity.devid == homeIdentity.devid, identity.fileID == directory.identity.fileID,
                      fstat(fd, &status) == 0, status.st_flags & UInt32(SF_DATALESS) == 0 else {
                    close(fd)
                    append(.scanRootUnreadable(path: directory.path, reason: .walkError), to: &result, limited: &limited)
                    continue
                }
                guard visited.insert("\(identity.devid):\(identity.fileID)").inserted else { close(fd); continue }
                do { source = try sourceFactory.makeSource(fileDescriptor: fd) }
                catch {
                    close(fd)
                    append(.scanRootUnreadable(path: directory.path, reason: reason(error)), to: &result, limited: &limited)
                    continue
                }
            case let .failed(reason):
                append(.scanRootUnreadable(path: directory.path, reason: reason), to: &result, limited: &limited)
                continue
            case .resolved:
                append(.scanRootUnreadable(path: directory.path, reason: .walkError), to: &result, limited: &limited)
                continue
            }
            var children: [Directory] = []
            var manifest = false
            var repository = directory.repository
            var complete = true
            var cloudRepository = false
            do {
                directoryLoop: while let batch = try source.nextBatch() {
                    for entry in batch {
                        guard !isCancelled(), now() < deadline, remaining > 0 else {
                            limited = true; complete = false; break directoryLoop
                        }
                        remaining -= 1
                        if case let .unresolved(code) = entry {
                            if code != ENOENT { throw DiskCleanPOSIXError(code: code) }
                            continue
                        }
                        guard case let .resolved(value) = entry, let name = DiskCleanInstallerScanner.name(of: value) else { continue }
                        var status = stat()
                        guard fstatat(source.directoryFileDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                            if errno != ENOENT { throw DiskCleanPOSIXError(code: errno) }
                            continue
                        }
                        if name == ".git" {
                            repository = directory.path
                            cloudRepository = status.st_flags & UInt32(SF_DATALESS) != 0
                            continue
                        }
                        guard status.st_dev == dev_t(truncatingIfNeeded: homeIdentity.devid),
                              status.st_flags & UInt32(SF_DATALESS) == 0 else { continue }
                        if status.st_mode & S_IFMT == S_IFREG {
                            manifest = manifest || Self.isManifest(name)
                            continue
                        }
                        guard status.st_mode & S_IFMT == S_IFDIR, !Self.excluded(name: name),
                              policy.safetyStatus(for: directory.path + "/" + name).isCleanable else { continue }
                        let child = directory.path + "/" + name
                        let metadata = try? URL(fileURLWithPath: child).resourceValues(forKeys: [.isPackageKey, .isUbiquitousItemKey, .isAliasFileKey, .volumeIsInternalKey])
                        guard metadata?.isPackage != true, metadata?.isUbiquitousItem != true,
                              metadata?.isAliasFile != true, metadata?.volumeIsInternal != false else { continue }
                        children.append(.init(path: child, depth: directory.depth + 1, identity: .init(stat: status)))
                    }
                }
            } catch {
                complete = false
                append(.scanRootUnreadable(path: directory.path, reason: reason(error)), to: &result, limited: &limited)
            }
            source.close()
            guard complete, !cloudRepository else { continue }
            let personalContainer = directory.depth == 1 && ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public"].contains((directory.path as NSString).lastPathComponent)
            if manifest, directory.depth > 0, !personalContainer, !DiskCleanPurgeRootPolicy.isTooBroad(directory.path) {
                result.roots.append(directory.path)
                result.repositories[directory.path] = repository
            } else {
                guard directory.depth < limits.maximumDepth else {
                    if !children.isEmpty { limited = true }
                    continue
                }
                queue += children.sorted { $0.path < $1.path }.map {
                    var child = $0
                    child.repository = repository
                    return child
                }
            }
        }
        if limited { result.limitations.append(.developerSearchLimited) }
        result.reservedRoots += result.roots
        return result
    }

    private static func isManifest(_ name: String) -> Bool {
        let markers: Set<String> = ["package.json", "Cargo.toml", "Package.swift", "pyproject.toml", "setup.py", "requirements.txt", "build.gradle", "build.gradle.kts", "pubspec.yaml", "composer.json"]
        return markers.contains(name) || ["csproj", "fsproj", "vbproj"].contains((name as NSString).pathExtension.lowercased())
    }

    private static func excluded(name: String) -> Bool {
        let lower = name.lowercased()
        let names: Set<String> = ["library", "applications", "cloudstorage", "box", "google drive", "googledrive", "pods", "carthage", "bower_components", "volumes"]
        let extensions: Set<String> = ["app", "framework", "bundle", "plugin", "appex", "xpc", "xcassets", "xcodeproj", "xcworkspace", "photoslibrary", "photolibrary", "musiclibrary", "sparsebundle", "backupbundle", "vmwarevm", "pvm", "utm", "pkg", "mpkg"]
        return name.hasPrefix(".") || names.contains(lower) || DiskCleanPurgeKind.byDirectoryName[lower] != nil
            || extensions.contains((lower as NSString).pathExtension) || lower.hasPrefix("dropbox")
            || lower.hasPrefix("onedrive") || lower.hasPrefix("google drive") || lower.hasPrefix("icloud")
    }

    private func append(_ limitation: DiskCleanScanLimitation, to result: inout Resolution, limited: inout Bool) {
        if result.limitations.count < 32 { result.limitations.append(limitation) }
        else { limited = true }
    }

    private func reason(_ error: Error) -> DiskCleanScanCompleteness.PartialReason {
        let code = (error as? DiskCleanPOSIXError)?.code
        return code == EPERM || code == EACCES ? .permissionDenied : .walkError
    }
}
