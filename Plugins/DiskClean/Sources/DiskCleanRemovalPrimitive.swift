import Darwin
import Foundation

// MARK: - Terminal disposition

/// Terminal disposition for one item (design §7.5).
///
/// Every case is an **honest** record: mid-delete failure is not reported as success; blocked
/// rollback is not reported as rolled back.
enum DiskCleanRemovalDisposition: Equatable, Sendable {
    /// Permanent delete finished; staged object no longer exists.
    case removed
    /// Moved to Trash. The name is staged for ordinary cleanup, or the native Trash name
    /// for installed-app removal.
    case trashed(stagedName: String)
    /// Identity recheck mismatch: object was replaced or changed after the scan. Original object
    /// was **not touched**.
    case changedSinceScan
    /// Failed before freeze, or failed after freeze and rolled back successfully. Original path object intact.
    case failed(reason: String)
    /// Mid-delete I/O failure; tree already half-deleted. Rollback is meaningless; debris stays under the staged name.
    case partiallyDeleted(stagedName: String, reason: String)
    /// Post-freeze disposition failed and rollback was blocked (original path already rebuilt).
    /// Staged object retained for reconciliation.
    case rollbackBlocked(stagedName: String, reason: String)
}

/// Seam for the verify-freeze-delete primitive. Executor depends only on this protocol; tests inject fakes here.
protocol DiskCleanPlanItemRemoving: Sendable {
    func remove(
        _ item: DiskCleanValidatedPlan.PlanItem,
        mode: DiskCleanRemovalMode
    ) -> DiskCleanRemovalDisposition
}

// MARK: - Injection seams

/// Trash seam.
///
/// Separate protocol not only for testability: the real implementation puts objects in the user's
/// Trash, and the repo hard-requires "filesystem tests must never touch real user directories", so
/// tests must be able to block this step.
protocol DiskCleanTrashing: Sendable {
    func trashItem(atPath path: String) throws
}

struct DiskCleanSystemTrash: DiskCleanTrashing {
    func trashItem(atPath path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }
}

/// Source of entry device IDs for prewalk (design §7.4 "whole-tree devid consistency").
///
/// Mount crossings cannot be constructed in a real-filesystem temp directory—mounting needs root.
/// Device-ID checks therefore need an injection point; otherwise this safety branch is only
/// reviewable, never testable. Same reason M1 left an entry-source seam on the walker.
protocol DiskCleanStagedEntryDeviceResolving: Sendable {
    func deviceID(ofEntry nameBytes: [CChar], statResult: stat) -> UInt64
}

struct DiskCleanRealStagedEntryDeviceResolver: DiskCleanStagedEntryDeviceResolving {
    func deviceID(ofEntry nameBytes: [CChar], statResult: stat) -> UInt64 {
        UInt64(UInt32(bitPattern: statResult.st_dev))
    }
}

// MARK: - Primitive

/// Verify-freeze-delete primitive (design §7.3, §7.4). The safety core.
///
/// Order is not interchangeable; each step closes a window:
/// 1. Open parent with `O_NOFOLLOW_ANY` + `fstatfs` local-volume check—any path component replaced
///    by a symlink fails here.
/// 2. `fstatat(AT_SYMLINK_NOFOLLOW)` rechecks `(devid, fileID, fileType, mtime)` (regular files also
///    compare size)—objects replaced after the scan are stopped here; never mis-delete.
/// 3. Journal is written and **fsync succeeds** before rename—the reverse would leave "unlogged
///    staged objects" that SafetyPolicy protects from scans while nobody knows their original name,
///    so user data effectively vanishes.
/// 4. `renameatx_np(RENAME_EXCL)` atomically renames to the staged name—object leaves the original
///    path and the path-replacement window closes; `RENAME_EXCL` never overwrites an existing object.
/// 5. Disposition (trash / recursive delete) always acts on the **staged path**.
///
/// Residual risk (design §7.7): deleting a directory deletes its full contents **at execution time**.
/// Root identity match ≠ deep contents match the scan—root mtime only reflects direct-child
/// add/remove. Acceptable semantics for cache directories.
struct DiskCleanRemovalPrimitive: DiskCleanPlanItemRemoving {
    /// Staged-name prefix. SafetyPolicy uses it to keep staged objects out of every scan's candidates (§7.6).
    static let stagedNamePrefix = ".mactools-staged-"
    /// Depth cap for prewalk and recursive delete: each level holds a directory fd; uncapped would
    /// hit EMFILE or blow the stack. Hitting the cap fails closed—do not risk continuing.
    static let maximumTreeDepth = 128

