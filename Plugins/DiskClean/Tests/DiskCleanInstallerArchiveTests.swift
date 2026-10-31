import Foundation
import XCTest
@testable import DiskCleanPlugin

final class DiskCleanInstallerArchiveTests: XCTestCase {
    func testInspectsInstallerNamesWithoutAcceptingOrdinaryCorruptOrEncryptedZIPs() throws {
        let root = try DiskCleanTempDirectory(name: "InstallerArchive")
        defer { root.remove() }
        let cases: [(String, Data, Bool)] = [
            ("App.zip", Self.archive(names: ["Tool.app/Contents/Info.plist"]), true),
            ("Photos.zip", Self.archive(names: ["Pictures/photo.jpg"]), false),
            ("Encrypted.zip", Self.archive(names: ["Tool.app/Contents/Info.plist"], encrypted: true), false),
            ("Corrupt.zip", Data([1, 2, 3]), false),
            ("Traversal.zip", Self.archive(names: ["../Tool.app/Contents/Info.plist"]), false)
        ]
        for (name, data, expected) in cases {
            let url = root.resolve(name)
            try data.write(to: url)
            XCTAssertEqual(DiskCleanInstallerArchive.isInstaller(path: url.path), expected, name)
        }
    }

    static func archive(names: [String], encrypted: Bool = false) -> Data {
        var data = Data()
        var central = Data()
        func header(_ count: Int, _ fields: [(Int, UInt32, Int)]) -> Data {
            var bytes = [UInt8](repeating: 0, count: count)
            for (offset, value, width) in fields {
                for index in 0..<width { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
            }
            return Data(bytes)
        }
        for name in names {
            let bytes = Data(name.utf8)
            let localOffset = data.count
            data.append(header(30, [(0, 0x04034b50, 4), (4, 20, 2), (6, encrypted ? 1 : 0, 2), (26, UInt32(bytes.count), 2)]))
            data.append(bytes)
            central.append(header(46, [(0, 0x02014b50, 4), (4, 20, 2), (6, 20, 2), (8, encrypted ? 1 : 0, 2),
                                        (28, UInt32(bytes.count), 2), (42, UInt32(localOffset), 4)]))
            central.append(bytes)
        }
        let location = data.count
        data.append(central)
        data.append(header(22, [(0, 0x06054b50, 4), (8, UInt32(names.count), 2), (10, UInt32(names.count), 2),
                               (12, UInt32(central.count), 4), (16, UInt32(location), 4)]))
        return data
    }
}
