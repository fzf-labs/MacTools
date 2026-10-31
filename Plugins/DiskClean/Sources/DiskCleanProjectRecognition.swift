import Darwin
import Foundation

/// Project names alone are insufficient evidence that a directory is rebuildable.
enum DiskCleanProjectRecognition {
    static func matches(kind: DiskCleanPurgeKind, parent: String) -> Bool {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool {
            var status = stat()
            return lstat(parent + "/" + name, &status) == 0 && (status.st_mode & S_IFMT) == S_IFREG
        }
        func dependency(_ name: String) -> Bool {
            guard let data = readSmallFile(parent + "/package.json"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return ["dependencies", "devDependencies"].contains { (json[$0] as? [String: Any])?[name] != nil }
        }
        let python = exists("pyproject.toml") || exists("setup.py")
        let flutter = readSmallFile(parent + "/pubspec.yaml").flatMap { String(data: $0, encoding: .utf8) }?
            .range(of: "(?m)^\\s+flutter\\s*:", options: .regularExpression) != nil
        switch kind {
        case .pythonCache: return true
        case .nodeModules: return exists("package.json")
        case .rustTarget: return exists("Cargo.toml")
        case .buildOutput: return exists("package.json") || python || exists("build.gradle") || exists("build.gradle.kts") || flutter
        case .distOutput: return exists("package.json") || python
        case .swiftBuild: return exists("Package.swift")
        case .nextOutput: return dependency("next")
        case .nuxtOutput, .nuxtBuild: return dependency("nuxt")
        case .pythonEnvironment, .pythonDotEnvironment:
            return python && readSmallFile(parent + "/" + kind.directoryName + "/pyvenv.cfg") != nil
        case .pytestCache, .mypyCache, .ruffCache: return python
        case .gradleCache: return exists("build.gradle") || exists("build.gradle.kts")
        case .dartCache: return flutter
        case .dotnetBin, .dotnetObj:
            guard let entries = try? DiskCleanDirectoryListing.read(parent) else { return false }
            return entries.contains { !$0.isDirectory && ["csproj", "fsproj", "vbproj"].contains(URL(fileURLWithPath: $0.path).pathExtension) }
        case .composerVendor:
            return exists("composer.json") && exists("composer.lock")
                && fm.fileExists(atPath: parent + "/vendor/composer/installed.json")
        }
    }

    static func readSmallFile(_ path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_flags & UInt32(SF_DATALESS) == 0, info.st_size >= 0, info.st_size <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count else { return nil }
        return Data(bytes)
    }
}
