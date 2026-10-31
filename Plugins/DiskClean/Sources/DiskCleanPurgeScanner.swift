import Darwin
import Foundation

// MARK: - Target kinds

/// Developer-artifact kind (design §10.1).
///
/// Each kind binds a set of **project markers**: only a same-level marker file counts as a hit.
/// That is the only false-positive defense—`~/Documents/build` may well be a photo folder, and
/// so may `~/Pictures/dist`; a wrong delete costs far more than a miss.
/// `__pycache__` is the only unconditional kind: CPython owns that name exclusively, so there is
/// no ambiguity.
enum DiskCleanPurgeKind: String, CaseIterable, Equatable, Sendable {
    case nodeModules
    case rustTarget
    case buildOutput
    case distOutput
    case pythonCache
    case swiftBuild, nextOutput, nuxtOutput, nuxtBuild
    case pythonEnvironment, pythonDotEnvironment, pytestCache, mypyCache, ruffCache
    case gradleCache, dartCache, dotnetBin, dotnetObj, composerVendor

    /// Directory name. Classification looks only at this name, not the rest of the path.
    var directoryName: String {
        switch self {
        case .nodeModules:
            return "node_modules"
        case .rustTarget:
            return "target"
        case .buildOutput:
            return "build"
        case .distOutput:
            return "dist"
        case .swiftBuild: return ".build"
        case .nextOutput: return ".next"
        case .nuxtOutput: return ".nuxt"
        case .nuxtBuild: return ".output"
        case .pythonEnvironment: return "venv"
        case .pythonDotEnvironment: return ".venv"
        case .pytestCache: return ".pytest_cache"
        case .mypyCache: return ".mypy_cache"
        case .ruffCache: return ".ruff_cache"
        case .gradleCache: return ".gradle"
        case .dartCache: return ".dart_tool"
        case .dotnetBin: return "bin"
        case .dotnetObj: return "obj"
        case .composerVendor: return "vendor"
        case .pythonCache: return "__pycache__"
        }
    }

    /// Sibling project-marker candidates: any one match is enough. Empty array means unconditional.
    var projectMarkers: [String] {
        switch self {
        case .nodeModules:
            return ["package.json"]
        case .rustTarget:
            return ["Cargo.toml"]
        case .buildOutput, .distOutput:
            return ["package.json", "setup.py", "pyproject.toml", "build.gradle", "build.gradle.kts", "pubspec.yaml"]
        case .swiftBuild: return ["Package.swift"]
        case .nextOutput, .nuxtOutput, .nuxtBuild: return ["package.json"]
        case .pythonEnvironment, .pythonDotEnvironment, .pytestCache, .mypyCache, .ruffCache: return ["pyproject.toml", "setup.py"]
        case .gradleCache: return ["build.gradle", "build.gradle.kts"]
        case .dartCache: return ["pubspec.yaml"]
        case .dotnetBin, .dotnetObj: return []
        case .composerVendor: return ["composer.json"]
        case .pythonCache: return []
        }
    }

    var displayName: String {
        switch self {
        case .nodeModules:
            return "Node 依赖"
        case .rustTarget:
            return "Rust 编译产物"
        case .buildOutput:
            return "构建输出"
        case .distOutput:
            return "打包输出"
        case .pythonCache: return "Python 字节码缓存"
        case .swiftBuild: return "SwiftPM 构建产物"
        case .nextOutput, .nuxtOutput, .nuxtBuild: return "前端框架产物"
        case .pythonEnvironment, .pythonDotEnvironment: return "Python 虚拟环境"
        case .pytestCache, .mypyCache, .ruffCache: return "Python 工具缓存"
        case .gradleCache: return "Gradle 项目缓存"
        case .dartCache: return "Flutter 工具缓存"
        case .dotnetBin, .dotnetObj: return ".NET 构建产物"
        case .composerVendor: return "Composer 依赖"
        }
    }

