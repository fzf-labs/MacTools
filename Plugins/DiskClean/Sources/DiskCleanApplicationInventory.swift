import AppKit
import Darwin
import Foundation

struct DiskCleanInstalledApplication: Identifiable, Equatable, Sendable {
    let path: String
    let bundleID: String
    let name: String
    let executable: String?
    let rejection: String?
    var version: String = ""
    var isHomebrew = false
    var indexedBytes: Int64? = nil
    var id: String { path }
}

struct DiskCleanApplicationInventoryResult: Sendable {
    let applications: [DiskCleanInstalledApplication]
    let isComplete: Bool
    let issues: [String]
}

/// Inventory is read-only. Missing roots are empty; failed/depth-limited reads are incomplete.
struct DiskCleanApplicationInventory: Sendable {
    static var defaultRoots: [String] { ["/Applications", NSHomeDirectory() + "/Applications"] }
    let roots: [String]
    var supplementsSystemInventory = false
    var homebrewRoots = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]

    func scan() async -> DiskCleanApplicationInventoryResult {
        let base = await diskCleanBackground { collect() }
        guard supplementsSystemInventory, !Task.isCancelled else { return base }
        var paths = Set<String>()
        var issues = base.issues
        do {
            let result = try await LocalDiskCleanSubprocessRunner().run(executablePath: "/usr/bin/mdfind",
                arguments: ["-0", "kMDItemContentType == 'com.apple.application-bundle'"], timeout: .seconds(5))
            if result.exitCode == 0 {
                paths.formUnion(String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\0").map(String.init))
            } else { issues.append("系统应用索引不可用") }
        } catch { issues.append("系统应用索引检查未完成") }
        let registered = await MainActor.run {
            base.applications.flatMap { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0.bundleID).map(\.path) }
        }
        paths.formUnion(registered)
        let discoveredPaths = paths
        let discovered = await diskCleanBackground {
            let brewPaths = Self.homebrewApplicationPaths(roots: homebrewRoots)
            return discoveredPaths.sorted().prefix(4000).compactMap { path -> DiskCleanInstalledApplication? in
                guard path.hasPrefix("/"), path.lowercased().hasSuffix(".app"),
                      !path.lowercased().contains(".app/"), !path.hasPrefix("/System/"),
                      !Self.isTrashPath(path), !path.contains("/Library/Caches/"),
                      !base.applications.contains(where: { $0.path == path }),
                      DiskCleanPhysicalPath.realpath(of: path) == path,
                      let bundle = Bundle(path: path), let id = bundle.bundleIdentifier, Self.validBundleID(id) else { return nil }
                let app = DiskCleanInstalledApplication(path: path, bundleID: id, name: bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                    executable: bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
                    rejection: Self.bundleRejection(path: path, bundleID: id))
                return Self.enriched(app, homebrewPaths: brewPaths)
            }
        }
        if paths.count > 4000 { issues.append("系统应用索引结果过多，清单可能不完整") }
        return .init(applications: (base.applications + discovered).sorted { $0.path < $1.path },
            isComplete: issues.isEmpty, issues: issues)
    }

    private func collect() -> DiskCleanApplicationInventoryResult {
        var apps: [DiskCleanInstalledApplication] = []
        var issues: [String] = []
        var visited = Set<String>()
        let deadline = Date().addingTimeInterval(20)
        for root in roots {
            var status = stat()
            if lstat(root, &status) != 0 {
                if errno != ENOENT { issues.append("无法读取应用目录：" + root) }
                continue
            }
            walk(root, depth: 0, visited: &visited, apps: &apps, issues: &issues, deadline: deadline)
        }
        let brewPaths = Self.homebrewApplicationPaths(roots: homebrewRoots)
        apps = apps.map { Self.enriched($0, homebrewPaths: brewPaths) }
        return .init(applications: apps.sorted { $0.path < $1.path }, isComplete: issues.isEmpty, issues: issues)
    }

    private static func enriched(_ application: DiskCleanInstalledApplication, homebrewPaths: Set<String>) -> DiskCleanInstalledApplication {
        var app = application
        let data = DiskCleanProjectRecognition.readSmallFile(app.path + "/Contents/Info.plist")
        let info = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        app.version = [info?["CFBundleShortVersionString"], info?["CFBundleVersion"]].compactMap { value -> String? in
            guard let text = value as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first ?? ""
        app.indexedBytes = (NSMetadataItem(url: URL(fileURLWithPath: app.path))?.value(forAttribute: "kMDItemPhysicalSize") as? NSNumber)?.int64Value
        if app.indexedBytes.map({ $0 <= 0 }) == true { app.indexedBytes = nil }
        app.isHomebrew = homebrewPaths.contains(app.path)
        return app
    }

    private func walk(_ path: String, depth: Int, visited: inout Set<String>,
                      apps: inout [DiskCleanInstalledApplication], issues: inout [String], deadline: Date) {
        guard Date() < deadline else { issues.append("应用清单检查超时"); return }
        guard !Task.isCancelled else { issues.append("扫描已取消"); return }
        guard visited.insert(path).inserted else { return }
        do {
            for child in try DiskCleanDirectoryListing.read(path) where child.isDirectory {
                if child.path.lowercased().hasSuffix(".app") {
                    guard let bundle = Bundle(path: child.path), let id = bundle.bundleIdentifier,
                          Self.validBundleID(id) else { issues.append("无法读取应用：" + child.path); continue }
                    apps.append(.init(path: child.path, bundleID: id,
                                      name: (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                                        ?? (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                                        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                                        ?? URL(fileURLWithPath: child.path).deletingPathExtension().lastPathComponent,
                                      executable: bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
                                      rejection: Self.bundleRejection(path: child.path, bundleID: id)))
                } else if depth < 5 {
                    walk(child.path, depth: depth + 1, visited: &visited, apps: &apps, issues: &issues, deadline: deadline)
                } else { issues.append("应用目录层级过深：" + child.path) }
            }
        } catch { issues.append("无法读取应用目录：" + path) }
    }

    static func homebrewApplicationPaths(roots: [String] = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]) -> Set<String> {
        var paths = Set<String>()
        for root in roots {
            guard let casks = try? FileManager.default.contentsOfDirectory(atPath: root), casks.count < 4000 else { continue }
            for cask in casks {
                guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root + "/" + cask), versions.count < 100 else { continue }
                for version in versions where !version.hasPrefix(".") {
                    let directory = root + "/" + cask + "/" + version
                    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory), entries.count < 100 else { continue }
                    for entry in entries where entry.lowercased().hasSuffix(".app") {
                        if let physical = DiskCleanPhysicalPath.realpath(of: directory + "/" + entry) { paths.insert(physical) }
                    }
                }
            }
        }
        return paths
    }

    static func isTrashPath(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    static func validBundleID(_ value: String) -> Bool {
        value.count <= 255 && value.contains(".") && !value.hasPrefix(".") && !value.hasSuffix(".")
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0) }
            && !value.contains("..")
    }

    static func bundleRejection(path: String, bundleID: String) -> String? {
        if bundleID.lowercased().hasPrefix("com.apple.") || path.hasPrefix("/System/") { return "系统应用受保护" }
        let host = Bundle.main.bundleURL.path
        if path == host || host.hasPrefix(path + "/") || bundleID == Bundle.main.bundleIdentifier { return "不能卸载 MacTools 自身" }
        return nil
    }

    @MainActor
    static func hasRegisteredCopy(bundleID: String) -> Bool {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).contains { url in
            guard !isTrashPath(url.path) else { return false }
            var status = stat()
            if lstat(url.path, &status) != 0 { return errno != ENOENT }
            // An inaccessible registered location cannot be treated as absence.
            return Bundle(url: url)?.bundleIdentifier == bundleID || !FileManager.default.isReadableFile(atPath: url.path)
        }
    }

    @MainActor
    static func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier?.lowercased() == bundleID.lowercased() }
    }
}

