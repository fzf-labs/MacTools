import AppKit
import MacToolsPluginKit
import ScreenCaptureKit

struct RecordingApplicationCatalog: Sendable {
    struct Display: Sendable { let display: CaptureDisplay; let name: String }
    struct Application: Sendable { let target: RecordingTarget; let name: String }
    let displays: [Display]
    let applications: [Application]

    @MainActor static func current() async throws -> Self {
        let content = try await CaptureSessionPreparation.content()
        try Task.checkCancellation()
        let displays = CaptureDisplay.current().map { display in
            Display(display: display, name: NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
            })?.localizedName ?? "\(display.id)")
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = content.applications.filter { $0.processID != ownPID }.sorted {
            $0.applicationName.localizedStandardCompare($1.applicationName) == .orderedAscending
        }
        let applications = displays.flatMap { item in
            apps.filter { app in
                content.windows.contains {
                    $0.owningApplication?.processID == app.processID && $0.windowLayer == 0 && $0.isOnScreen
                        && $0.frame.width > 1 && $0.frame.height > 1
                        && $0.frame.intersects(CGDisplayBounds(item.display.id))
                }
            }.map { app in
                Application(target: .application(processID: app.processID, bundleID: app.bundleIdentifier, display: item.display),
                            name: app.applicationName)
            }
        }
        return Self(displays: displays, applications: applications)
    }
}