    /// Stable synthetic target ID (`DiskCleanRuleCatalogV2` builds targets from this).
    /// Written as-is into audit logs; changing it changes historical record semantics.
    var targetID: String {
        "purge." + directoryName
    }

    /// Directory name → kind. Names are unique, so use a dictionary rather than sequential compares.
    static let byDirectoryName: [String: DiskCleanPurgeKind] = Dictionary(
        uniqueKeysWithValues: DiskCleanPurgeKind.allCases.map { ($0.directoryName, $0) }
    )
}

// MARK: - Git state

/// Git state of the repository containing the candidate (design §10.1 git warning).
///
/// **Fail-safe direction is fixed**: if inspection fails, treat as dirty. A false "dirty" only
/// skips default selection (user can still check); a false "clean" may let users unknowingly
/// delete workspace state that uncommitted build artifacts depend on.
enum DiskCleanPurgeGitState: Equatable, Sendable {
    /// No `.git` found within the root boundary. No badge; treat as a normal candidate.
    case notInRepository
    case clean(repositoryPath: String)
    case dirty(repositoryPath: String, reason: DirtyReason)

    enum DirtyReason: Equatable, Sendable {
        /// `git status --porcelain -unormal` produced output.
        case uncommittedChanges
        /// `git log --branches --not --remotes` produced output.
        case unpushedCommits
        /// git missing, timed out (2s), or non-zero exit—treat as dirty.
        case inspectionFailed(String)
    }

    var isDirty: Bool {
        if case .dirty = self { return true }
        return false
    }

    var repositoryPath: String? {
        switch self {
        case .notInRepository:
            return nil
        case let .clean(repositoryPath):
            return repositoryPath
        case let .dirty(repositoryPath, _):
            return repositoryPath
        }
    }
}

// MARK: - Discovery results

/// One hit from the traversal phase. Git check and sizing are not done yet—both are filled in later.
struct DiskCleanPurgeDiscoveredItem: Equatable, Sendable {
    /// **Physical path**: root is `realpath`-normalized and each level is opened no-follow, so the
    /// joined result has no symlink ancestors and can go straight to sizing and removal primitives
    /// (design §13-6).
    let path: String
    let kind: DiskCleanPurgeKind
    /// Project-marker filename that matched. `__pycache__` is unconditional, so nil.
    let projectMarker: String?
    /// Directory containing the marker—the project root.
    let projectPath: String
    /// Nearest `.git` ancestor (including the scan root itself; never past the root boundary).
    /// nil = not in a repository.
    let repositoryPath: String?
}

/// Traversal status of a single scan root.
enum DiskCleanPurgeRootStatus: Equatable, Sendable {
    /// Never opened—directory deleted, TCC denied, or non-local volume. UI must distinguish this
    /// from "scanned but no candidates".
    case unreadable(reason: DiskCleanScanCompleteness.PartialReason)
    /// Traversed. `completeness` records subtrees skipped along the way (permission, mount point;
    /// depth truncation is not counted).
    case traversed(completeness: DiskCleanScanCompleteness)
}

struct DiskCleanPurgeDiscoveryReport: Equatable, Sendable {
    let root: String
    let status: DiskCleanPurgeRootStatus
    let items: [DiskCleanPurgeDiscoveredItem]
}

/// Full candidate description with git state. Stage two mints a unified-pipeline `DiskCleanCandidate` from this.
struct DiskCleanPurgeCandidate: Identifiable, Equatable, Sendable {
    let item: DiskCleanPurgeDiscoveredItem
    let gitState: DiskCleanPurgeGitState
    var protectionReason: String? = nil
    var recentlyActive = false

    var id: String { item.path }
    var path: String { item.path }
    var kind: DiskCleanPurgeKind { item.kind }
    var projectMarker: String? { item.projectMarker }
    var projectPath: String { item.projectPath }

