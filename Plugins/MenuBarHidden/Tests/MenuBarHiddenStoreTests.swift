// SPDX-License-Identifier: GPL-3.0-only
// Restored and adapted for MacTools on 2026-09-07.

import XCTest
import MacToolsPluginKit
@testable import MenuBarHiddenPlugin

@MainActor
final class MenuBarHiddenStoreTests: XCTestCase {

    func testPortableOrderingAndRequestedFlagsSurviveDeniedPermissions() throws {
        let source = MenuBarHiddenStore(storage: FakePluginStorage())
        source.isEnabled = true
        source.isAlwaysHiddenEnabled = true
        source.showsHiddenIconsInPanel = true
        source.recordVisibleHiddenLayout(visibleKeys: ["v2", "v1"], hiddenKeys: ["h2", "h1"])
        source.orderedAlwaysHiddenItemStableKeys = ["missing", "a2", "a1"]
        let data = try XCTUnwrap(source.portableBackup())
        let destination = MenuBarHiddenStore(storage: FakePluginStorage())
        let manager = MenuBarHiddenManager(store: destination, permissionProvider: {
            MenuBarHiddenPermissionsStatus(hasAccessibility: false, hasScreenRecording: false)
        })
        XCTAssertTrue(manager.restorePortableBackup(data))
        XCTAssertTrue(destination.isEnabled)
        XCTAssertTrue(destination.isAlwaysHiddenEnabled)
        XCTAssertTrue(destination.showsHiddenIconsInPanel)
        XCTAssertEqual(destination.visibleItemStableKeys, ["v2", "v1"])
        XCTAssertEqual(destination.hiddenItemStableKeys, ["h2", "h1"])
        XCTAssertEqual(destination.orderedAlwaysHiddenItemStableKeys, ["missing", "a2", "a1"])
        XCTAssertEqual(destination.portableBackup(), data)
    }

    func testVisibleHiddenLayoutPersistsStableKeysInOrderWithoutDuplicates() {
        let storage = MenuBarHiddenMemoryStorage()
        let store = MenuBarHiddenStore(storage: storage)

        store.recordVisibleHiddenLayout(
            visibleKeys: ["com.example.a:Item", "com.example.a:Item", ""],
            hiddenKeys: ["com.example.b:Item", "com.example.a:Item", "com.example.c:Item"]
        )

        XCTAssertTrue(store.hasVisibleHiddenLayout)
        XCTAssertEqual(storage.stringArray(forKey: "visible-item-stable-keys"), [
            "com.example.a:Item",
        ])
        XCTAssertEqual(storage.stringArray(forKey: "hidden-item-stable-keys"), [
            "com.example.b:Item",
            "com.example.c:Item",
        ])
        XCTAssertEqual(MenuBarHiddenStore(storage: storage).visibleItemStableKeys, [
            "com.example.a:Item",
        ])
        XCTAssertEqual(MenuBarHiddenStore(storage: storage).hiddenItemStableKeys, [
            "com.example.b:Item",
            "com.example.c:Item",
        ])
    }

    func testAlwaysHiddenItemStableKeysPreserveOrderWithoutDuplicates() {
        let storage = MenuBarHiddenMemoryStorage()
        let store = MenuBarHiddenStore(storage: storage)
        let first = MenuBarItemTag(namespace: "com.example.b", title: "Item", windowID: nil, instanceIndex: 0)
        let second = MenuBarItemTag(namespace: "com.example.a", title: "Item", windowID: nil, instanceIndex: 1)

        store.recordAlwaysHiddenItem(first)
        store.recordAlwaysHiddenItem(second)
        store.recordAlwaysHiddenItem(first)

        XCTAssertEqual(storage.stringArray(forKey: "always-hidden-item-stable-keys"), [
            "com.example.b:Item",
            "com.example.a:Item:1",
        ])
        XCTAssertEqual(MenuBarHiddenStore(storage: storage).alwaysHiddenItemStableKeys, [
            "com.example.a:Item:1",
            "com.example.b:Item",
        ])
    }

    func testRemovingLastAlwaysHiddenItemClearsStorage() {
        let storage = MenuBarHiddenMemoryStorage()
        let store = MenuBarHiddenStore(storage: storage)
        let tag = MenuBarItemTag(namespace: "com.example.app", title: "Item", windowID: nil, instanceIndex: 0)

        store.recordAlwaysHiddenItem(tag)
        store.removeAlwaysHiddenItem(tag)

        XCTAssertTrue(store.alwaysHiddenItemStableKeys.isEmpty)
        XCTAssertNil(storage.stringArray(forKey: "always-hidden-item-stable-keys"))
    }
}
