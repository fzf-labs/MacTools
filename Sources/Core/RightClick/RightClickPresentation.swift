import AppKit
import SwiftUI
import MacToolsPluginKit

@MainActor
final class RightClickTaskPresentation: NSObject, ObservableObject, NSWindowDelegate {
    @Published var completed = 0
    @Published var total = 0
    @Published var finished = false
    @Published var details = ""
    @Published var title = ""
    let cancellation = RightClickCancellation()
    private var controller: NSWindowController?

    func show(title: String) {
        self.title = title
        if let controller { controller.window?.title = title; controller.showWindow(nil); return }
        let view = RightClickTaskView(model: self)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 480, height: 260))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        controller = NSWindowController(window: window)
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil)
    }
    func update(_ count: Int, total: Int) { completed = count; self.total = total }
    func finish(_ result: RightClickFileResult) {
        finished = true
        if result.failures.isEmpty && !result.cancelled && result.skipped == 0 {
            close()
        } else {
            let summary = "\(RightClickStrings.text("Completed")): \(result.outputs.count) · \(RightClickStrings.text("Skipped")): \(result.skipped)"
            details = ([summary] + (result.cancelled ? [RightClickStrings.text("Cancelled. Completed items were kept.")] : []) + result.failures).joined(separator: "\n\n")
        }
    }
    func close() { controller?.close(); controller = nil }
    func windowWillClose(_ notification: Notification) {
        if !finished { cancellation.cancel() }
        controller = nil
    }
}

private struct RightClickTaskView: View {
    @ObservedObject var model: RightClickTaskPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            if !model.finished {
                if model.total > 0 {
                    ProgressView(value: Double(model.completed), total: Double(model.total))
                    Text("\(model.completed) / \(model.total)").font(PluginSettingsTheme.Typography.monospacedValue)
                } else { ProgressView().controlSize(.small) }
            }
            ScrollView {
                Text(model.details.isEmpty ? RightClickStrings.text("Processing files…") : model.details)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(RightClickStrings.text(model.finished ? "Close" : "Cancel")) {
                    if model.finished { model.close() }
                    else { model.cancellation.cancel(); model.details = RightClickStrings.text("Stopping after the current file…") }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(PluginSettingsTheme.Spacing.pagePadding)
        .frame(minWidth: 440, minHeight: 220)
    }
}

@MainActor
enum RightClickDialogs {
    static func error(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = RightClickStrings.text("Operation Failed")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: RightClickStrings.text("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    static func confirm(_ action: RightClickAction, selection: RightClickSelection, destination: URL? = nil, paths: [String]? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = RightClickStrings.text(action.title)
        alert.informativeText = RightClickStrings.text("Review the selected items before continuing.") + "\n\n" + (paths ?? selection.urls.map(\.path)).prefix(8).joined(separator: "\n")
            + (selection.items.count > 8 ? "\n… (\(selection.items.count))" : "")
            + (destination.map { "\n\n→ " + $0.path } ?? "")
        alert.addButton(withTitle: RightClickStrings.text("Continue"))
        alert.addButton(withTitle: RightClickStrings.text("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
    static func name(title: String, initial: String) -> String? {
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
        let alert = NSAlert()
        alert.messageText = RightClickStrings.text(title)
        alert.accessoryView = field
        alert.addButton(withTitle: RightClickStrings.text("Continue"))
        alert.addButton(withTitle: RightClickStrings.text("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
    static func collision(destination: URL, title: String = "Files with the same name exist.", sources: [URL] = []) -> RightClickCollision? {
        let alert = NSAlert()
        alert.messageText = RightClickStrings.text(title)
        alert.informativeText = destination.path + "\n" + RightClickStrings.text("Choose how to handle existing items. Folders are never merged.")
            + "\n\n" + sources.prefix(8).map(\.path).joined(separator: "\n")
        alert.addButton(withTitle: RightClickStrings.text("Keep Both"))
        alert.addButton(withTitle: RightClickStrings.text("Skip"))
        alert.addButton(withTitle: RightClickStrings.text("Replace"))
        alert.addButton(withTitle: RightClickStrings.text("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal().rawValue {
        case 1000: return .keepBoth
        case 1001: return .skip
        case 1002:
            let confirmation = NSAlert()
            confirmation.messageText = RightClickStrings.text("Replace existing items?")
            confirmation.informativeText = RightClickStrings.text("Existing destinations will be moved to Trash before replacement.") + "\n\n" + alert.informativeText
            confirmation.addButton(withTitle: RightClickStrings.text("Cancel"))
            confirmation.addButton(withTitle: RightClickStrings.text("Replace"))
            return confirmation.runModal() == .alertSecondButtonReturn ? .replace : nil
        default: return nil
        }
    }

    static func rename(_ sources: [URL]) -> RightClickRenameOptions? {
        let model = RightClickRenameEditor(sources: sources)
        let host = NSHostingView(rootView: RightClickRenameView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
        let alert = NSAlert()
        alert.messageText = RightClickStrings.text("Batch Rename")
        alert.accessoryView = host
        alert.addButton(withTitle: RightClickStrings.text("Rename"))
        alert.addButton(withTitle: RightClickStrings.text("Cancel"))
        model.onValidityChange = { alert.buttons.first?.isEnabled = $0 }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, model.valid else { return nil }
        return model.options
    }
}

@MainActor
private final class RightClickRenameEditor: ObservableObject {
    @Published var options = RightClickRenameOptions() { didSet { refresh() } }
    @Published var preview = ""
    @Published var valid = false
    let sources: [URL]
    var onValidityChange: ((Bool) -> Void)?
    init(sources: [URL]) { self.sources = sources }
    func refresh() {
        do {
            let pairs = try RightClickFileOperations().renamePreview(sources, options: options)
            valid = pairs.contains { $0.0 != $0.1 }
            preview = pairs.prefix(100).map { "\($0.0.lastPathComponent) → \($0.1.lastPathComponent)" }.joined(separator: "\n")
            if pairs.count > 100 { preview += "\n… (\(pairs.count))" }
        } catch { valid = false; preview = error.localizedDescription }
        onValidityChange?(valid)
    }
}

private struct RightClickRenameView: View {
    @ObservedObject var model: RightClickRenameEditor
    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                TextField(RightClickStrings.text("Find"), text: $model.options.find)
                TextField(RightClickStrings.text("Replace With"), text: $model.options.replacement)
            }
            HStack {
                TextField(RightClickStrings.text("Prefix"), text: $model.options.prefix)
                TextField(RightClickStrings.text("Suffix"), text: $model.options.suffix)
            }
            HStack {
                Toggle(RightClickStrings.text("Numbering"), isOn: $model.options.numbered)
                TextField(RightClickStrings.text("Start"), value: $model.options.start, format: .number)
                    .frame(width: 80)
                Toggle(RightClickStrings.text("Preserve Extension"), isOn: $model.options.preserveExtension)
            }
            ScrollView {
                Text(model.preview).font(PluginSettingsTheme.Typography.monospacedValue)
                    .foregroundStyle(model.valid ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
    }
}