    /// Default-selection policy: not selected when the repo is dirty (including inspection failure); otherwise selected.
    var isSelectedByDefault: Bool { !gitState.isDirty && !recentlyActive && protectionReason == nil }
}

struct DiskCleanPurgeRootReport: Equatable, Sendable {
    let root: String
    let status: DiskCleanPurgeRootStatus
    let candidates: [DiskCleanPurgeCandidate]
}

struct DiskCleanPurgeScanResult: Equatable, Sendable {
    let reports: [DiskCleanPurgeRootReport]

    var candidates: [DiskCleanPurgeCandidate] {
        reports.flatMap(\.candidates)
    }
}

// MARK: - Traversal

/// Developer-artifact discovery walk (design §10.1). **Blocking**; called by `DiskCleanPurgeScanner`
/// on a background queue.
///
/// Uses fd-relative bulk metadata with a `readdir` fallback rather than `FileManager.enumerator`:
/// the latter has no no-follow or device constraints and will follow symlinks out of the scan root
/// and silently cross mount points. This is discovery only and deletes nothing, but produced paths
/// go straight to removal primitives, so they must be trustworthy physical paths.
///
/// Depth cap is 6 levels; prune on hit: `node_modules` contains thousands of nested `node_modules`,
/// and reporting any from the second level on is pointless—deleting the outer one already deletes them.
struct DiskCleanPurgeDiscovery: Sendable {
    static let defaultMaximumDepth = 6

    /// Maximum depth at which candidates can match (root is 0). Directories at the cap still
    /// participate in matching but are not enumerated further.
    let maximumDepth: Int
    private let opener: DiskCleanRootOpener
    private let sourceFactory: any DiskCleanDirectoryEntrySourceFactory

    init(
        maximumDepth: Int = defaultMaximumDepth,
        opener: DiskCleanRootOpener = DiskCleanRootOpener(),
        sourceFactory: any DiskCleanDirectoryEntrySourceFactory = DiskCleanDiscoveryEntrySourceFactory()
    ) {
        self.maximumDepth = max(maximumDepth, 1)
        self.opener = opener
        self.sourceFactory = sourceFactory
    }

    func discover(root: String, isCancelled: () -> Bool = { false }, repositoryPath: String? = nil,
                  deadline: Date = .distantFuture, maximumEntries: Int = .max,
                  maximumCandidates: Int = .max) -> DiskCleanPurgeDiscoveryReport {
        switch opener.open(path: root) {
        case let .failed(reason):
            return DiskCleanPurgeDiscoveryReport(root: root, status: .unreadable(reason: reason), items: [])

        case .resolved:
            // Root is not a directory (file / symlink / socket). Nothing to traverse; report unreadable honestly.
            return DiskCleanPurgeDiscoveryReport(root: root, status: .unreadable(reason: .walkError), items: [])

        case let .directory(fileDescriptor, identity):
            var state = TraversalState(rootDevice: identity.devid, deadline: deadline,
                remainingEntries: maximumEntries, maximumCandidates: maximumCandidates)
            let rootRepository = Self.containsGitEntry(directoryFileDescriptor: fileDescriptor) ? root : repositoryPath
            visit(
                fileDescriptor: fileDescriptor,
                path: root,
                depth: 0,
                repositoryPath: rootRepository,
                isCancelled: isCancelled,
                state: &state
            )
            // readdir order is filesystem-defined; sorting stabilizes both the list and tests.
            return DiskCleanPurgeDiscoveryReport(
                root: root,
                status: .traversed(completeness: state.accumulator.completeness),
                items: state.items.sorted { $0.path < $1.path }
            )
        }
    }

    // MARK: Internals

    private struct TraversalState {
        let rootDevice: UInt64
        let deadline: Date
        var remainingEntries: Int
        let maximumCandidates: Int
        var items: [DiskCleanPurgeDiscoveredItem] = []
        var accumulator = DiskCleanCompletenessAccumulator()
    }

