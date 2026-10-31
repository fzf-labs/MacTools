import Foundation
import MacToolsPluginKit

// MARK: - Expansion product

/// Product of one non-rules expansion (design §10).
///
/// Shape deliberately matches the rules-expansion stage—hits + reserved roots + limitations + logs—so the engine's later
/// ownership, safety, sizing, and artifact cast all run unchanged; P2 candidates cannot skip a step.
struct DiskCleanExternalExpansion: Sendable {
    var hits: [DiskCleanTargetHit] = []
    var reservedRootPaths: [String] = []
    var limitations: [DiskCleanScanLimitation] = []
    var logMessages: [DiskCleanScanLogMessage] = []

    init() {}
}

/// Adapter seam from a specialized scanner into the unified pipeline.
///
/// The engine only knows this protocol, so tests can feed arbitrary candidates into the full pipeline without touching the filesystem
/// (sizing → completeness → artifact → Planner → executor), validating the pipeline rather than the scanner.
protocol DiskCleanExternalExpanding: Sendable {
    /// `catalog` resolves synthetic targets by targetID. Unknown targetIDs are dropped and logged—
    /// a candidate that cannot attach to a target would be rejected at `makePlan` anyway; drop early and say so.
    func expand(
        scope: DiskCleanScanScope,
        catalog: DiskCleanRuleCatalogV2,
        localization: PluginLocalization
    ) async -> DiskCleanExternalExpansion
}

protocol DiskCleanProgressiveExternalExpanding: DiskCleanExternalExpanding {
    func expand(scope: DiskCleanScanScope, catalog: DiskCleanRuleCatalogV2, localization: PluginLocalization,
                onDiscovery: @escaping @Sendable ([DiskCleanTargetHit]) -> Void) async -> DiskCleanExternalExpansion
}

// MARK: - Purge / development products

/// `DiskCleanPurgeScanner` → unified pipeline (design §10.1).
struct DiskCleanDeveloperArtifactExpansion: DiskCleanProgressiveExternalExpanding {
    private let scanner: DiskCleanPurgeScanner
    private let automaticLocations: DiskCleanDeveloperArtifactLocations

    init(scanner: DiskCleanPurgeScanner = DiskCleanPurgeScanner(), automaticHome: String? = nil) {
        self.scanner = scanner
        automaticLocations = .init(home: automaticHome ?? NSHomeDirectory())
    }

    func expand(
        scope: DiskCleanScanScope,
        catalog: DiskCleanRuleCatalogV2,
        localization: PluginLocalization
    ) async -> DiskCleanExternalExpansion {
        await expand(scope: scope, catalog: catalog, localization: localization, onDiscovery: { _ in })
    }

    func expand(scope: DiskCleanScanScope, catalog: DiskCleanRuleCatalogV2, localization: PluginLocalization,
                onDiscovery: @escaping @Sendable ([DiskCleanTargetHit]) -> Void) async -> DiskCleanExternalExpansion {
        var expansion = DiskCleanExternalExpansion()
        let roots: [String]
        var repositories: [String: String] = [:]
        let automatic = scope == .automaticProjects
        let deadline = Date().addingTimeInterval(60)
        if automatic {
            let locations = automaticLocations
            let resolved = await diskCleanBackground { locations.resolve() }
            roots = resolved.roots
            repositories = resolved.repositories
            expansion.reservedRootPaths = resolved.reservedRoots
            expansion.limitations = resolved.limitations
        } else { roots = scope.developerArtifactRoots }
        guard !roots.isEmpty else { return expansion }

        @Sendable func hits(for report: DiskCleanPurgeRootReport) -> [DiskCleanTargetHit] {
            report.candidates.compactMap { candidate in
                guard let target = catalog.target(id: candidate.kind.targetID) else { return nil }
                return .init(target: target,
                    item: .init(path: candidate.path, isDirectory: true, isSymlink: false, resolvedSymlinkTarget: nil),
                    specificity: 0, facts: Self.facts(for: candidate))
            }
        }

        // **Every configured root enters the reserved set**, whether or not traversal succeeded.
        //
        // Semantics: "the root itself is not a delete target, and any part of the root not covered by a candidate was never reviewed." Ancestor assertions therefore
        // reject any plan path that has a root as a descendant (e.g. `~` or a root's parent), while candidates **inside** a root
        // are unaffected—they are descendants of the root, not ancestors. Depth cap 6 and unexplored regions left by hit-and-prune
        // are covered by the same rule.
        expansion.reservedRootPaths += roots

        let result = await scanner.scan(roots: roots, repositories: repositories,
            limits: automatic ? .init(deadline: deadline) : nil) { report in
                if automatic { onDiscovery(hits(for: report)) }
            }
        if automatic, result.reports.contains(where: {
            if case let .traversed(completeness) = $0.status { return !completeness.isComplete }
            return false
        }), !expansion.limitations.contains(.developerSearchLimited) {
            expansion.limitations.append(.developerSearchLimited)
        }
        for report in result.reports {
            switch report.status {
            case let .unreadable(reason):
                // A root that cannot open at all must be distinguished from "scanned with no candidates", or the user sees a dishonest empty list.
                expansion.limitations.append(
                    .scanRootUnreadable(path: report.root, reason: reason)
                )

            case let .traversed(completeness):
                // Partial subtree skips only affect discovery completeness, not deletability of already-found candidates (the root is already reserved).
                // So only log; do not escalate to a limitation—the list is already in front of the user, and when a root is unreadable
                // the user already has a stronger signal.
                guard case let .partial(reasons) = completeness else { break }
                expansion.logMessages.append(
                    DiskCleanScanLogMessage(
                        text: localization.format(
                            "scanLog.purge.partialRoot",
                            defaultValue: "%@ 有子目录未能读取（%@），可能漏报部分产物",
                            report.root,
                            DiskCleanFormat.partialReasons(reasons, localization: localization)
                        ),
                        tone: .warning
                    )
                )
            }

            for candidate in report.candidates where catalog.target(id: candidate.kind.targetID) == nil {
                expansion.logMessages.append(Self.missingTargetLog(candidate.kind.targetID, localization: localization))
            }
            expansion.hits += hits(for: report)
        }

        return expansion
    }

