import Foundation

struct RightClickFailure: LocalizedError, Sendable {
    var message: String
    var path: String = ""
    var errorDescription: String? {
        let text = RightClickStrings.text(message)
        return path.isEmpty ? text : "\(text)\n\(path)"
    }
}

enum RightClickStrings {
    static func text(_ key: String, bundle: Bundle = .main) -> String {
        let languages = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
        for language in Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: languages) {
            if let path = bundle.path(forResource: language, ofType: "lproj"), let localized = Bundle(path: path) {
                let value = localized.localizedString(forKey: key, value: key, table: "RightClick")
                if value != key { return value }
            }
        }
        return bundle.localizedString(forKey: key, value: key, table: "RightClick")
    }
}

/// Managed resources never refer to a user-editable external payload after import.
struct RightClickResourceStore: Sendable {
    var root: URL = RightClickConfigurationStore.configFileURL.deletingLastPathComponent()
        .appendingPathComponent("RightClickResources", isDirectory: true)
    static let maximumFileSize = 64 * 1024 * 1024
    static let maximumArchiveSize = 256 * 1024 * 1024
    static let maximumEntries = 4096

    func url(for resource: RightClickResource) throws -> URL {
        guard Self.safeComponent(resource.filename), resource.filename.hasPrefix(resource.id.uuidString) else {
            throw RightClickFailure(message: "Invalid resource.")
        }
        let url = root.appendingPathComponent(resource.filename)
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard url.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().path == resolvedRoot.path else {
            throw RightClickFailure(message: "Invalid resource.")
        }
        return url
    }

