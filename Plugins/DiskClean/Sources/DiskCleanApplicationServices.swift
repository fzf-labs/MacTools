import AppKit
import Darwin
import Foundation
import Security

struct DiskCleanApplicationServiceProof: Equatable, Sendable {
    let path: String
    let program: String
    let label: String?
    let domain: String
    let contents: Data?
    let helperTeam: String?
    let helperRequirement: String?
    var ownerID: String? = nil

    var target: String? { label.map { domain + "/" + $0 } }

    static func read(path: String, home: String, bundleID: String, copies: [DiskCleanInstalledApplication]) -> Self? {
        guard !copies.isEmpty, copies.allSatisfy({ Bundle(path: $0.path)?.bundleIdentifier == bundleID }) else { return nil }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let userAgents = DiskCleanPhysicalPath.resolve(home + "/Library/LaunchAgents")
        let isHelper = parent == "/Library/PrivilegedHelperTools"
        guard isHelper || [userAgents, "/Library/LaunchAgents", "/Library/LaunchDaemons"].contains(parent),
              DiskCleanPhysicalPath.realpath(of: path) == path else { return nil }
        let contents = isHelper ? nil : DiskCleanProjectRecognition.readSmallFile(path)
        let plist = contents.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let arguments = plist?["ProgramArguments"] as? [String]
        guard let program = isHelper ? path : (plist?["Program"] as? String ?? arguments?.first),
              program.hasPrefix("/"), !program.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              DiskCleanPhysicalPath.realpath(of: program) == program else { return nil }
        let label = plist?["Label"] as? String
        if !isHelper {
            let declarations = Set(copies.flatMap {
                Array((Bundle(path: $0.path)?.object(forInfoDictionaryKey: "SMPrivilegedExecutables") as? [String: String] ?? [:]).keys)
            })
            guard let label, DiskCleanApplicationInventory.validBundleID(label),
                  label.lowercased() == bundleID.lowercased() || label.lowercased().hasPrefix(bundleID.lowercased() + ".")
                    || declarations.contains(label) else { return nil }
        }
        let insideBundle = copies.contains { program.hasPrefix($0.path + "/Contents/") }
        var team: String?
        var requirement: String?
        var ownerID = bundleID
        if !insideBundle {
            guard URL(fileURLWithPath: program).deletingLastPathComponent().path == "/Library/PrivilegedHelperTools",
                  let helper = DiskCleanApplicationIdentity.signingInfo(program), let helperTeam = helper.team else { return nil }
            let declarations = copies.compactMap { app -> String? in
                guard DiskCleanApplicationIdentity.signingInfo(app.path)?.team == helperTeam else { return nil }
                return (Bundle(path: app.path)?.object(forInfoDictionaryKey: "SMPrivilegedExecutables") as? [String: String])?[helper.id]
            }
            guard let value = declarations.first, validSignature(program, requirement: value) else { return nil }
            team = helperTeam
            requirement = value
            ownerID = helper.id
        }
        return .init(path: path, program: program, label: label,
            domain: parent == "/Library/LaunchDaemons" ? "system" : "gui/" + String(getuid()),
            contents: contents, helperTeam: team, helperRequirement: requirement, ownerID: ownerID)
    }

    func rejection() -> String? {
        guard DiskCleanPhysicalPath.realpath(of: path) == path else { return "后台组件位置已变化" }
        if let contents, DiskCleanProjectRecognition.readSmallFile(path) != contents { return "后台服务配置已变化，请重新检查" }
        if let helperTeam, let helperRequirement {
            guard let signature = DiskCleanApplicationIdentity.signingInfo(program), signature.team == helperTeam, signature.id == ownerID,
                  Self.validSignature(program, requirement: helperRequirement) else { return "辅助组件签名已变化" }
        }
        return nil
    }

    private static func validSignature(_ path: String, requirement: String) -> Bool {
        var code: SecStaticCode?
        var expected: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(requirement as CFString, [], &expected) == errSecSuccess,
              let code, let expected else { return false }
        return SecStaticCodeCheckValidity(code, [], expected) == errSecSuccess
    }
}

protocol DiskCleanApplicationServiceManaging: Sendable {
    func stop(_ proof: DiskCleanApplicationServiceProof) async throws
    func isStopped(_ proof: DiskCleanApplicationServiceProof) async throws -> Bool
}

struct DiskCleanApplicationServices: DiskCleanApplicationServiceManaging {
    var runner: any DiskCleanSubprocessRunning = LocalDiskCleanSubprocessRunner()

    func isStopped(_ proof: DiskCleanApplicationServiceProof) async throws -> Bool {
        guard let target = proof.target else { return true }
        let result = try await runner.run(executablePath: "/bin/launchctl", arguments: ["print", target], timeout: .seconds(3))
        if result.exitCode == 0 {
            let lines = String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines.filter({ $0.hasPrefix("program = ") }) == ["program = " + proof.program],
                  lines.filter({ $0.hasPrefix("path = ") }) == ["path = " + proof.path] else {
                throw CocoaError(.fileReadNoPermission)
            }
            return false
        }
        guard result.exitCode == 113 else { throw CocoaError(.fileReadUnknown) }
        return true
    }

    func stop(_ proof: DiskCleanApplicationServiceProof) async throws {
        guard proof.rejection() == nil else { throw CocoaError(.fileReadCorruptFile) }
        guard let target = proof.target, try await !isStopped(proof) else { return }
        if proof.domain == "system" {
            let command = "/bin/launchctl bootout " + Self.shellQuote(target)
            let script = "do shell script " + Self.appleScriptQuote(command) + " with administrator privileges"
            let result = try await runner.run(executablePath: "/usr/bin/osascript", arguments: ["-e", script], timeout: .seconds(120))
            guard result.exitCode == 0 else { throw CocoaError(.fileWriteNoPermission) }
        } else {
            let result = try await runner.run(executablePath: "/bin/launchctl", arguments: ["bootout", target], timeout: .seconds(8))
            guard result.exitCode == 0 else { throw CocoaError(.fileWriteNoPermission) }
        }
        guard try await isStopped(proof) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
