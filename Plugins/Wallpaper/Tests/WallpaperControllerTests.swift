import AppKit
import ImageIO
import MacToolsPluginKit
import UniformTypeIdentifiers
import XCTest
@testable import WallpaperPlugin

@MainActor
final class WallpaperControllerTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
    }

    private func image(_ name: String, red: CGFloat = 1) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let url = temporary.appendingPathComponent(name + ".png")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        return url
    }

    private func library() -> WallpaperLibrary {
        WallpaperLibrary(root: temporary.appendingPathComponent("Managed"), cache: temporary.appendingPathComponent("Cache"))
    }

    private func controller(_ library: WallpaperLibrary, system: WallpaperTestSystem) -> WallpaperController {
        WallpaperController(context: PluginRuntimeContext(pluginID: "wallpaper"), system: system, library: library)
    }

    func testManualApplicationRecordsOnlySuccessfulDisplaysAndPinsImage() async throws {
        let library = library()
        _ = try await library.load()
        let original = try image("source")
        let originalData = try Data(contentsOf: original)
        let asset = WallpaperAsset(id: "photo", title: "Source", localURL: original)
        var state = WallpaperState()
        state.assets[asset.id] = asset
        try await library.save(state, revision: 1)
        let system = WallpaperTestSystem()
        system.failedDisplay = "second"
        let controller = controller(library, system: system)
        await controller.activate()?.value
        defer { controller.deactivate() }

        let result = await controller.execute("apply-asset", assetID: asset.id)
        guard case .failed = result else { return XCTFail("A partial display update must report failure") }
        XCTAssertEqual(system.writes.map(\.0), ["first"])
        XCTAssertEqual(controller.state.history["first"]?.entries, [asset.id])
        XCTAssertNil(controller.state.history["second"])
        XCTAssertFalse(controller.profile.enabled)
        XCTAssertEqual(try Data(contentsOf: original), originalData)
        let saved = try await library.load()
        XCTAssertTrue(saved.appliedIDs.contains(asset.id))
        XCTAssertFalse(saved.appliedNames.isEmpty)
    }

    func testDetectedExternalChangePausesWithoutReplacingDesktop() async throws {
        let library = library()
        _ = try await library.load()
        let system = WallpaperTestSystem()
        var state = WallpaperState()
        state.profiles["all"]?.enabled = true
        state.profiles["all"]?.started = true
        state.profiles["all"]?.admittedDisplays = ["first", "second"]
        state.profiles["all"]?.expected = system.desktops
        state.profiles["all"]?.nextDate = .distantPast
        try await library.save(state, revision: 1)
        let controller = controller(library, system: system)
        await controller.activate()?.value
        defer { controller.deactivate() }
        system.desktops["first"]?.url = temporary.appendingPathComponent("user-choice.png")

        await controller.tick()

        XCTAssertFalse(controller.profile.enabled)
        XCTAssertNotNil(controller.profile.pauseReason)
        XCTAssertTrue(system.writes.isEmpty)
        XCTAssertEqual(system.desktops["first"]?.url.lastPathComponent, "user-choice.png")
    }

    func testInvalidImageAndDeactivatedActionsNeverWriteDesktop() async throws {
        let library = library()
        _ = try await library.load()
        let bad = temporary.appendingPathComponent("bad.png")
        try Data("not an image".utf8).write(to: bad)
        let asset = WallpaperAsset(id: "bad", title: "Bad", localURL: bad)
        var state = WallpaperState(); state.assets[asset.id] = asset
        try await library.save(state, revision: 1)
        let system = WallpaperTestSystem()
        let controller = controller(library, system: system)
        await controller.activate()?.value
        let result = await controller.execute("apply-asset", assetID: "bad")
        guard case .failed = result else { return XCTFail("Invalid content must fail") }
        controller.deactivate()
        _ = await controller.execute("apply-asset", assetID: "bad")
        XCTAssertTrue(system.writes.isEmpty)
        XCTAssertTrue(controller.state.appliedIDs.isEmpty)
    }

    func testCacheCleanupPreservesCurrentFavoriteAndOriginalFiles() async throws {
        let library = library()
        _ = try await library.load()
        let original = try image("original")
        let imported = try await library.prepare(WallpaperAsset(id: "current", title: "Current", localURL: original))
        var state = WallpaperState()
        state.assets[imported.id] = imported
        state.appliedIDs.insert(imported.id)
        _ = try await library.thumbnail(imported)

        try await library.clean(state: state, clear: true)

        let readable = await library.readable(imported)
        XCTAssertTrue(readable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        let usage = try await library.usage()
        XCTAssertEqual(usage.cached, 0)
        XCTAssertGreaterThan(usage.managed, 0)
    }

    func testFolderScanDoesNotFollowLinksAndMissingFolderRetainsFailure() async throws {
        let directory = temporary.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = try image("outside")
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("linked.png"), withDestinationURL: original)
        try FileManager.default.copyItem(at: original, to: directory.appendingPathComponent("inside.png"))
        let bookmark = try directory.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let folder = WallpaperFolder(url: directory, bookmark: bookmark)
        let library = library()
        let result = try await library.scan([folder])
        XCTAssertEqual(result.assets.map(\.title), ["inside.png"])
        XCTAssertTrue(result.completeFolderIDs.contains(folder.id))
        try FileManager.default.removeItem(at: directory)
        let missing = try await library.scan([folder])
        XCTAssertFalse(missing.completeFolderIDs.contains(folder.id))
        XCTAssertNotNil(missing.issues[folder.id])
    }

    func testCorruptLibraryAfterReactivationIsPreservedAndDisablesActions() async throws {
        let library = library()
        let system = WallpaperTestSystem()
        let controller = controller(library, system: system)
        await controller.activate()?.value
        XCTAssertTrue(controller.ready)
        controller.deactivate()
        let url = temporary.appendingPathComponent("Managed/library.json")
        let original = Data("broken library".utf8)
        try original.write(to: url)
        let reload = controller.activate()
        XCTAssertFalse(controller.ready)
        await reload?.value
        defer { controller.deactivate() }
        XCTAssertFalse(controller.ready)
        XCTAssertNotNil(controller.error)
        _ = await controller.execute("next")
        XCTAssertTrue(system.writes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testProviderCallbackAfterDeactivationCannotApplyWallpaper() async throws {
        let library = library()
        _ = try await library.load()
        var state = WallpaperState()
        state.profiles["all"]?.collection = .wallhaven
        try await library.save(state, revision: 1)
        let source = WallpaperGatedSource()
        let system = WallpaperTestSystem()
        let controller = WallpaperController(context: PluginRuntimeContext(pluginID: "wallpaper"),
                                             system: system, library: library, source: source)
        await controller.activate()?.value
        let operation = Task { await controller.execute("next") }
        await source.waitUntilRequested()
        controller.deactivate()
        let asset = WallpaperAsset(id: "late", title: "Late", localURL: try image("late"))
        await source.complete(WallpaperPage(assets: [asset], page: 1, lastPage: 1))
        let result = await operation.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(system.writes.isEmpty)
        XCTAssertFalse(controller.state.appliedIDs.contains(asset.id))
    }

    func testProviderRetryBoundsPreserveDesktop() async throws {
        for retryCount in [3, -1] {
            let library = WallpaperLibrary(root: temporary.appendingPathComponent("Managed-\(retryCount)"),
                cache: temporary.appendingPathComponent("Cache-\(retryCount)"))
            _ = try await library.load()
            let system = WallpaperTestSystem()
            var state = WallpaperState()
            state.profiles["all"]?.collection = .wallhaven
            state.profiles["all"]?.enabled = true
            state.profiles["all"]?.started = true
            state.profiles["all"]?.expected = system.desktops
            state.profiles["all"]?.admittedDisplays = ["first", "second"]
            state.profiles["all"]?.nextDate = .distantPast
            state.profiles["all"]?.retryCount = retryCount
            try await library.save(state, revision: 1)
            let controller = WallpaperController(context: PluginRuntimeContext(pluginID: "wallpaper"),
                system: system, library: library, source: WallpaperFailingSource())
            await controller.activate()?.value
            defer { controller.deactivate() }
            await controller.tick()
            XCTAssertEqual(controller.profile.enabled, retryCount < 3)
            if retryCount < 3 { XCTAssertEqual(controller.profile.retryCount, 1) }
            else { XCTAssertNotNil(controller.profile.pauseReason) }
            XCTAssertTrue(system.writes.isEmpty)
        }
    }

    func testManifestMatchesCanonicalActions() throws {
        let controller = controller(library(), system: WallpaperTestSystem())
        let plugin = WallpaperPlugin(context: PluginRuntimeContext(pluginID: "wallpaper"), controller: controller)
        try PluginManifestActionAssertions.assertConsistency(pluginDirectoryName: "Wallpaper", definitions: plugin.actionDefinitions, permissionIDs: { _ in [] })
    }

    private func localCollection(_ library: WallpaperLibrary) async throws -> [WallpaperAsset] {
        _ = try await library.load()
        let bookmark = try temporary.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let folder = WallpaperFolder(url: temporary, bookmark: bookmark)
        let assets = try ["a", "b", "c"].enumerated().map { index, name in
            WallpaperAsset(id: name, title: name, localURL: try image(name, red: CGFloat(index + 1) / 3), folderID: folder.id)
        }
        var state = WallpaperState()
        state.folders = [folder]
        state.assets = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        state.profiles["all"]?.shuffled = false
        try await library.save(state, revision: 1)
        return assets
    }

    func testInvalidStoredHistoryCannotIndexOutsideEntriesAndNextStartsNewHistory() async throws {
        let library = library()
        let assets = try await localCollection(library)
        var state = try await library.load()
        state.history = Dictionary(uniqueKeysWithValues: ["first", "second"].map {
            ($0, WallpaperHistory(entries: [assets[0].id], cursor: Int.max))
        })
        try await library.save(state, revision: 1)
        let system = WallpaperTestSystem()
        let controller = controller(library, system: system)
        await controller.activate()?.value
        defer { controller.deactivate() }
        XCTAssertFalse(controller.canGoBack)
        let previous = await controller.execute("previous")
        if case .failed = previous { } else { XCTFail("Invalid history must not navigate backwards") }
        XCTAssertTrue(system.writes.isEmpty)
        let next = await controller.execute("next")
        XCTAssertEqual(next, .succeeded())
        XCTAssertEqual(controller.state.history["first"]?.entries, [assets[0].id])
        XCTAssertEqual(controller.state.history["first"]?.cursor, 0)
    }

    func testManualSwitchHistoryFavoritesAndIntervalPersistence() async throws {
        let library = library()
        let assets = try await localCollection(library)
        let system = WallpaperTestSystem()
        let controller = controller(library, system: system)
        await controller.activate()?.value
        defer { controller.deactivate() }

        for asset in assets.prefix(2) {
            let result = await controller.execute("next")
            XCTAssertEqual(result, .succeeded())
            XCTAssertEqual(controller.currentAsset?.id, asset.id)
            let managed = try XCTUnwrap(controller.state.assets[asset.id].flatMap(library.managedURL))
            XCTAssertTrue(system.desktops.values.allSatisfy { $0.url == managed })
        }
        XCTAssertEqual(Set(system.writes.map(\.1)).count, 2)
        XCTAssertTrue(controller.canGoBack)
        _ = await controller.execute("previous")
        XCTAssertEqual(controller.currentAsset?.id, "a")
        _ = await controller.execute("next")
        XCTAssertEqual(controller.currentAsset?.id, "b")
        _ = await controller.execute("previous")
        _ = await controller.execute("apply-asset", assetID: "c")
        XCTAssertTrue(controller.state.history.values.allSatisfy { $0.entries == ["a", "c"] })

        await controller.favorite("c")
        XCTAssertEqual(controller.assets(in: "favorites", query: "").map(\.id), ["c"])
        controller.configure { $0.collection = .favorites; $0.interval = 3_600 }
        let resumed = await controller.setRotation(true)
        XCTAssertEqual(resumed, .succeeded())
        XCTAssertTrue(controller.profile.enabled)
        XCTAssertEqual(controller.profile.interval, 3_600)
        let nextDate = try XCTUnwrap(controller.profile.nextDate)
        XCTAssertEqual(nextDate.timeIntervalSinceNow, 3_600, accuracy: 5)
        _ = await controller.setRotation(false)
        XCTAssertFalse(controller.profile.enabled)
        _ = await controller.execute("next")
        XCTAssertFalse(controller.profile.enabled)
        let saved = try await library.load()
        XCTAssertEqual(saved.profiles["all"]?.interval, 3_600)
        XCTAssertEqual(saved.profiles["all"]?.enabled, false)
        await controller.favorite("c")
        XCTAssertTrue(controller.assets(in: "favorites", query: "").isEmpty)
    }

    func testOverdueRotationChangesDesktopAndPausePreventsFurtherWrites() async throws {
        let library = library()
        _ = try await localCollection(library)
        var state = try await library.load()
        let system = WallpaperTestSystem()
        state.profiles["all"]?.enabled = true
        state.profiles["all"]?.started = true
        state.profiles["all"]?.expected = system.desktops
        state.profiles["all"]?.admittedDisplays = Set(system.desktops.keys)
        state.profiles["all"]?.nextDate = .distantPast
        try await library.save(state, revision: 2)
        let controller = controller(library, system: system)
        await controller.activate()?.value
        defer { controller.deactivate() }

        await controller.tick()
        XCTAssertEqual(controller.currentAsset?.id, "a")
        XCTAssertEqual(system.writes.count, 2)
        XCTAssertTrue(controller.profile.enabled)
        XCTAssertGreaterThan(try XCTUnwrap(controller.profile.nextDate), Date())
        controller.configure { $0.interval = 300 }
        XCTAssertEqual(controller.profile.interval, 300)
        _ = await controller.setRotation(false)
        await controller.tick()
        XCTAssertEqual(system.writes.count, 2)
        let resumed = await controller.setRotation(true)
        XCTAssertEqual(resumed, .succeeded())
        XCTAssertTrue(controller.profile.enabled)
        XCTAssertEqual(system.writes.count, 2)
    }

    func testStartingRotationAppliesFirstImageBeforeScheduling() async throws {
        let library = library()
        _ = try await localCollection(library)
        let system = WallpaperTestSystem()
        let controller = controller(library, system: system)
        await controller.activate()?.value
        defer { controller.deactivate() }

        let result = await controller.setRotation(true)
        XCTAssertEqual(result, .succeeded())
        XCTAssertTrue(controller.profile.enabled)
        XCTAssertEqual(controller.currentAsset?.id, "a")
        XCTAssertEqual(system.writes.count, 2)
        controller.configure { $0.interval = 900 }
        XCTAssertEqual(controller.profile.interval, 900)
        XCTAssertEqual(try XCTUnwrap(controller.profile.nextDate).timeIntervalSinceNow, 900, accuracy: 5)
    }

    func testOnlineCollectionSwitchesImagesAndRetainsAppliedHistory() async throws {
        let library = library()
        let assets = try await localCollection(library)
        let system = WallpaperTestSystem()
        let controller = WallpaperController(context: PluginRuntimeContext(pluginID: "wallpaper"), system: system,
                                             library: library, source: WallpaperStaticSource(assets: assets))
        await controller.activate()?.value
        defer { controller.deactivate() }
        let query = WallpaperQuery(keywords: "nature")
        controller.useQuery(query)

        let first = await controller.execute("next")
        XCTAssertEqual(first, .succeeded())
        XCTAssertEqual(controller.currentAsset?.id, "a")
        let second = await controller.execute("next")
        XCTAssertEqual(second, .succeeded())
        XCTAssertEqual(controller.currentAsset?.id, "b")
        XCTAssertEqual(Set(system.writes.map(\.1)).count, 2)
        XCTAssertEqual(controller.state.queryMembership[query.identity], Set(assets.map(\.id)))
        XCTAssertEqual(controller.assets(in: "history", query: "").map(\.id), ["b", "a"])
        XCTAssertFalse(controller.profile.enabled)
    }
}

private struct WallpaperStaticSource: WallpaperSource {
    let assets: [WallpaperAsset]
    func search(_ query: WallpaperQuery, page: Int) async throws -> WallpaperPage {
        WallpaperPage(assets: assets, page: 1, lastPage: 1)
    }
}

private actor WallpaperGatedSource: WallpaperSource {
    private var request: CheckedContinuation<WallpaperPage, Error>?
    private var ready: CheckedContinuation<Void, Never>?
    func search(_ query: WallpaperQuery, page: Int) async throws -> WallpaperPage {
        try await withCheckedThrowingContinuation { continuation in
            request = continuation
            ready?.resume(); ready = nil
        }
    }
    func waitUntilRequested() async {
        if request != nil { return }
        await withCheckedContinuation { ready = $0 }
    }
    func complete(_ page: WallpaperPage) { request?.resume(returning: page); request = nil }
}

private actor WallpaperFailingSource: WallpaperSource {
    func search(_ query: WallpaperQuery, page: Int) async throws -> WallpaperPage { throw URLError(.notConnectedToInternet) }
}

@MainActor
private final class WallpaperTestSystem: WallpaperSystemControlling {
    var desktops = ["first": WallpaperDesktopState(url: URL(fileURLWithPath: "/test/first.png"), fill: true),
                    "second": WallpaperDesktopState(url: URL(fileURLWithPath: "/test/second.png"), fill: true)]
    var failedDisplay: String?
    var writes: [(String, URL)] = []
    func displays() -> [WallpaperDisplay] {
        [WallpaperDisplay(id: "first", name: "Display", width: 1920, height: 1080),
         WallpaperDisplay(id: "second", name: "Display", width: 1080, height: 1920)]
    }
    func read(displayID: String) -> WallpaperDesktopState? { desktops[displayID] }
    func apply(_ url: URL, displayID: String, fill: Bool) throws {
        if displayID == failedDisplay { throw WallpaperFailure.disconnected }
        desktops[displayID] = WallpaperDesktopState(url: url, fill: fill)
        writes.append((displayID, url))
    }
}
