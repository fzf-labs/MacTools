import AppKit
import SwiftUI

/// Reuses native table cells inside a scrolling form, without introducing another scroll view.
struct SettingsEmbeddedRows<Element: Identifiable, Row: View>: NSViewRepresentable {
    let elements: [Element]
    let rowHeight: CGFloat
    @ViewBuilder let row: (Element) -> Row
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTableView {
        let table = SettingsEmbeddedTableView()
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.intercellSpacing = .zero
        table.rowHeight = rowHeight
        let column = NSTableColumn(identifier: .init("content"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        return table
    }

    func updateNSView(_ table: NSTableView, context: Context) {
        let coordinator = context.coordinator
        let changed = coordinator.content?.elements.map(\.id) != elements.map(\.id)
        coordinator.content = self
        table.rowHeight = rowHeight
        if changed {
            table.reloadData()
        } else {
            // Keep the existing field editor when preferences or other row content change.
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound else { return }
            for index in visible.location..<NSMaxRange(visible) where elements.indices.contains(index) {
                if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? SettingsEmbeddedRowCell {
                    cell.host.rootView = coordinator.contentView(at: index)
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTableView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width, height: CGFloat(elements.count) * rowHeight)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var content: SettingsEmbeddedRows?

        func numberOfRows(in tableView: NSTableView) -> Int { content?.elements.count ?? 0 }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let content, content.elements.indices.contains(row) else { return nil }
            let cell = tableView.makeView(withIdentifier: SettingsEmbeddedRowCell.reuseIdentifier, owner: nil) as? SettingsEmbeddedRowCell
                ?? SettingsEmbeddedRowCell()
            cell.host.rootView = contentView(at: row)
            return cell
        }

        func contentView(at index: Int) -> AnyView {
            guard let content, content.elements.indices.contains(index) else { return AnyView(EmptyView()) }
            let element = content.elements[index]
            return AnyView(content.row(element)
                .id(element.id)
                .environment(\.locale, content.locale)
                .environment(\.layoutDirection, content.layoutDirection))
        }
    }
}

private final class SettingsEmbeddedTableView: NSTableView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
}

private final class SettingsEmbeddedRowCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("settings.embedded-row")
    let host = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
