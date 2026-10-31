import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanWhitelistStoreTests: XCTestCase {
    private let home = "/Users/tester"

    func testUninstallOmitsDefaultRetentionButPreservesCustomAndSensitiveProtection() {
        let policy = DiskCleanSafetyPolicy(homeDirectory: home, whitelistStore: .init(homeDirectory: home,
            customRules: ["$HOME/Library/Caches/Customer/*"]))
        let application = DiskCleanReviewValidation.application(bundleID: "org.example.fixture", roots: [],
            bundlePath: "/Applications/Fixture.app", isBundle: true)
        let uninstall = policy.forReview(application)
        for path in [home + "/Library/Caches/JetBrains.Fixture", "/Applications/Fixture.app/.DS_Store"] {
            XCTAssertFalse(policy.safetyStatus(for: path).isCleanable)
            XCTAssertTrue(uninstall.safetyStatus(for: path).isCleanable)
            for evidence: DiskCleanReviewValidation? in [nil, .cache(bundleID: "org.example.fixture"),
                .leftover(bundleID: "org.example.fixture", roots: []), .project, .installer] {
                XCTAssertFalse(policy.forReview(evidence).safetyStatus(for: path).isCleanable)
            }
        }
        XCTAssertFalse(uninstall.safetyStatus(for: home + "/Library/Caches/Customer/data").isCleanable)
        XCTAssertFalse(uninstall.safetyStatus(for: home + "/Library/Caches/A", alsoChecking: [home + "/Library/Caches/Customer/data"]).isCleanable)
        XCTAssertFalse(uninstall.safetyStatus(for: home + "/.ssh/id_ed25519").isCleanable)
        XCTAssertFalse(uninstall.safetyStatus(for: home + "/Library/Keychains/login.keychain-db").isCleanable)
        XCTAssertFalse(uninstall.safetyStatus(for: "/System/Library/CoreServices").isCleanable)
    }

    func testDefaultRulesIncludeMoleProtectedCleanEntries() {
        let store = DiskCleanWhitelistStore(homeDirectory: home)
        let rules = Set(store.expandedRules().map(\.expandedPattern))

        XCTAssertTrue(rules.contains("\(home)/Library/Caches/ms-playwright*"))
        XCTAssertTrue(rules.contains("\(home)/.cache/huggingface*"))
        XCTAssertTrue(rules.contains("\(home)/.m2/repository/*"))
        XCTAssertTrue(rules.contains("\(home)/.gradle/caches/*"))
        XCTAssertTrue(rules.contains("\(home)/.gradle/daemon/*"))
        XCTAssertTrue(rules.contains("\(home)/.ollama/models/*"))
        XCTAssertTrue(rules.contains("\(home)/Library/Caches/com.nssurge.surge-mac/*"))
        XCTAssertTrue(rules.contains("\(home)/Library/Application Support/com.nssurge.surge-mac/*"))
        XCTAssertTrue(rules.contains("\(home)/Library/Caches/org.R-project.R/R/renv/*"))
        XCTAssertTrue(rules.contains("\(home)/Library/Caches/JetBrains*"))
        XCTAssertTrue(rules.contains("\(home)/Library/Application Support/JetBrains*"))
        XCTAssertTrue(rules.contains("\(home)/Library/Caches/com.apple.FontRegistry*"))
        XCTAssertTrue(rules.contains("\(home)/Library/Caches/com.apple.spotlight*"))
        XCTAssertTrue(rules.contains("\(home)/Library/Caches/com.apple.Spotlight*"))
        XCTAssertTrue(rules.contains("\(home)/Library/Caches/CloudKit*"))
        XCTAssertTrue(rules.contains("\(home)/Library/Mobile Documents*"))
        XCTAssertTrue(rules.contains(DiskCleanWhitelistStore.finderMetadataSentinel))
    }

    func testExpandsHomeFormsAndCollapsesDuplicates() {
        let store = DiskCleanWhitelistStore(
            homeDirectory: home,
            includeDefaults: false,
            customRules: [
                "~/Library/Caches/Foo",
                "$HOME/Library/Caches/Foo",
                "${HOME}/Library/Caches/Foo",
                "\(home)/Library/Caches/Foo"
            ]
        )

        XCTAssertEqual(store.expandedRules().map(\.expandedPattern), ["\(home)/Library/Caches/Foo"])
    }

    func testRejectsInvalidCustomRules() {
        let store = DiskCleanWhitelistStore(homeDirectory: home, includeDefaults: false)

        XCTAssertThrowsError(try store.validateCustomRule("Library/Caches/Foo"))
        XCTAssertThrowsError(try store.validateCustomRule("\(home)/Library/../Secrets"))
        XCTAssertThrowsError(try store.validateCustomRule("\(home)/Library/Caches/Foo\nBar"))
        XCTAssertThrowsError(try store.validateCustomRule("/"))
        XCTAssertThrowsError(try store.validateCustomRule("/System/Library/Caches"))
        XCTAssertThrowsError(try store.validateCustomRule("/Library/Extensions"))
    }

    func testMatchesGlobParentChildAndFinderMetadataSentinel() {
        let store = DiskCleanWhitelistStore(
            homeDirectory: home,
            includeDefaults: false,
            customRules: [
                "\(home)//Library//Application Support/Google/Chrome/Default/Service Worker/CacheStorage",
                "\(home)/Library/Caches/org.R-project.R/R/renv/*",
                "\(home)/Library/Caches/Customer/*",
                DiskCleanWhitelistStore.finderMetadataSentinel
            ]
        )

        XCTAssertNotNil(store.matchingRule(for: "\(home)/Library/Application Support/Google/Chrome/Default//Service Worker/CacheStorage"))
        XCTAssertNotNil(store.matchingRule(for: "\(home)/Library/Caches/org.R-project.R"))
        XCTAssertNotNil(store.matchingRule(for: "\(home)/Library/Caches/Customer/cbbim-w-prod.mat"))
        XCTAssertNotNil(store.matchingRule(for: "\(home)/Documents/.DS_Store"))
        XCTAssertNil(store.matchingRule(for: "\(home)/Library/Caches/Other/extra.dat"))
    }
}
