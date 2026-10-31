import SwiftUI
import MacToolsPluginKit

// MARK: - Section guidance states

/// What a section should say when there are "no candidates to show" (design §10).
///
/// Purely derived, view-free, so it can be asserted directly against snapshots. It exists
/// because several empty states **must stay distinct**: no scan roots configured, never
/// scanned, scanned but access denied, roots unreadable, truly empty — each demands a
/// different next step from the user. Collapsing them into one "nothing here" makes the user guess.
enum DiskCleanSectionGuidance: Equatable, Sendable {
    /// Show the candidate list normally.
    case candidates
    /// Developer-artifacts section has no scan roots configured yet.
    case needsRoots
    /// Not scanned yet.
    case notScanned
    /// Scan root access denied (TCC). **Must never look like "nothing cleanable"** —
    /// `~/Downloads` may hold tens of GB of installers.
    case accessDenied(path: String)
    /// Scan root cannot be opened: deleted, replaced by a file, or on a non-local volume.
    case rootsUnreadable(paths: [String])
    /// Scanned; truly empty.
    case empty

    static func resolve(_ snapshot: DiskCleanControllerSnapshot) -> DiskCleanSectionGuidance {
        if case .developerArtifacts = snapshot.scope, snapshot.scope.isEmpty {
            return .needsRoots
        }
        guard let result = snapshot.scanResult else { return .notScanned }
        // With candidates, show them normally; root problems are reported honestly by the limitation banner and need not own the whole list.
        guard result.candidates.isEmpty else { return .candidates }

        let unreadable = result.limitations.compactMap { limitation -> (String, DiskCleanScanCompleteness.PartialReason)? in
            guard case let .scanRootUnreadable(path, reason) = limitation else { return nil }
            return (path, reason)
        }
        if let denied = unreadable.first(where: { $0.1 == .permissionDenied }) {
            return .accessDenied(path: denied.0)
        }
        if !unreadable.isEmpty {
            return .rootsUnreadable(paths: unreadable.map(\.0))
        }
        return .empty
    }
}

// MARK: - Reusable pieces

/// Banner (shared by limitation, error, and FDA guidance).
struct DiskCleanBanner<Trailing: View>: View {
    let symbolName: String
    let tint: Color
    let title: String
    let lines: [String]
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
                .frame(width: PluginSettingsTheme.Size.rowIcon)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            trailing()
        }
        .pluginSettingsListRowPadding()
        .pluginSettingsCardBackground(.standard)
    }
}

extension DiskCleanBanner where Trailing == EmptyView {
    init(symbolName: String, tint: Color, title: String, lines: [String]) {
        self.init(symbolName: symbolName, tint: tint, title: title, lines: lines) { EmptyView() }
    }
}

struct DiskCleanSectionHeader: View {
    let title: String
    let symbolName: String

    var body: some View {
        Label(title, systemImage: symbolName)
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)
    }
}
