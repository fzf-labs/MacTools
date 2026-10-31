import Foundation

// MARK: - Category tri-state

/// Tri-state for category checkboxes (design §8.1).
///
/// `unavailable` and `noneSelected` must stay distinct: the former means "this category has
/// nothing selectable" (checkbox disabled; clicking does nothing), the latter means "there
/// are selectable items but none are selected" (one click selects all low-risk items).
/// Merging them makes users hammer a checkbox that never moves.
///
/// There is no `none` case name: this type appears as dictionary values, and
/// `dict[key] = .none` would be read as `Optional.none` (delete the key) — a trap not worth leaving.
enum DiskCleanCategorySelectionState: Equatable, Sendable {
    case unavailable
    case noneSelected
    case partiallySelected
    case allSelected

    var isSelectable: Bool {
        self != .unavailable
    }

    /// Whether the checkbox currently looks checked (partial uses a dash rather than a tick; the view distinguishes that).
    var isChecked: Bool {
        self == .allSelected || self == .partiallySelected
    }
}

// MARK: - Selection projection

/// Read-only projection of selection state. Snapshots carry it; detail and menu-bar both read only this copy.
///
/// Menu bar and detail share one authoritative selection (design review round1-#5): both entries
/// read the same projection and issue the same commands. There is no dual semantics of
/// "panel cleans everything / detail cleans checked items".
struct DiskCleanSelectionProjection: Equatable, Sendable {
    let selectedIDs: Set<DiskCleanCandidate.ID>
    let selectableIDs: Set<DiskCleanCandidate.ID>
    let selectedEstimatedBytes: Int64
    let categoryStates: [DiskCleanCategoryID: DiskCleanCategorySelectionState]

    static let empty = DiskCleanSelectionProjection(
        selectedIDs: [],
        selectableIDs: [],
        selectedEstimatedBytes: 0,
        categoryStates: [:]
    )

    var selectedCount: Int { selectedIDs.count }

    var isEmpty: Bool { selectedIDs.isEmpty }

    func isSelected(_ candidateID: DiskCleanCandidate.ID) -> Bool {
        selectedIDs.contains(candidateID)
    }

    func isSelectable(_ candidateID: DiskCleanCandidate.ID) -> Bool {
        selectableIDs.contains(candidateID)
    }

    /// Categories absent from this scan are treated as `unavailable` — no candidates means nothing selectable.
    func state(of category: DiskCleanCategoryID) -> DiskCleanCategorySelectionState {
        categoryStates[category] ?? .unavailable
    }
}

// MARK: - Selection model

/// Authoritative tri-state selection model (design §8.1). Owned exclusively by the Controller.
///
/// **This model does not store candidates — only "what the user did"**: per-candidate explicit
/// overrides, and per-category explicit select-all / deselect-all. Selectedness is always
/// derived from `(candidate facts, user overrides, category operations)`. Streaming new
/// candidates therefore need no "backfill registration" step to land on the right side —
/// during scan, candidates appear without sizes and are later completed by `candidateSized`;
/// an incrementally maintained selected set is easy to desync from candidate facts between
/// those moments, while recomputation cannot desync.
///
/// Three semantics (design §8.1):
/// - **Unselectable means toggle is rejected**, not merely UI-disabled: locked / whitelisted /
///   protected / non-complete / unsized / mount-containing candidates make `setCandidate`
///   return false with no record kept.
/// - **Default selected = low risk and selectable**. medium/high and dynamic-rule products
///   (target risk always >= medium) are never selected by default.
/// - **"Select all" = select every low-risk item in the category**; medium/high are never
///   pulled in by select-all (UI copy matches this).
struct DiskCleanSelectionModel: Equatable, Sendable {
    /// Category-level explicit operation.
    ///
    /// `selectAllLowRisk` affects **newly arrived** candidates exactly like "never operated"
    /// (both fall through to default policy). We still record it to override a prior
    /// `deselectAll` and to give "user explicitly acted on this category" a name in the model.
    enum CategoryOperation: Equatable, Sendable {
        case selectAllLowRisk
        case deselectAll
    }

    private struct CandidateOverride: Equatable, Sendable {
        let category: DiskCleanCategoryID
        let isSelected: Bool
    }

    private var candidateOverrides: [DiskCleanCandidate.ID: CandidateOverride] = [:]
    private var categoryOperations: [DiskCleanCategoryID: CategoryOperation] = [:]

