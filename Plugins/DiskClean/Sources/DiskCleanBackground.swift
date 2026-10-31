import Foundation

/// Propagates cancellation into blocking discovery work without occupying the main actor.
func diskCleanBackground<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) async -> Value {
    let worker = Task.detached(priority: .utility, operation: operation)
    return await withTaskCancellationHandler {
        await worker.value
    } onCancel: {
        worker.cancel()
    }
}
