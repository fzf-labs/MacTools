import Foundation

/// A proposed association becomes removable only through explicit per-file review and final confirmation.
struct DiskCleanApplicationNameCandidate: Equatable, Sendable {
    let home: String
    let relativePath: String
    let matchedName: String

    func permits(_ path: String) -> Bool {
        guard DiskCleanApplicationNameVariants.make([matchedName]).contains(matchedName),
              !relativePath.split(separator: "/").contains(".."), !relativePath.hasPrefix("/") else { return false }
        let roots = ["Library/Application Support/", "Library/Caches/", "Library/Logs/", ".config/", ".cache/", ".local/share/"]
        var allowed = roots.contains { relativePath == $0 + matchedName }
        for vendor in ["Tencent", "Microsoft", "Adobe", "Google", "JetBrains", "Mozilla", "Avid"] {
            allowed = allowed || relativePath == "Library/Application Support/" + vendor + "/" + matchedName
        }
        let crashPrefix = "Library/Application Support/CrashReporter/" + matchedName + "_"
        if relativePath.hasPrefix(crashPrefix), relativePath.hasSuffix(".plist") {
            allowed = UUID(uuidString: String(relativePath.dropFirst(crashPrefix.count).dropLast(6))) != nil
        }
        return allowed && DiskCleanPhysicalPath.resolve(home + "/" + relativePath) == path
    }

    static func claimedNames(by applications: [DiskCleanInstalledApplication], excluding bundleID: String) -> Set<String> {
        applications.filter { $0.bundleID != bundleID }.reduce(into: Set<String>()) { result, app in
            var names: Set<String> = [app.name, URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent]
            if let executable = app.executable { names.insert(executable) }
            let bundle = Bundle(path: app.path)
            for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
                if let name = bundle?.object(forInfoDictionaryKey: key) as? String { names.insert(name) }
            }
            names.formUnion(DiskCleanApplicationProductRules.rule(for: app.bundleID)?.aliases ?? [])
            result.formUnion(DiskCleanApplicationNameVariants.make(names).map { $0.lowercased() })
        }
    }

    func hasConflictingOwner(in applications: [DiskCleanInstalledApplication], excluding bundleID: String) -> Bool {
        Self.claimedNames(by: applications, excluding: bundleID).contains(matchedName.lowercased())
    }
}
