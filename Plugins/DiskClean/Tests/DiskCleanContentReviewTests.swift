import Foundation
import XCTest
@testable import DiskCleanPlugin

final class DiskCleanContentReviewTests: XCTestCase {
    func testFinderMetadataFollowsUninstallButExplicitProtectionStillReportsItsPath() throws {
        let root = try DiskCleanTempDirectory(name: "UninstallMetadata")
        defer { root.remove() }
        let metadata = try root.makeFile("Fixture.app/Contents/.DS_Store", bytes: 8)
        let path = root.resolve("Fixture.app").path
        let evidence = DiskCleanReviewValidation.application(bundleID: "org.example.fixture", roots: [], bundlePath: path, isBundle: true)
        let policy = DiskCleanSafetyPolicy(homeDirectory: root.path)
        XCTAssertNotNil(DiskCleanContentReview(policy: policy).inspect(path: path).rejection)
        let report = DiskCleanContentReview(policy: policy.forReview(evidence)).inspect(path: path)
        XCTAssertNil(report.rejection)
        XCTAssertEqual(report.inspection?.measurement?.estimatedBytes, 8)
        let custom = DiskCleanSafetyPolicy(homeDirectory: root.path, whitelistStore: .init(homeDirectory: root.path,
            customRules: [DiskCleanWhitelistStore.finderMetadataSentinel]))
        let protected = DiskCleanContentReview(policy: custom.forReview(evidence)).inspect(path: path)
        XCTAssertTrue(protected.rejection?.contains(metadata.path) == true)
    }

    func testProtectedDescendantsAndNestedRepositoriesBlockWholeDirectory() throws {
        let root = try DiskCleanTempDirectory(name: "ContentReview")
        defer { root.remove() }
        let cases = ["project/build/nested/.git/config", "project/build/target-keypair.json", "data/.ssh/key"]
        for relative in cases {
            let sandbox = try root.makeDirectory(UUID().uuidString)
            let file = sandbox.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
            let report = DiskCleanContentReview(policy: .init(homeDirectory: sandbox.path), project: true).inspect(path: sandbox.path)
            XCTAssertNotNil(report.rejection, relative)
        }
    }

    func testIncompleteInspectionDoesNotAuthorizeRemovalAndDoesNotFollowLinks() throws {
        let root = try DiskCleanTempDirectory(name: "ContentReview")
        defer { root.remove() }
        try root.makeFile("build/cache", bytes: 8)
        let limited = DiskCleanContentReview(policy: .init(), project: true, maximumEntries: 0).inspect(path: root.resolve("build").path)
        XCTAssertNotNil(limited.rejection)
        try root.makeDirectory("outside/.git")
        try FileManager.default.createSymbolicLink(atPath: root.resolve("build/link").path, withDestinationPath: root.resolve("outside").path)
        let reviewed = DiskCleanContentReview(policy: .init(), project: true).inspect(path: root.resolve("build").path)
        XCTAssertNil(reviewed.rejection)
    }

    func testFrameworkAndVirtualEnvironmentRequireProjectEvidence() throws {
        let root = try DiskCleanTempDirectory(name: "ProjectRecognition")
        defer { root.remove() }
        try root.makeDirectory("project/.venv")
        let path = root.resolve("project").path
        XCTAssertFalse(DiskCleanProjectRecognition.matches(kind: .pythonDotEnvironment, parent: path))
        try Data("[project]".utf8).write(to: URL(fileURLWithPath: path + "/pyproject.toml"))
        XCTAssertFalse(DiskCleanProjectRecognition.matches(kind: .pythonDotEnvironment, parent: path))
        try Data("home = /python".utf8).write(to: URL(fileURLWithPath: path + "/.venv/pyvenv.cfg"))
        XCTAssertTrue(DiskCleanProjectRecognition.matches(kind: .pythonDotEnvironment, parent: path))
        try Data("{\"dependencies\":{\"next\":\"15\"}}".utf8).write(to: URL(fileURLWithPath: path + "/package.json"))
        XCTAssertTrue(DiskCleanProjectRecognition.matches(kind: .nextOutput, parent: path))
        XCTAssertFalse(DiskCleanProjectRecognition.matches(kind: .nuxtOutput, parent: path))
        XCTAssertFalse(DiskCleanProjectRecognition.matches(kind: .composerVendor, parent: path))
    }
}
