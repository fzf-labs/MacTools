import Foundation
import XCTest
@testable import DiskCleanPlugin

final class DiskCleanApplicationProductRulesTests: XCTestCase {
    func testCuratedLeavesKeepChannelsAndVendorSiblingsSeparate() throws {
        let root = try DiskCleanTempDirectory(name: "ProductLeaves")
        defer { root.remove() }
        let chrome = try root.makeDirectory("Library/Application Support/Google/Chrome").path
        let beta = try root.makeDirectory("Library/Application Support/Google/Chrome Beta").path
        let other = try root.makeDirectory("Library/Application Support/Google/Other").path
        let resolver = DiskCleanApplicationOwnership(home: root.path)
        let result = resolver.resolve(bundleID: "com.google.Chrome.beta", identity: .init(ids: ["com.google.Chrome.beta"]))
        XCTAssertTrue(result.report.hasProductRule)
        XCTAssertEqual(result.associations.map(\.path), [beta])
        let proof = try XCTUnwrap(result.associations.first?.proof)
        XCTAssertNil(proof.rejection(at: beta))
        XCTAssertNotNil(proof.rejection(at: chrome))
        XCTAssertFalse(result.associations.contains { $0.path == other })
        XCTAssertTrue(resolver.suspectedBundleIDs().isSuperset(of: ["com.google.Chrome", "com.google.Chrome.beta"]))
    }

    func testZCodeSupportAndUpdaterLeavesHaveExactProductEvidence() throws {
        let root = try DiskCleanTempDirectory(name: "ZCodeLeaves")
        defer { root.remove() }
        let support = try root.makeDirectory("Library/Application Support/ZCode").path
        let updater = try root.makeDirectory("Library/Caches/@zcodedesktop-updater").path
        try root.makeDirectory("Library/Application Support/ZCode Other")
        try root.makeDirectory("Library/Caches/@other-updater")
        let result = DiskCleanApplicationOwnership(home: root.path)
            .resolve(bundleID: "dev.zcode.app", identity: .init(ids: ["dev.zcode.app"]))
        XCTAssertEqual(Set(result.associations.map(\.path)), [support, updater])
        XCTAssertTrue(result.associations.allSatisfy { $0.manualReason == nil && $0.proof?.product != nil })
        XCTAssertEqual(result.associations.first { $0.path == support }?.isPersonal, true)
        XCTAssertEqual(result.associations.first { $0.path == updater }?.isPersonal, false)
        let lowerAlias = root.resolve("Library/Application Support/zcode").path
        if FileManager.default.fileExists(atPath: lowerAlias) {
            let row = try XCTUnwrap(result.associations.first { $0.path == support })
            XCTAssertTrue(row.logicalPaths.contains(lowerAlias))
            XCTAssertTrue(row.proof?.logicalPaths.contains(lowerAlias) == true)
        }

    }

    func testHiddenAndSharedRulesCannotAuthorizeRemoval() throws {
        let root = try DiskCleanTempDirectory(name: "SharedProductLeaves")
        defer { root.remove() }
        let hidden = try root.makeDirectory(".vscode").path
        let firefox = try root.makeDirectory("Library/Application Support/Firefox").path
        let code = try root.makeDirectory("Library/Application Support/Code").path
        let resolver = DiskCleanApplicationOwnership(home: root.path)
        let codeResult = resolver.resolve(bundleID: "com.microsoft.VSCode", identity: .init(ids: ["com.microsoft.VSCode"]))
        XCTAssertNotNil(codeResult.associations.first { $0.path == hidden }?.manualReason)
        XCTAssertNotNil(codeResult.associations.first { $0.path == hidden }?.proof?.rejection(at: hidden))
        XCTAssertNil(codeResult.associations.first { $0.path == code }?.manualReason)
        let firefoxResult = resolver.resolve(bundleID: "org.mozilla.firefox", identity: .init(ids: ["org.mozilla.firefox"]))
        XCTAssertNotNil(firefoxResult.associations.first { $0.path == firefox }?.manualReason)
        XCTAssertFalse(resolver.suspectedBundleIDs().contains("org.mozilla.firefox"))
        let claimed = resolver.resolve(bundleID: "com.microsoft.VSCode", identity: .init(ids: ["com.microsoft.VSCode"]), otherOwners: ["com.microsoft.VSCode"])
        XCTAssertNotNil(claimed.associations.first { $0.path == code }?.manualReason)
        XCTAssertTrue(DiskCleanApplicationProductRules.all.allSatisfy { rule in
            rule.locations.allSatisfy { DiskCleanApplicationProductRules.isSafeRelativePath($0.relativePath) }
        })
        for invalid in ["../Library/Caches", "/Library/Caches/App", "Library/Application Support/Google", "Library/Caches/Microsoft", "Library/Application Support/google", "Library/Caches/[ab]", ".config/", ".cache/../secrets", "Library/Caches/*"] {
            XCTAssertFalse(DiskCleanApplicationProductRules.isSafeRelativePath(invalid), invalid)
        }
    }

