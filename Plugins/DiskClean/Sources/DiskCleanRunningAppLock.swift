import AppKit
import Foundation

/// Snapshot of running apps/processes (design §4.2 item 4).
///
/// v1 spawned `pgrep` **once per rule** (43 rules = 43 subprocesses). Here we take one
/// snapshot: one `NSWorkspace.runningApplications` plus one batched `pgrep`, then every
/// target's lock check runs in memory.
///
/// The snapshot is a value type and does not auto-refresh — that is intentional: use one
/// point-in-time decision for the whole scan, then take a fresh snapshot before execution
/// (§7.1 preflight, §7.2 per-item recheck) for a dual-time lock.
struct DiskCleanRunningAppSnapshot: Equatable, Sendable {
    /// Bundle IDs of running apps (lowercased; bundle IDs are case-insensitive).
    let runningBundleIDs: Set<String>
    /// Running process names (`pgrep -x` exact matches; case-sensitive).
    let runningProcessNames: Set<String>
    let observedAt: Date
    var processStateKnown = true

    init(
        runningBundleIDs: Set<String> = [],
        runningProcessNames: Set<String> = [],
        observedAt: Date = Date()
    ) {
        self.runningBundleIDs = Set(runningBundleIDs.map { $0.lowercased() })
        self.runningProcessNames = runningProcessNames
        self.observedAt = observedAt
    }

    /// Process name that locks this target, or nil when unlocked.
    ///
    /// On a bundle-ID hit, return the bundle ID itself as the display name — the user sees
    /// something like "in use (com.google.Chrome)", which is more honest than a guessed
    /// localized app name and needs no extra lookup.
    func lockingProcessName(for target: DiskCleanRuleTarget) -> String? {
        lockingProcessName(
            bundleIDs: target.lockedByBundleIDs,
            processNames: target.skipWhenProcessIsRunning
        )
    }

    /// Execution-side entry: plan items carry their own lock declarations (copied from the catalog at mint time), so no catalog lookup is needed.
    func lockingProcessName(bundleIDs: [String], processNames: [String]) -> String? {
        if !processNames.isEmpty && !processStateKnown { return "进程状态无法确认" }
        for bundleID in bundleIDs where runningBundleIDs.contains(bundleID.lowercased()) {
            return bundleID
        }
        for name in processNames where runningProcessNames.contains(name) {
            return name
        }
        return nil
    }

    /// Replace the bundle-ID set, keep everything else. Used when the executor refreshes lock checks per item.
    func replacingBundleIDs(_ bundleIDs: Set<String>, observedAt: Date) -> DiskCleanRunningAppSnapshot {
        var snapshot = DiskCleanRunningAppSnapshot(runningBundleIDs: bundleIDs,
            runningProcessNames: runningProcessNames, observedAt: observedAt)
        snapshot.processStateKnown = processStateKnown
        return snapshot
    }

    /// Deduplicated process names declared by all targets. That set is the batch pgrep query.
    static func processNames(in targets: [DiskCleanRuleTarget]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for target in targets {
            for name in target.skipWhenProcessIsRunning where seen.insert(name).inserted {
                ordered.append(name)
            }
        }
        return ordered
    }
}

/// Snapshot source seam. Scan and execution share one interface so the decision matrix is tested once.
protocol DiskCleanRunningAppSnapshotting: Sendable {
    func makeSnapshot(processNames: [String]) async -> DiskCleanRunningAppSnapshot

    /// Refresh only the bundle-ID half; keep process names from the provided snapshot.
    ///
    /// Used by the executor's per-item lock recheck (§7.2): `NSWorkspace.runningApplications`
    /// is a cheap in-memory read, so refreshing per item is fine; `pgrep` spawns a subprocess,
    /// and per-item runs would turn one cleanup into dozens of forks, so process names reuse
    /// the preflight snapshot. The trade-off is that process-name lock decisions can lag by
    /// at most one cleanup duration; the real defenses are the removal primitive's identity
    /// checks and freeze (§7.3, §7.4), not this layer.
    func refreshingBundleIDs(in snapshot: DiskCleanRunningAppSnapshot) async -> DiskCleanRunningAppSnapshot
}