    /// Recursion rather than an explicit stack: with depth cap 6, stack and fd use stay constant-
    /// scale and the readability is worth it (executor delete prewalk caps at 128 and must use an
    /// explicit stack there).
    ///
    /// Takes ownership of `fileDescriptor`.
    private func visit(
        fileDescriptor: Int32,
        path: String,
        depth: Int,
        repositoryPath: String?,
        isCancelled: () -> Bool,
        state: inout TraversalState
    ) {
        let source: any DiskCleanDirectoryEntrySource
        do {
            source = try sourceFactory.makeSource(fileDescriptor: fileDescriptor)
        } catch {
            // Protocol contract: on makeSource throw, fd ownership remains with the caller.
            close(fileDescriptor)
            state.accumulator.add(errno: (error as? DiskCleanPOSIXError)?.code ?? EIO)
            return
        }
        defer { source.close() }

        while true {
            guard !isCancelled(), Date() < state.deadline, state.remainingEntries > 0,
                  state.items.count < state.maximumCandidates else {
                // Same cancel exit as sizing: mark result incomplete so the caller knows this is not "finished empty".
                state.accumulator.add(.timedOut)
                return
            }

            let batch: [DiskCleanWalkEntry]?
            do {
                batch = try source.nextBatch()
            } catch {
                state.accumulator.add(errno: (error as? DiskCleanPOSIXError)?.code ?? EIO)
                return
            }
            guard let batch else { return }

            for entry in batch {
                guard !isCancelled(), Date() < state.deadline, state.remainingEntries > 0,
                      state.items.count < state.maximumCandidates else { state.accumulator.add(.timedOut); return }
                state.remainingEntries -= 1
                guard case let .resolved(resolved) = entry else {
                    state.accumulator.add(.walkError)
                    continue
                }
                // Never follow or report symlinks: following leaves the scan root; reporting would make users think the target is deleted.
                guard resolved.fileType == .directory else { continue }
                guard let name = Self.name(of: resolved) else {
                    // Filename is not valid UTF-8 and cannot safely become a candidate path. Skip one tree; fail-safe.
                    state.accumulator.add(.walkError)
                    continue
                }

                let childPath = path + "/" + name
                let childDepth = depth + 1
                guard resolved.devid == state.rootDevice else {
                    state.accumulator.add(.crossedMountPoint)
                    continue
                }
                var status = stat()
                guard fstatat(source.directoryFileDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno != ENOENT { state.accumulator.add(errno: errno) }
                    continue
                }
                guard status.st_mode & S_IFMT == S_IFDIR, status.st_flags & UInt32(SF_DATALESS) == 0 else { continue }
                guard UInt64(UInt32(bitPattern: status.st_dev)) == state.rootDevice else {
                    state.accumulator.add(.crossedMountPoint)
                    continue
                }
                let values = try? URL(fileURLWithPath: childPath).resourceValues(forKeys: [.isPackageKey, .isUbiquitousItemKey])
                let lower = name.lowercased()
                guard values?.isPackage != true, values?.isUbiquitousItem != true,
                      !["library", "applications", "cloudstorage", "box", "google drive"].contains(lower),
                      !lower.hasPrefix("dropbox"), !lower.hasPrefix("onedrive"), !lower.hasPrefix("icloud") else { continue }

                if let kind = DiskCleanPurgeKind.byDirectoryName[name],
                   let match = Self.projectMarker(for: kind, directoryFileDescriptor: source.directoryFileDescriptor),
                   DiskCleanProjectRecognition.matches(kind: kind, parent: path) {
                    state.items.append(
                        DiskCleanPurgeDiscoveredItem(
                            path: childPath,
                            kind: kind,
                            projectMarker: match.markerName,
                            projectPath: path,
                            repositoryPath: repositoryPath
                        )
                    )
                    continue  // prune on hit
                }

                guard childDepth < maximumDepth, !name.hasPrefix("."),
                      DiskCleanPurgeKind.byDirectoryName[name] == nil else { continue }

                descend(
                    name: resolved.nameBytes,
                    parentFileDescriptor: source.directoryFileDescriptor,
                    childPath: childPath,
                    depth: childDepth,
                    inheritedRepositoryPath: repositoryPath,
                    isCancelled: isCancelled,
                    state: &state
                )
            }
        }
    }