    func testNameVariantsExpandDiscoveryWithoutGrantingOwnership() throws {
        let root = try DiskCleanTempDirectory(name: "NameVariants")
        defer { root.remove() }
        let variants = DiskCleanApplicationNameVariants.make(["Example Editor Beta 2.1", "../Secrets", ".ssh", "Google", "Example_Editor"])
        XCTAssertTrue(variants.isSuperset(of: ["Example Editor", "example_editor", "Example-Editor", "ExampleEditor"]))
        XCTAssertFalse(variants.contains("Google"))
        XCTAssertFalse(variants.contains(where: { $0.contains("/") || $0.hasPrefix(".") }))
        let hidden = try root.makeDirectory(".config/example_editor").path
        let legacy = try root.makeDirectory("Library/Application Support/Example_Editor").path
        let secret = try root.makeDirectory(".exampleeditor").path
        let result = DiskCleanApplicationOwnership(home: root.path).resolve(bundleID: "org.example.editor",
            identity: .init(ids: ["org.example.editor"], names: ["Example Editor Beta 2.1"]))
        XCTAssertFalse(result.report.hasProductRule)
        XCTAssertEqual(Set(result.associations.map { $0.path.lowercased() }), Set([hidden, legacy].map { $0.lowercased() }))
        XCTAssertTrue(result.associations.allSatisfy { $0.manualReason != nil && $0.isPersonal })
        XCTAssertFalse(result.associations.contains { $0.path == secret })
        XCTAssertTrue(result.report.checks.contains { $0.path == hidden && $0.source == .name && $0.state == .checked })
    }

    func testCoverageKeepsMissingDeniedAndIncompleteLocationsDistinct() throws {
        let root = try DiskCleanTempDirectory(name: "DetailedCoverage")
        defer { root.remove() }
        try root.makeFile("Library/Preferences/ByHost", bytes: 1)
        let resolver = DiskCleanApplicationOwnership(home: root.path)
        let id = "org.example.editor"
        let result = resolver.resolve(bundleID: id, identity: .init(ids: [id], isComplete: false), claimsComplete: false)
        XCTAssertTrue(result.report.checks.contains { $0.path == root.resolve("Library/Caches/" + id).path && $0.state == .missing })
        XCTAssertTrue(result.report.checks.contains { $0.path == root.resolve("Library/Preferences/ByHost").path && $0.state == .incomplete })
        XCTAssertTrue(result.report.checks.contains { $0.path == root.resolve("Library/Containers").path && $0.state == .permissionRequired })
        XCTAssertFalse(result.report.identityComplete)
        XCTAssertFalse(result.report.claimsComplete)
        var report = DiskCleanApplicationScanReport()
        report.record(path: "/example", category: .support, source: .productRule, state: .permissionRequired)
        report.record(path: "/example", category: .support, source: .name, state: .checked)
        report.record(path: "/example", category: .support, source: .productRule, state: .incomplete)
        XCTAssertEqual(report.checks.count, 1)
        XCTAssertEqual(report.checks.first?.state, .permissionRequired)
    }
}
