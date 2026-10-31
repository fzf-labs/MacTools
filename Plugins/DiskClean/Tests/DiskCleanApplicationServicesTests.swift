import Foundation
import XCTest
@testable import DiskCleanPlugin

final class DiskCleanApplicationServicesTests: XCTestCase {
    func testServiceAttributionRequiresOwnedProgramAndRejectsChangedOrInjectedConfigurations() throws {
        let root = try DiskCleanTempDirectory(name: "ApplicationServiceProof")
        defer { root.remove() }
        let id = "org.example.editor"
        let label = "org.example.external-agent"
        let contents = try root.makeDirectory("Apps/Editor.app/Contents")
        try write(["CFBundleIdentifier": id, "SMPrivilegedExecutables": [label: "identifier org.example.external-agent"]], at: contents.appendingPathComponent("Info.plist"))
        let program = try root.makeFile("Apps/Editor.app/Contents/MacOS/Editor", bytes: 4).path
        let path = try root.makeDirectory("Home/Library/LaunchAgents").appendingPathComponent(id + ".agent.plist")
        try write(["Label": label, "ProgramArguments": [program]], at: path)
        let app = DiskCleanInstalledApplication(path: contents.deletingLastPathComponent().path, bundleID: id, name: "Editor", executable: "Editor", rejection: nil)
        let identity = DiskCleanApplicationIdentity.read(bundleID: id, copies: [app])
        let result = DiskCleanApplicationOwnership(home: root.resolve("Home").path).resolve(bundleID: id, identity: identity)
        let item = try XCTUnwrap(result.associations.first { $0.path == path.path })
        XCTAssertEqual(item.category, .services)
        XCTAssertNil(item.manualReason)
        let proof = try XCTUnwrap(item.proof?.service)
        XCTAssertNil(proof.rejection())
        let shared = DiskCleanApplicationOwnership(home: root.resolve("Home").path).resolve(bundleID: id, identity: identity, otherOwners: [label])
        XCTAssertNotNil(shared.associations.first { $0.path == path.path }?.manualReason)
        try write(["Label": id + ".agent", "ProgramArguments": ["/usr/bin/true"]], at: path)
        XCTAssertNotNil(proof.rejection())
        XCTAssertNil(DiskCleanApplicationServiceProof.read(path: path.path, home: root.resolve("Home").path, bundleID: id, copies: [app]))
        try write(["Label": id + ".agent'; touch /tmp/injected", "ProgramArguments": [program]], at: path)
        XCTAssertNil(DiskCleanApplicationServiceProof.read(path: path.path, home: root.resolve("Home").path, bundleID: id, copies: [app]))
    }

    func testServiceStopHandlesAlreadyStoppedAndFailsClosedWhenStateIsUnknown() async throws {
        let root = try DiskCleanTempDirectory(name: "ApplicationServiceStop")
        defer { root.remove() }
        let path = try root.makeFile("agent.plist", bytes: 4).path
        let contents = try Data(contentsOf: URL(fileURLWithPath: path))
        for domain in ["gui/501", "system"] {
            let proof = DiskCleanApplicationServiceProof(path: path, program: root.resolve("Program").path,
                label: "org.example.editor.agent", domain: domain, contents: contents, helperTeam: nil, helperRequirement: nil)
            let runner = ServiceFixtureRunner(results: [.init(exitCode: 0, standardOutput: Data(("program = " + proof.program + "\npath = " + proof.path).utf8)),
                .init(exitCode: 0, standardOutput: Data()), .init(exitCode: 113, standardOutput: Data())])
            try await DiskCleanApplicationServices(runner: runner).stop(proof)
            let targets = await runner.targets
            XCTAssertEqual(Set(targets), [proof.target!])
            let scripts = await runner.administrativeScripts
            XCTAssertEqual(scripts.count, domain == "system" ? 1 : 0)
            XCTAssertTrue(scripts.allSatisfy { $0.contains(proof.target!) && !$0.contains(proof.program) })
            let unknown = ServiceFixtureRunner(results: [.init(exitCode: 5, standardOutput: Data())])
            do {
                try await DiskCleanApplicationServices(runner: unknown).stop(proof)
                XCTFail("An unknown service state must not authorize stopping a job")
            } catch {}
            let changed = await unknown.mutations
            XCTAssertEqual(changed, 0)
            let spoofed = ServiceFixtureRunner(results: [.init(exitCode: 0, standardOutput: Data(("program = /usr/bin/true\npath = " + proof.path + "\narguments = {\nprogram = " + proof.program + "\n}").utf8))])
            do {
                try await DiskCleanApplicationServices(runner: spoofed).stop(proof)
                XCTFail("Ambiguous loaded-job metadata must not authorize stopping a service")
            } catch {}
            let spoofedChanges = await spoofed.mutations
            XCTAssertEqual(spoofedChanges, 0)
        }
    }

    private func write(_ plist: [String: Any], at url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }
}

private actor ServiceFixtureRunner: DiskCleanSubprocessRunning {
    var results: [DiskCleanSubprocessResult]
    var targets: [String] = []
    var mutations = 0
    var administrativeScripts: [String] = []
    init(results: [DiskCleanSubprocessResult]) { self.results = results }
    func run(executablePath: String, arguments: [String], timeout: Duration) async throws -> DiskCleanSubprocessResult {
        if arguments.first == "bootout" { mutations += 1 }
        if executablePath == "/usr/bin/osascript" {
            mutations += 1
            if let script = arguments.last { administrativeScripts.append(script) }
        } else if let target = arguments.last { targets.append(target) }
        guard !results.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return results.removeFirst()
    }
}
