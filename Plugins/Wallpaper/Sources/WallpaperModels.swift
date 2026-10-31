import Foundation

struct WallpaperAsset: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var title: String
    var localURL: URL?
    var folderID: UUID?
    var remoteURL: URL?
    var thumbnailURL: URL?
    var pageURL: URL?
    var sourceURL: URL?
    var uploader: String?
    var width = 0
    var height = 0
    var managedName: String?
    var queryID: String?
    var modifiedAt: Date?
}

struct WallpaperFolder: Codable, Identifiable, Sendable {
    var id = UUID()
    var url: URL
    var bookmark: Data
    var recursive = false
    var included = true
}

struct WallpaperQuery: Codable, Equatable, Sendable {
    var keywords = "landscape"
    var categories = "100"
    var sorting = "toplist"
    var orientation = "landscape"
    var minimumWidth = 0
    var minimumHeight = 0

    var identity: String {
        [keywords, categories, sorting, orientation, String(minimumWidth), String(minimumHeight)].joined(separator: "|")
    }
}

enum WallpaperCollection: String, Codable, CaseIterable, Sendable {
    case local, favorites, wallhaven
}

struct WallpaperHistory: Codable, Sendable {
    var entries: [String] = []
    var cursor = -1

    mutating func record(_ id: String) {
        if entries.indices.contains(cursor), entries[cursor] == id { return }
        entries = entries.indices.contains(cursor) ? Array(entries.prefix(cursor + 1)) : []
        entries.append(id)
        entries = Array(entries.suffix(100))
        cursor = entries.count - 1
    }
}

struct WallpaperProfile: Codable, Sendable {
    var enabled = false
    var started = false
    var collection = WallpaperCollection.local
    var query = WallpaperQuery()
    var shuffled = true
    var interval: TimeInterval = 1_800
    var fill = true
    var nextDate: Date?
    var pauseReason: String?
    var bag: [String] = []
    var recent: [String] = []
    var expected: [String: WallpaperDesktopState] = [:]
    var admittedDisplays: Set<String> = []
    var retryCount = 0
}

struct WallpaperDesktopState: Codable, Equatable, Sendable {
    var url: URL
    var fill: Bool
    var scaling: UInt = 3
}

struct WallpaperState: Codable, Sendable {
    var version = 1
    var assets: [String: WallpaperAsset] = [:]
    var folders: [WallpaperFolder] = []
    var favorites: Set<String> = []
    var history: [String: WallpaperHistory] = [:]
    var profiles: [String: WallpaperProfile] = ["all": WallpaperProfile()]
    // Keep every applied payload: a hidden Space may still reference it.
    var appliedIDs: Set<String> = []
    var appliedNames: Set<String> = []
    var queryMembership: [String: Set<String>] = [:]
    var selectedScope = "all"
    var independentDisplays = false
    var cacheBudget: Int64 = 1_024 * 1_024 * 1_024
}

struct WallpaperDisplay: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let width: Int
    let height: Int
}

struct WallpaperScan: Sendable {
    var assets: [WallpaperAsset] = []
    var completeFolderIDs: Set<UUID> = []
    var issues: [UUID: String] = [:]
    var resolvedFolders: [WallpaperFolder] = []
}

struct WallpaperPage: Sendable {
    var assets: [WallpaperAsset]
    var page: Int
    var lastPage: Int
}

enum WallpaperFailure: Error, Sendable {
    case invalidImage, missingFile, noCandidates, disconnected, storage, invalidResponse
    case rateLimited(TimeInterval)
    case http(Int)
}

enum WallpaperSelection {
    static func next(candidates: [String], current: String?, profile: inout WallpaperProfile) -> String? {
        let eligible = Array(Set(candidates)).sorted()
        guard !eligible.isEmpty else { return nil }
        if eligible.count == 1 { return eligible[0] }
        if profile.shuffled {
            profile.bag.removeAll { !eligible.contains($0) || $0 == current }
            if profile.bag.isEmpty {
                profile.bag = eligible.filter { $0 != current }.shuffled()
            }
            return profile.bag.removeFirst()
        }
        // The caller supplies natural title order; identity order is only used for shuffle membership.
        let ordered = candidates.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard let current, let index = ordered.firstIndex(of: current) else { return ordered.first }
        return ordered[(index + 1) % ordered.count]
    }
}