struct DiskCleanListedEntry: Sendable {
    let path: String
    let isDirectory: Bool
}

/// All broad discovery uses the same bounded-batch, no-follow metadata source as Disk Clean.
enum DiskCleanDirectoryListing {
    static func read(_ path: String) throws -> [DiskCleanListedEntry] {
        let opened = DiskCleanRootOpener().open(path: path)
        let fd: Int32
        switch opened {
        case let .directory(descriptor, _): fd = descriptor
        case .resolved: throw DiskCleanPOSIXError(code: ENOTDIR)
        case let .failed(reason):
            throw DiskCleanPOSIXError(code: reason == .permissionDenied ? EACCES : (reason == .unsupportedVolume ? ENOTSUP : EIO))
        }
        let source: any DiskCleanDirectoryEntrySource
        do { source = try DiskCleanDiscoveryEntrySourceFactory().makeSource(fileDescriptor: fd) }
        catch { close(fd); throw error }
        defer { source.close() }
        var result: [DiskCleanListedEntry] = []
        while let batch = try source.nextBatch() {
            try Task.checkCancellation()
            for entry in batch {
                guard case let .resolved(value) = entry,
                      let name = String(bytes: value.nameBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
                    throw DiskCleanPOSIXError(code: EIO)
                }
                guard value.fileType == .directory || value.fileType == .regularFile else { continue }
                guard result.count < 20_000 else { throw DiskCleanPOSIXError(code: EOVERFLOW) }
                result.append(.init(path: path + "/" + name, isDirectory: value.fileType == .directory))
            }
        }
        return result
    }
}

/// Generic cache rules still retain an exact reverse-DNS owner when one is available.
enum DiskCleanCacheOwner {
    static func bundleID(path: String) -> String? {
        for prefix in ["/Library/Caches/", "/Library/Logs/"] {
            guard let range = path.range(of: prefix) else { continue }
            let component = String(path[range.upperBound...].split(separator: "/").first ?? "")
            if DiskCleanApplicationInventory.validBundleID(component) { return component }
        }
        return nil
    }
}
