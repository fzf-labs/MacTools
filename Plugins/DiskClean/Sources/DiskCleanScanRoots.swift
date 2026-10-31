import Foundation

struct DiskCleanScanRootsStore: @unchecked Sendable {
    let key: String
    let defaults: [String]
    var preferences: UserDefaults = .standard
    var preservesDefaults = false
    func load() -> [String] { normalized((preservesDefaults ? defaults : []) + (preferences.stringArray(forKey: key) ?? defaults)) }
    func normalized(_ roots: [String]) -> [String] {
        var seen = Set<String>()
        return roots.map { DiskCleanPhysicalPath.realpath(of: $0) ?? $0 }.filter { seen.insert($0).inserted }
    }
}

struct DiskCleanScanRoots: Sendable {
    let paths: [String]

    init(store: DiskCleanScanRootsStore) { paths = store.load() }
}
