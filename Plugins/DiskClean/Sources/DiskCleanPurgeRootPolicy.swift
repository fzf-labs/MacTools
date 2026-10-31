import Foundation

/// Hard denylist for developer-artifact scan roots.
///
/// Purge discovery walks up to 6 levels and may default-select marker matches. Using Home,
/// `/Applications`, or other top-level locations as a root makes accidental mass selection too easy.
/// Project subfolders under Documents/Desktop remain allowed.
enum DiskCleanPurgeRootPolicy {
    /// Exact system / volume roots that must never be scan roots.
    private static let exactRestrictedRoots: Set<String> = [
        "/",
        "/Applications",
        "/System",
        "/Library",
        "/Users",
        "/home",
        "/Volumes",
        "/Network",
        "/private",
        "/var",
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/opt",
        "/cores",
    ]

    /// Well-known top-level folders under the user’s home that are too broad as roots.
    private static let restrictedHomeFolderNames: Set<String> = [
        "Desktop",
        "Documents",
        "Downloads",
        "Library",
        "Movies",
        "Music",
        "Pictures",
        "Public",
    ]

    /// `path` must already be a physical, trailing-slash-trimmed absolute path.
    static func isTooBroad(_ path: String) -> Bool {
        if exactRestrictedRoots.contains(path) {
            return true
        }

        let home = trimTrailingSlashes(NSHomeDirectory())
        if path == home {
            return true
        }
        if restrictedHomeFolderNames.contains(where: { path == home + "/" + $0 }) {
            return true
        }

        // Another user’s home (`/Users/name`) — and its top-level personal folders — is equally too broad.
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2, components[0] == "Users" || components[0] == "home" else {
            return false
        }
        if components.count == 2 {
            return true
        }
        if components.count == 3, restrictedHomeFolderNames.contains(String(components[2])) {
            return true
        }

        return false
    }

    private static func trimTrailingSlashes(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}
