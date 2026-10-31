import Foundation

/// Shares duplicate URLs and bounds concurrent image transfers across every visible surface.
actor WallpaperTransferService {
    private struct Request {
        var id: UUID
        var task: Task<Data, Error>
        var consumers: Set<UUID>
    }
    private var requests: [URL: Request] = [:]
    private var running = 0
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    func fetch(_ url: URL, limit: Int) async throws -> Data {
        let consumer = UUID()
        let requestID: UUID
        let task: Task<Data, Error>
        if let existing = requests[url] {
            requestID = existing.id
            task = existing.task
            requests[url]?.consumers.insert(consumer)
        } else {
            requestID = UUID()
            task = Task { try await self.download(url, limit: limit) }
            requests[url] = Request(id: requestID, task: task, consumers: [consumer])
        }
        defer { releaseConsumer(url, requestID: requestID, consumer: consumer) }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: {
            Task { await self.releaseConsumer(url, requestID: requestID, consumer: consumer) }
        }
        try Task.checkCancellation()
        return result
    }

    private func releaseConsumer(_ url: URL, requestID: UUID, consumer: UUID) {
        guard requests[url]?.id == requestID else { return }
        requests[url]?.consumers.remove(consumer)
        if requests[url]?.consumers.isEmpty == true { requests.removeValue(forKey: url)?.task.cancel() }
    }

    private func download(_ url: URL, limit: Int) async throws -> Data {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if running >= 3 {
                try await withCheckedThrowingContinuation { continuation in waiters.append((id, continuation)) }
            } else { running += 1 }
        } onCancel: { Task { await self.cancelWaiter(id) } }
        defer {
            if !waiters.isEmpty { waiters.removeFirst().1.resume() }
            else { running -= 1 }
        }
        try Task.checkCancellation()
        return try await WallpaperHTTP(limit: limit).fetch(url)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }

    func cancelAll() {
        for request in requests.values { request.task.cancel() }
        requests.removeAll()
        let pending = waiters
        waiters.removeAll()
        for (_, continuation) in pending { continuation.resume(throwing: CancellationError()) }
    }
}