    private let journal: DiskCleanStagingJournal
    private let trash: any DiskCleanTrashing
    private let deviceResolver: any DiskCleanStagedEntryDeviceResolving
    private let stagedNameFactory: @Sendable () -> String
    private let now: @Sendable () -> Date

    init(
        journal: DiskCleanStagingJournal,
        trash: any DiskCleanTrashing = DiskCleanSystemTrash(),
        deviceResolver: any DiskCleanStagedEntryDeviceResolving = DiskCleanRealStagedEntryDeviceResolver(),
        stagedNameFactory: @escaping @Sendable () -> String = {
            DiskCleanRemovalPrimitive.stagedNamePrefix + UUID().uuidString
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.journal = journal
        self.trash = trash
        self.deviceResolver = deviceResolver
        self.stagedNameFactory = stagedNameFactory
        self.now = now
    }

    func remove(
        _ item: DiskCleanValidatedPlan.PlanItem,
        mode: DiskCleanRemovalMode
    ) -> DiskCleanRemovalDisposition {
        guard let location = ParentAnchoredPath(path: item.path) else {
            return .failed(reason: "无法解析父目录：\(item.path)")
        }

        // Reject symlinks along the whole chain: any intermediate component replaced by a link elsewhere fails here.
        let parentDescriptor = Darwin.open(
            location.parentPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_NONBLOCK
        )
        guard parentDescriptor >= 0 else {
            let code = errno
            // Parent gone → object cannot still be at the original place; treat as changed, not failed.
            return code == ENOENT ? .changedSinceScan : .failed(reason: Self.describe(code, doing: "打开父目录"))
        }
        defer { close(parentDescriptor) }

        guard Self.isLocalVolume(fileDescriptor: parentDescriptor) else {
            return .failed(reason: "父目录不在本地卷上")
        }

        switch verifyIdentity(parentDescriptor: parentDescriptor, name: location.name, item: item) {
        case .mismatch:
            return .changedSinceScan
        case let .failure(reason):
            return .failed(reason: reason)
        case .match:
            break
        }

        let staged: StagedObject
        switch stage(parentDescriptor: parentDescriptor, location: location, mode: mode) {
        case let .failure(disposition):
            return disposition
        case let .success(object):
            staged = object
        }

        // Post-freeze recheck: the object under the staged name must still be the same one.
        // Under RENAME_EXCL this step "should never fail"—and "should never" is exactly the kind
        // of assertion safety code must verify explicitly.
        guard identityMatches(parentDescriptor: parentDescriptor, name: staged.name, expected: item.rootIdentity) else {
            return rollback(
                parentDescriptor: parentDescriptor,
                staged: staged,
                originalName: location.name,
                reason: "暂存后身份复核不符",
                dispositionAfterRollback: .changedSinceScan
            )
        }

        switch mode {
        case .trash:
            return moveToTrash(
                parentDescriptor: parentDescriptor,
                staged: staged,
                location: location
            )
        case .permanent:
            return deletePermanently(
                parentDescriptor: parentDescriptor,
                staged: staged,
                location: location,
                item: item
            )
        }
    }

    // MARK: - Identity verification (§7.3)

    private enum IdentityOutcome {
        case match
        case mismatch
        case failure(reason: String)
    }

    private func verifyIdentity(
        parentDescriptor: Int32,
        name: String,
        item: DiskCleanValidatedPlan.PlanItem
    ) -> IdentityOutcome {
        var status = stat()
        guard fstatat(parentDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            return code == ENOENT ? .mismatch : .failure(reason: Self.describe(code, doing: "复核对象身份"))
        }

        // (devid, fileID, fileType) exact match + mtime compare. Replacement by a same-named new
        // directory or symlink shows up here as a fileID or fileType difference.
        guard DiskCleanRootIdentity(stat: status) == item.rootIdentity else {
            return .mismatch
        }
        // Regular files also compare size: when content is rewritten but mtime is preserved, size is the second evidence.
        if item.rootIdentity.fileType == .regularFile, status.st_size != item.estimatedBytes {
            return .mismatch
        }
        return .match
    }

    private func identityMatches(
        parentDescriptor: Int32,
        name: String,
        expected: DiskCleanRootIdentity
    ) -> Bool {
        var status = stat()
        guard fstatat(parentDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        return DiskCleanRootIdentity(stat: status) == expected
    }

    // MARK: - Freeze (§7.4 steps 1–2)

    private struct StagedObject {
        let entryID: String
        let name: String
    }

    private enum StageOutcome {
        case success(StagedObject)
        case failure(DiskCleanRemovalDisposition)
    }

    private func stage(
        parentDescriptor: Int32,
        location: ParentAnchoredPath,
        mode: DiskCleanRemovalMode
    ) -> StageOutcome {
        // UUID collision probability is negligible, but RENAME_EXCL EEXIST can also mean another
        // process happened to take the name—retry once with a new name; if still conflicting, give up
        // (no infinite retries).
        for attempt in 0..<2 {
            let stagedName = stagedNameFactory()
            let entry = DiskCleanStagingJournal.Entry(
                id: UUID().uuidString,
                timestamp: now(),
                parentPath: location.parentPath,
                originalName: location.name,
                stagedName: stagedName,
                mode: mode.rawValue
            )

            // Hard ordering rule: rename only after begin + fsync returns successfully. If the journal cannot be written, do not touch the file.
            do {
                try journal.begin(entry)
            } catch {
                return .failure(.failed(reason: "无法写入暂存日志：\(error.localizedDescription)"))
            }

            let status = renameatx_np(
                parentDescriptor,
                location.name,
                parentDescriptor,
                stagedName,
                UInt32(RENAME_EXCL)
            )
            if status == 0 {
                return .success(StagedObject(entryID: entry.id, name: stagedName))
            }

            let code = errno
            // rename did not happen → no staged object; complete the entry immediately so reconciliation does not spin on it.
            journal.complete(entryID: entry.id, status: "abortedBeforeRename", at: now())

            if code == EEXIST, attempt == 0 {
                continue
            }
            if code == ENOENT {
                return .failure(.changedSinceScan)
            }
            return .failure(.failed(reason: Self.describe(code, doing: "暂存改名")))
        }
        return .failure(.failed(reason: "暂存名连续冲突"))
    }

    /// Rollback: `RENAME_EXCL` rename back to the original name.
    ///
    /// **Original path being rebuilt is common for cache processes** (apps rebuild their own cache
    /// directories while running). Never overwrite in that case: keep the staged object, return
    /// `rollbackBlocked`, leave the journal entry **incomplete**, and hand off to startup
    /// reconciliation or the user.
    private func rollback(
        parentDescriptor: Int32,
        staged: StagedObject,
        originalName: String,
        reason: String,
        dispositionAfterRollback: DiskCleanRemovalDisposition
    ) -> DiskCleanRemovalDisposition {
        let status = renameatx_np(
            parentDescriptor,
            staged.name,
            parentDescriptor,
            originalName,
            UInt32(RENAME_EXCL)
        )
        guard status == 0 else {
            let code = errno
            // Leave the journal incomplete for recovery, but release the in-process active
            // mark so same-process reconciliation can still pick the entry up.
            journal.releaseActive(entryID: staged.entryID)
            return .rollbackBlocked(
                stagedName: staged.name,
                reason: "\(reason)；回滚失败：\(Self.describe(code, doing: "改回原名"))"
            )
        }
        journal.complete(entryID: staged.entryID, status: "rolledBack", at: now())
        return dispositionAfterRollback
    }

    // MARK: - Trash (§7.4 step 3)

    private func moveToTrash(
        parentDescriptor: Int32,
        staged: StagedObject,
        location: ParentAnchoredPath
    ) -> DiskCleanRemovalDisposition {
        // Act on the **staged path**: `trashItem` re-resolves by path; calling it on the original
        // path reopens the replacement window §7.3 just closed.
        let stagedPath = Self.join(location.parentPath, staged.name)
        do {
            try trash.trashItem(atPath: stagedPath)
        } catch {
            let reason = "移入废纸篓失败：\(error.localizedDescription)"
            return rollback(
                parentDescriptor: parentDescriptor,
                staged: staged,
                originalName: location.name,
                reason: reason,
                dispositionAfterRollback: .failed(reason: reason)
            )
        }
        journal.complete(entryID: staged.entryID, status: "trashed", at: now())
        return .trashed(stagedName: staged.name)
    }

    // MARK: - Permanent delete (§7.4 step 3)

    private func deletePermanently(
        parentDescriptor: Int32,
        staged: StagedObject,
        location: ParentAnchoredPath,
        item: DiskCleanValidatedPlan.PlanItem
    ) -> DiskCleanRemovalDisposition {
        // Non-directory: single unlinkat, no prewalk. For symlinks, delete the link itself; never follow.
        guard item.rootIdentity.fileType == .directory else {
            guard unlinkat(parentDescriptor, staged.name, 0) == 0 else {
                let reason = Self.describe(errno, doing: "删除对象")
                return rollback(
                    parentDescriptor: parentDescriptor,
                    staged: staged,
                    originalName: location.name,
                    reason: reason,
                    dispositionAfterRollback: .failed(reason: reason)
                )
            }
            journal.complete(entryID: staged.entryID, status: "removed", at: now())
            return .removed
        }

        // Non-destructive prewalk: walk the whole tree read-only first to confirm no mount
        // crossings and no abnormal entries. Fail → rollback. Discovering problems mid-delete
        // means the tree is already missing a piece, and rollback is then meaningless.
        switch prewalk(
            parentDescriptor: parentDescriptor,
            name: staged.name,
            expectedDevice: item.rootIdentity.devid,
            depth: 0
        ) {
        case .ok:
            break
        case .crossedMountPoint:
            let reason = "暂存树内发现挂载点，已放弃删除"
            return rollback(
                parentDescriptor: parentDescriptor,
                staged: staged,
                originalName: location.name,
                reason: reason,
                dispositionAfterRollback: .failed(reason: reason)
            )
        case let .failure(walkReason):
            let reason = "删除前检查失败：\(walkReason)"
            return rollback(
                parentDescriptor: parentDescriptor,
                staged: staged,
                originalName: location.name,
                reason: reason,
                dispositionAfterRollback: .failed(reason: reason)
            )
        }

        do {
            try journal.markIrreversible(entryID: staged.entryID, at: now())
        } catch {
            let reason = "无法确认不可逆删除日志：\(error.localizedDescription)"
            return rollback(
                parentDescriptor: parentDescriptor,
                staged: staged,
                originalName: location.name,
                reason: reason,
                dispositionAfterRollback: .failed(reason: reason)
            )
        }

        if let reason = deleteTree(
            parentDescriptor: parentDescriptor,
            nameBytes: Array(staged.name.utf8CString),
            expectedDevice: item.rootIdentity.devid,
            expectedFileID: item.rootIdentity.fileID,
            depth: 0
        ) {
            // The durable irreversible phase prevents startup recovery from renaming this
            // half-deleted tree back even if the terminal record cannot be persisted.
            journal.complete(entryID: staged.entryID, status: "partiallyDeleted", at: now())
            return .partiallyDeleted(stagedName: staged.name, reason: reason)
        }
        journal.complete(entryID: staged.entryID, status: "removed", at: now())
        return .removed
    }

    // MARK: - fd-relative tree walk

    private enum TreeOutcome {
        case ok
        case crossedMountPoint
        case failure(reason: String)
    }

    /// Read-only prewalk: fully fd-relative addressing; per-entry `fstatat(AT_SYMLINK_NOFOLLOW)` device-ID check.
    private func prewalk(
        parentDescriptor: Int32,
        name: String,
        expectedDevice: UInt64,
        depth: Int
    ) -> TreeOutcome {
        prewalk(
            parentDescriptor: parentDescriptor,
            nameBytes: Array(name.utf8CString),
            expectedDevice: expectedDevice,
            depth: depth
        )
    }

    private func prewalk(
        parentDescriptor: Int32,
        nameBytes: [CChar],
        expectedDevice: UInt64,
        depth: Int
    ) -> TreeOutcome {
        guard depth < Self.maximumTreeDepth else {
            return .failure(reason: "目录层级超过 \(Self.maximumTreeDepth) 层")
        }
        guard let directory = OpenDirectory(parentDescriptor: parentDescriptor, nameBytes: nameBytes) else {
            let code = errno
            return .failure(reason: Self.describe(code, doing: "打开暂存目录"))
        }
        defer { directory.close() }

        var directoryStatus = stat()
        guard fstat(directory.descriptor, &directoryStatus) == 0 else {
            return .failure(reason: Self.describe(errno, doing: "复核暂存目录"))
        }
        guard deviceResolver.deviceID(ofEntry: nameBytes, statResult: directoryStatus) == expectedDevice else {
            return .crossedMountPoint
        }

        var childDirectories: [[CChar]] = []
        while let entry = directory.next() {
            var status = stat()
            let statResult = entry.nameBytes.withUnsafeBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return -1 }
                return fstatat(directory.descriptor, base, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard statResult == 0 else {
                return .failure(reason: Self.describe(errno, doing: "读取条目属性"))
            }
            guard deviceResolver.deviceID(ofEntry: entry.nameBytes, statResult: status) == expectedDevice else {
                return .crossedMountPoint
            }
            if DiskCleanRootIdentity.FileType(mode: status.st_mode) == .directory {
                childDirectories.append(entry.nameBytes)
            }
        }
        if let code = directory.readError {
            return .failure(reason: Self.describe(code, doing: "枚举暂存目录"))
        }

        for childName in childDirectories {
            let outcome = prewalk(
                parentDescriptor: directory.descriptor,
                nameBytes: childName,
                expectedDevice: expectedDevice,
                depth: depth + 1
            )
            guard case .ok = outcome else { return outcome }
        }
        return .ok
    }

    /// fd recursive delete. Returns nil when the whole tree is gone; otherwise the first failure reason.
    ///
    /// Entry names stay as raw `[CChar]` bytes with no `String` round-trip: illegal UTF-8 names
    /// converted to String and back lose bytes and would point at a different (or missing) object on delete.
    private func deleteTree(
        parentDescriptor: Int32,
        nameBytes: [CChar],
        expectedDevice: UInt64,
        expectedFileID: UInt64,
        depth: Int
    ) -> String? {
        guard depth < Self.maximumTreeDepth else {
            return "目录层级超过 \(Self.maximumTreeDepth) 层"
        }
        guard let directory = OpenDirectory(parentDescriptor: parentDescriptor, nameBytes: nameBytes) else {
            return Self.describe(errno, doing: "打开暂存目录")
        }

        var directoryStatus = stat()
        guard fstat(directory.descriptor, &directoryStatus) == 0 else {
            let reason = Self.describe(errno, doing: "复核暂存目录")
            directory.close()
            return reason
        }
        guard deviceResolver.deviceID(ofEntry: nameBytes, statResult: directoryStatus) == expectedDevice else {
            directory.close()
            return "暂存树内发现挂载点，已停止删除"
        }
        guard directoryStatus.st_ino == expectedFileID else {
            directory.close()
            return "暂存目录在打开前发生变化，已停止删除"
        }

        // Read the whole directory before deleting: interleaving readdir and unlink makes stream position semantics implementation-dependent.
        var entries: [[CChar]] = []
        while let entry = directory.next() {
            entries.append(entry.nameBytes)
        }
        if let code = directory.readError {
            directory.close()
            return Self.describe(code, doing: "枚举暂存目录")
        }

        var failureReason: String?
        for entryNameBytes in entries where failureReason == nil {
            var status = stat()
            let statResult = entryNameBytes.withUnsafeBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return -1 }
                return fstatat(directory.descriptor, base, &status, AT_SYMLINK_NOFOLLOW)
            }
            if statResult != 0 {
                if errno == ENOENT { continue }
                failureReason = Self.describe(errno, doing: "删除前复核条目")
                continue
            }
            guard deviceResolver.deviceID(ofEntry: entryNameBytes, statResult: status) == expectedDevice else {
                failureReason = "暂存树内发现挂载点，已停止删除"
                continue
            }

            if DiskCleanRootIdentity.FileType(mode: status.st_mode) == .directory {
                failureReason = deleteTree(
                    parentDescriptor: directory.descriptor,
                    nameBytes: entryNameBytes,
                    expectedDevice: expectedDevice,
                    expectedFileID: status.st_ino,
                    depth: depth + 1
                )
            } else {
                let result = entryNameBytes.withUnsafeBufferPointer { buffer -> Int32 in
                    guard let base = buffer.baseAddress else { return -1 }
                    return unlinkat(directory.descriptor, base, 0)
                }
                if result != 0, errno != ENOENT {
                    failureReason = Self.describe(errno, doing: "删除文件")
                }
            }
        }

        // Release the directory fd before rmdir of itself; otherwise unlinkat fails more easily on busy mount points.
        directory.close()
        if let failureReason {
            return failureReason
        }

        var finalStatus = stat()
        let finalStatResult = nameBytes.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return fstatat(parentDescriptor, base, &finalStatus, AT_SYMLINK_NOFOLLOW)
        }
        if finalStatResult != 0 {
            return errno == ENOENT ? nil : Self.describe(errno, doing: "删除前复核目录")
        }
        guard deviceResolver.deviceID(ofEntry: nameBytes, statResult: finalStatus) == expectedDevice,
              finalStatus.st_ino == directoryStatus.st_ino,
              DiskCleanRootIdentity.FileType(mode: finalStatus.st_mode) == .directory else {
            return "暂存目录在删除前发生变化，已停止删除"
        }
        let removeResult = nameBytes.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return unlinkat(parentDescriptor, base, AT_REMOVEDIR)
        }
        if removeResult != 0, errno != ENOENT {
            return Self.describe(errno, doing: "删除目录")
        }
        return nil
    }

    // MARK: - Utilities

    private static func isLocalVolume(fileDescriptor: Int32) -> Bool {
        var fileSystem = statfs()
        guard fstatfs(fileDescriptor, &fileSystem) == 0 else { return false }
        return fileSystem.f_flags & UInt32(MNT_LOCAL) != 0
    }

    static func join(_ parentPath: String, _ name: String) -> String {
        parentPath == "/" ? "/" + name : parentPath + "/" + name
    }

    private static func describe(_ code: Int32, doing action: String) -> String {
        "\(action)失败（\(String(cString: strerror(code)))）"
    }
}

