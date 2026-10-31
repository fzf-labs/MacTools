import Foundation
import XCTest
@testable import WallpaperPlugin

final class WallhavenWallpaperSourceTests: XCTestCase {
    func testProviderAdmitsOnlySafeMatchingImagesAndBoundsPagination() throws {
        let items: [[String: Any]] = [
            item(id: "abc123", purity: "sfw", path: "https://w.wallhaven.cc/full/ab/wallhaven-abc123.jpg"),
            item(id: "def456", purity: "nsfw", path: "https://w.wallhaven.cc/full/de/wallhaven-def456.jpg"),
            item(id: "bad123", purity: "sfw", path: "https://example.com/photo.jpg"),
        ]
        let data = try JSONSerialization.data(withJSONObject: ["data": items, "meta": ["current_page": 1, "last_page": 900]])
        let page = try WallhavenWallpaperSource.decode(data, query: WallpaperQuery())
        XCTAssertEqual(page.assets.map(\.id), ["wallhaven.abc123"])
        XCTAssertEqual(page.lastPage, 100)
        XCTAssertFalse(WallpaperHTTP.allows(URL(string: "http://w.wallhaven.cc/image.jpg")!))
        XCTAssertFalse(WallpaperHTTP.allows(URL(string: "https://wallhaven.cc.evil.example/image.jpg")!))
    }

    func testShuffleExhaustsCollectionAndHistoryBranchesAfterExplicitApplication() {
        var profile = WallpaperProfile()
        let first = WallpaperSelection.next(candidates: ["a", "b", "c"], current: nil, profile: &profile)
        let second = WallpaperSelection.next(candidates: ["a", "b", "c"], current: first, profile: &profile)
        let third = WallpaperSelection.next(candidates: ["a", "b", "c"], current: second, profile: &profile)
        XCTAssertEqual(Set([first, second, third].compactMap { $0 }), ["a", "b", "c"])
        let fourth = WallpaperSelection.next(candidates: ["a", "b", "c"], current: third, profile: &profile)
        XCTAssertNotEqual(fourth, third)
        var history = WallpaperHistory()
        history.record("a"); history.record("b"); history.record("c")
        history.cursor = 0
        history.record("d")
        XCTAssertEqual(history.entries, ["a", "d"])
        XCTAssertEqual(history.cursor, 1)
        history.cursor = -2
        history.record("e")
        XCTAssertEqual(history.entries, ["e"])
        XCTAssertEqual(history.cursor, 0)
    }

    private func item(id: String, purity: String, path: String) -> [String: Any] {
        ["id": id, "url": "https://wallhaven.cc/w/\(id)", "path": path,
         "purity": purity, "dimension_x": 3840, "dimension_y": 2160,
         "thumbs": ["small": "https://th.wallhaven.cc/small/ab/\(id).jpg"]]
    }
}
