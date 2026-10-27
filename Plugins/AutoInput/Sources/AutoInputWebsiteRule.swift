import Foundation

enum AutoInputWebsiteMatch: String, Codable, CaseIterable, Identifiable {
    case domainSuffix
    case domain
    case urlRegex

    var id: String { rawValue }
}

struct AutoInputWebsiteRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var browserBundleIdentifier = ""
    var match: AutoInputWebsiteMatch = .domainSuffix
    var pattern = ""
    var inputSourceID = ""
    var isEnabled = true

    var isValid: Bool {
        guard !inputSourceID.isEmpty, !pattern.isEmpty, pattern.count <= 512 else { return false }
        if match == .urlRegex {
            return (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)) != nil
        }
        return Self.normalizedDomain(pattern) != nil
    }

    func matches(_ url: URL, browserBundleIdentifier: String) -> Bool {
        guard isEnabled, isValid,
              self.browserBundleIdentifier.isEmpty || self.browserBundleIdentifier == browserBundleIdentifier,
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        else { return false }

        switch match {
        case .domain:
            return host == Self.normalizedDomain(pattern)
        case .domainSuffix:
            guard let domain = Self.normalizedDomain(pattern) else { return false }
            return host == domain || host.hasSuffix(".\(domain)")
        case .urlRegex:
            guard url.absoluteString.utf16.count <= 8192,
                  let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            else { return false }
            // ICU progress callbacks bound user-authored expressions on long addresses.
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(25))
            var found = false
            expression.enumerateMatches(
                in: url.absoluteString,
                options: .reportProgress,
                range: NSRange(url.absoluteString.startIndex..., in: url.absoluteString)
            ) { result, _, stop in
                if ContinuousClock.now >= deadline {
                    stop.pointee = true
                } else if result != nil {
                    found = true
                    stop.pointee = true
                }
            }
            return found
        }
    }

    static func normalizedDomain(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: "https://\(value)"),
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.query == nil, components.fragment == nil,
              let host = components.url?.host, !host.isEmpty
        else { return nil }
        return host.lowercased()
    }
}

struct AutoInputBrowser: Identifiable {
    let id: String
    let name: String

    static let supported: [Self] = [
        .init(id: "com.apple.Safari", name: "Safari"),
        .init(id: "com.apple.SafariTechnologyPreview", name: "Safari Technology Preview"),
        .init(id: "com.google.Chrome", name: "Google Chrome"),
        .init(id: "com.google.Chrome.beta", name: "Google Chrome Beta"),
        .init(id: "com.google.Chrome.canary", name: "Google Chrome Canary"),
        .init(id: "org.chromium.Chromium", name: "Chromium"),
        .init(id: "com.microsoft.edgemac", name: "Microsoft Edge"),
        .init(id: "com.brave.Browser", name: "Brave"),
        .init(id: "com.vivaldi.Vivaldi", name: "Vivaldi"),
        .init(id: "com.operasoftware.Opera", name: "Opera"),
        .init(id: "company.thebrowser.Browser", name: "Arc"),
        .init(id: "company.thebrowser.dia", name: "Dia"),
        .init(id: "org.mozilla.firefox", name: "Firefox"),
        .init(id: "org.mozilla.firefoxdeveloperedition", name: "Firefox Developer Edition"),
        .init(id: "org.mozilla.nightly", name: "Firefox Nightly"),
        .init(id: "app.zen-browser.zen", name: "Zen"),
        .init(id: "net.imput.helium", name: "Helium"),
        .init(id: "ai.perplexity.comet", name: "Comet"),
        .init(id: "com.naver.Whale", name: "Whale"),
        .init(id: "com.citrolabs.ego.lite", name: "ego lite"),
        .init(id: "com.tab-browser.Tabbit", name: "Tabbit Browser"),
        .init(id: "com.quark.desktop", name: "Quark"),
    ]

    static func supports(_ bundleIdentifier: String) -> Bool {
        supported.contains { $0.id == bundleIdentifier }
    }
}

struct AutoInputBrowserContext: Equatable, Sendable {
    let bundleIdentifier: String
    let processIdentifier: pid_t
    var url: URL?
    var isAddressBarFocused = false
    var permissionDenied = false
}

@MainActor
protocol AutoInputBrowserObserving: AnyObject {
    var onContextChange: ((AutoInputBrowserContext) -> Void)? { get set }
    func observe(_ application: AutoInputApplication)
    func stop()
}
