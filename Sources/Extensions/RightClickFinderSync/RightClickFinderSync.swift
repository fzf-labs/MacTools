import AppKit
import FinderSync
import Foundation
import OSLog

final class RightClickFinderSync: FIFinderSync {
    private var requestsByTitle: [String: RightClickRequest] = [:]
    private let scheme = Bundle.main.object(forInfoDictionaryKey: "MTRightClickHostURLScheme") as? String ?? "mactools"
    private let toolbarName = Bundle.main.object(forInfoDictionaryKey: "MTRightClickToolbarItemName") as? String ?? "MacTools"

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/", isDirectory: true)]
    }
    override var toolbarItemName: String { toolbarName }
    override var toolbarItemToolTip: String { toolbarName + " · " + RightClickStrings.text("File Tools") }
    override var toolbarItemImage: NSImage {
        let image = NSImage(systemSymbolName: "contextualmenu.and.cursorarrow", accessibilityDescription: toolbarName) ?? NSImage()
        image.isTemplate = true
        return image
    }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let configuration = RightClickConfigurationStore.load()
        guard configuration.menuEnabled else { return nil }
        let controller = FIFinderSyncController.default()
        let selected = menuKind == .contextualMenuForContainer ? [] : controller.selectedItemURLs() ?? []
        let targeted = controller.targetedURL()
        let directory: URL?
        if let targeted {
            let values = try? targeted.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            directory = values?.isDirectory == true && values?.isPackage != true ? targeted : targeted.deletingLastPathComponent()
        } else { directory = selected.first?.deletingLastPathComponent() }
        guard let selection = try? RightClickSelection.capture(urls: selected, directory: directory, relativeBase: selected.isEmpty ? directory?.deletingLastPathComponent() : directory) else { return nil }
        requestsByTitle.removeAll()
        let entries = RightClickMenuBuilder.entries(configuration: configuration, selection: selection) {
            RightClickLocalization.string($0, defaultValue: $0, preferredLanguages: configuration.preferredLanguages)
        }
        let menu = NSMenu(title: toolbarName)
        for entry in entries { add(entry, to: menu, configuration: configuration) }
        return menu.items.isEmpty ? nil : menu
    }

    private func add(_ entry: RightClickMenuEntry, to menu: NSMenu, configuration: RightClickConfiguration) {
        let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
        if configuration.showIcons {
            item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
        }
        if !entry.children.isEmpty {
            let submenu = NSMenu(title: entry.title)
            for child in entry.children { add(child, to: submenu, configuration: configuration) }
            guard !submenu.items.isEmpty else { return }
            item.submenu = submenu
        } else if let request = entry.request {
            if request.action == .paste && NSPasteboard.general.string(forType: NSPasteboard.PasteboardType("com.mactools.right-click.cut")) == nil { return }
            // Finder can strip representedObject. Titles must remain unique globally
            // so even duplicate resource or application names retain exact identity.
            var title = item.title
            var number = 2
            while requestsByTitle[title] != nil { title = entry.title + " (\(number))"; number += 1 }
            item.title = title
            item.target = self
            item.action = #selector(performAction(_:))
            item.representedObject = try? JSONEncoder().encode(request)
            requestsByTitle[title] = request
        } else { return }
        menu.addItem(item)
    }

    @objc private func performAction(_ item: NSMenuItem) {
        let represented = (item.representedObject as? Data).flatMap { try? JSONDecoder().decode(RightClickRequest.self, from: $0) }
        guard let request = represented ?? requestsByTitle[item.title] else { return }
        let configuration = RightClickConfigurationStore.load()
        guard configuration.menuEnabled, configuration.isEnabled(request.action) else { return }
        if request.action.isCopyInformation {
            let urls = request.selection.urls.isEmpty ? request.selection.directory.map { [$0] } ?? [] : request.selection.urls
            let text: String
            switch request.action {
            case .copyName: text = RightClickPathFormatter.joinedFileNames(urls)
            case .copyRelative: text = RightClickPathFormatter.joinedRelativePaths(urls, base: request.selection.relativeBase)
            case .copyShell: text = RightClickPathFormatter.joinedShellEscapedPaths(urls)
            case .copyURL: text = RightClickPathFormatter.joinedFileURLs(urls)
            default: text = RightClickPathFormatter.joinedPaths(urls)
            }
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } else if let url = request.url(scheme: scheme) {
            NSWorkspace.shared.open(url)
        }
    }
}
