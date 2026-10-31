import Foundation
import XCTest
@testable import DiskCleanPlugin

final class DiskCleanApplicationOwnershipTests: XCTestCase {
    func testFiveCategoryReviewIncludesByHostAndMetadataOwnedUUIDContainer() async throws {
        let root = try DiskCleanTempDirectory(name: "ApplicationCategories")
        defer { root.remove() }
        let id = "org.example.editor"
        let app = try root.makeDirectory("Apps/Editor.app/Contents").deletingLastPathComponent()
        try plist(["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"], to: app.appendingPathComponent("Contents/Info.plist"))
        try root.makeFile("Home/Library/Application Support/" + id + "/settings", bytes: 2)
        try root.makeFile("Home/Library/Caches/" + id + "/cache", bytes: 3)
        try root.makeFile("Home/Library/Preferences/ByHost/" + id + "." + UUID().uuidString + ".plist", bytes: 4)
        try root.makeFile("Home/Library/HTTPStorages/" + id + "/data", bytes: 5)
        let container = try root.makeDirectory("Home/Library/Containers/" + UUID().uuidString)
        try plist(["MCMMetadataIdentifier": id], to: container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        let resolver = DiskCleanApplicationOwnership(home: root.resolve("Home").path, includeContainers: true)
        let owned = resolver.resolve(bundleID: id, identity: .init(ids: [id]))
        XCTAssertEqual(Set(owned.associations.map(\.category)), [.support, .caches, .preferences, .sandbox])
        XCTAssertTrue(owned.associations.contains { $0.path == container.path && $0.proof?.containerOwner == id })
        XCTAssertEqual(owned.coverage[.sandbox], .checked)
        let inventory = await DiskCleanApplicationInventory(roots: [root.resolve("Apps").path]).scan()
        let review = await DiskCleanApplicationReviewBuilder(home: root.resolve("Home").path,
            roots: [root.resolve("Apps").path], leftovers: false, inventorySnapshot: inventory).prepare()
        XCTAssertEqual(Set(review.rows.map(\.category)), [.application, .support, .caches, .preferences, .sandbox])
        XCTAssertTrue(review.rows.filter { $0.category == .support || $0.category == .preferences }.allSatisfy(\.isPersonal))
    }

    func testSharedClaimsGroupsAndNameMatchesCannotAuthorizeRemoval() throws {
        let root = try DiskCleanTempDirectory(name: "SharedOwnership")
        defer { root.remove() }
        let id = "org.example.editor"
        let extensionID = id + ".share"
        try root.makeFile("Library/Caches/" + extensionID + "/cache", bytes: 3)
        try root.makeFile("Library/Application Support/Example Editor/data", bytes: 3)
        try root.makeFile("Library/Group Containers/group.org.example.shared/data", bytes: 3)
        let resolver = DiskCleanApplicationOwnership(home: root.path, includeContainers: true)
        let result = resolver.resolve(bundleID: id, identity: .init(ids: [id, extensionID], groups: ["group.org.example.shared"]),
            applicationName: "Example Editor", otherOwners: [extensionID])
        XCTAssertEqual(result.associations.count, 3)
        XCTAssertTrue(result.associations.allSatisfy { $0.manualReason != nil })
        XCTAssertFalse(result.associations.contains { $0.path == root.resolve("Library/Application Support").path })
    }

    func testContainerOwnershipIsRecheckedAndParentChildPathsAreNotDuplicated() throws {
        let root = try DiskCleanTempDirectory(name: "ContainerProof")
        defer { root.remove() }
        let id = "org.example.editor"
        let container = try root.makeDirectory("Library/Containers/" + id)
        let metadata = container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        try plist(["MCMMetadataIdentifier": id], to: metadata)
        let resolver = DiskCleanApplicationOwnership(home: root.path, includeContainers: true)
        let resolved = resolver.resolve(bundleID: id, identity: .init(ids: [id]))
        let item = try XCTUnwrap(resolved.associations.first { $0.path == container.path })
        XCTAssertNil(item.proof?.rejection(at: item.path))
        try plist(["MCMMetadataIdentifier": "org.example.other"], to: metadata)
        XCTAssertNotNil(item.proof?.rejection(at: item.path))
        XCTAssertTrue(resolver.resolve(bundleID: id, identity: .init(ids: [id])).associations.isEmpty)
    }

    func testInaccessibleOrInvalidContainerRootDoesNotBecomeEmptyCheckedCategory() throws {
        let root = try DiskCleanTempDirectory(name: "OwnershipCoverage")
        defer { root.remove() }
        try root.makeFile("Library/Containers", bytes: 2)
        let resolver = DiskCleanApplicationOwnership(home: root.path, includeContainers: true)
        XCTAssertEqual(resolver.resolve(bundleID: "org.example.editor", identity: .init(ids: ["org.example.editor"])).coverage[.sandbox], .incomplete)
        let unauthorized = DiskCleanApplicationOwnership(home: root.path)
        XCTAssertEqual(unauthorized.resolve(bundleID: "org.example.editor", identity: .init(ids: ["org.example.editor"])).coverage[.sandbox], .permissionRequired)
    }

    func testFreshComponentClaimBlocksAssociatedDataAfterBundleRemoval() async throws {
        let root = try DiskCleanTempDirectory(name: "FreshComponentClaim")
        defer { root.remove() }
        let owner = "org.example.original.share"
        let other = try root.makeDirectory("Other.app/Contents/PlugIns/Share.appex/Contents")
        try plist(["CFBundleIdentifier": owner], to: other.appendingPathComponent("Info.plist"))
        let cache = try root.makeFile("Home/Library/Caches/" + owner + "/cache", bytes: 4).deletingLastPathComponent().path
        let presence = DiskCleanApplicationPresence(inventory: { _ in
            .init(applications: [.init(path: root.resolve("Other.app").path, bundleID: "org.example.other",
                name: "Other", executable: nil, rejection: nil)], isComplete: true, issues: [])
        }, registered: { _ in false }, running: { _ in false })
        let validator = DiskCleanReviewValidator(policy: .init(homeDirectory: root.resolve("Home").path), presence: presence)
        let evidence = DiskCleanReviewValidation.application(bundleID: "org.example.original", roots: [],
            bundlePath: root.resolve("Removed.app").path, isBundle: false,
            proof: .init(path: cache, ownerID: owner))
        let rejection = await validator.rejection(path: cache, evidence: evidence)
        XCTAssertNotNil(rejection)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache))
    }

    func testHomeAliasPreservesLogicalPathsAndSharedCacheRootsAreNotOrphans() throws {
        let root = try DiskCleanTempDirectory(name: "OwnershipAliases")
        defer { root.remove() }
        let home = try root.makeDirectory("Home").path
        let alias = root.resolve("HomeAlias").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: home)
        let id = "org.example.editor"
        let cache = try root.makeFile("Home/Library/Caches/" + id + "/cache", bytes: 3).deletingLastPathComponent().path
        let resolver = DiskCleanApplicationOwnership(home: alias)
        let row = try XCTUnwrap(resolver.associations(bundleID: id).first { $0.category == .caches })
        XCTAssertEqual(row.path, cache)
        XCTAssertTrue(row.logicalPaths.contains(alias + "/Library/Caches/" + id))
        try root.makeFile("Home/Library/Caches/com.crashlytics.data/shared", bytes: 3)
        try root.makeFile("Home/Library/Caches/" + id + ".ShipIt/cache", bytes: 3)
        let suspects = resolver.suspectedBundleIDs()
        XCTAssertFalse(suspects.contains("com.crashlytics.data"))
        XCTAssertFalse(suspects.contains(id + ".ShipIt"))
        XCTAssertTrue(suspects.contains(id))
    }

    func testSystemAndVendorCacheLeavesRequireExactOwnership() throws {
        let root = try DiskCleanTempDirectory(name: "DarwinCacheOwnership")
        defer { root.remove() }
        let id = "org.example.editor"
        let helper = id + ".helper"
        let expected = try root.makeFile("DarwinCache/" + helper + "/data", bytes: 4).deletingLastPathComponent().path
        try root.makeFile("DarwinCache/" + helper + ".other/data", bytes: 4)
        let resolver = DiskCleanApplicationOwnership(home: root.path, userCacheRoot: root.resolve("DarwinCache").path)
        let result = resolver.resolve(bundleID: id, identity: .init(ids: [id, helper]))
        XCTAssertEqual(result.associations.map(\.path), [expected])
        XCTAssertEqual(result.associations.first?.category, .caches)
        XCTAssertEqual(result.associations.first?.proof?.ownerID, helper)
        XCTAssertFalse(result.associations.first?.isPersonal ?? true)
        XCTAssertTrue(resolver.reservedRoots.contains(root.resolve("DarwinCache").path))
        let chrome = try root.makeFile("Library/Caches/Google/Chrome/Default/Cache_Data/data", bytes: 4).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        try root.makeFile("Library/Caches/Google/Other/cache", bytes: 4)
        let chromeResult = resolver.resolve(bundleID: "com.google.Chrome", identity: .init(ids: ["com.google.Chrome"]))
        XCTAssertEqual(chromeResult.associations.map(\.path), [chrome])
        XCTAssertNil(chromeResult.associations.first?.manualReason)
        let updater = try root.makeFile("DarwinCache/com.google.GoogleUpdater/cache", bytes: 4).deletingLastPathComponent().path
        let withUpdater = resolver.resolve(bundleID: "com.google.Chrome", identity: .init(ids: ["com.google.Chrome", "com.google.GoogleUpdater"]))
        XCTAssertNotNil(withUpdater.associations.first { $0.path == updater }?.manualReason)
        let offlineID = "com.spotify.client.helper"
        let offline = try root.makeDirectory("DarwinCache/" + offlineID).path
        let offlineResult = resolver.resolve(bundleID: "com.spotify.client", identity: .init(ids: ["com.spotify.client", offlineID]))
        XCTAssertEqual(offlineResult.associations.first { $0.path == offline }?.isPersonal, true)

    }

    func testLocalizedDisplayNamesRetainExecutableCrashReportCandidates() throws {
        let root = try DiskCleanTempDirectory(name: "LocalizedApplicationFiles")
        defer { root.remove() }
        let report = try root.makeFile("Library/Application Support/CrashReporter/WeChat_" + UUID().uuidString + ".plist", bytes: 4).path
        let resolver = DiskCleanApplicationOwnership(home: root.path)
        let result = resolver.resolve(bundleID: "org.example.chat", identity: .init(ids: ["org.example.chat"], names: ["WeChat"]),
            applicationName: "微信")
        let candidate = try XCTUnwrap(result.associations.first { $0.path == report })
        XCTAssertEqual(candidate.category, .caches)
        XCTAssertNotNil(candidate.manualReason)
    }

    func testDerivedCacheNamesCannotBecomeLeftoversWhileParentAppIsInstalled() async throws {
        let root = try DiskCleanTempDirectory(name: "DerivedCacheOwner")
        defer { root.remove() }
        let id = "org.example.editor.TempCache"
        let cache = try root.makeFile("DarwinCache/" + id + "/data", bytes: 4).deletingLastPathComponent().path
        let resolver = DiskCleanApplicationOwnership(home: root.path, userCacheRoot: root.resolve("DarwinCache").path)
        XCTAssertTrue(resolver.suspectedBundleIDs().contains(id))
        let presence = DiskCleanApplicationPresence(inventory: { _ in
            .init(applications: [.init(path: root.resolve("Other.app").path, bundleID: "org.example.Editor",
                name: "Editor", executable: nil, rejection: nil)], isComplete: true, issues: [])
        }, registered: { _ in false }, running: { _ in false })
        let validator = DiskCleanReviewValidator(policy: .init(homeDirectory: root.path), presence: presence)
        let rejection = await validator.rejection(path: cache, evidence: .leftover(bundleID: id, roots: [], proof: .init(path: cache, ownerID: id)))
        XCTAssertNotNil(rejection)
        XCTAssertFalse(DiskCleanApplicationIdentity.hasPotentialOwner("org.example.editorial", in: ["org.example.Editor"]))
    }

    func testUnrelatedIncompleteClaimsDoNotLockVerifiedMainOwnedFiles() throws {
        let root = try DiskCleanTempDirectory(name: "MainOwnershipScope")
        defer { root.remove() }
        let id = "com.microsoft.VSCode"
        let contents = try root.makeDirectory("Apps/Code.app/Contents")
        try plist(["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"], to: contents.appendingPathComponent("Info.plist"))
        let app = DiskCleanInstalledApplication(path: contents.deletingLastPathComponent().path, bundleID: id,
            name: "Code", executable: nil, rejection: nil)
        var identity = DiskCleanApplicationIdentity.read(bundleID: id, copies: [app])
        XCTAssertEqual(identity.mainBundleID, id)
        let helperID = id + ".helper"
        identity.ids.insert(helperID)
        let cache = try root.makeDirectory("Home/Library/Caches/" + id).path
        let support = try root.makeDirectory("Home/Library/Application Support/Code").path
        let preferences = try root.makeFile("Home/Library/Preferences/" + id + ".plist", bytes: 1).path
        let helperCache = try root.makeDirectory("Home/Library/Caches/" + helperID).path
        let container = try root.makeDirectory("Home/Library/Containers/" + UUID().uuidString)
        try plist(["MCMMetadataIdentifier": id], to: container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        let helperContainer = try root.makeDirectory("Home/Library/Containers/" + UUID().uuidString)
        try plist(["MCMMetadataIdentifier": helperID], to: helperContainer.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        let resolver = DiskCleanApplicationOwnership(home: root.resolve("Home").path, includeContainers: true)
        let result = resolver.resolve(bundleID: id, identity: identity, otherOwners: ["org.example.unrelated"], claimsComplete: false)
        for path in [cache, support, preferences, container.path] {
            let item = try XCTUnwrap(result.associations.first { $0.path == path })
            XCTAssertNil(item.manualReason, path)
            XCTAssertFalse(try XCTUnwrap(item.proof).requiresCompleteClaims(for: id))
        }
        XCTAssertNotNil(result.associations.first { $0.path == helperCache }?.manualReason)
        XCTAssertNotNil(result.associations.first { $0.path == helperContainer.path }?.manualReason)
        XCTAssertTrue(result.report.checks.contains { $0.path == helperContainer.path && $0.state.needsAttention })
        XCTAssertFalse(result.report.checks.contains { $0.path == container.path && $0.state.needsAttention })
        XCTAssertFalse(result.report.claimsComplete)
        identity.isComplete = false
        identity.verifiedPrivateIDs.insert(helperID)
        let privateResult = resolver.resolve(bundleID: id, identity: identity, claimsComplete: false)
        for path in [helperCache, helperContainer.path] {
            let item = try XCTUnwrap(privateResult.associations.first { $0.path == path })
            XCTAssertNil(item.manualReason, path)
            XCTAssertFalse(try XCTUnwrap(item.proof).requiresCompleteClaims(for: id))
            XCTAssertEqual(try XCTUnwrap(item.proof).allowsPersonalSessionRemoval, path == helperContainer.path)
            XCTAssertFalse(privateResult.report.checks.contains { $0.path == path && $0.state.needsAttention })
        }
        let sharedHelper = resolver.resolve(bundleID: id, identity: identity, otherOwners: [helperID], claimsComplete: false)
        for path in [helperCache, helperContainer.path] {
            XCTAssertNotNil(sharedHelper.associations.first { $0.path == path }?.manualReason, path)
        }
        let conflicting = resolver.resolve(bundleID: id, identity: identity, otherOwners: [id], claimsComplete: false)
        XCTAssertTrue(conflicting.associations.allSatisfy { $0.manualReason != nil })
        let suspected = resolver.resolve(bundleID: id, identity: .init(ids: [id]), claimsComplete: false)
        XCTAssertTrue(suspected.associations.allSatisfy { $0.manualReason != nil })
    }

    private func plist(_ value: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url)
    }
}
