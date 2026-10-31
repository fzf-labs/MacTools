import Foundation

struct DiskCleanApplicationScanCheck: Identifiable, Equatable, Sendable {
    enum State: String, Sendable {
        case checked, missing, permissionRequired, incomplete, unsupported
        var needsAttention: Bool { self != .checked && self != .missing }
        var issuePriority: Int {
            switch self {
            case .permissionRequired: 3
            case .incomplete, .unsupported: 2
            case .checked, .missing: 0
            }
        }
    }
    enum Source: String, Sendable {
        case bundleID, productRule, name, container, system, identity
    }
    let path: String
    let category: DiskCleanApplicationFileCategory
    let source: Source
    let state: State
    var id: String { category.rawValue + ":" + path }
}

struct DiskCleanApplicationScanReport: Sendable {
    var checks: [DiskCleanApplicationScanCheck] = []
    var hasProductRule = false
    var identityComplete = true
    var claimsComplete = true

    mutating func record(path: String, category: DiskCleanApplicationFileCategory,
                         source: DiskCleanApplicationScanCheck.Source, state: DiskCleanApplicationScanCheck.State) {
        let check = DiskCleanApplicationScanCheck(path: path, category: category, source: source, state: state)
        if let index = checks.firstIndex(where: { $0.id == check.id }) {
            // A successful later probe must not conceal a denied or unfinished earlier probe.
            if state.issuePriority > checks[index].state.issuePriority
                || (state.issuePriority == checks[index].state.issuePriority && source != .name) {
                checks[index] = check
            }
        } else { checks.append(check) }
    }
}