    private func descend(
        name: [CChar],
        parentFileDescriptor: Int32,
        childPath: String,
        depth: Int,
        inheritedRepositoryPath: String?,
        isCancelled: () -> Bool,
        state: inout TraversalState
    ) {
        // Single-component `openat` + `O_NOFOLLOW`: if the entry becomes a symlink between readdir and open, fail with ELOOP.
        let childDescriptor = name.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return openat(parentFileDescriptor, base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard childDescriptor >= 0 else {
            state.accumulator.add(errno: errno)
            return
        }

        var status = stat()
        guard fstat(childDescriptor, &status) == 0 else {
            let code = errno
            close(childDescriptor)
            state.accumulator.add(errno: code)
            return
        }
        guard UInt64(UInt32(bitPattern: status.st_dev)) == state.rootDevice else {
            close(childDescriptor)
            state.accumulator.add(.crossedMountPoint)
            return
        }
        guard status.st_flags & UInt32(SF_DATALESS) == 0 else { close(childDescriptor); return }

        // Nearest `.git` overrides the inherited value: nested repos (submodules, independent monorepo repos) use the nearest.
        let repositoryPath = Self.containsGitEntry(directoryFileDescriptor: childDescriptor)
            ? childPath
            : inheritedRepositoryPath

        visit(
            fileDescriptor: childDescriptor,
            path: childPath,
            depth: depth,
            repositoryPath: repositoryPath,
            isCancelled: isCancelled,
            state: &state
        )
    }

    /// Project-marker match result. `unconditional` must be distinct from "matched a marker":
    /// the former has no marker basis to show in the candidate description, not "marker is empty string".
    private enum MarkerMatch {
        case unconditional
        case matched(String)

        var markerName: String? {
            if case let .matched(name) = self { return name }
            return nil
        }
    }

    /// Returns nil = no match, not a candidate.
    private static func projectMarker(
        for kind: DiskCleanPurgeKind,
        directoryFileDescriptor: Int32
    ) -> MarkerMatch? {
        guard !kind.projectMarkers.isEmpty else { return .unconditional }
        for marker in kind.projectMarkers
        where existsAsFile(name: marker, directoryFileDescriptor: directoryFileDescriptor) {
            return .matched(marker)
        }
        return nil
    }

    /// Marker must be a file or symlink, not a directory: in monorepos `package.json` may be a
    /// symlink, but a **directory** named `package.json` is only a coincidence, not a project root.
    private static func existsAsFile(name: String, directoryFileDescriptor: Int32) -> Bool {
        var status = stat()
        guard fstatat(directoryFileDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        return DiskCleanRootIdentity.FileType(mode: status.st_mode) != .directory
    }

    /// `.git` may be a directory (normal repo) or a file (worktree / submodule gitdir pointer); both count.
    private static func containsGitEntry(directoryFileDescriptor: Int32) -> Bool {
        var status = stat()
        return fstatat(directoryFileDescriptor, ".git", &status, AT_SYMLINK_NOFOLLOW) == 0
    }

    private static func name(of entry: DiskCleanResolvedEntry) -> String? {
        let bytes = entry.nameBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        // Prefer String(bytes:encoding:) over String(decoding:): the latter replaces invalid bytes
        // with U+FFFD, producing a path to a non-existent file that is useless to removal primitives.
        return String(bytes: bytes, encoding: .utf8)
    }
}

// MARK: - Git inspection

/// Repository dirty-state check. Both commands use the `DiskCleanSubprocessRunning` seam with a 2s timeout (design §10.1).
struct DiskCleanGitStatusInspector: Sendable {
    static let executablePath = "/usr/bin/env"
    static let timeout = Duration.seconds(2)

    private let runner: any DiskCleanSubprocessRunning

    init(runner: any DiskCleanSubprocessRunning = LocalDiskCleanSubprocessRunner()) {
        self.runner = runner
    }

    func inspect(repositoryPath: String) async -> DiskCleanPurgeGitState {
        do {
            let status = try await run(
                arguments: ["-C", repositoryPath, "status", "--porcelain", "-unormal"]
            )
            guard status.exitCode == 0 else {
                return .dirty(repositoryPath: repositoryPath, reason: .inspectionFailed("status 退出码 \(status.exitCode)"))
            }
            if !Self.isBlank(status.standardOutput) {
                return .dirty(repositoryPath: repositoryPath, reason: .uncommittedChanges)
            }

            // Unpushed commits: commits on local branches not on any remote. One is enough, hence -n 1.
            let unpushed = try await run(
                arguments: ["-C", repositoryPath, "log", "--branches", "--not", "--remotes", "-n", "1"]
            )
            guard unpushed.exitCode == 0 else {
                return .dirty(repositoryPath: repositoryPath, reason: .inspectionFailed("log 退出码 \(unpushed.exitCode)"))
            }
            if !Self.isBlank(unpushed.standardOutput) {
                return .dirty(repositoryPath: repositoryPath, reason: .unpushedCommits)
            }
            return .clean(repositoryPath: repositoryPath)
        } catch {
            return .dirty(repositoryPath: repositoryPath, reason: .inspectionFailed(Self.describe(error)))
        }
    }

    private func run(arguments: [String]) async throws -> DiskCleanSubprocessResult {
        try await runner.run(
            executablePath: Self.executablePath,
            arguments: ["-u", "GIT_DIR", "-u", "GIT_WORK_TREE", "-u", "GIT_INDEX_FILE", "-u", "GIT_COMMON_DIR",
                "-u", "GIT_CONFIG_PARAMETERS", "-u", "GIT_CONFIG_COUNT", "GIT_OPTIONAL_LOCKS=0", "/usr/bin/git",
                "--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "log.showSignature=false"] + arguments,
            timeout: Self.timeout
        )
    }

    /// Only blank output counts as clean: git emits empty string with no changes; shell-wrapped paths may add a newline.
    private static func isBlank(_ output: Data) -> Bool {
        String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DiskCleanSubprocessError.timedOut:
            return "git 检查超时"
        case DiskCleanSubprocessError.executableUnavailable:
            return "未找到 git"
        case let DiskCleanSubprocessError.launchFailed(_, message):
            return "git 启动失败：\(message)"
        default:
            return "git 检查失败"
        }
    }
}

// MARK: - Scanner

/// Developer-artifact purge scanner (design §10.1).
///
/// Orchestrates two jobs: blocking traversal on a background thread, and one git inspection per
/// repository (a single repo often has dozens of `node_modules`; spawning per item would multiply
/// the 2s timeout by dozens).
struct DiskCleanPurgeScanner: Sendable {
    private let discovery: DiskCleanPurgeDiscovery
    private let inspector: DiskCleanGitStatusInspector

    init(
        discovery: DiskCleanPurgeDiscovery = DiskCleanPurgeDiscovery(),
        inspector: DiskCleanGitStatusInspector = DiskCleanGitStatusInspector()
    ) {
        self.discovery = discovery
        self.inspector = inspector
    }

    struct Limits: Sendable {
        let deadline: Date
        var maximumEntriesPerProject = 20_000
        var maximumContentEntries = 250_000
        var maximumCandidates = 1_000
    }

    func scan(roots: [String], repositories: [String: String] = [:], limits: Limits? = nil,
              onReport: @Sendable (DiskCleanPurgeRootReport) -> Void = { _ in }) async -> DiskCleanPurgeScanResult {
        var reports: [DiskCleanPurgeRootReport] = []
        var inspectedRepositories: [String: DiskCleanPurgeGitState] = [:]
        var remaining = limits?.maximumCandidates ?? Int.max

        for root in roots {
            if Task.isCancelled || Date() >= (limits?.deadline ?? .distantFuture) || remaining <= 0 {
                let report = DiskCleanPurgeRootReport(root: root, status: .traversed(completeness: .partial(reasons: [.timedOut])), candidates: [])
                reports.append(report); onReport(report)
                continue
            }
            let discovered = await discoverInBackground(root: root, repository: repositories[root], limits: limits, maximumCandidates: remaining)
            var candidates: [DiskCleanPurgeCandidate] = []
            candidates.reserveCapacity(discovered.items.count)

            var status = discovered.status
            for item in discovered.items {
                guard !Task.isCancelled, Date() < (limits?.deadline ?? .distantFuture), remaining > 0 else {
                    status = .traversed(completeness: .partial(reasons: [.timedOut])); break
                }
                let repository = item.repositoryPath ?? ""
                let state: DiskCleanPurgeGitState
                if repository.isEmpty {
                    state = .notInRepository
                } else if let cached = inspectedRepositories[repository] {
                    state = cached
                } else {
                    state = await inspector.inspect(repositoryPath: repository)
                    inspectedRepositories[repository] = state
                }
                var candidate = DiskCleanPurgeCandidate(item: item, gitState: state)
                let timeout = limits.map { max(0, min(20, $0.deadline.timeIntervalSinceNow)) }
                candidate.protectionReason = await DiskCleanReviewValidator(inspectionTimeout: timeout,
                    inspectionMaximumEntries: limits?.maximumContentEntries).rejection(path: item.path, evidence: .project)
                guard Date() < (limits?.deadline ?? .distantFuture) else {
                    status = .traversed(completeness: .partial(reasons: [.timedOut])); break
                }
                let reviewTimeout = limits.map { max(0, min(20, $0.deadline.timeIntervalSinceNow)) } ?? 20
                let maximumEntries = limits?.maximumContentEntries ?? 250_000
                let review = await diskCleanBackground {
                    DiskCleanContentReview(policy: DiskCleanSafetyPolicy(), project: true,
                        maximumEntries: maximumEntries, timeout: reviewTimeout).inspect(path: item.path)
                }
                candidate.protectionReason = candidate.protectionReason ?? review.rejection
                candidate.recentlyActive = Date().timeIntervalSince(review.latestActivity) < 7 * 86_400
                candidates.append(candidate)
                remaining -= 1
            }

            let report = DiskCleanPurgeRootReport(root: root, status: status, candidates: candidates)
            reports.append(report)
            onReport(report)
        }

        return DiskCleanPurgeScanResult(reports: reports)
    }

    /// Traversal blocks in `readdir`/`openat` and must not occupy Swift concurrency's cooperative
    /// thread pool. Depth cap 6 bounds the cost, so WorkerPool abandon budgets are unnecessary—
    /// that machinery is for sizing that can hang forever.
    ///
    /// Blocking traversal does not observe `Task.isCancelled`; cancel sets `DiskCleanCancellationFlag`
    /// (same as WorkerPool) and traversal polls it per batch.
    private func discoverInBackground(root: String, repository: String?, limits: Limits?, maximumCandidates: Int) async -> DiskCleanPurgeDiscoveryReport {
        let flag = DiskCleanCancellationFlag()
        let discovery = self.discovery
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(
                        returning: discovery.discover(root: root, isCancelled: { flag.isSet }, repositoryPath: repository,
                            deadline: limits?.deadline ?? .distantFuture,
                            maximumEntries: limits?.maximumEntriesPerProject ?? Int.max, maximumCandidates: maximumCandidates)
                    )
                }
            }
        } onCancel: {
            flag.set()
        }
    }
}