    func importResource(from source: URL, kind: RightClickResource.Kind) throws -> RightClickResource {
        let fm = FileManager.default
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey])
        guard values.isSymbolicLink != true,
              values.isDirectory != true || (kind == .template && values.isPackage == true) else {
            throw RightClickFailure(message: "Choose a file or a document package.")
        }
        let id = UUID()
        let ext = source.pathExtension
        let resource = RightClickResource(id: id, name: source.deletingPathExtension().lastPathComponent,
            kind: kind, filename: id.uuidString + (ext.isEmpty ? "" : ".\(ext)"))
        let destination = try url(for: resource)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        // Read and bound the input before copying. Package payloads must contain no links.
        _ = try files(for: source, id: id)
        try fm.copyItem(at: source, to: staging)
        try fm.moveItem(at: staging, to: destination)
        return resource
    }

    func remove(_ resource: RightClickResource) throws {
        let target = try url(for: resource)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }

    struct Archive: Codable, Sendable {
        var version = 1
        var resources: [RightClickResource]
        var files: [Payload]
    }
    struct Payload: Codable, Sendable {
        var resourceID: UUID
        /// Empty identifies the resource itself; otherwise a relative package path.
        var path: String
        var data: Data?
    }

    func exportArchive(resources: [RightClickResource], to destination: URL) throws {
        var payloads: [Payload] = []
        for resource in resources { payloads += try files(for: url(for: resource), id: resource.id) }
        guard payloads.count <= Self.maximumEntries,
              payloads.reduce(0, { $0 + ($1.data?.count ?? 0) }) <= Self.maximumArchiveSize else {
            throw RightClickFailure(message: "Resource package is too large.")
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(Archive(resources: resources, files: payloads))
        guard data.count <= Self.maximumArchiveSize else { throw RightClickFailure(message: "Resource package is too large.") }
        try data.write(to: destination, options: .withoutOverwriting)
    }

    func importArchive(from source: URL, restoring metadata: [RightClickResource] = []) throws -> [RightClickResource] {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= Self.maximumArchiveSize else { throw RightClickFailure(message: "Resource package is too large.") }
        let data = try Data(contentsOf: source)
        guard data.count <= Self.maximumArchiveSize else { throw RightClickFailure(message: "Resource package is too large.") }
        let archive = try PropertyListDecoder().decode(Archive.self, from: data)
        try Self.validate(archive)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".package-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        var imported: [RightClickResource] = []
        for old in archive.resources {
            let restored = metadata.first { $0.id == old.id && $0.filename == old.filename && $0.kind == old.kind }
            let targetExists = FileManager.default.fileExists(atPath: try url(for: old).path)
            let mayRestore = restored != nil && !targetExists
            let id = mayRestore ? old.id : UUID()
            let ext = URL(fileURLWithPath: old.filename).pathExtension
            let resource = RightClickResource(id: id, name: mayRestore ? restored!.name : old.name, kind: old.kind,
                filename: id.uuidString + (ext.isEmpty ? "" : ".\(ext)"), enabled: mayRestore ? restored!.enabled : old.enabled)
            let target = staging.appendingPathComponent(resource.filename)
            let payloads = archive.files.filter { $0.resourceID == old.id }.sorted {
                $0.path.split(separator: "/").count < $1.path.split(separator: "/").count
            }
            for payload in payloads {
                let path = payload.path.isEmpty ? target : target.appendingPathComponent(payload.path)
                if let bytes = payload.data {
                    try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: path, options: .withoutOverwriting)
                } else {
                    try fm.createDirectory(at: path, withIntermediateDirectories: true)
                }
            }
            imported.append(resource)
        }
        var committed: [URL] = []
        do {
            for resource in imported {
                let target = try url(for: resource)
                try fm.moveItem(at: staging.appendingPathComponent(resource.filename), to: target)
                committed.append(target)
            }
        } catch {
            for target in committed { try? fm.removeItem(at: target) }
            throw error
        }
        return imported
    }

    static func validate(_ archive: Archive) throws {
        let ids = Set(archive.resources.map(\.id))
        guard archive.version == 1, !archive.resources.isEmpty, archive.resources.count <= 256,
              ids.count == archive.resources.count, archive.files.count <= maximumEntries,
              archive.files.reduce(0, { $0 + ($1.data?.count ?? 0) }) <= maximumArchiveSize,
              archive.resources.allSatisfy({ safeComponent($0.filename) && $0.filename.hasPrefix($0.id.uuidString) && !$0.name.isEmpty && $0.name.count <= 200 })
        else { throw RightClickFailure(message: "Invalid resource package.") }
        var paths: Set<String> = []
        for payload in archive.files {
            guard ids.contains(payload.resourceID), payload.data.map({ $0.count <= maximumFileSize }) ?? true,
                  payload.path.isEmpty || safeRelativePath(payload.path),
                  paths.insert(payload.resourceID.uuidString + "/" + payload.path).inserted else {
                throw RightClickFailure(message: "Invalid resource package.")
            }
        }
        for id in ids {
            guard archive.files.contains(where: { $0.resourceID == id && $0.path.isEmpty }) else {
                throw RightClickFailure(message: "Invalid resource package.")
            }
            let filePaths = archive.files.filter { $0.resourceID == id && $0.data != nil }.map(\.path)
            let allPaths = archive.files.filter { $0.resourceID == id }.map(\.path)
            guard !filePaths.contains(where: { file in allPaths.contains { $0 != file && (file.isEmpty || $0.hasPrefix(file + "/")) } }) else {
                throw RightClickFailure(message: "Invalid resource package.")
            }
        }
    }

    private func files(for source: URL, id: UUID) throws -> [Payload] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        let values = try source.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else { throw RightClickFailure(message: "Symbolic links are not supported here.") }
        if values.isDirectory != true {
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= Self.maximumFileSize else {
                throw RightClickFailure(message: "Resource file is too large.")
            }
            let data = try Data(contentsOf: source)
            guard data.count <= Self.maximumFileSize else { throw RightClickFailure(message: "Resource file is too large.") }
            return [Payload(resourceID: id, path: "", data: data)]
        }
        var result = [Payload(resourceID: id, path: "", data: nil)]
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: Array(keys),
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw RightClickFailure(message: "Cannot read resource.")
        }
        var bytes = 0
        for case let url as URL in enumerator {
            let item = try url.resourceValues(forKeys: keys)
            guard item.isSymbolicLink != true, item.isDirectory == true || item.isRegularFile == true,
                  result.count < Self.maximumEntries else { throw RightClickFailure(message: "Invalid resource package.") }
            let relative = String(url.path.dropFirst(source.path.count + 1))
            guard Self.safeRelativePath(relative) else { throw RightClickFailure(message: "Invalid resource package.") }
            var data: Data?
            if item.isRegularFile == true {
                guard (item.fileSize ?? Int.max) <= Self.maximumFileSize else { throw RightClickFailure(message: "Resource file is too large.") }
                data = try Data(contentsOf: url)
                bytes += data?.count ?? 0
                guard bytes <= Self.maximumArchiveSize, (data?.count ?? 0) <= Self.maximumFileSize else {
                    throw RightClickFailure(message: "Resource package is too large.")
                }
            }
            result.append(Payload(resourceID: id, path: relative, data: data))
        }
        if let enumerationError { throw enumerationError }
        return result
    }

    static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.utf8.contains(0)
    }
    static func safeRelativePath(_ value: String) -> Bool {
        !value.hasPrefix("/") && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { safeComponent(String($0)) }
    }
}
