import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

/// Hover changes stay local until a drop commits the order once.
struct RightClickMenuDrag {
    enum Item: Equatable {
        case category(RightClickCategory)
        case action(RightClickAction)
    }

    let token = UUID()
    let item: Item
    let originalCategories: [RightClickCategory]
    let originalActions: [RightClickAction]
    var categories: [RightClickCategory]
    var actions: [RightClickAction]

    init(item: Item, configuration: RightClickConfiguration) {
        self.item = item
        originalCategories = configuration.orderedCategories
        originalActions = configuration.orderedActions
        categories = originalCategories
        actions = originalActions
    }

    func accepts(_ target: Item) -> Bool {
        switch (item, target) {
        case (.category, .category): true
        case let (.action(source), .action(destination)): source.category == destination.category
        default: false
        }
    }

    mutating func preview(at target: Item, after: Bool) {
        switch (item, target) {
        case let (.category(source), .category(destination)):
            categories = inserting(source, at: destination, after: after, in: categories)
        case let (.action(source), .action(destination)) where source.category == destination.category:
            actions = inserting(source, at: destination, after: after, in: actions)
        default: break
        }
    }

    private func inserting<T: Equatable>(_ source: T, at target: T, after: Bool, in values: [T]) -> [T] {
        guard source != target, values.contains(source) else { return values }
        var result = values.filter { $0 != source }
        guard let index = result.firstIndex(of: target) else { return values }
        result.insert(source, at: index + (after ? 1 : 0))
        return result
    }
}

struct RightClickMenuDropTarget: ViewModifier {
    let accepts: () -> Bool
    let hover: (Bool) -> Void
    let commit: () -> Bool
    @State private var height: CGFloat = 44

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { height = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, value in height = value }
                }
            }
            .onDrop(of: [.text], delegate: RightClickMenuDropDelegate(
                height: height, accepts: accepts, hover: hover, commit: commit
            ))
    }
}

private struct RightClickMenuDropDelegate: DropDelegate {
    let height: CGFloat
    let accepts: () -> Bool
    let hover: (Bool) -> Void
    let commit: () -> Bool

    func validateDrop(info: DropInfo) -> Bool { accepts() }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard accepts() else { return DropProposal(operation: .forbidden) }
        hover(info.location.y >= height / 2)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard accepts() else { return false }
        hover(info.location.y >= height / 2)
        return commit()
    }
}

/// The workspace owns the source so animated row moves cannot detach its session.
@MainActor
final class RightClickMenuDragSource: NSObject, ObservableObject, NSDraggingSource {
    private var completion: (() -> Void)?
    var isDragging: Bool { completion != nil }

    func begin(completion: @escaping () -> Void) { self.completion = completion }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let end = completion
        completion = nil
        end?()
    }
}

struct RightClickMenuDragHandle: NSViewRepresentable {
    let title: String
    let symbol: String
    let help: String
    let reduceMotion: Bool
    let source: RightClickMenuDragSource
    let begin: () -> UUID
    let cancel: (UUID) -> Void

    func makeNSView(context: Context) -> RightClickMenuDragHandleView { RightClickMenuDragHandleView() }

    func updateNSView(_ view: RightClickMenuDragHandleView, context: Context) {
        view.title = title
        view.symbol = symbol
        view.toolTip = help
        view.reduceMotion = reduceMotion
        view.source = source
        view.begin = begin
        view.cancel = cancel
    }
}

final class RightClickMenuDragHandleView: NSImageView {
    var title = ""
    var symbol = ""
    var reduceMotion = false
    var source: RightClickMenuDragSource?
    var begin: (() -> UUID)?
    var cancel: ((UUID) -> Void)?
    private var mouseDownPoint: NSPoint?

    init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
        imageScaling = .scaleNone
        contentTintColor = .tertiaryLabelColor
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { mouseDownPoint = event.locationInWindow }
    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let initial = mouseDownPoint, let source, !source.isDragging,
              let begin, let cancel, let container = window?.contentView,
              hypot(event.locationInWindow.x - initial.x, event.locationInWindow.y - initial.y) >= 3 else { return }
        mouseDownPoint = nil
        let token = begin()
        source.begin { cancel(token) }
        let preview = draggingImage()
        let item = NSDraggingItem(pasteboardWriter: token.uuidString as NSString)
        let point = container.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - preview.size.width + 15, y: point.y - preview.size.height / 2,
                                     width: preview.size.width, height: preview.size.height), contents: preview)
        let session = container.beginDraggingSession(with: [item], event: event, source: source)
        session.draggingFormation = .none
        session.animatesToStartingPositionsOnCancelOrFail = !reduceMotion
    }

    private func draggingImage() -> NSImage {
        let font = PluginTypography.body.nsFont
        let textInset: CGFloat = symbol.isEmpty ? 12 : 40
        let width = min(320, max(130, ceil((title as NSString).size(withAttributes: [.font: font]).width) + textInset + 12))
        let image = NSImage(size: NSSize(width: width, height: 36))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            let rect = NSRect(origin: .zero, size: image.size).insetBy(dx: 1, dy: 1)
            let shape = NSBezierPath(roundedRect: rect, xRadius: PluginSettingsTheme.Radius.control, yRadius: PluginSettingsTheme.Radius.control)
            NSColor.windowBackgroundColor.setFill()
            shape.fill()
            NSColor.separatorColor.setStroke()
            shape.stroke()
            if !symbol.isEmpty {
                let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                icon?.draw(in: NSRect(x: 12, y: 9, width: 18, height: 18))
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (title as NSString).draw(in: NSRect(x: textInset, y: (36 - font.pointSize - 4) / 2, width: width - textInset - 12, height: font.pointSize + 5),
                                    withAttributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
            image.unlockFocus()
        }
        return image
    }
}
