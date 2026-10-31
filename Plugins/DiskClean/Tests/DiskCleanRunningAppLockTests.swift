import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanRunningAppLockTests: XCTestCase {
    func testUnknownProcessStateRemainsLockedAfterRefreshingApplicationIDs() {
        var snapshot = DiskCleanRunningAppSnapshot()
        snapshot.processStateKnown = false
        let refreshed = snapshot.replacingBundleIDs([], observedAt: Date())
        XCTAssertNotNil(refreshed.lockingProcessName(bundleIDs: [], processNames: ["node"]))
        XCTAssertNil(refreshed.lockingProcessName(bundleIDs: [], processNames: []))
    }

    // MARK: - Decision matrix

    func testBundleIDMatchIsCaseInsensitive() {
        let snapshot = DiskCleanRunningAppSnapshot(runningBundleIDs: ["COM.Google.Chrome"])
        let target = DiskCleanRuleTarget.test(id: "browser.chrome", lockedByBundleIDs: ["com.google.chrome"])

        XCTAssertEqual(snapshot.lockingProcessName(for: target), "com.google.chrome")
    }

    func testProcessNameMatchIsCaseSensitive() {
        let snapshot = DiskCleanRunningAppSnapshot(runningProcessNames: ["Docker"])

        XCTAssertEqual(
            snapshot.lockingProcessName(for: .test(id: "a", skipWhenProcessIsRunning: ["Docker"])),
            "Docker"
        )
        XCTAssertNil(
            snapshot.lockingProcessName(for: .test(id: "b", skipWhenProcessIsRunning: ["docker"])),
            "process names are exact matches without case folding"
        )
    }

    func testUnlockedTargetReturnsNil() {
        let snapshot = DiskCleanRunningAppSnapshot(
            runningBundleIDs: ["com.apple.finder"],
            runningProcessNames: ["Xcode"]
        )
        let target = DiskCleanRuleTarget.test(
            id: "a",
            lockedByBundleIDs: ["com.google.Chrome"],
            skipWhenProcessIsRunning: ["Docker"]
        )

        XCTAssertNil(snapshot.lockingProcessName(for: target))
    }

    func testBundleIDTakesPrecedenceOverProcessName() {
        let snapshot = DiskCleanRunningAppSnapshot(
            runningBundleIDs: ["com.vivaldi.vivaldi"],
            runningProcessNames: ["Vivaldi"]
        )
        let target = DiskCleanRuleTarget.test(
            id: "a",
            lockedByBundleIDs: ["com.vivaldi.Vivaldi"],
            skipWhenProcessIsRunning: ["Vivaldi"]
        )

        XCTAssertEqual(snapshot.lockingProcessName(for: target), "com.vivaldi.Vivaldi")
    }

    func testProcessNamesCollectionIsDeduplicatedAndOrdered() {
        let names = DiskCleanRunningAppSnapshot.processNames(in: [
            .test(id: "a", skipWhenProcessIsRunning: ["Docker", "Xcode"]),
            .test(id: "b", skipWhenProcessIsRunning: ["Xcode", "Simulator"]),
            .test(id: "c")
        ])

        XCTAssertEqual(names, ["Docker", "Xcode", "Simulator"])
    }

    // MARK: - Batched pgrep

    func testQueriesAllProcessNamesInASingleSubprocess() async {
        let runner = FakeDiskCleanSubprocessRunner(exitCode: 0, standardOutput: "421 Docker\n99 Xcode\n")
        let lock = DiskCleanRunningAppLock(subprocessRunner: runner)

        let snapshot = await lock.makeSnapshot(processNames: ["Docker", "Xcode", "Simulator"])

        XCTAssertEqual(runner.invocations.count, 1, "one subprocess for all names, replacing v1 per-rule pgrep")
        XCTAssertEqual(
            runner.invocations.first?.arguments,
            ["-x", "-l", "(Docker|Xcode|Simulator)"]
        )
        XCTAssertEqual(snapshot.runningProcessNames, ["Docker", "Xcode"])
    }

    func testSkipsSubprocessWhenNoTargetDeclaresProcessNames() async {
        let runner = FakeDiskCleanSubprocessRunner(exitCode: 0)
        let lock = DiskCleanRunningAppLock(subprocessRunner: runner)

        let snapshot = await lock.makeSnapshot(processNames: [])

        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertTrue(snapshot.runningProcessNames.isEmpty)
    }

    func testTreatsExitCodeOneAsNoMatchRatherThanFailure() async {
        let runner = FakeDiskCleanSubprocessRunner(exitCode: 1, standardOutput: "")
        let lock = DiskCleanRunningAppLock(subprocessRunner: runner)

        let snapshot = await lock.makeSnapshot(processNames: ["Docker"])

        XCTAssertTrue(snapshot.runningProcessNames.isEmpty)
    }

    func testSubprocessFailureDegradesToEmptyProcessSet() async {
        let runner = FakeDiskCleanSubprocessRunner(
            error: DiskCleanSubprocessError.timedOut(path: "/usr/bin/pgrep")
        )
        let lock = DiskCleanRunningAppLock(subprocessRunner: runner)

        let snapshot = await lock.makeSnapshot(processNames: ["Docker"])

        XCTAssertTrue(
            snapshot.runningProcessNames.isEmpty,
            "pgrep failure only under-reports locks; execution dual-point recheck covers it; never abort the scan"
        )
    }

    func testIgnoresProcessNamesOutsideTheRequestedSet() async {
        let runner = FakeDiskCleanSubprocessRunner(
            exitCode: 0,
            standardOutput: "1 Docker\n2 SomethingElse\n"
        )
        let lock = DiskCleanRunningAppLock(subprocessRunner: runner)

        let snapshot = await lock.makeSnapshot(processNames: ["Docker"])

        XCTAssertEqual(snapshot.runningProcessNames, ["Docker"])
    }

    // MARK: - Parsing and escaping
}
