import XCTest
import MacToolsPluginKit
@testable import MacTools

final class ApplicationScannerTests: XCTestCase {

    func testExplicitApplicationScopeDeduplicatesDirectoryResults() throws {
        let directory = try makeTempDir()
        let app = try makeAppBundle(in: directory, named: "Single.app")
        let items = ApplicationScanner.scan(roots: [app.path, directory.path])
        XCTAssertEqual(items.map(\.id), [app.path])
        try FileManager.default.removeItem(at: app)
        XCTAssertTrue(ApplicationScanner.scan(roots: [app.path]).isEmpty)
    }

    func testSystemLanguageLoctableNamesKeepEnglishAliases() throws {
        let directory = try makeTempDir()
        let app = try makeAppBundle(in: directory, named: "Calculator.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let table = ["zh_CN": ["CFBundleDisplayName": "计算器"], "fr": ["CFBundleDisplayName": "Calculatrice"]]
        let data = try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0)
        try data.write(to: resources.appendingPathComponent("InfoPlist.loctable"))
        let names = ApplicationScanner.applicationNames(for: app, preferredLanguages: ["zh-Hans-CN"])
        XCTAssertEqual(names.name, "计算器")
        XCTAssertTrue(names.alternates.contains("Calculator"))
        XCTAssertFalse(names.alternates.contains("Calculatrice"))
    }

    @MainActor
    func testAdditionalScopesValidateAndPersistWithoutChangingDefaultRoots() throws {
        let directory = try makeTempDir()
        let file = directory.appendingPathComponent("ordinary.txt")
        try Data().write(to: file)
        let suite = "ApplicationScopesTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = ApplicationCatalog(defaults: defaults, defaultSearchRoots: [])
        XCTAssertFalse(catalog.addSearchRoot(file))
        XCTAssertTrue(catalog.addSearchRoot(directory))
        XCTAssertTrue(catalog.addSearchRoot(directory))
        XCTAssertEqual(catalog.searchRoots, [directory.path])
        let restored = ApplicationCatalog(defaults: defaults, defaultSearchRoots: [])
        XCTAssertEqual(restored.additionalSearchRoots, [directory.path])
        restored.removeSearchRoot(directory.path)
        XCTAssertTrue(ApplicationCatalog(defaults: defaults, defaultSearchRoots: []).additionalSearchRoots.isEmpty)
    }

    @MainActor
    func testWarmPageEntryReusesAppSnapshotUntilExplicitRefresh() async throws {
        let directory = try makeTempDir()
        let suite = "ApplicationSnapshotTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = ApplicationCatalogItem(id: "fixture", name: "Fixture", url: directory.appendingPathComponent("Fixture.app"))
        let catalog = ApplicationCatalog(defaults: defaults, defaultSearchRoots: [directory.path], observesChanges: false, scan: { _ in [item] })
        let initial = expectation(description: "Initial snapshot")
        catalog.onChange = { initial.fulfill() }
        XCTAssertTrue(catalog.loadIfNeeded())
        XCTAssertFalse(catalog.loadIfNeeded())
        await fulfillment(of: [initial], timeout: 5)
        XCTAssertEqual(catalog.items, [item])
        XCTAssertFalse(catalog.loadIfNeeded())
        XCTAssertFalse(catalog.loadIfNeeded())
        let refreshed = expectation(description: "Explicit refresh")
        catalog.onChange = { refreshed.fulfill() }
        catalog.refresh()
        await fulfillment(of: [refreshed], timeout: 5)
        XCTAssertEqual(catalog.items, [item])
    }

    // MARK: - strippedAppSuffix (only trailing ".app", never mid-string)

    func testStrippedAppSuffixRemovesOnlyTrailingDotApp() {
        XCTAssertEqual(ApplicationScanner.strippedAppSuffix("Safari.app"), "Safari")
        XCTAssertEqual(ApplicationScanner.strippedAppSuffix("Safari"), "Safari")
        XCTAssertEqual(ApplicationScanner.strippedAppSuffix("App Store"), "App Store")
        // ".app" in the middle must NOT be removed (the bug Codex flagged).
        XCTAssertEqual(ApplicationScanner.strippedAppSuffix("My.app Helper"), "My.app Helper")
        // Only ONE trailing suffix removed.
        XCTAssertEqual(ApplicationScanner.strippedAppSuffix("Weird.app.app"), "Weird.app")
        XCTAssertEqual(ApplicationScanner.strippedAppSuffix(""), "")
    }

