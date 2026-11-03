import AppKit
import MacToolsPluginKit
import SwiftUI
import XCTest
@testable import AIUsagePlugin

@MainActor
final class AIUsageViewModelTests: XCTestCase {
    func testPortableSettingsKeepConsentLocalAndDoNotFetchDuringRestore() async throws {
        let source = makeModel(AIUsageTestClient())
        source.updatePreferences { $0.codexEnabled = false; $0.refreshInterval = 900; $0.showsMenuBar = true; $0.allowsCredentialAccess = true }
        let client = AIUsageTestClient()
        let destination = makeModel(client)
        destination.start()
        XCTAssertTrue(destination.restorePortableBackup(try XCTUnwrap(source.portableBackup())))
        XCTAssertFalse(destination.preferences.codexEnabled)
        XCTAssertEqual(destination.preferences.refreshInterval, 900)
        XCTAssertTrue(destination.preferences.showsMenuBar)
        XCTAssertFalse(destination.preferences.allowsCredentialAccess)
        XCTAssertFalse(destination.preferences.allowsClaudeKeychain)
        let count = await client.count
        XCTAssertEqual(count, 0)
        destination.stop()
    }

    private var date = Date(timeIntervalSince1970: 1_800_000_000)

    func testImportedIntervalReschedulesSuccessfulSnapshotWithoutImmediateFetch() async throws {
        for (oldInterval, newInterval) in [(1800, 120), (120, 1800)] {
            let client = AIUsageTestClient()
            let fetchedAt = date
            await client.setResult(.success(AIUsageSnapshot(windows: [], plan: nil, fetchedAt: fetchedAt)))
            let model = makeModel(client)
            model.updatePreferences { $0.refreshInterval = oldInterval }
            enable(model)
            await settle(model)
            let source = makeModel(AIUsageTestClient())
            source.updatePreferences { $0.refreshInterval = newInterval; $0.claudeEnabled = false }

            XCTAssertTrue(model.restorePortableBackup(try XCTUnwrap(source.portableBackup())))
            XCTAssertEqual(model.states[.codex]?.nextRefresh, fetchedAt.addingTimeInterval(Double(newInterval)))
            var count = await client.count
            XCTAssertEqual(count, 1)
            date = fetchedAt.addingTimeInterval(121)
            model.refresh()
            await settle(model)
            count = await client.count
            XCTAssertEqual(count, newInterval == 120 ? 2 : 1)
            model.stop()
        }
    }

    func testImportedIntervalPreservesFailureAndRateLimitBackoff() async throws {
        for failure in [AIUsageFailure.network, .rateLimited(retryAfter: 900)] {
            let client = AIUsageTestClient()
            let model = makeModel(client)
            model.updatePreferences { $0.refreshInterval = 1800 }
            enable(model)
            await settle(model)
            await client.setResult(.failure(failure))
            date.addTimeInterval(61)
            model.refresh(manual: true)
            await settle(model)
            let deadline = model.states[.codex]?.nextRefresh
            let count = await client.count
            let source = makeModel(AIUsageTestClient())
            source.updatePreferences { $0.refreshInterval = 120; $0.claudeEnabled = false }

            XCTAssertTrue(model.restorePortableBackup(try XCTUnwrap(source.portableBackup())))
            XCTAssertEqual(model.states[.codex]?.nextRefresh, deadline)
            XCTAssertEqual(model.states[.codex]?.failure, failure)
            let after = await client.count
            XCTAssertEqual(after, count)
            model.stop()
        }
    }

    func testConsentGatePreventsCredentialAndNetworkWork() async {
        let client = AIUsageTestClient()
        let model = makeModel(client)
        model.start()
        model.refresh(manual: true)
        await settle(model)
        let count = await client.count
        XCTAssertEqual(count, 0)
        XCTAssertTrue(model.states.isEmpty)
        model.stop()
    }

    func testManualRefreshCoalescesAndEnforcesMinimumInterval() async {
        let client = AIUsageTestClient()
        let model = makeModel(client)
        enable(model)
        model.refresh(manual: true)
        model.refresh(manual: true)
        await settle(model)
        var count = await client.count
        XCTAssertEqual(count, 1)
        model.refresh(manual: true)
        await settle(model)
        count = await client.count
        XCTAssertEqual(count, 1)
        date.addTimeInterval(61)
        model.refresh(manual: true)
        await settle(model)
        count = await client.count
        XCTAssertEqual(count, 2)
        model.stop()
    }

    func testNetworkFailureRetainsSnapshotAndRateLimitCannotBeBypassed() async {
        let client = AIUsageTestClient()
        let model = makeModel(client)
        enable(model)
        await settle(model)
        let first = model.states[.codex]?.snapshot
        await client.setResult(.failure(.network))
        date.addTimeInterval(61)
        model.refresh(manual: true)
        await settle(model)
        XCTAssertEqual(model.states[.codex]?.snapshot, first)
        XCTAssertEqual(model.states[.codex]?.failure, .network)
        await client.setResult(.failure(.rateLimited(retryAfter: 900)))
        date.addTimeInterval(61)
        model.refresh(manual: true)
        await settle(model)
        let count = await client.count
        date.addTimeInterval(61)
        model.refresh(manual: true)
        await settle(model)
        let after = await client.count
        XCTAssertEqual(count, after)
        XCTAssertEqual(model.states[.codex]?.snapshot, first)
        model.stop()
    }

