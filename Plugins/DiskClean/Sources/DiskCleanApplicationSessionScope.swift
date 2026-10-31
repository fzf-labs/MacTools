import Darwin
import Foundation

/// A narrow policy context for personally selected, exclusively attributed application data.
struct DiskCleanApplicationSessionScope: Sendable {
    private let roots: [String]

    init?(path: String, home: String, proof: DiskCleanApplicationProof) {
        guard proof.allowsPersonalSessionRemoval, let mainID = proof.mainBundleID, let owner = proof.ownerID,
              DiskCleanApplicationInventory.validBundleID(owner), !proof.requiresCompleteClaims(for: mainID),
              proof.rejection(at: path) == nil else { return nil }
        let root = DiskCleanPhysicalPath.resolve(path)
        let folders = ["Application Support", "Containers", "HTTPStorages", "WebKit", "Application Scripts"]
        let anchors = folders.map { DiskCleanPhysicalPath.realpath(of: home + "/Library/" + $0)
            ?? DiskCleanPhysicalPath.resolve(home + "/Library/" + $0) }
        let reviewedName = proof.nameCandidate?.permits(root) == true
        guard reviewedName || anchors.contains(where: { root.hasPrefix($0 + "/") }) else { return nil }
        let exactOwnerPaths = folders.map { DiskCleanPhysicalPath.resolve(home + "/Library/" + $0 + "/" + owner) }
            + [DiskCleanPhysicalPath.resolve(home + "/Library/WebKit/com.apple.WebKit.WebContent/" + owner)]
        let containerRoot = anchors[1]
        let ownedContainer = proof.containerOwner == owner
            && URL(fileURLWithPath: root).deletingLastPathComponent().path == containerRoot
        guard reviewedName || proof.product?.permits(root) == true || exactOwnerPaths.contains(root) || ownedContainer else { return nil }
        var identity = stat()
        let hasIdentity = lstat(root, &identity) == 0
        roots = Array(Set([root] + proof.logicalPaths.filter { alias in
            if DiskCleanPhysicalPath.resolve(alias) == root { return true }
            var status = stat()
            return hasIdentity && lstat(alias, &status) == 0 && status.st_dev == identity.st_dev && status.st_ino == identity.st_ino
        }))
    }

    func permitsSessionState(at path: String) -> Bool {
        guard roots.contains(where: { path.hasPrefix($0 + "/") }) else { return false }
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return ["cookies", "cookies-journal", "session storage", "sessions", "local state"].contains(name)
            || name.hasSuffix(".binarycookies")
    }
}