    init() {}

    // MARK: - Selectability

    /// Whether the candidate is selectable.
    ///
    /// Same decision as `DiskCleanCandidate.isCleanable` — do not duplicate the conditions:
    /// the six unselectable cases in design §8.1 (locked / whitelisted / protected /
    /// non-complete / unsized / mount-containing) all live in `isCleanable`; two copies would drift.
    static func isSelectable(_ candidate: DiskCleanCandidate) -> Bool {
        candidate.isCleanable
    }

    /// Default policy: low risk and selectable. Dynamic-rule products always have target risk >= medium, so they land on the unselected side automatically.
    static func isSelectedByDefault(_ candidate: DiskCleanCandidate) -> Bool {
        isSelectable(candidate) && candidate.risk == .low
    }

    func isSelected(_ candidate: DiskCleanCandidate) -> Bool {
        guard Self.isSelectable(candidate) else { return false }
        if let override = candidateOverrides[candidate.id] {
            return override.isSelected
        }
        if categoryOperations[candidate.category] == .deselectAll {
            return false
        }
        return candidate.risk == .low
    }

    // MARK: - Commands

    /// Select/deselect one candidate. Returns whether it was accepted — unselectable candidates are always rejected with no override record.
    @discardableResult
    mutating func setCandidate(_ candidate: DiskCleanCandidate, isSelected: Bool) -> Bool {
        guard Self.isSelectable(candidate) else { return false }
        candidateOverrides[candidate.id] = CandidateOverride(
            category: candidate.category,
            isSelected: isSelected
        )
        return true
    }

    /// Category-level select all (low risk only) / deselect all.
    ///
    /// Clears prior per-item overrides for the category: a category operation is coarser, and pressing it means reset this category's state.
    mutating func setCategory(_ category: DiskCleanCategoryID, isSelected: Bool) {
        categoryOperations[category] = isSelected ? .selectAllLowRisk : .deselectAll
        candidateOverrides = candidateOverrides.filter { $0.value.category != category }
    }

    /// Return to "user has done nothing". Must be called for each new scan: candidate IDs are
    /// `targetID::path` and stable across scans, so without a clear prior selections would silently carry over.
    mutating func reset() {
        candidateOverrides = [:]
        categoryOperations = [:]
    }

    // MARK: - Derived state

    func selectedIDs(in candidates: [DiskCleanCandidate]) -> Set<DiskCleanCandidate.ID> {
        Set(candidates.filter(isSelected).map(\.id))
    }

    /// One pass computing every selection fact the snapshot needs.
    func projection(for candidates: [DiskCleanCandidate]) -> DiskCleanSelectionProjection {
        var selectedIDs: Set<DiskCleanCandidate.ID> = []
        var selectableIDs: Set<DiskCleanCandidate.ID> = []
        var selectedBytes: Int64 = 0
        var selectableCountByCategory: [DiskCleanCategoryID: Int] = [:]
        var selectedCountByCategory: [DiskCleanCategoryID: Int] = [:]
        var categoryStates: [DiskCleanCategoryID: DiskCleanCategorySelectionState] = [:]

        for candidate in candidates {
            // Record category presence first: a category of only unselectable items still needs
            // a state (`unavailable`), or the view cannot tell "nothing scanned" from "everything protected".
            categoryStates[candidate.category] = .unavailable

            guard Self.isSelectable(candidate) else { continue }
            selectableIDs.insert(candidate.id)
            selectableCountByCategory[candidate.category, default: 0] += 1

            guard isSelected(candidate) else { continue }
            selectedIDs.insert(candidate.id)
            selectedBytes += max(candidate.estimatedBytes, 0)
            selectedCountByCategory[candidate.category, default: 0] += 1
        }

        for (category, selectableCount) in selectableCountByCategory where selectableCount > 0 {
            let selectedCount = selectedCountByCategory[category] ?? 0
            switch selectedCount {
            case 0:
                categoryStates[category] = .noneSelected
            case selectableCount:
                categoryStates[category] = .allSelected
            default:
                categoryStates[category] = .partiallySelected
            }
        }

        return DiskCleanSelectionProjection(
            selectedIDs: selectedIDs,
            selectableIDs: selectableIDs,
            selectedEstimatedBytes: selectedBytes,
            categoryStates: categoryStates
        )
    }
}