    func testChangedAccountAndExpiredLoginClearPreviousSnapshot() async {
        let client = AIUsageTestClient()
        let model = makeModel(client)
        enable(model)
        await settle(model)
        XCTAssertNotNil(model.states[.codex]?.snapshot)
        await client.setIdentity("new-account")
        await client.setResult(.failure(.network))
        date.addTimeInterval(61)
        model.refresh(manual: true)
        await settle(model)
        XCTAssertNil(model.states[.codex]?.snapshot)
        await client.setResult(.failure(.expired))
        date.addTimeInterval(61)
        model.refresh(manual: true)
        await settle(model)
        XCTAssertNil(model.states[.codex]?.snapshot)
        XCTAssertEqual(model.states[.codex]?.failure, .expired)
        model.stop()
    }

    func testRevokingAccessCancelsWorkAndErasesInMemoryUsage() async {
        let client = AIUsageTestClient()
        let model = makeModel(client)
        enable(model)
        await settle(model)
        date.addTimeInterval(61)
        model.refresh(manual: true)
        model.updatePreferences { $0.allowsCredentialAccess = false }
        await settle(model)
        XCTAssertTrue(model.states.isEmpty)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertFalse(model.preferences.allowsClaudeKeychain)
        model.stop()
    }

    func testAuthorizationIsIndependentOfServiceVisibilityAndFileAccess() async {
        let client = AIUsageTestClient()
        let model = makeModel(client)
        model.updatePreferences { $0.codexEnabled = false; $0.claudeEnabled = false }
        model.start()
        model.setClaudeKeychainAccess(true)
        await settle(model)
        let authorizations = await client.authorizations
        let requests = await client.count
        XCTAssertEqual(authorizations, 1)
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(model.preferences.allowsClaudeKeychain)
        XCTAssertFalse(model.preferences.allowsCredentialAccess)
        model.updatePreferences { $0.claudeEnabled = true }
        await settle(model)
        XCTAssertNotNil(model.states[.claude]?.snapshot)
        let fileAccess = await client.lastFileAccess
        XCTAssertFalse(fileAccess)
        model.updatePreferences { $0.allowsCredentialAccess = true }
        await settle(model)
        model.updatePreferences { $0.allowsCredentialAccess = false; $0.claudeEnabled = false }
        XCTAssertTrue(model.preferences.allowsClaudeKeychain)
        model.setClaudeKeychainAccess(false)
        XCTAssertFalse(model.preferences.allowsClaudeKeychain)
        model.stop()
    }

    private func makeModel(_ client: AIUsageTestClient) -> AIUsageViewModel {
        AIUsageViewModel(storage: AIUsageTestStorage(), client: client, now: { self.date })
    }

    private func enable(_ model: AIUsageViewModel) {
        model.updatePreferences { $0.allowsCredentialAccess = true; $0.claudeEnabled = false }
        model.start()
    }

    private func settle(_ model: AIUsageViewModel) async {
        for _ in 0..<1000 {
            await Task.yield()
            if !model.isRefreshing && !model.isAuthorizingKeychain { return }
        }
        XCTFail("Refresh did not settle")
    }
}

actor AIUsageTestClient: AIUsageFetching {
    private(set) var count = 0
    private(set) var authorizations = 0
    private(set) var lastFileAccess = true
    private var identity = "test-account"
    private var result: Result<AIUsageSnapshot, AIUsageFailure> = .success(snapshot)
    private var providerResults: [AIUsageProvider: Result<AIUsageSnapshot, AIUsageFailure>] = [:]
    static let snapshot = AIUsageSnapshot(windows: [
        AIUsageWindow(id: "session", usedPercent: 34, resetsAt: Date().addingTimeInterval(7200), duration: 18_000),
        AIUsageWindow(id: "weekly", usedPercent: 82, resetsAt: Date().addingTimeInterval(172_800), duration: 604_800)
    ], plan: "plus", fetchedAt: Date())

    func fetch(_ provider: AIUsageProvider, allowsFileAccess: Bool, allowsKeychain: Bool) async -> AIUsageFetchResult {
        count += 1
        lastFileAccess = allowsFileAccess
        await Task.yield()
        return AIUsageFetchResult(credentialID: identity, result: providerResults[provider] ?? result)
    }
    func authorizeClaudeKeychain() async -> AIUsageFailure? { authorizations += 1; return nil }
    func setResult(_ result: Result<AIUsageSnapshot, AIUsageFailure>) {
        self.result = result
        providerResults = [:]
    }
    func setResult(_ result: Result<AIUsageSnapshot, AIUsageFailure>, for provider: AIUsageProvider) {
        providerResults[provider] = result
    }
    func setIdentity(_ identity: String) { self.identity = identity }
}

@MainActor
final class AIUsageTestStorage: PluginStorage {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
}