/// Inline target selection; its discovery work exists only while application preparation is visible.
@MainActor
final class RecordingApplicationPicker: NSView, NSMenuDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var onChange: (() -> Void)?
    let collectionView = NSCollectionView()
    private let applicationScroll = NSScrollView()
    private let gridIdentifier = NSUserInterfaceItemIdentifier("RecordingApplicationItem")
    private var selection: RecordingTarget?
    let displayPicker = NSPopUpButton()
    let refreshButton = NSButton()
    private let headerRows = NSStackView()
    private let statusRow = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private var header: NSView!
    private var headerWidth: NSLayoutConstraint!
    private var gridWidth: NSLayoutConstraint!
    private var gridHeight: NSLayoutConstraint!
    private var displayWidth: NSLayoutConstraint!
    private var availableSize = NSSize(width: 650, height: 400)
    private var failure: String?
    private var refreshPending = false
    private(set) var isLoading = false
    private let environment: ScreenshotEnvironment
    private let discover: @MainActor () async throws -> RecordingApplicationCatalog
    private var catalog: RecordingApplicationCatalog?
    private var applications: [RecordingApplicationCatalog.Application] = []
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var initialDisplayID: CGDirectDisplayID?
    private var active = false
    private var generation: UInt64 = 0
    private var selectionRevision: UInt64 = 0
    var selectedTarget: RecordingTarget? {
        guard active, !isLoading else { return nil }
        return selection
    }

    init(environment: ScreenshotEnvironment,
         discover: @escaping @MainActor () async throws -> RecordingApplicationCatalog = { try await .current() }) {
        self.environment = environment
        self.discover = discover
        super.init(frame: .zero)
        let appTitle = environment.string("record.target.application", "应用")
        let displayTitle = environment.string("record.display.title", "显示器")
        CaptureActionBar.configure(displayPicker)
        displayPicker.target = self
        displayPicker.action = #selector(selectionChanged(_:))
        displayPicker.menu?.autoenablesItems = false
        displayPicker.menu?.delegate = self
        displayPicker.setAccessibilityLabel(displayTitle)
        displayPicker.setAccessibilityIdentifier("screenshot.record.display")
        displayWidth = displayPicker.widthAnchor.constraint(equalToConstant: 220)
        displayWidth.isActive = true
        displayPicker.cell?.lineBreakMode = .byTruncatingMiddle
        refreshButton.title = environment.string("record.application.refresh", "刷新应用")
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshButton.imagePosition = .imageOnly
        refreshButton.target = self
        refreshButton.action = #selector(refreshApplications)
        refreshButton.toolTip = refreshButton.title
        refreshButton.setAccessibilityLabel(refreshButton.title)
        refreshButton.setAccessibilityIdentifier("screenshot.record.refreshApplications")
        CaptureActionBar.configure(refreshButton)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [displayPicker, spacer, progress, refreshButton] { headerRows.addArrangedSubview(view) }
        headerRows.orientation = .horizontal
        headerRows.alignment = .centerY
        headerRows.spacing = 8
        header = NSView()
        header.addSubview(headerRows)
        headerRows.translatesAutoresizingMaskIntoConstraints = false
        headerWidth = header.widthAnchor.constraint(equalToConstant: 600)
        NSLayoutConstraint.activate([
            headerWidth,
            headerRows.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: CaptureActionBar.insets.left),
            headerRows.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -CaptureActionBar.insets.right),
            headerRows.topAnchor.constraint(equalTo: header.topAnchor, constant: CaptureActionBar.insets.top),
            headerRows.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -CaptureActionBar.insets.bottom),
        ])
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 104, height: 92)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        collectionView.frame = NSRect(x: 0, y: 0, width: 600, height: 208)
        collectionView.autoresizingMask = [.width]
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(RecordingApplicationItem.self, forItemWithIdentifier: gridIdentifier)
        collectionView.setAccessibilityLabel(appTitle)
        collectionView.setAccessibilityIdentifier("screenshot.record.applications")
        applicationScroll.documentView = collectionView
        applicationScroll.hasVerticalScroller = true
        applicationScroll.drawsBackground = false
        applicationScroll.autohidesScrollers = true
        gridWidth = applicationScroll.widthAnchor.constraint(equalToConstant: 600)
        gridHeight = applicationScroll.heightAnchor.constraint(equalToConstant: 208)
        gridWidth.isActive = true
        gridHeight.isActive = true
        statusLabel.font = PluginTypography.detail.nsFont
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier("screenshot.record.applicationStatus")
        progress.setAccessibilityLabel(environment.string("capture.preparing", "正在准备…"))
        progress.style = .spinning
        progress.controlSize = .small
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        statusRow.addArrangedSubview(statusLabel)
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.isHidden = true
        let body = NSStackView(views: [header, statusRow, applicationScroll])
        body.orientation = .vertical
        body.alignment = .centerX
        body.spacing = 0
        addSubview(body)
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     body.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     body.topAnchor.constraint(equalTo: topAnchor),
                                     body.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }

    func constrain(to available: NSSize) {
        availableSize = available
        let outerWidth = max(260, available.width)
        headerWidth.constant = outerWidth
        let width = min(600, outerWidth)
        gridWidth.constant = width
        displayWidth.constant = min(220, width - 100)
        statusLabel.preferredMaxLayoutWidth = width - 40
        let columns = max(1, Int((width - 32) / 112))
        let rows = (applications.count + columns - 1) / columns
        let desiredHeight = CGFloat(rows) * 100 + 8
        let remaining = available.height - header.fittingSize.height - (statusRow.isHidden ? 0 : statusRow.fittingSize.height) - 8
        gridHeight.constant = applications.isEmpty ? 0 : min(208, desiredHeight, max(80, remaining))
        applicationScroll.isHidden = applications.isEmpty
    }

    private func publish() {
        refreshButton.isEnabled = !isLoading
        progress.isHidden = !isLoading
        if isLoading { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        let message: String?
        if isLoading { message = nil }
        else if let failure { message = failure }
        else if applications.isEmpty { message = environment.string("record.application.empty", "暂无可录制的应用") }
        else { message = nil }
        statusLabel.stringValue = message ?? ""
        statusRow.isHidden = message == nil
        constrain(to: availableSize)
        onChange?()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func activate(displayID: CGDirectDisplayID) {
        guard !active else { return }
        active = true
        initialDisplayID = displayID
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func stop() {
        active = false
        generation &+= 1
        task?.cancel()
        task = nil
        isLoading = false
        refreshPending = false
        progress.stopAnimation(nil)
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        observers.removeAll()
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    @objc private func refreshApplications() { refresh() }

    func refresh() {
        guard active else { return }
        guard task == nil else { refreshPending = true; return }
        let oldTarget = selectedTarget
        let previousDisplay = currentDisplay?.id ?? initialDisplayID
        let previousSelectionRevision = selectionRevision
        generation &+= 1
        let token = generation
        isLoading = true
        failure = nil
        publish()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await discover()
                try Task.checkCancellation()
                guard active, generation == token else { return }
                let userSelected = selectionRevision != previousSelectionRevision
                let desiredDisplay = userSelected ? currentDisplay?.id : previousDisplay
                let desiredTarget = userSelected ? selection : oldTarget
                let scrollOrigin = applicationScroll.contentView.bounds.origin
                let sameDisplay = desiredDisplay == currentDisplay?.id
                catalog = value
                replaceItems(displayPicker, titles: value.displays.map(\.name))
                for (item, display) in zip(displayPicker.itemArray, value.displays) { item.representedObject = display.display }
                displayPicker.selectItem(at: value.displays.firstIndex { $0.display.id == desiredDisplay } ?? -1)
                rebuildApplications(preserving: desiredTarget)
                isLoading = false
                task = nil
                if desiredTarget != nil, selection == nil {
                    failure = environment.string("record.target.unavailable", "录制目标已关闭或不可用，请重新选择")
                }
                if sameDisplay {
                    collectionView.layoutSubtreeIfNeeded()
                    applicationScroll.contentView.scroll(to: scrollOrigin)
                    applicationScroll.reflectScrolledClipView(applicationScroll.contentView)
                }
                publish()
                refreshIfNeeded()
            } catch {
                guard active, generation == token, !Task.isCancelled else { return }
                isLoading = false
                task = nil
                applications = []
                selection = nil
                collectionView.reloadData()
                failure = environment.captureErrorDescription(error)
                publish()
                refreshIfNeeded()
            }
        }
    }

    private func refreshIfNeeded() {
        guard refreshPending else { return }
        refreshPending = false
        refresh()
    }

    private var currentDisplay: CaptureDisplay? {
        guard let catalog, catalog.displays.indices.contains(displayPicker.indexOfSelectedItem) else { return nil }
        return catalog.displays[displayPicker.indexOfSelectedItem].display
    }

    private func replaceItems(_ picker: NSPopUpButton, titles: [String]) {
        picker.removeAllItems()
        for title in titles {
            let item = NSMenuItem(title: title, action: #selector(chooseDisplay(_:)), keyEquivalent: "")
            item.target = self
            picker.menu?.addItem(item)
        }
        picker.selectItem(at: titles.isEmpty ? -1 : 0)
    }

    private func rebuildApplications(preserving oldTarget: RecordingTarget?) {
        applications = catalog?.applications.filter { $0.target.display == currentDisplay } ?? []
        selection = oldTarget.flatMap { target in applications.first { $0.target == target }?.target }
        collectionView.reloadData()
        updateSelection()
        displayPicker.toolTip = displayPicker.titleOfSelectedItem
    }

    private func updateSelection() {
        let index = applications.firstIndex { $0.target == selection }
        collectionView.selectionIndexPaths = Set(index.map { [IndexPath(item: $0, section: 0)] } ?? [])
        collectionView.setAccessibilityValue(index.map { applications[$0].name } ?? "")
    }

    func selectApplication(_ target: RecordingTarget) {
        guard active, selection != target, applications.contains(where: { $0.target == target }) else { return }
        selection = target
        selectionRevision &+= 1
        failure = nil
        updateSelection()
        window?.makeFirstResponder(collectionView)
        publish()
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { applications.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: gridIdentifier, for: indexPath)
        if let item = item as? RecordingApplicationItem {
            let app = applications[indexPath.item]
            item.configure(name: app.name, target: app.target) { [weak self] in self?.selectApplication(app.target) }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item, applications.indices.contains(index) else { return }
        selectApplication(applications[index].target)
    }

    @objc private func chooseDisplay(_ item: NSMenuItem) {
        guard let display = item.representedObject as? CaptureDisplay else { return }
        displayPicker.selectItem(at: catalog?.displays.firstIndex { $0.display == display } ?? -1)
        selectionChanged(displayPicker)
    }

    @objc private func selectionChanged(_ sender: NSPopUpButton) {
        selectionRevision &+= 1
        failure = nil
        rebuildApplications(preserving: nil)
        publish()
    }
}

/// A native collection item keeps keyboard and accessibility selection alongside the app artwork.
@MainActor
private final class RecordingApplicationItem: NSCollectionViewItem {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let checkmark = NSImageView()

    override func loadView() {
        let tile = RecordingApplicationTile()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 40).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 40).isActive = true
        nameLabel.font = PluginTypography.body.nsFont
        nameLabel.alignment = .center
        nameLabel.maximumNumberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.widthAnchor.constraint(equalToConstant: 104).isActive = true
        let stack = NSStackView(views: [iconView, nameLabel])
        stack.orientation = .vertical
        stack.spacing = 4
        tile.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        checkmark.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        checkmark.contentTintColor = .controlAccentColor
        checkmark.isHidden = true
        tile.addSubview(checkmark)
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
                                     stack.topAnchor.constraint(equalTo: tile.topAnchor, constant: 8),
                                     checkmark.widthAnchor.constraint(equalToConstant: 18),
                                     checkmark.heightAnchor.constraint(equalToConstant: 18),
                                     checkmark.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -6),
                                     checkmark.topAnchor.constraint(equalTo: tile.topAnchor, constant: 6)])
        view = tile
    }

    func configure(name: String, target: RecordingTarget, onSelect: @escaping () -> Void) {
        nameLabel.stringValue = name
        view.toolTip = name
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.radioButton)
        view.setAccessibilityLabel(name)
        (view as? RecordingApplicationTile)?.onSelect = onSelect
        if case .application(let pid, let bundleID, _) = target,
           let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == bundleID {
            iconView.image = app.icon
        } else { iconView.image = nil }
        if iconView.image == nil { iconView.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil) }
        updateSelectionAppearance()
    }

    override var isSelected: Bool { didSet { updateSelectionAppearance() } }

    private func updateSelectionAppearance() {
        guard isViewLoaded else { return }
        (view as? RecordingApplicationTile)?.selected = isSelected
        checkmark.isHidden = !isSelected
        view.setAccessibilitySelected(isSelected)
        view.setAccessibilityValue(isSelected ? 1 : 0)
    }
}

@MainActor
private final class RecordingApplicationTile: NSView {
    var onSelect: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        guard let onSelect else { return false }
        onSelect()
        return true
    }
    var selected = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
