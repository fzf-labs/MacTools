import Foundation

/// Shared by all sections. Actor reentrancy is guarded across the awaited write operation.
actor DiskCleanSerialExecutor: DiskCleanExecuting {
    private let base: any DiskCleanExecuting
    private var isExecuting = false
    init(base: any DiskCleanExecuting) { self.base = base }
    func execute(plan: DiskCleanValidatedPlan) async throws -> DiskCleanExecutionResult {
        guard !isExecuting else {
            throw DiskCleanExecutionError.safetyRejected(path: "", reason: "另一项清理正在执行，请稍后重试")
        }
        isExecuting = true
        defer { isExecuting = false }
        return try await base.execute(plan: plan)
    }
}
