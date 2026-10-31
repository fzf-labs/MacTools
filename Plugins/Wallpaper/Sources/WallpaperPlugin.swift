import AppKit
import MacToolsPluginKit
import SwiftUI

public final class WallpaperPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        WallpaperProvider(context: context)
    }
}

@MainActor
private struct WallpaperProvider: PluginProvider {
    let context: PluginRuntimeContext
    func makePlugins() -> [any MacToolsPlugin] { [WallpaperPlugin(context: context)] }
}

@MainActor
final class WallpaperPlugin: MacToolsPlugin, PluginActionProviding, PluginSettingsPresenting,
                             DisplayTopologyRefreshing, PluginRuntimeLocalizationRefreshing {
    let controller: WallpaperController
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?
    private var expanded = false

    init(context: PluginRuntimeContext, controller: WallpaperController? = nil) {
        self.controller = controller ?? WallpaperController(context: context)
        self.controller.onChange = { [weak self] in self?.onStateChange?() }
    }

    var metadata: PluginMetadata {
        PluginMetadata(id: "wallpaper", title: controller.text("Wallpaper"), iconName: "photo.on.rectangle",
                       iconTint: Color(nsColor: .systemTeal), order: 41,
                       defaultDescription: controller.text("Browse and rotate local and online wallpapers."))
    }

    private var status: String {
        if !controller.ready { return controller.text("Loading…") }
        if controller.busy { return controller.text("Applying…") }
        if let reason = controller.profile.pauseReason { return controller.text(reason) }
        if controller.profile.enabled, let date = controller.profile.nextDate {
            return controller.scopeTitle(controller.state.selectedScope) + " · "
                + date.formatted(.dateTime.hour().minute().locale(PluginRuntimeLocalization.locale))
        }
        return controller.currentAsset?.title ?? controller.text("Choose a folder or browse Wallhaven.")
    }

    private var rowState: PluginPanelRowState {
        PluginPanelRowState(subtitle: status, isOn: controller.profile.enabled,
                            isEnabled: controller.ready, isAvailable: true,
                            detail: expanded ? detail : nil, errorMessage: controller.error)
    }

    var panelItems: [PluginPanelItem] {
        [.row(id: "control", initialPlacement: .featurePanel,
              descriptor: PluginPanelRowDescriptor(controlStyle: .disclosure, menuActionBehavior: .keepPresented),
              state: rowState, action: { [weak self] in self?.handle($0) }),
         .iconWidget(id: "next", title: controller.text("Next Wallpaper"), systemImage: "forward.end",
                     control: .button, state: rowState, menuActionBehavior: .keepPresented,
                     action: { [weak self] _ in self?.run("next") }),
         .widget(id: "preview", title: metadata.title, systemImage: metadata.iconName,
                 descriptor: PluginPanelWidgetDescriptor(span: PluginPanelWidgetSpan(width: 2, height: 4)!),
                 state: PluginPanelWidgetState(subtitle: status, isActive: controller.profile.enabled,
                                               isEnabled: controller.ready, isAvailable: true, errorMessage: controller.error)) { [weak self] context in
             if let self {
                 WallpaperQuickView(controller: self.controller, isPreview: context.isPreview,
                                    openSettings: { [weak self] in self?.requestSettingsPresentation?() })
             }
         }]
    }

    private var detail: PluginPanelDetail {
        let titles = ["next": "Next Wallpaper", "previous": "Previous Wallpaper", "toggle-rotation": "Pause or Resume Rotation", "settings": "Open Wallpaper Settings"]
        return PluginPanelDetail(controls: ["next", "previous", "toggle-rotation", "settings"].map { id in
            PluginPanelControl(id: id, kind: .actionRow, options: [], selectedOptionID: nil,
                               dateValue: nil, minimumDate: nil, displayedComponents: nil, datePickerStyle: nil,
                               sectionTitle: nil, actionTitle: controller.text(titles[id]!),
                               actionIconSystemName: id == "settings" ? "gearshape" : "photo",
                               isEnabled: !controller.busy || id == "settings")
        })
    }

    var settingsPage: PluginSettingsPage? {
        .workspace(description: metadata.defaultDescription) { [weak self] _ in
            if let self { WallpaperWorkspace(controller: self.controller) }
        }
    }

    func activate(context: PluginRuntimeContext) { controller.activate() }
    func deactivate(reason: PluginDeactivationReason) { controller.deactivate() }
    func refresh() { controller.refreshDisplays() }
    func refreshDisplayTopology() { controller.refreshDisplays() }
    func refreshLocalization() { onStateChange?(); controller.objectWillChange.send() }

    private func handle(_ action: PluginPanelAction) {
        switch action {
        case .setDisclosureExpanded(let value): expanded = value; onStateChange?()
        case .invokeAction(let id):
            if id == "settings" { requestSettingsPresentation?() } else { run(id) }
        default: break
        }
    }

    private func run(_ id: String) {
        Task {
            if id == "toggle-rotation" { _ = await controller.setRotation(!controller.profile.enabled) }
            else { _ = await controller.execute(id) }
        }
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        [("next", "Next Wallpaper"), ("previous", "Previous Wallpaper"), ("toggle-rotation", "Pause or Resume Rotation")].map { id, title in
            PluginShortcutDefinition(id: id, title: controller.text(title), description: metadata.defaultDescription,
                                     actionID: id, scope: .global, defaultBinding: nil, isRequired: false)
        }
    }

    func handleShortcutAction(id: String) { run(id) }

    var actionDefinitions: [ActionDefinition] {
        [("next", "Next Wallpaper"), ("previous", "Previous Wallpaper"),
         ("toggle-rotation", "Pause or Resume Rotation"), ("set-rotation-enabled", "Set Automatic Rotation"),
         ("apply-asset", "Apply Wallpaper")].map { id, title in
            var parameters: [ActionParameterDefinition] = []
            if id == "set-rotation-enabled" { parameters = [.init(id: "enabled", title: controller.text("Automatic Rotation"), kind: .boolean)] }
            if id == "apply-asset" {
                parameters = [.init(id: "asset", title: controller.text("Image"), kind: .string, portability: .localOnly),
                              .init(id: "scope", title: controller.text("Display"), kind: .string, isRequired: false, portability: .localOnly)]
            }
            return ActionDefinition(key: ActionKey(providerID: "wallpaper", actionID: id),
                                    title: controller.text(title), description: controller.text(title),
                                    keywords: ["wallpaper", "desktop", metadata.title], systemImage: metadata.iconName,
                                    parameters: parameters, externalInvocationPolicy: .allowed,
                                    capabilities: [.automatic, .background, .foregroundInteractive, .cancellable])
        }
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        actionDefinitions.filter { $0.key.actionID != "apply-asset" && $0.key.actionID != "set-rotation-enabled" }.map {
            ActionCatalogEntry(reference: ActionReference(key: $0.key), title: $0.title, subtitle: status)
        }
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key.providerID == "wallpaper", actionDefinitions.contains(where: { $0.key == reference.key }),
              controller.ready, !controller.busy else { return .unavailable(controller.text("Wallpaper is busy or unavailable.")) }
        if reference.key.actionID == "apply-asset" {
            guard case let .string(id) = reference.parameters["asset"], controller.state.assets[id] != nil else {
                return .unavailable(controller.text("The image is unavailable. Choose another image."))
            }
        }
        if reference.key.actionID == "previous", !controller.canGoBack {
            return .unavailable(controller.text("The image is unavailable. Choose another image."))
        }
        return .available
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { [weak self] in
            guard let self else { return .cancelled }
            let reference = invocation.reference
            guard reference.key.providerID == "wallpaper" else { return .failed(message: controller.text("Wallpaper is busy or unavailable.")) }
            switch reference.key.actionID {
            case "toggle-rotation": return await controller.setRotation(!controller.profile.enabled)
            case "set-rotation-enabled":
                guard case let .boolean(enabled) = reference.parameters["enabled"] else { return .failed(message: controller.text("Wallpaper is busy or unavailable.")) }
                return await controller.setRotation(enabled)
            case "apply-asset":
                guard case let .string(id) = reference.parameters["asset"] else { return .failed(message: controller.text("The image is unavailable. Choose another image.")) }
                let scope: String?
                if case let .string(value) = reference.parameters["scope"] { scope = value } else { scope = nil }
                return await controller.execute("apply-asset", assetID: id, scope: scope)
            case "next", "previous": return await controller.execute(reference.key.actionID)
            default: return .failed(message: controller.text("Wallpaper is busy or unavailable."))
            }
        }
    }
}
