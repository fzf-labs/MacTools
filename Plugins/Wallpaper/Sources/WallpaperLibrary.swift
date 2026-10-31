import CryptoKit
import Darwin
import Foundation
import ImageIO
import MacToolsFileSystem
import UniformTypeIdentifiers

actor WallpaperLibrary {
    let root: URL
    let cache: URL
    private let fm = FileManager.default
    private var savedRevision: UInt64 = 0
    private var cacheBudget: Int64 = 1_024 * 1_024 * 1_024
    private var lastCacheTrim = Date.distantPast

    init(root: URL, cache: URL) {
        self.root = root
        self.cache = cache
    }

    func load() throws -> WallpaperState {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("library.json")
        guard fm.fileExists(atPath: url.path) else { return WallpaperState() }
        let state = try JSONDecoder().decode(WallpaperState.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw WallpaperFailure.storage }
        return state
    }

    func save(_ state: WallpaperState, revision: UInt64) throws {
        guard revision >= savedRevision else { return }
        let data = try JSONEncoder().encode(state)
        try data.write(to: root.appendingPathComponent("library.json"), options: .atomic)
        savedRevision = revision
        cacheBudget = state.cacheBudget
    }

    static func inspect(_ data: Data) throws -> (Int, Int, String) {
        guard data.count <= 50 * 1_024 * 1_024,
              let image = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(image) == 1,
              let rawType = CGImageSourceGetType(image) as String?,
              let type = UTType(rawType),
              [UTType.jpeg, .png, .heic].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, Int64(width) * Int64(height) <= 100_000_000 else {
            throw WallpaperFailure.invalidImage
        }
        // Dynamic desktop HEIC files carry Apple desktop metadata in addition to image frames.
        if let metadata = CGImageSourceCopyMetadataAtIndex(image, 0, nil),
           let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag],
           tags.contains(where: { tag in
               let namespace = CGImageMetadataTagCopyNamespace(tag) as String? ?? ""
               return namespace.contains("apple.com/namespace") && namespace.contains("desktop")
           }) { throw WallpaperFailure.invalidImage }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: 16] as CFDictionary
        guard CGImageSourceCreateThumbnailAtIndex(image, 0, options) != nil else { throw WallpaperFailure.invalidImage }
        return (width, height, type.preferredFilenameExtension ?? "jpg")
    }

    func prepare(_ asset: WallpaperAsset, remoteData: Data? = nil) throws -> WallpaperAsset {
        if let existing = managedURL(asset), fm.isReadableFile(atPath: existing.path) { return asset }
        let data: Data
        if let remoteData {
            data = remoteData
        } else if let url = asset.localURL {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 50 * 1_024 * 1_024 else { throw WallpaperFailure.invalidImage }
            data = try Data(contentsOf: url)
        } else { throw WallpaperFailure.missingFile }
        try Task.checkCancellation()
        let (width, height, ext) = try Self.inspect(data)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = "\(hash).\(ext)"
        let destination = root.appendingPathComponent(name)
        if !fm.fileExists(atPath: destination.path) { try data.write(to: destination, options: .atomic) }
        var imported = asset
        imported.managedName = name
        imported.width = width
        imported.height = height
        return imported
    }

    nonisolated func managedURL(_ asset: WallpaperAsset) -> URL? {
        guard let name = asset.managedName,
              name.range(of: #"^[a-f0-9]{64}\.(jpg|jpeg|png|heic)$"#, options: .regularExpression) != nil else { return nil }
        return root.appendingPathComponent(name)
    }

    func readable(_ asset: WallpaperAsset) -> Bool {
        guard let url = managedURL(asset) else { return false }
        return fm.isReadableFile(atPath: url.path)
    }

    func thumbnail(_ asset: WallpaperAsset, remoteData: Data? = nil) throws -> Data? {
        let key = SHA256.hash(data: Data(asset.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let cached = cache.appendingPathComponent(key + ".jpg")
        if let data = try? Data(contentsOf: cached) { return data }
        let source: CGImageSource?
        if let remoteData {
            guard remoteData.count <= 4 * 1_024 * 1_024 else { return nil }
            source = CGImageSourceCreateWithData(remoteData as CFData, nil)
        } else if let url = managedURL(asset) ?? asset.localURL {
            source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        } else { return nil }
        guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
        ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { return nil }
        let data = output as Data
        try data.write(to: cached, options: .atomic)
        if Date().timeIntervalSince(lastCacheTrim) > 60 {
            try trimThumbnails(clear: false, budget: cacheBudget)
            lastCacheTrim = .now
        }
        return data
    }

    func scan(_ folders: [WallpaperFolder]) throws -> WallpaperScan {
        var result = WallpaperScan()
        for var folder in folders {
            try Task.checkCancellation()
            var stale = false
            do {
                folder.url = try URL(resolvingBookmarkData: folder.bookmark, options: [.withoutUI],
                                     relativeTo: nil, bookmarkDataIsStale: &stale)
                if stale { folder.bookmark = try folder.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
                let access = folder.url.startAccessingSecurityScopedResource()
                defer { if access { folder.url.stopAccessingSecurityScopedResource() } }
                // URL normalization deliberately keeps /var aliases; O_NOFOLLOW_ANY needs realpath.
                guard let physical = realpath(folder.url.path, nil) else { throw WallpaperFailure.missingFile }
                let physicalURL = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
                free(physical)
                var pending = [physicalURL]
                var partial = false
                while let directory = pending.popLast() {
                    try Task.checkCancellation()
                    do {
                        try FileSystemDirectoryReader.readBatches(path: directory.path, cancelled: { Task.isCancelled }) { batch in
                            if batch.skippedCount > 0 { partial = true }
                            for entry in batch.entries {
                                guard let name = entry.displayName, !name.hasPrefix("."),
                                      name.utf8.elementsEqual((entry.nameBytes ?? []).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }) else { continue }
                                let url = directory.appendingPathComponent(name)
                                if entry.fileType == .directory, folder.recursive {
                                    let values = try? url.resourceValues(forKeys: [.isPackageKey])
                                    if values?.isPackage == false { pending.append(url) }
                                } else if entry.fileType == .regularFile,
                                          ["jpg", "jpeg", "png", "heic"].contains(url.pathExtension.lowercased()) {
                                    let id = "local.\(folder.id.uuidString).\(entry.devid ?? 0).\(entry.fileID ?? 0).\(entry.modificationDate?.timeIntervalSince1970 ?? 0)"
                                    result.assets.append(WallpaperAsset(id: id, title: name, localURL: url, folderID: folder.id,
                                                                       modifiedAt: entry.modificationDate))
                                }
                            }
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { partial = true }
                }
                if partial { result.issues[folder.id] = "partial" }
                else { result.completeFolderIDs.insert(folder.id) }
                result.resolvedFolders.append(folder)
            } catch is CancellationError { throw CancellationError() }
            catch { result.issues[folder.id] = "access" }
        }
        return result
    }

    func usage() throws -> (managed: Int64, cached: Int64) {
        func size(_ directory: URL) throws -> Int64 {
            try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]).reduce(0) {
                let values = try $1.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                return $0 + (values.isRegularFile == true ? Int64(values.fileSize ?? 0) : 0)
            }
        }
        return try (size(root), size(cache))
    }

    func clean(state: WallpaperState, clear: Bool) throws {
        let pinned = state.appliedIDs.union(state.favorites)
        let names = Set(pinned.compactMap { state.assets[$0]?.managedName }).union(state.appliedNames)
        let candidates = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        for url in candidates where url.lastPathComponent != "library.json" && !names.contains(url.lastPathComponent) {
            guard url.lastPathComponent.range(of: #"^[a-f0-9]{64}\.(jpg|jpeg|png|heic)$"#, options: .regularExpression) != nil else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true, values.isSymbolicLink != true { try fm.removeItem(at: url) }
        }
        try trimThumbnails(clear: clear, budget: state.cacheBudget)
    }

    private func trimThumbnails(clear: Bool, budget: Int64) throws {
        let files = try fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey])
            .filter { $0.lastPathComponent.range(of: #"^[a-f0-9]{64}\.jpg$"#, options: .regularExpression) != nil }
        let sorted = files.sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
        var total = try usage().cached
        for url in sorted where clear || total > budget {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { continue }
            try fm.removeItem(at: url)
            total -= Int64(values.fileSize ?? 0)
        }
    }
}
