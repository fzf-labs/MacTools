import Darwin
import AppKit
import Foundation
import MacToolsPluginKit

/// Evidence belongs to the reviewed candidate and survives sizing and plan construction.
enum DiskCleanReviewValidation: Equatable, Sendable {
    case project
    case installer
    case cache(bundleID: String)
    case application(bundleID: String, roots: [String], bundlePath: String, isBundle: Bool, proof: DiskCleanApplicationProof? = nil)
    case leftover(bundleID: String, roots: [String], proof: DiskCleanApplicationProof? = nil)
}

struct DiskCleanTreeReview: Sendable {
    var latestActivity = Date.distantPast
    var rejection: String?
    var inspection: DiskCleanApplicationInspection?
    var estimatedBytes: Int64? = 0
    var fileCount = 0
    var hardLinks = Set<String>()
}

struct DiskCleanApplicationInspection: Equatable, Sendable {
    let identity: DiskCleanRootIdentity
    let observedAt: Date
    var measurement: DiskCleanSizeResult? = nil
}

/// Reads fd-relative batches without following links or crossing filesystems.
/// Inspection is deliberately bounded; an unfinished inspection never authorizes removal.
struct DiskCleanContentReview: Sendable {
    let policy: DiskCleanSafetyPolicy
    var protectsPersonalContents = true
    var project = false
    var maximumEntries = 250_000
    var timeout: TimeInterval = 20
    var applicationSessionScope: DiskCleanApplicationSessionScope? = nil
    var logicalRoots: [String] = []
    var localization: PluginLocalization = .init(bundle: .main)

    func inspect(path: String) -> DiskCleanTreeReview {
        var report = DiskCleanTreeReview()
        var status = stat()
        guard lstat(path, &status) == 0 else {
            report.rejection = "无法复核文件"
            return report
        }
        report.latestActivity = DiskCleanRootIdentity.date(from: status.st_mtimespec)
        let identity = DiskCleanRootIdentity(stat: status)
        guard identity.fileType == .directory || identity.fileType == .regularFile,
              status.st_flags & UInt32(SF_DATALESS) == 0 else {
            report.rejection = "文件类型或下载状态不支持"
            return report
        }
        let fd: Int32
        switch DiskCleanRootOpener().open(path: path) {
        case let .resolved(_, openedIdentity):
            guard openedIdentity == identity else { report.rejection = "文件已变化，请重新扫描"; return report }
            let observedAt = Date()
            report.inspection = .init(identity: identity, observedAt: observedAt,
                measurement: .init(estimatedBytes: max(status.st_size, 0), fileCount: 1,
                    completeness: .complete, rootIdentity: identity, observedAt: observedAt))
            return report
        case let .directory(descriptor, openedIdentity):
            guard openedIdentity == identity else { close(descriptor); report.rejection = "文件已变化，请重新扫描"; return report }
            fd = descriptor
        case .failed:
            report.rejection = "无法读取目录或磁盘不受支持"
            return report
        }
        var remaining = maximumEntries
        let deadline = Date().addingTimeInterval(timeout)
        visit(fd: fd, path: path, device: status.st_dev, depth: 0,
              remaining: &remaining, deadline: deadline, root: path, report: &report)
        if report.rejection == nil {
            guard lstat(path, &status) == 0, DiskCleanRootIdentity(stat: status) == identity else {
                report.rejection = "文件已变化，请重新扫描"
                return report
            }
            let observedAt = Date()
            let measurement = report.estimatedBytes.map { DiskCleanSizeResult(estimatedBytes: $0, fileCount: report.fileCount,
                completeness: .complete, rootIdentity: identity, observedAt: observedAt) }
            report.inspection = .init(identity: identity, observedAt: observedAt, measurement: measurement)
        }
        return report
    }

