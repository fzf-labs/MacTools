import AppKit
import MacToolsPluginKit

@MainActor
final class LauncherSystemActionProvider {
    private var previousApplication: NSRunningApplication?
    private let perform: @MainActor @Sendable (LauncherSystemAction, NSRunningApplication?) async -> ActionExecutionResult

    init(perform: @escaping @MainActor @Sendable (LauncherSystemAction, NSRunningApplication?) async -> ActionExecutionResult = {
        await LauncherSystemActionRunner.run($0, previousApplication: $1)
    }) { self.perform = perform }

    func captureTarget() {
        let app = NSWorkspace.shared.frontmostApplication
        previousApplication = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
    }
    func command(for reference: ActionReference) -> LauncherSystemAction? {
        guard reference.key.providerID == LauncherSystemAction.providerID, reference.schemaVersion == 1,
              reference.parameters == .empty else { return nil }
        return LauncherSystemAction(rawValue: reference.key.actionID)
    }
    var registration: ActionProviderRegistration {
        .init(providerID: LauncherSystemAction.providerID, identity: ObjectIdentifier(self),
              definitions: LauncherSystemAction.allCases.map(\.definition), catalogEntries: [],
              availability: { [weak self] in
                  self?.command(for: $0) != nil ? .available : .unavailable(LauncherText.unavailable)
              }, begin: { [weak self] invocation in
                  guard let self, let command = command(for: invocation.reference) else {
                      return .failure(.invalidParameters(LauncherText.unavailable))
                  }
                  // Capture the target for this execution before the next launcher session can replace it.
                  let target = previousApplication
                  return .success(ActionExecutionHandle { [perform] in
                      guard !Task.isCancelled else { return .cancelled }
                      return await perform(command, target)
                  })
              })
    }
}
