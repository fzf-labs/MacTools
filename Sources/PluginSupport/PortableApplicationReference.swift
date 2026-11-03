import Foundation

/// A destination-resolved application identity. Paths are relative to a named installation root.
struct PortableApplicationReference: Codable, Equatable {
    enum Location: String, Codable {
        case applications, userApplications, systemApplications, cryptexApplications, unresolved

        var root: URL? {
            switch self {
            case .applications: URL(fileURLWithPath: "/Applications", isDirectory: true)
            case .userApplications: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            case .systemApplications: URL(fileURLWithPath: "/System/Applications", isDirectory: true)
            case .cryptexApplications: URL(fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications", isDirectory: true)
            case .unresolved: nil
            }
        }
    }

    let bundleIdentifier: String?
    let location: Location
    let relativePath: String?
    let bundleName: String

    init(url: URL?, roots: [Location: URL] = [:]) {
        let url = url?.standardizedFileURL.resolvingSymlinksInPath()
        bundleIdentifier = url.flatMap { Bundle(url: $0)?.bundleIdentifier }
        bundleName = url?.lastPathComponent ?? "Unavailable.app"
        var matched: (Location, String)?
        for role in [Location.applications, .userApplications, .systemApplications, .cryptexApplications] {
            guard let root = (roots[role] ?? role.root)?.resolvingSymlinksInPath(), let path = url?.path, path.hasPrefix(root.path + "/") else { continue }
            matched = (role, String(path.dropFirst(root.path.count + 1)))
            break
        }
        if let matched, bundleIdentifier != nil {
            location = matched.0
            relativePath = matched.1
        } else {
            location = .unresolved
            relativePath = nil
        }
    }

    var isValid: Bool {
        guard !bundleName.isEmpty, bundleName.utf8.count <= 256, bundleName.hasSuffix(".app"),
              !bundleName.contains("/"), !bundleName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        if let bundleIdentifier {
            guard !bundleIdentifier.isEmpty, bundleIdentifier.utf8.count <= 256,
                  bundleIdentifier.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0) }) else { return false }
        }
        if location == .unresolved { return relativePath == nil }
        guard bundleIdentifier != nil, let relativePath, relativePath.utf8.count <= 1_024,
              !relativePath.hasPrefix("/"), !relativePath.contains("\\"), relativePath.hasSuffix(".app"),
              !relativePath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && parts.dropLast().allSatisfy { !$0.hasSuffix(".app") }
    }

    func resolvedURL(roots: [Location: URL] = [:]) -> URL? {
        guard isValid, location != .unresolved, let root = roots[location] ?? location.root, let relativePath, let bundleIdentifier else { return nil }
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
              FileManager.default.fileExists(atPath: candidate.path),
              Bundle(url: candidate)?.bundleIdentifier == bundleIdentifier else { return nil }
        return candidate
    }
}