    private func visit(fd: Int32, path: String, device: dev_t, depth: Int,
                       remaining: inout Int, deadline: Date, root: String, report: inout DiskCleanTreeReview) {
        let source: any DiskCleanDirectoryEntrySource
        do { source = try DiskCleanDiscoveryEntrySourceFactory().makeSource(fileDescriptor: fd) }
        catch { close(fd); report.rejection = "目录检查未完成"; return }
        defer { source.close() }
        do {
            while let batch = try source.nextBatch() {
                for entry in batch {
                    guard !Task.isCancelled, remaining > 0, depth < 128, Date() < deadline else {
                        report.rejection = "目录检查未完成，请缩小范围"
                        return
                    }
                    remaining -= 1
                    guard case let .resolved(value) = entry,
                          let name = String(bytes: value.nameBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
                        report.rejection = "无法确认目录内容"; return
                    }
                    let child = path + "/" + name
                    let aliases = logicalRoots.map { $0 + String(child.dropFirst(root.count)) }
                    if let protected = ([child] + aliases).compactMap({ path in
                        policy.whitelistStore.matchingRule(for: path).map { (path, $0) }
                    }).first {
                        report.rejection = policy.isApplicationUninstall
                            ? localization.format("uninstall.protectedRule", defaultValue: "用户保护的文件：%@（规则：%@）", protected.0, protected.1.rawPattern)
                            : "目录内含白名单项目"
                        return
                    }
                    if protectsPersonalContents && !policy.safetyStatus(for: child, alsoChecking: aliases,
                        applicationSessionScope: applicationSessionScope).isCleanable {
                        report.rejection = policy.isApplicationUninstall
                            ? localization.format("uninstall.protectedContent", defaultValue: "包含受保护的数据：%@", child)
                            : "目录内含受保护或白名单项目"
                        return
                    }
                    if [".ssh", ".gnupg", "Keychains"].contains(name) {
                        report.rejection = policy.isApplicationUninstall
                            ? localization.format("uninstall.protectedKey", defaultValue: "密钥或凭据受保护：%@", child)
                            : "目录内含凭据或密钥"
                        return
                    }
                    if project && (name == ".git" || name.hasSuffix("-keypair.json")) {
                        report.rejection = "目录内含仓库或部署密钥"; return
                    }
                    var status = stat()
                    guard fstatat(fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                        report.rejection = "文件已变化，请重新扫描"; return
                    }
                    // Cloud placeholders must never be hydrated by inspection or deletion.
                    guard status.st_flags & UInt32(SF_DATALESS) == 0 else {
                        report.rejection = "目录包含尚未下载的云端文件"; return
                    }
                    report.latestActivity = max(report.latestActivity, DiskCleanRootIdentity.date(from: status.st_mtimespec))
                    if (status.st_mode & S_IFMT) == S_IFREG || (status.st_mode & S_IFMT) == S_IFLNK {
                        let key = String(status.st_dev) + ":" + String(status.st_ino)
                        if status.st_nlink <= 1 || report.hardLinks.insert(key).inserted {
                            report.fileCount += 1
                            if let bytes = report.estimatedBytes {
                                let total = bytes.addingReportingOverflow(max(status.st_size, 0))
                                report.estimatedBytes = total.overflow ? nil : total.partialValue
                            }
                        }
                    }
                    if (status.st_mode & S_IFMT) == S_IFDIR {
                        guard status.st_dev == device else { report.rejection = "目录跨越挂载点"; return }
                        let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
                        guard next >= 0 else { report.rejection = "无法检查子目录"; return }
                        visit(fd: next, path: child, device: device, depth: depth + 1,
                              remaining: &remaining, deadline: deadline, root: root, report: &report)
                        if report.rejection != nil { return }
                    }
                }
            }
        } catch { report.rejection = "目录检查未完成" }
    }
}

/// Injectable presence probes keep ownership and reinstall checks independent of the live desktop in tests.
struct DiskCleanApplicationPresence: Sendable {
    var inventory: @Sendable ([String]) async -> DiskCleanApplicationInventoryResult
    var registered: @Sendable (String) async -> Bool
    var running: @Sendable (String) async -> Bool
    static let live = DiskCleanApplicationPresence(
        inventory: { await DiskCleanApplicationInventory(roots: $0, supplementsSystemInventory: true).scan() },
        registered: { await DiskCleanApplicationInventory.hasRegisteredCopy(bundleID: $0) },
        running: { await DiskCleanApplicationInventory.isRunning(bundleID: $0) })
}

protocol DiskCleanReviewValidating: Sendable {
    func rejection(path: String, evidence: DiskCleanReviewValidation) async -> String?
}

struct DiskCleanReviewValidator: DiskCleanReviewValidating {
    let policy: DiskCleanSafetyPolicy
    let runner: any DiskCleanSubprocessRunning
    let presence: DiskCleanApplicationPresence
    let services: any DiskCleanApplicationServiceManaging
    let localization: PluginLocalization
    let inspectionTimeout: TimeInterval?
    let inspectionMaximumEntries: Int?

    init(policy: DiskCleanSafetyPolicy = DiskCleanSafetyPolicy(),
         runner: any DiskCleanSubprocessRunning = LocalDiskCleanSubprocessRunner(),
         presence: DiskCleanApplicationPresence = .live,
         services: any DiskCleanApplicationServiceManaging = DiskCleanApplicationServices(),
         localization: PluginLocalization = .init(bundle: .main),
         inspectionTimeout: TimeInterval? = nil, inspectionMaximumEntries: Int? = nil) {
        self.policy = policy
        self.runner = runner
        self.presence = presence
        self.services = services
        self.localization = localization
        self.inspectionTimeout = inspectionTimeout
        self.inspectionMaximumEntries = inspectionMaximumEntries
    }

