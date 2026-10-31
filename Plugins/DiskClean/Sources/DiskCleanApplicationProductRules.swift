import Foundation

/// Exact, product-specific leaves researched from the upstream Homebrew Cask registry.
/// Aliases only discover review candidates; they never grant removal authority.
struct DiskCleanApplicationProductRule: Sendable {
    struct Location: Sendable {
        let relativePath: String
        let category: DiskCleanApplicationFileCategory
        var personal = true
        var reviewOnly = false
    }
    let bundleID: String
    let aliases: Set<String>
    let locations: [Location]
}

enum DiskCleanApplicationProductRules {
    private static func support(_ name: String, reviewOnly: Bool = false) -> DiskCleanApplicationProductRule.Location {
        .init(relativePath: "Library/Application Support/" + name, category: .support, reviewOnly: reviewOnly)
    }
    private static func cache(_ name: String, personal: Bool = false) -> DiskCleanApplicationProductRule.Location {
        .init(relativePath: "Library/Caches/" + name, category: .caches, personal: personal)
    }
    private static func log(_ name: String) -> DiskCleanApplicationProductRule.Location {
        .init(relativePath: "Library/Logs/" + name, category: .caches, personal: false)
    }
    private static func hidden(_ path: String) -> DiskCleanApplicationProductRule.Location {
        .init(relativePath: path, category: .support, reviewOnly: true)
    }
    static let all: [DiskCleanApplicationProductRule] = [
        .init(bundleID: "com.microsoft.VSCode", aliases: ["Visual Studio Code", "Code"],
              locations: [support("Code"), hidden(".vscode")]),
        .init(bundleID: "com.microsoft.VSCodeInsiders", aliases: ["Visual Studio Code - Insiders", "Code - Insiders"],
              locations: [support("Code - Insiders"), hidden(".vscode-insiders")]),
        .init(bundleID: "com.todesktop.230313mzl4w4u92", aliases: ["Cursor"],
              locations: [support("Cursor"), .init(relativePath: "Library/Application Support/Caches/cursor-updater", category: .caches, personal: false), log("Cursor")]),
        .init(bundleID: "com.tinyspeck.slackmacgap", aliases: ["Slack"], locations: [support("Slack"), log("Slack")]),
        .init(bundleID: "com.hnc.Discord", aliases: ["Discord"], locations: [support("discord")]),
        .init(bundleID: "com.figma.Desktop", aliases: ["Figma"], locations: [support("Figma"), support("figma-desktop")]),
        .init(bundleID: "com.postmanlabs.mac", aliases: ["Postman"], locations: [support("Postman"), support("com.postmanlabs.mac.ShipIt"), cache("Postman")]),
        .init(bundleID: "com.google.Chrome", aliases: ["Google Chrome", "Chrome"], locations: [support("Google/Chrome"), cache("Google/Chrome")]),
        .init(bundleID: "com.google.Chrome.beta", aliases: ["Google Chrome Beta"], locations: [support("Google/Chrome Beta"), cache("Google/Chrome Beta")]),
        .init(bundleID: "com.google.Chrome.canary", aliases: ["Google Chrome Canary"], locations: [support("Google/Chrome Canary"), cache("Google/Chrome Canary")]),
        .init(bundleID: "com.microsoft.edgemac", aliases: ["Microsoft Edge"], locations: [support("Microsoft Edge"), cache("Microsoft Edge"), support("Microsoft/EdgeUpdater", reviewOnly: true)]),
        .init(bundleID: "com.brave.Browser", aliases: ["Brave Browser", "Brave"], locations: [support("BraveSoftware/Brave-Browser"), cache("BraveSoftware/Brave-Browser")]),
        // Other Firefox editions can share profiles and update data.
        .init(bundleID: "org.mozilla.firefox", aliases: ["Firefox"], locations: [support("Firefox", reviewOnly: true), .init(relativePath: "Library/Caches/Firefox", category: .caches, reviewOnly: true), .init(relativePath: "Library/Caches/Mozilla/updates/Applications/Firefox", category: .caches, reviewOnly: true)]),
        .init(bundleID: "notion.id", aliases: ["Notion"], locations: [support("Notion"), .init(relativePath: "Library/Application Support/Caches/notion-updater", category: .caches, personal: false), log("Notion")]),
        .init(bundleID: "md.obsidian", aliases: ["Obsidian"], locations: [support("obsidian")]),
        .init(bundleID: "us.zoom.xos", aliases: ["zoom.us", "Zoom"], locations: [support("zoom.us"), support("ZoomUpdater", reviewOnly: true), log("zoom.us")]),
        .init(bundleID: "dev.zcode.app", aliases: ["ZCode"], locations: [support("ZCode"), cache("@zcodedesktop-updater")]),
        .init(bundleID: "cn.apifox.app", aliases: ["Apifox"], locations: [support("apifox")]),
        .init(bundleID: "com.spotify.client", aliases: ["Spotify"], locations: [support("Spotify"), log("Spotify")]),
        .init(bundleID: "ru.keepcoder.Telegram", aliases: ["Telegram"], locations: []),
        .init(bundleID: "com.tencent.xinWeChat", aliases: ["WeChat", "微信"], locations: []),
        .init(bundleID: "com.tencent.qq", aliases: ["QQ"], locations: []),
        .init(bundleID: "com.tencent.QQMusicMac", aliases: ["QQMusic", "QQ音乐"], locations: []),
        .init(bundleID: "com.tencent.WeWorkMac", aliases: ["WeCom", "WeChatWork", "企业微信"], locations: [])
    ]

