import AppKit
import Darwin
import Foundation

enum DiskCleanApplicationChange: Sendable {
    case inventory
    case running(Set<String>)
}

@MainActor
final class DiskCleanApplicationObserver {
    private var notifications: [NSObjectProtocol] = []
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounce: Task<Void, Never>?
    private var pendingInventoryChange = false
    private var pendingRunningIDs = Set<String>()
    private let changed: @MainActor (DiskCleanApplicationChange) -> Void

    init(roots: [String], changed: @escaping @MainActor (DiskCleanApplicationChange) -> Void) {
        self.changed = changed
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let running = name == NSWorkspace.didLaunchApplicationNotification || name == NSWorkspace.didTerminateApplicationNotification
                let id = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                let change: DiskCleanApplicationChange
                if running, let id { change = .running([id]) }
                else { change = .inventory }
                Task { @MainActor [weak self] in self?.schedule(change) }
            })
        }
        for root in roots {
            let fd = open(root, O_EVTONLY | O_NOFOLLOW_ANY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .attrib], queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor [weak self] in self?.schedule(.inventory) } }
            source.setCancelHandler { close(fd) }
            sources.append(source)
            source.resume()
        }
    }

    private func schedule(_ change: DiskCleanApplicationChange) {
        switch change {
        case .inventory: pendingInventoryChange = true
        case let .running(ids): pendingRunningIDs.formUnion(ids)
        }
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self else { return }
            let change: DiskCleanApplicationChange = pendingInventoryChange ? .inventory : .running(pendingRunningIDs)
            pendingInventoryChange = false
            pendingRunningIDs = []
            changed(change)
        }
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        pendingInventoryChange = false
        pendingRunningIDs = []
        for token in notifications { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        notifications.removeAll()
        for source in sources { source.cancel() }
        sources.removeAll()
    }
}