    func rejection(path: String, evidence: DiskCleanReviewValidation) async -> String? {
        switch evidence {
        case let .cache(bundleID):
            if await presence.running(bundleID) { return "应用仍在运行" }
            let paths = await MainActor.run {
                NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path)
            }
            for bundlePath in paths {
                if !(await processIsIdle(bundleID: bundleID, bundlePath: bundlePath)) { return "应用进程仍在使用或无法确认" }
            }
        case .installer:
            if URL(fileURLWithPath: path).pathExtension.lowercased() == "zip" && !DiskCleanInstallerArchive.isInstaller(path: path) {
                return "安装压缩包已变化或无法检查"
            }
        case .project:
            let url = URL(fileURLWithPath: path)
            guard let kind = DiskCleanPurgeKind.byDirectoryName[url.lastPathComponent],
                  DiskCleanProjectRecognition.matches(kind: kind, parent: url.deletingLastPathComponent().path) else {
                return "项目标记已变化"
            }
            if let reason = await trackedContentRejection(path: path) { return reason }
            if let reason = await projectProcessRejection(path: path) { return reason }
        case let .application(bundleID, roots, bundlePath, isBundle, proof):
            if let reason = proof?.rejection(at: path) { return reason }
            if let service = proof?.service {
                do {
                    if try await !services.isStopped(service) { return "后台服务仍在运行，请重试卸载" }
                    if service.label == nil {
                        let result = try await runner.run(executablePath: "/bin/ps", arguments: ["-axo", "comm="], timeout: .seconds(3))
                        guard result.exitCode == 0,
                              !String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n").contains(where: { $0 == service.program }) else {
                            return "辅助组件仍在运行，请重试卸载"
                        }
                    }
                } catch { return "无法确认后台服务状态，请重试" }
            }
            if isBundle {
                guard Bundle(path: path)?.bundleIdentifier == bundleID,
                      DiskCleanApplicationInventory.bundleRejection(path: path, bundleID: bundleID) == nil else {
                    return "应用身份或权限已变化"
                }
            } else {
                let inventory = await presence.inventory(roots)
                guard inventory.isComplete, !inventory.applications.contains(where: { $0.bundleID == bundleID }),
                      !(await presence.registered(bundleID)) else {
                    return "仍有应用副本或安装状态无法确认"
                }
                if let candidate = proof?.nameCandidate, candidate.hasConflictingOwner(in: inventory.applications, excluding: bundleID) {
                    return "另一个应用可能使用此关联文件"
                }
                if let record = proof?.crashRecord, record.hasConflictingOwner(in: inventory.applications, excluding: bundleID) {
                    return "另一个应用使用相同的退出记录名称"
                }
                if let proof, proof.ownerID != nil {
                    let claims = await diskCleanBackground {
                        DiskCleanApplicationIdentity.otherClaims(excluding: bundleID, applications: inventory.applications)
                    }
                    if let reason = proof.ownershipCheck(for: bundleID, otherOwners: claims.ids, claimsComplete: claims.complete).rejection {
                        return reason
                    }
                }
                // A failed bundle move must never authorize associated data removal.
                guard !FileManager.default.fileExists(atPath: bundlePath) else { return "应用尚未移到废纸篓" }
            }
            if await presence.running(bundleID) { return "应用仍在运行" }
            if !(await processIsIdle(bundleID: bundleID, bundlePath: bundlePath)) { return "应用进程仍在使用或无法确认" }
        case let .leftover(bundleID, roots, proof):
            if let reason = proof?.rejection(at: path) { return reason }
            let inventory = await presence.inventory(roots)
            guard inventory.isComplete, !inventory.applications.contains(where: { $0.bundleID == bundleID }),
                  !(await presence.registered(bundleID)) else {
                return "应用已安装或安装状态无法确认"
            }
            if let ownerID = proof?.ownerID {
                let claims = await diskCleanBackground {
                    DiskCleanApplicationIdentity.otherClaims(excluding: bundleID, applications: inventory.applications)
                }
                guard claims.complete, !DiskCleanApplicationIdentity.hasPotentialOwner(ownerID, in: claims.ids) else { return "关联文件的归属已变化或无法确认" }
            }
            if await presence.running(bundleID) { return "应用仍在运行" }
        }
        let proof: DiskCleanApplicationProof?
        if case let .application(_, _, _, false, applicationProof) = evidence { proof = applicationProof }
        else { proof = nil }
        let sessionScope = proof.flatMap { DiskCleanApplicationSessionScope(path: path, home: policy.homeDirectory, proof: $0) }
        let isApplicationReview: Bool
        if case .application = evidence { isApplicationReview = true } else { isApplicationReview = false }
        let review = DiskCleanContentReview(
            policy: policy.forReview(evidence),
            protectsPersonalContents: !evidence.isApplicationBundle,
            project: evidence == .project,
            maximumEntries: inspectionMaximumEntries ?? (isApplicationReview ? 1_000_000 : 250_000),
            timeout: inspectionTimeout ?? (isApplicationReview ? 90 : 20),
            applicationSessionScope: sessionScope,
            logicalRoots: proof?.logicalPaths ?? [],
            localization: localization
        )
        return await diskCleanBackground { review.inspect(path: path).rejection }
    }

    private func processIsIdle(bundleID: String, bundlePath: String) async -> Bool {
        do {
            let result = try await runner.run(executablePath: "/bin/ps", arguments: ["-axo", "comm="], timeout: .seconds(3))
            guard result.exitCode == 0 else { return false }
            return !String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n")
                .contains { $0.hasPrefix(bundlePath + "/") }
        } catch { return false }
    }

    private func projectProcessRejection(path: String) async -> String? {
        do {
            let result = try await runner.run(executablePath: "/bin/ps", arguments: ["-axo", "pid=,comm="], timeout: .seconds(3))
            guard result.exitCode == 0 else { return "无法确认构建进程状态" }
            let tools: Set<String> = ["node", "npm", "pnpm", "yarn", "bun", "swift", "swift-build", "xcodebuild", "cargo", "rustc", "python", "python3", "java", "gradle", "dotnet", "dart", "flutter", "php", "composer"]
            let pids = String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
                let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                guard fields.count == 2, Int(fields[0]) != nil,
                      tools.contains(URL(fileURLWithPath: String(fields[1])).lastPathComponent) else { return nil }
                return String(fields[0])
            }
            guard !pids.isEmpty else { return nil }
            let cwd = try await runner.run(executablePath: "/usr/sbin/lsof",
                arguments: ["-a", "-p", pids.joined(separator: ","), "-d", "cwd", "-F", "pn"], timeout: .seconds(3))
            guard cwd.exitCode == 0 else { return "无法确认构建进程目录" }
            let output = String(decoding: cwd.standardOutput, as: UTF8.self)
            let observed = Set(output.split(separator: "\n").filter { $0.hasPrefix("p") }.map { String($0.dropFirst()) })
            guard Set(pids).isSubset(of: observed) else { return "部分构建进程无法检查" }
            let project = URL(fileURLWithPath: path).deletingLastPathComponent().path
            if output.split(separator: "\n").filter({ $0.hasPrefix("n") }).contains(where: {
                let directory = String($0.dropFirst())
                return directory == project || directory.hasPrefix(project + "/")
            }) { return "项目仍有运行中的开发或构建进程" }
            return nil
        } catch { return "无法确认构建进程状态" }
    }

    private func trackedContentRejection(path: String) async -> String? {
        var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        while parent.path != "/" {
            if FileManager.default.fileExists(atPath: parent.appendingPathComponent(".git").path) {
                do {
                    let relative = String(path.dropFirst(parent.path.count + 1))
                    let result = try await runner.run(executablePath: "/usr/bin/env", arguments: [
                        "-u", "GIT_DIR", "-u", "GIT_WORK_TREE", "-u", "GIT_INDEX_FILE", "-u", "GIT_COMMON_DIR",
                        "-u", "GIT_LITERAL_PATHSPECS", "-u", "GIT_GLOB_PATHSPECS", "-u", "GIT_NOGLOB_PATHSPECS", "-u", "GIT_ICASE_PATHSPECS",
                        "GIT_OPTIONAL_LOCKS=0", "/usr/bin/git", "-c", "core.fsmonitor=false",
                        "--git-dir=" + parent.path + "/.git", "--work-tree=" + parent.path,
                        "ls-files", "--", ":(top,literal,icase)" + relative
                    ], timeout: .seconds(3))
                    guard result.exitCode == 0 else { return "无法检查 Git 已跟踪文件" }
                    return result.standardOutput.isEmpty ? nil : "目录包含 Git 已跟踪文件"
                } catch { return "无法检查 Git 已跟踪文件" }
            }
            parent.deleteLastPathComponent()
        }
        return nil
    }
}

extension DiskCleanReviewValidation {
    var requiresTrash: Bool {
        switch self {
        case .application, .leftover: return true
        case .project, .installer, .cache: return false
        }
    }

    var isApplicationBundle: Bool {
        if case let .application(_, _, _, isBundle, _) = self { return isBundle }
        return false
    }
}
