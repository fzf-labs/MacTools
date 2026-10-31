import AppKit
import Darwin
import Foundation

protocol DiskCleanApplicationTrashRemoving: Sendable {
    func remove(_ item: DiskCleanValidatedPlan.PlanItem) async -> DiskCleanRemovalDisposition
}

protocol DiskCleanApplicationRecycling: Sendable {
    func recycle(reference: DiskCleanApplicationTrashReference) async throws -> URL
}

struct DiskCleanApplicationTrashReference: @unchecked Sendable {
    private let value: CFURL

    init?(path: String) {
        guard let reference = CFURLCreateFileReferenceURL(kCFAllocatorDefault, URL(fileURLWithPath: path) as CFURL, nil)?.takeRetainedValue(),
              CFURLIsFileReferenceURL(reference) else { return nil }
        value = reference
    }

    var isFileReference: Bool { CFURLIsFileReferenceURL(value) }
    var resolvedPath: String? {
        guard let url = CFURLCreateFilePathURL(kCFAllocatorDefault, value, nil)?.takeRetainedValue(),
              let path = CFURLCopyFileSystemPath(url, .cfurlposixPathStyle) else { return nil }
        return path as String
    }

    func recycle() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DiskCleanRecycleApplicationFileReference(value) { destination, error in
                if let error { continuation.resume(throwing: error) }
                else if let destination { continuation.resume(returning: URL(fileURLWithPath: destination)) }
                else { continuation.resume(throwing: CocoaError(.fileWriteUnknown)) }
            }
        }
    }
}

struct DiskCleanWorkspaceRecycler: DiskCleanApplicationRecycling {
    func recycle(reference: DiskCleanApplicationTrashReference) async throws -> URL { try await reference.recycle() }
}

/// Finder receives a file reference, never a replaceable pathname or a shell command.
struct DiskCleanApplicationTrash: DiskCleanApplicationTrashRemoving {
    var recycler: any DiskCleanApplicationRecycling = DiskCleanWorkspaceRecycler()

    func remove(_ item: DiskCleanValidatedPlan.PlanItem) async -> DiskCleanRemovalDisposition {
        guard case .application = item.validation else { return .failed(reason: "此操作仅用于应用卸载") }
        guard !Task.isCancelled else { return .failed(reason: "已取消") }
        let parent = (item.path as NSString).deletingLastPathComponent
        let name = (item.path as NSString).lastPathComponent
        let fd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard fd >= 0 else { return .failed(reason: "无法访问父目录，请检查访问权限") }
        defer { close(fd) }
        var volume = statfs()
        guard fstatfs(fd, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0,
              volume.f_flags & UInt32(MNT_RDONLY) == 0 else { return .failed(reason: "磁盘不可写或不支持移到废纸篓") }
        var status = stat()
        guard fstatat(fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
              DiskCleanRootIdentity(stat: status) == item.rootIdentity,
              item.rootIdentity.fileType == .directory || item.rootIdentity.fileType == .regularFile else {
            return .changedSinceScan
        }
        // Keep the reviewed inode alive while Finder may be waiting for authorization.
        let object = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard object >= 0 else { return .failed(reason: "无法访问父目录，请检查访问权限") }
        defer { close(object) }
        var parentStatus = stat()
        guard fstat(object, &status) == 0, fstat(fd, &parentStatus) == 0,
              DiskCleanRootIdentity(stat: status) == item.rootIdentity else { return .changedSinceScan }
        guard status.st_dev == parentStatus.st_dev else { return .failed(reason: "目录跨越挂载点") }
        guard let reference = DiskCleanApplicationTrashReference(path: item.path),
              let current = reference.resolvedPath, current == item.path,
              lstat(current, &status) == 0, DiskCleanRootIdentity(stat: status) == item.rootIdentity else {
            return .changedSinceScan
        }
        do {
            try Task.checkCancellation()
            let destination = try await recycler.recycle(reference: reference)
            guard lstat(destination.path, &status) == 0,
                  status.st_ino == item.rootIdentity.fileID,
                  UInt64(UInt32(bitPattern: status.st_dev)) == item.rootIdentity.devid else {
                return .failed(reason: "废纸篓操作结果无法确认，请在访达中检查")
            }
            return .trashed(stagedName: destination.lastPathComponent)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }
}
