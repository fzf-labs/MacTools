import Foundation

/// Keeps the selection alive through authorization and rejects late permission replies after cancellation.
@MainActor
final class RecordingStartGate {
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    var isPreparing: Bool { task != nil }

    func start(_ request: RecordingRequest,
               authorize: @escaping @MainActor () async -> Bool = { await RecordingAuthorization.requestMicrophone() },
               validate: @escaping @MainActor (RecordingAudioOptions) throws -> Void = { try RecordingAuthorization.validate($0) },
               completion: @escaping @MainActor (Result<RecordingRequest, Error>) -> Void) {
        guard task == nil else { return }
        generation &+= 1
        let token = generation
        task = Task { [weak self] in
            do {
                if request.audio.microphone, !(await authorize()) { throw RecordingRequestError.microphoneDenied }
                try Task.checkCancellation()
                try validate(request.audio)
                guard let self, generation == token else { return }
                task = nil
                completion(.success(request))
            } catch {
                guard let self, generation == token, !Task.isCancelled else { return }
                task = nil
                completion(.failure(error))
            }
        }
    }

    func cancel() { generation &+= 1; task?.cancel(); task = nil }
}
