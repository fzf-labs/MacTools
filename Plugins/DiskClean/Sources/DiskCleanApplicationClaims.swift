import Darwin
import Foundation

/// One inventory epoch shares discovery work; execution still reads fresh claims.
struct DiskCleanApplicationClaimsSnapshot: Sendable {
    let owners: [String: Set<String>]
    let incompleteOwners: Set<String>

    func otherClaims(excluding bundleID: String) -> (ids: Set<String>, complete: Bool) {
        let others = owners.keys.filter { $0.caseInsensitiveCompare(bundleID) != .orderedSame }
        return (others.reduce(into: Set<String>()) { $0.formUnion(owners[$1] ?? []) },
            !others.contains { incompleteOwners.contains($0) })
    }

    static func read(_ applications: [DiskCleanInstalledApplication]) -> Self {
        var owners: [String: Set<String>] = [:]
        var incomplete = Set<String>()
        let deadline = Date().addingTimeInterval(10)
        var budget = 20_000
        func visit(_ path: String, owner: String, depth: Int) {
            var status = stat()
            guard lstat(path, &status) == 0 else { if errno != ENOENT { incomplete.insert(owner) }; return }
            guard depth < 6, budget > 0, Date() < deadline, !Task.isCancelled else { incomplete.insert(owner); return }
            guard let children = try? DiskCleanDirectoryListing.read(path) else { incomplete.insert(owner); return }
            for child in children where child.isDirectory && !["Resources", "Headers", "Modules", "_CodeSignature"].contains(URL(fileURLWithPath: child.path).lastPathComponent) && !child.path.hasSuffix(".lproj") {
                budget -= 1
                if ["app", "appex", "xpc"].contains(URL(fileURLWithPath: child.path).pathExtension.lowercased()) {
                    if let id = Bundle(path: child.path)?.bundleIdentifier { owners[owner, default: []].insert(id) }
                    else { incomplete.insert(owner) }
                } else { visit(child.path, owner: owner, depth: depth + 1) }
                if budget <= 0 || Date() >= deadline { incomplete.insert(owner); break }
            }
        }
        for app in applications {
            owners[app.bundleID, default: []].insert(app.bundleID)
            let helpers = Bundle(path: app.path)?.object(forInfoDictionaryKey: "SMPrivilegedExecutables") as? [String: String] ?? [:]
            owners[app.bundleID, default: []].formUnion(helpers.keys.filter(DiskCleanApplicationInventory.validBundleID))
            for folder in ["PlugIns", "XPCServices", "Library/LoginItems", "Helpers", "Frameworks"] {
                visit(app.path + "/Contents/" + folder, owner: app.bundleID, depth: 0)
            }
        }
        return .init(owners: owners, incompleteOwners: incomplete)
    }
}
