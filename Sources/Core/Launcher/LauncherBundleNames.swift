import Foundation

/// Reads system-provided bundle names without loading bundle executables.
enum LauncherBundleNames {
    static var systemLanguages: [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
            ?? Locale.preferredLanguages
    }

    static func read(for url: URL, fallbackName: String, preferredLanguages: [String]? = nil,
                     fileManager: FileManager = .default) -> (name: String, alternates: [String]) {
        let fallback = fallbackName
        guard let bundle = Bundle(url: url) else { return (fallback, []) }
        let base = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String) ?? fallback
        let resources = url.appendingPathComponent("Contents/Resources")
        let table = (try? Data(contentsOf: resources.appendingPathComponent("InfoPlist.loctable")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: [String: String]] } ?? [:]
        let languages = preferredLanguages
            ?? UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
            ?? Locale.preferredLanguages
        let development = (bundle.infoDictionary?["CFBundleDevelopmentRegion"] as? String ?? "en").lowercased()
        var names: [String] = []
        for language in languages + ["en"] {
            let codes = languageCodes(language)
            var localized: String?
            for code in codes {
                var values = table[code] ?? [:]
                let path = resources.appendingPathComponent(code + ".lproj/InfoPlist.strings")
                if let data = try? Data(contentsOf: path),
                   let strings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] {
                    values.merge(strings, uniquingKeysWith: { _, explicit in explicit })
                }
                if let title = values["CFBundleDisplayName-macos"] ?? values["CFBundleDisplayName"]
                    ?? values["CFBundleName-macos"] ?? values["CFBundleName"], !title.isEmpty { localized = title; break }
            }
            if let localized { names.append(localized) }
            else if codes.contains(development) || (codes.contains("en") && development == "english") { names.append(base) }
        }
        let name = names.first ?? fallback
        let fileName = url.pathExtension == "app" ? String(url.lastPathComponent.dropLast(4)) : url.deletingPathExtension().lastPathComponent
        let alternates = Array(Set(names + [base, fallback, fileName])).filter { $0 != name }.sorted()
        return (name, alternates)
    }
    private static func languageCodes(_ language: String) -> [String] {
        let canonical = language.replacingOccurrences(of: "_", with: "-")
        var codes = [canonical, canonical.replacingOccurrences(of: "-", with: "_")]
        if canonical.hasPrefix("zh") {
            let traditional = canonical.contains("Hant") || ["TW", "HK", "MO"].contains(canonical.split(separator: "-").last.map(String.init) ?? "")
            codes += traditional ? ["zh-Hant", "zh_TW", "zh-HK"] : ["zh-Hans", "zh_CN"]
        }
        if let base = canonical.split(separator: "-").first { codes.append(String(base)) }
        return codes
    }

}
