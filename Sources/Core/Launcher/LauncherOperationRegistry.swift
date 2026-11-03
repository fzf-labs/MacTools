import Foundation
import MacToolsPluginKit

/// Host-only adapter for application and settings navigation through the shared executor.
@MainActor
final class LauncherPreparedAction {
    let reference: ActionReference
    private var releaseHandler: (() -> Void)?
    init(reference: ActionReference, release: @escaping () -> Void = {}) {
        self.reference = reference
        releaseHandler = release
    }
    func release() {
        let handler = releaseHandler
        releaseHandler = nil
        handler?()
    }
}

@MainActor
final class LauncherOperationRegistry {
    let providerID: String
    private var operations: [String: @MainActor @Sendable () async -> ActionExecutionResult] = [:]
    private var running: [String: ActionExecutionHandle] = [:]
    init(providerID: String) { self.providerID = providerID }
    var definition: ActionDefinition {
        .init(key: .init(providerID: providerID, actionID: "launcher.perform"),
              title: LauncherText.title, description: LauncherText.description, systemImage: "command.square",
              parameters: [.init(id: "operation", title: "Operation", kind: .string, privacy: .sensitive, portability: .localOnly)],
              externalInvocationPolicy: .unavailable, capabilities: [.foregroundInteractive, .cancellable])
    }
    func prepare(operation: @escaping @MainActor @Sendable () async -> ActionExecutionResult) -> LauncherPreparedAction {
        let id = UUID().uuidString
        operations[id] = operation
        return .init(reference: .init(key: definition.key, parameters: try! ActionParameterSet(["operation": .string(id)])),
                     release: { [weak self] in self?.operations[id] = nil; self?.running[id] = nil })
    }
    func availability(_ reference: ActionReference) -> ActionAvailability {
        guard reference.key == definition.key, case let .string(id)? = reference.parameters["operation"], operations[id] != nil else {
            return .unavailable(PluginKitLocalization.actionInvalidParameters)
        }
        return .available
    }
    func begin(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard invocation.reference.key == definition.key,
              case let .string(id)? = invocation.reference.parameters["operation"], let operation = operations.removeValue(forKey: id) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let handle = ActionExecutionHandle(operation: operation)
        running[id] = handle
        return handle
    }
    func invalidate() {
        operations.removeAll()
        running.values.forEach { $0.cancel() }
        running.removeAll()
    }
}