    static func rule(for bundleID: String) -> DiskCleanApplicationProductRule? {
        all.first { $0.bundleID == bundleID }
    }

    static func isExclusive(_ path: String, to bundleID: String) -> Bool {
        guard let rule = rule(for: bundleID), rule.locations.contains(where: { $0.relativePath == path && !$0.reviewOnly }) else { return false }
        return !all.contains { other in
            other.bundleID != bundleID && other.locations.contains {
                let candidate = $0.relativePath.lowercased()
                let selected = path.lowercased()
                return candidate == selected || candidate.hasPrefix(selected + "/") || selected.hasPrefix(candidate + "/")
            }
        }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.contains(where: { "*?[]".contains($0) }), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        let roots = ["Library/Application Support/", "Library/Caches/", "Library/Logs/", ".config/", ".cache/", ".local/share/"]
        let vendors: Set<String> = ["Google", "Microsoft", "Tencent", "Adobe", "Mozilla", "JetBrains", "Avid", "BraveSoftware", "Caches"]
        if [".vscode", ".vscode-insiders"].contains(path) { return true }
        guard let root = roots.first(where: { path.hasPrefix($0) }) else { return false }
        let leaf = String(path.dropFirst(root.count))
        return !leaf.isEmpty && !vendors.contains(where: { $0.caseInsensitiveCompare(leaf) == .orderedSame })
    }
}

struct DiskCleanApplicationProductProof: Equatable, Sendable {
    let home: String
    let bundleID: String
    let relativePath: String

    func permits(_ path: String) -> Bool {
        guard DiskCleanApplicationProductRules.isSafeRelativePath(relativePath),
              DiskCleanApplicationProductRules.isExclusive(relativePath, to: bundleID) else { return false }
        return DiskCleanPhysicalPath.resolve(home + "/" + relativePath) == path
    }
}

enum DiskCleanApplicationNameVariants {
    static func make(_ seeds: Set<String>) -> Set<String> {
        let forbidden: Set<String> = ["library", "application support", "caches", "logs", "preferences", "microsoft", "google", "tencent", "adobe", "mozilla", "electron", "helper", "config", "cache", "share"]
        func valid(_ name: String) -> Bool {
            name.count >= 2 && name.count <= 100 && !name.contains("/") && !name.contains("\\")
                && !name.contains("..") && !name.hasPrefix(".") && !forbidden.contains(name.lowercased())
                && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        var result = Set<String>()
        for seed in seeds.sorted().filter({ valid($0.trimmingCharacters(in: .whitespacesAndNewlines)) }).prefix(16) {
            let name = seed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard valid(name) else { continue }
            let separated = name.replacingOccurrences(of: #"[\s_-]+"#, with: " ", options: .regularExpression)
            var bases = [name, separated]
            var stripped = name
            for _ in 0..<3 {
                let next = stripped.replacingOccurrences(of: #"(?i)(?:[\s_-]+(?:nightly|beta|alpha|dev|canary|preview|insiders?|stable|release|rc|lts|developer edition|technology preview)|[\s_-]+v?\d+(?:\.\d+){0,3})$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
                guard valid(next), next != stripped else { break }
                bases.append(next)
                stripped = next
            }
            for base in bases {
                for variant in [base, base.replacingOccurrences(of: " ", with: ""), base.replacingOccurrences(of: " ", with: "-"), base.replacingOccurrences(of: " ", with: "_")] {
                    if valid(variant) { result.insert(variant); result.insert(variant.lowercased()) }
                }
            }
        }
        return result
    }
}