    // MARK: - nested-helper guard (path-level)

    func testIsNestedInsideAnotherApp() {
        XCTAssertFalse(ApplicationScanner.isNestedInsideAnotherApp(URL(fileURLWithPath: "/Applications/Foo.app")))
        XCTAssertFalse(ApplicationScanner.isNestedInsideAnotherApp(URL(fileURLWithPath: "/Applications/Utilities/Terminal.app")))
        XCTAssertTrue(ApplicationScanner.isNestedInsideAnotherApp(
            URL(fileURLWithPath: "/Applications/Foo.app/Contents/Helpers/Bar.app")
        ))
    }

    // MARK: - isValidAppBundle (directory + Contents/Info.plist)

    func testIsValidAppBundleRequiresDirectoryAndInfoPlist() throws {
        let tmp = try makeTempDir()
        let validApp = try makeAppBundle(in: tmp, named: "Real.app")
        let emptyDirApp = tmp.appendingPathComponent("Empty.app")
        try FileManager.default.createDirectory(at: emptyDirApp, withIntermediateDirectories: true)
        let fileApp = tmp.appendingPathComponent("File.app")
        try Data().write(to: fileApp)

        XCTAssertTrue(ApplicationScanner.isValidAppBundle(at: validApp.path))
        XCTAssertFalse(ApplicationScanner.isValidAppBundle(at: emptyDirApp.path)) // no Info.plist
        XCTAssertFalse(ApplicationScanner.isValidAppBundle(at: fileApp.path))     // not a directory
        XCTAssertFalse(ApplicationScanner.isValidAppBundle(at: tmp.appendingPathComponent("Missing.app").path))
    }

    // MARK: - scan over a fixture tree

    func testScanFindsAppsRecursivelyAndSorts() throws {
        let tmp = try makeTempDir()
        _ = try makeAppBundle(in: tmp, named: "Zebra.app")
        // Recursion: an app inside a subfolder (like /Applications/Utilities).
        let utilities = tmp.appendingPathComponent("Utilities", isDirectory: true)
        try FileManager.default.createDirectory(at: utilities, withIntermediateDirectories: true)
        _ = try makeAppBundle(in: utilities, named: "Alpha.app")

        let items = ApplicationScanner.scan(roots: [tmp.path])
        XCTAssertEqual(items.map(\.name), ["Alpha", "Zebra"]) // sorted
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
    }

    func testScanExcludesCorruptBundleWithoutInfoPlist() throws {
        let tmp = try makeTempDir()
        _ = try makeAppBundle(in: tmp, named: "Good.app")
        // A directory named like an app but with no Info.plist (corrupt/placeholder).
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("Broken.app"), withIntermediateDirectories: true
        )
        // A FILE named like an app.
        try Data().write(to: tmp.appendingPathComponent("NotReal.app"))

        let items = ApplicationScanner.scan(roots: [tmp.path])
        XCTAssertEqual(items.map(\.name), ["Good"])
    }

    func testScanExcludesNestedHelperApp() throws {
        let tmp = try makeTempDir()
        let host = try makeAppBundle(in: tmp, named: "Host.app")
        // A real helper app embedded inside the host bundle. `.skipsPackageDescendants`
        // should prevent it from ever being yielded; the nested guard is the backstop.
        let helpersDir = host.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersDir, withIntermediateDirectories: true)
        _ = try makeAppBundle(in: helpersDir, named: "Helper.app")

        let items = ApplicationScanner.scan(roots: [tmp.path])
        XCTAssertEqual(items.map(\.name), ["Host"]) // Helper.app excluded
    }

    func testScanSkipsNonexistentRoots() {
        let items = ApplicationScanner.scan(roots: ["/no/such/path/\(UUID().uuidString)"])
        XCTAssertTrue(items.isEmpty)
    }

    func testScanDedupesSymlinkedDuplicate() throws {
        let tmp = try makeTempDir()
        let real = try makeAppBundle(in: tmp, named: "Real.app")
        let link = tmp.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let items = ApplicationScanner.scan(roots: [tmp.path])
        // Real.app and Link.app resolve to the same path → a single deduped entry.
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, real.resolvingSymlinksInPath().path)
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Creates a minimal valid `.app` bundle (a directory with `Contents/Info.plist`).
    @discardableResult
    private func makeAppBundle(in parent: URL, named name: String) throws -> URL {
        let app = parent.appendingPathComponent(name, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("<plist></plist>".utf8).write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }
}