// MARK: - Directory stream

/// RAII wrapper around `openat` + `fdopendir`.
///
/// `closedir` also closes the underlying fd, so fd ownership has exactly one owner throughout: this type.
private final class OpenDirectory {
    struct Entry {
        /// NUL-terminated raw byte name, passed straight back to `fstatat` / `unlinkat`.
        let nameBytes: [CChar]
    }

    let descriptor: Int32
    private let stream: UnsafeMutablePointer<DIR>
    private var isClosed = false
    /// `readdir` error code. nil means enumeration finished normally.
    private(set) var readError: Int32?

    convenience init?(parentDescriptor: Int32, name: String) {
        self.init(parentDescriptor: parentDescriptor, nameBytes: Array(name.utf8CString))
    }

    init?(parentDescriptor: Int32, nameBytes: [CChar]) {
        // Single component + parent already fd-anchored, so O_NOFOLLOW is enough; never follow symlinks.
        let descriptor = nameBytes.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return openat(parentDescriptor, base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return nil }
        guard let stream = fdopendir(descriptor) else {
            let code = errno
            // This type has its own close(); without the module qualifier it would resolve to the instance method.
            Darwin.close(descriptor)
            errno = code
            return nil
        }
        self.descriptor = descriptor
        self.stream = stream
    }

