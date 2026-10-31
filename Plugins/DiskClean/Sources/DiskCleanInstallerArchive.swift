import Darwin
import Foundation

/// Reads only a bounded ZIP central directory. Never extracts, hydrates, or executes an archive.
enum DiskCleanInstallerArchive {
    static func isInstaller(path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_flags & UInt32(SF_DATALESS) == 0, status.st_size >= 22 else { return false }
        let tailSize = Int(min(status.st_size, 65_557))
        guard let tail = read(fd: fd, offset: status.st_size - Int64(tailSize), count: tailSize) else { return false }
        for offset in stride(from: tail.count - 22, through: 0, by: -1) {
            guard word(tail, offset, 4) == 0x06054b50,
                  offset + 22 + word(tail, offset + 20, 2) == tail.count else { continue }
            let count = word(tail, offset + 10, 2)
            let length = word(tail, offset + 12, 4)
            let location = word(tail, offset + 16, 4)
            guard word(tail, offset + 4, 2) == 0, word(tail, offset + 6, 2) == 0,
                  count == word(tail, offset + 8, 2), count > 0, count < 10_000,
                  length > 0, length <= 2_097_152,
                  Int64(location) + Int64(length) == status.st_size - Int64(tailSize) + Int64(offset),
                  let directory = read(fd: fd, offset: Int64(location), count: length) else { return false }
            guard containsInstaller(directory: directory, entryCount: count) else { return false }
            var cursor = 0
            for _ in 0..<count {
                let localOffset = word(directory, cursor + 42, 4)
                guard localOffset < location,
                      let local = read(fd: fd, offset: Int64(localOffset), count: 30),
                      word(local, 0, 4) == 0x04034b50,
                      word(local, 6, 2) == word(directory, cursor + 8, 2),
                      word(local, 8, 2) == word(directory, cursor + 10, 2) else { return false }
                let nameLength = word(directory, cursor + 28, 2)
                let size = word(directory, cursor + 20, 4)
                guard nameLength == word(local, 26, 2),
                      Int64(localOffset) + 30 + Int64(nameLength) + Int64(word(local, 28, 2)) + Int64(size) <= Int64(location),
                      let localName = read(fd: fd, offset: Int64(localOffset) + 30, count: nameLength),
                      localName == Array(directory[(cursor + 46)..<(cursor + 46 + nameLength)]) else { return false }
                cursor += 46 + nameLength + word(directory, cursor + 30, 2) + word(directory, cursor + 32, 2)
            }
            return true
        }
        return false
    }

    static func containsInstaller(directory: [UInt8], entryCount: Int) -> Bool {
        var offset = 0
        var found = false
        for _ in 0..<entryCount {
            guard offset + 46 <= directory.count, word(directory, offset, 4) == 0x02014b50,
                  word(directory, offset + 8, 2) & 1 == 0 else { return false }
            let length = word(directory, offset + 28, 2)
            let end = offset + 46 + length
            let next = end + word(directory, offset + 30, 2) + word(directory, offset + 32, 2)
            guard length > 0, next <= directory.count,
                  let name = String(bytes: directory[(offset + 46)..<end], encoding: .utf8),
                  !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { return false }
            found = found || name.split(separator: "/").contains {
                ["app", "pkg", "mpkg", "dmg", "xip"].contains((String($0) as NSString).pathExtension.lowercased())
            }
            offset = next
        }
        return offset == directory.count && found
    }

    private static func read(fd: Int32, offset: Int64, count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        let actual = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, offset) }
        return actual == count ? bytes : nil
    }
    private static func word(_ bytes: [UInt8], _ offset: Int, _ width: Int) -> Int {
        (0..<width).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
    }
}