extension DiskCleanRunningAppSnapshotting {
    func refreshingBundleIDs(in snapshot: DiskCleanRunningAppSnapshot) async -> DiskCleanRunningAppSnapshot {
        snapshot
    }
}

/// Real implementation: `NSWorkspace` plus one batched `pgrep`.
///
/// Both sources are additive only: either source failing only under-reports locks
/// (candidates may still be deleted), so **execution must retake a snapshot and recheck
/// per item** (§7.2). This layer is not the sole defense.
struct DiskCleanRunningAppLock: DiskCleanRunningAppSnapshotting {
    static let defaultExecutablePath = "/usr/bin/pgrep"

    let executablePath: String
    let timeout: Duration
    let subprocessRunner: any DiskCleanSubprocessRunning
    let now: @Sendable () -> Date

    init(
        executablePath: String = DiskCleanRunningAppLock.defaultExecutablePath,
        timeout: Duration = DiskCleanDynamicRuleProviders.subprocessTimeout,
        subprocessRunner: any DiskCleanSubprocessRunning = LocalDiskCleanSubprocessRunner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.executablePath = executablePath
        self.timeout = timeout
        self.subprocessRunner = subprocessRunner
        self.now = now
    }

    func makeSnapshot(processNames: [String]) async -> DiskCleanRunningAppSnapshot {
        let names = await runningProcessNames(among: processNames)
        var snapshot = DiskCleanRunningAppSnapshot(runningBundleIDs: await Self.runningBundleIDs(),
            runningProcessNames: names ?? [], observedAt: now())
        snapshot.processStateKnown = names != nil
        return snapshot
    }

    func refreshingBundleIDs(in snapshot: DiskCleanRunningAppSnapshot) async -> DiskCleanRunningAppSnapshot {
        snapshot.replacingBundleIDs(await Self.runningBundleIDs(), observedAt: now())
    }

    /// `NSWorkspace` is only guaranteed main-thread safe, so hop to the main actor to read it.
    private static func runningBundleIDs() async -> Set<String> {
        await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
    }

    private func runningProcessNames(among names: [String]) async -> Set<String>? {
        guard !names.isEmpty else { return [] }

        let result: DiskCleanSubprocessResult
        do {
            result = try await subprocessRunner.run(
                executablePath: executablePath,
                arguments: ["-x", "-l", Self.pattern(for: names)],
                timeout: timeout
            )
        } catch {
            // Unknown state must not authorize deletion.
            return nil
        }
        // pgrep exits 1 with empty output when nothing matches — not a failure.
        guard result.exitCode == 0 || result.exitCode == 1 else { return nil }

        // Trust only names in this query set: the pattern is a regex, so output could theoretically include surprises.
        let requested = Set(names)
        return Set(Self.processNames(fromPgrepOutput: result.standardOutput).filter(requested.contains))
    }

    /// Query all names at once: `pgrep -x` pattern is ERE and `-x` requires a full-name match,
    /// so `(a|b|c)` means "name exactly equals one of these".
    static func pattern(for names: [String]) -> String {
        "(" + names.map(escapeForExtendedRegex).joined(separator: "|") + ")"
    }

    /// Process names routinely contain regex metacharacters such as `.`, `+`, `(` (`com.docker.backend`); escape every character.
    static func escapeForExtendedRegex(_ name: String) -> String {
        let metacharacters: Set<Character> = ["\\", ".", "^", "$", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|"]
        var escaped = ""
        escaped.reserveCapacity(name.count)
        for character in name {
            if metacharacters.contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    /// Each `pgrep -l` line is `<pid> <process name>`; names may contain spaces, so only strip the pid before the first space.
    static func processNames(fromPgrepOutput output: Data) -> [String] {
        String(decoding: output, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let separatorIndex = line.firstIndex(of: " ") else { return nil }
                let name = String(line[line.index(after: separatorIndex)...])
                return name.isEmpty ? nil : name
            }
    }
}