    deinit {
        close()
    }

    func next() -> Entry? {
        guard !isClosed else { return nil }
        while true {
            errno = 0
            guard let directoryEntry = readdir(stream) else {
                let code = errno
                if code != 0 {
                    readError = code
                }
                return nil
            }
            guard let nameBytes = Self.nameBytes(of: directoryEntry), !Self.isDotEntry(nameBytes) else {
                continue
            }
            return Entry(nameBytes: nameBytes)
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        closedir(stream)
    }

    private static func nameBytes(of entry: UnsafeMutablePointer<dirent>) -> [CChar]? {
        let length = Int(entry.pointee.d_namlen)
        guard length > 0 else { return nil }
        return withUnsafePointer(to: entry.pointee.d_name) { tuplePointer in
            let characters = UnsafeRawPointer(tuplePointer).assumingMemoryBound(to: CChar.self)
            var bytes = Array(UnsafeBufferPointer(start: characters, count: length))
            bytes.append(0)
            return bytes
        }
    }

    private static func isDotEntry(_ nameBytes: [CChar]) -> Bool {
        let dot = CChar(UInt8(ascii: "."))
        switch nameBytes.count {
        case 2: return nameBytes[0] == dot
        case 3: return nameBytes[0] == dot && nameBytes[1] == dot
        default: return false
        }
    }
}