    /// Dirty repo (including check failure) → keep the target's medium risk, not selected by default; everything else drops to low and is selected by default.
    static func facts(for candidate: DiskCleanPurgeCandidate) -> DiskCleanCandidateFacts {
        var notes: [DiskCleanCandidateNote] = [
            .developerProject(path: candidate.projectPath, marker: candidate.projectMarker)
        ]
        if case let .dirty(repositoryPath, reason) = candidate.gitState {
            notes.append(.repositoryHasChanges(repositoryPath: repositoryPath, reason: reason))
        }
        return DiskCleanCandidateFacts(
            risk: candidate.isSelectedByDefault ? .low : nil,
            notes: notes,
            rejection: candidate.protectionReason,
            validation: .project
        )
    }

    private static func missingTargetLog(
        _ targetID: String,
        localization: PluginLocalization
    ) -> DiskCleanScanLogMessage {
        DiskCleanScanLogMessage(
            text: localization.format(
                "scanLog.missingTarget",
                defaultValue: "规则目录缺少 target %@，已跳过对应候选",
                targetID
            ),
            tone: .error
        )
    }
}

// MARK: - Leftover installers

/// `DiskCleanInstallerScanner` → unified pipeline (design §10.2).
struct DiskCleanInstallerExpansion: DiskCleanProgressiveExternalExpanding {
    private let scanner: DiskCleanInstallerScanner?
    private let homeScanner: DiskCleanInstallerHomeScanner

    init(scanner: DiskCleanInstallerScanner? = nil,
         homeScanner: DiskCleanInstallerHomeScanner = .init(home: NSHomeDirectory())) {
        self.scanner = scanner
        self.homeScanner = homeScanner
    }

    func expand(scope: DiskCleanScanScope, catalog: DiskCleanRuleCatalogV2,
                localization: PluginLocalization) async -> DiskCleanExternalExpansion {
        await expand(scope: scope, catalog: catalog, localization: localization, onDiscovery: { _ in })
    }

    func expand(scope: DiskCleanScanScope, catalog: DiskCleanRuleCatalogV2, localization: PluginLocalization,
                onDiscovery: @escaping @Sendable ([DiskCleanTargetHit]) -> Void) async -> DiskCleanExternalExpansion {
        @Sendable func hits(_ candidates: [DiskCleanInstallerCandidate]) -> [DiskCleanTargetHit] {
            candidates.compactMap { candidate in
                guard let target = catalog.target(id: candidate.kind.targetID) else { return nil }
                return DiskCleanTargetHit(target: target,
                    item: .init(path: candidate.path,
                        isDirectory: (try? URL(fileURLWithPath: candidate.path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                        isSymlink: false, resolvedSymlinkTarget: nil),
                    specificity: 0, facts: Self.facts(for: candidate))
            }
        }
        var expansion = DiskCleanExternalExpansion()
        expansion.reservedRootPaths = Array(Set(DiskCleanInstallerKind.allCases
            .compactMap { catalog.target(id: $0.targetID) }.flatMap { $0.expandedReservedRootPaths() })).sorted()
        let report: DiskCleanInstallerHomeScan
        if let scanner {
            let outcome = await diskCleanBackground { scanner.scan() }
            switch outcome {
            case let .scanned(candidates): report = .init(candidates: candidates)
            case let .denied(path): report = .init(limitations: [.scanRootUnreadable(path: path, reason: .permissionDenied)])
            case let .unavailable(path, reason): report = .init(limitations: [.scanRootUnreadable(path: path, reason: reason)])
            }
            onDiscovery(hits(report.candidates))
        } else {
            let search = homeScanner
            report = await diskCleanBackground {
                search.scan { candidates in onDiscovery(hits(candidates)) }
            }
        }
        expansion.hits = hits(report.candidates)
        expansion.reservedRootPaths += report.reservedRoots
        expansion.limitations = report.limitations
        for id in Set(report.candidates.map { $0.kind.targetID }) where catalog.target(id: id) == nil {
            expansion.logMessages.append(.init(text: localization.format("scanLog.missingTarget",
                defaultValue: "规则目录缺少 target %@，已跳过对应候选", id), tone: .error))
        }
        return expansion
    }

    static func facts(for candidate: DiskCleanInstallerCandidate) -> DiskCleanCandidateFacts {
        var notes: [DiskCleanCandidateNote] = []
        switch candidate.note {
        case .mayNotBeInstaller: notes.append(.mayNotBeInstaller)
        case .recentlyModified: notes.append(.recentlyDownloaded(modifiedAt: candidate.modifiedAt))
        case nil: break
        }
        return DiskCleanCandidateFacts(risk: candidate.isSelectedByDefault ? .low : nil,
            notes: notes, validation: .installer)
    }
}
