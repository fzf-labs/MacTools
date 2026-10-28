import Foundation
import UniformTypeIdentifiers

enum RightClickLocalization {
    private static let appleLanguagesKey = "AppleLanguages"
    private static let rightClickTable = "RightClick"
    private static let finderSyncBundleSuffix = ".right-click.finder-sync"

    static func string(
        _ key: String,
        defaultValue: String,
        bundle: Bundle = .main,
        preferredLanguages: [String]? = nil
    ) -> String {
        for localizedBundle in LocalizedBundleResolver.localizedBundles(
            in: bundle,
            preferredLanguages: preferredLanguages ?? effectivePreferredLanguages(for: bundle),
            baseLanguage: "en"
        ) {
            let localizedValue = localizedBundle.localizedString(forKey: key, value: nil, table: rightClickTable)
            if localizedValue != key {
                return localizedValue
            }
        }

        return defaultValue
    }

    private static func effectivePreferredLanguages(for bundle: Bundle) -> [String] {
        // Finder Sync is a separate process. It must read the host app's
        // explicit AppleLanguages override rather than this extension's list.
        for bundleIdentifier in preferenceBundleIdentifiers(for: bundle) {
            if let appleLanguages = explicitAppleLanguages(forBundleIdentifier: bundleIdentifier) {
                return appleLanguages
            }
        }

        return Locale.preferredLanguages
    }

    private static func preferenceBundleIdentifiers(for bundle: Bundle) -> [String] {
        guard let bundleIdentifier = bundle.bundleIdentifier else {
            return []
        }

        return preferenceBundleIdentifiers(forBundleIdentifier: bundleIdentifier)
    }

    private static func preferenceBundleIdentifiers(forBundleIdentifier bundleIdentifier: String) -> [String] {
        if bundleIdentifier.hasSuffix(finderSyncBundleSuffix) {
            let hostBundleIdentifier = String(bundleIdentifier.dropLast(finderSyncBundleSuffix.count))
            return [hostBundleIdentifier, bundleIdentifier]
        }

        return [bundleIdentifier]
    }

    private static func explicitAppleLanguages(forBundleIdentifier bundleIdentifier: String) -> [String]? {
        let applicationID = bundleIdentifier as CFString
        CFPreferencesAppSynchronize(applicationID)
        guard
            let value = CFPreferencesCopyValue(
                appleLanguagesKey as CFString,
                applicationID,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            ) as? [String],
            !value.isEmpty
        else {
            return nil
        }

        return value
    }
}

struct RightClickPathFormatter {
    static func relativePath(of target: URL, to base: URL) -> String {
        let baseComponents = base.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let targetComponents = target.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var sharedCount = 0

        while sharedCount < baseComponents.count,
              sharedCount < targetComponents.count,
              baseComponents[sharedCount] == targetComponents[sharedCount] {
            sharedCount += 1
        }

        let upCount = max(0, baseComponents.count - sharedCount)
        let downComponents = targetComponents.dropFirst(sharedCount)
        let components = Array(repeating: "..", count: upCount) + Array(downComponents)
        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    static func joinedPaths(_ urls: [URL]) -> String {
        urls.map(\.path).joined(separator: "\n")
    }

    static func joinedFileNames(_ urls: [URL]) -> String {
        urls.map(\.lastPathComponent).joined(separator: "\n")
    }

    static func joinedRelativePaths(_ urls: [URL], base: URL?) -> String {
        urls
            .map { url in
                guard let base else {
                    return url.path
                }

                return relativePath(of: url, to: base)
            }
            .joined(separator: "\n")
    }

    /// Shell-escaped paths, space-separated so the whole line can be pasted as
    /// terminal arguments.
    static func joinedShellEscapedPaths(_ urls: [URL]) -> String {
        urls.map { shellEscaped($0.path) }.joined(separator: " ")
    }

    static func joinedFileURLs(_ urls: [URL]) -> String {
        urls.map(\.absoluteString).joined(separator: "\n")
    }

    /// Single-quote wrap, with embedded single quotes escaped as `'\''`.
    static func shellEscaped(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension RightClickSelection {
    /// Capture exactly the items belonging to this menu; never consult Finder again.
    static func capture(urls: [URL], directory: URL?, relativeBase: URL? = nil) throws -> Self {
        let items = try urls.map { url -> RightClickSelectionItem in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey, .isSymbolicLinkKey])
            return RightClickSelectionItem(url: url, isDirectory: values.isDirectory == true,
                isPackage: values.isPackage == true, isImage: values.contentType?.conforms(to: .image) == true)
        }
        if let directory, try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true {
            throw RightClickFailure(message: "Folder is unavailable.", path: directory.path)
        }
        return Self(items: items, directory: directory, relativeBase: relativeBase ?? directory)
    }
}
