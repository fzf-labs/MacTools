import Foundation
import MacToolsPluginKit

/// Reviewed compatibility inventory for official plugins predating explicit launcher declarations.
/// Unknown providers and unlisted actions are deliberately excluded, independent of localized names.
enum LauncherActionPolicy {
    static func legacyRole(for key: ActionKey) -> LauncherActionRole? {
        if systemActions[key.providerID]?.contains(key.actionID) == true { return .systemOperation }
        if featureActions[key.providerID]?.contains(key.actionID) == true { return .pluginFeature }
        return nil
    }
    static let workspaces: Set<String> = ["key-stats", "com.mactools.plugin.storage-explorer", "system-data"]
    static let systemActions: [String: Set<String>] = [
        "lock-screen": ["execute"],
        "system-power": ["sleep", "log-out", "restart", "shut-down"],
        "display-sleep": ["execute"],
        "system-mute": ["toggle", "set-enabled"],
        "microphone-mute": ["toggle", "set-enabled"],
        "appearance": ["toggle", "set-enabled", "set-mode"],
        "auto-hide-dock": ["toggle", "set-enabled"],
        "auto-hide-menu-bar": ["toggle", "set-enabled", "set-mode"],
        "display-brightness": ["display-brightness.decrease", "display-brightness.increase", "disable-built-in-display", "restore-built-in-display"],
        "display-volume": ["display-volume.decrease", "display-volume.increase"],
        "display-true-color": ["toggle", "set-enabled"],
        "display-resolution": ["set-resolution"],
        "night-shift": ["toggle", "set-enabled"],
        "stage-manager": ["toggle", "set-enabled"],
        "eject-disk": ["eject-all"],
        "empty-trash": ["empty"],
        "quit-apps": ["choose-apps"],
        "system-soft-restart": ["restart-user-services"],
    ]
    static let featureActions: [String: Set<String>] = [
        "ai-assistant": ["translate", "summarize", "polish"],
        "action-grid": ["show"],
        "app-hotkey": ["launch"],
        "app-volume": ["set-volume"],
        "apple-shortcuts": ["run-shortcut"],
        "auto-input": ["toggle", "set-enabled", "select-input-source"],
        "battery-charge-limit": ["set-enabled", "hold", "resume", "discharge", "set-limit"],
        "clipboard": ["open-history", "previous-sequential-queue-item", "skip-sequential-queue-item", "restart-sequential-queue", "cancel-sequential-queue", "clear-current-clipboard"],
        "cloudflare-r2": ["upload-file"],
        "disk-clean": ["scan-and-review"],
        "dock-lock": ["toggle", "set-enabled"],
        "fan-control": ["apply-preset"],
        "fix-damaged-app": ["choose-app"],
        "hide-notch": ["toggle", "set-enabled"],
        "homebrew": ["update", "upgrade-all", "doctor", "cleanup"],
        "ip-overview": ["copy-local-ipv4", "copy-public-ipv4"],
        "keep-awake": ["toggle", "set-enabled", "start-for-duration"],
        "launch-control": ["start-favorite", "stop-favorite", "restart-favorite"],
        "launchpad": ["toggleLaunchpad"],
        "mac-settings": ["open", "open-favorites", "open-category", "open-setting", "search", "set-boolean", "apply-profile", "undo-most-recent-change"],
        "menu-bar-hidden": ["set-enabled"],
        "middle-click": ["toggle"],
        "physical-clean-mode": ["enter"],
        "saved-scripts": ["run-script"],
        "screenshot": ["capture", "quick-capture", "extract-text", "scrolling-capture", "record"],
        "sidecar": ["connect-first-available", "disconnect-all", "device"],
        "siri": ["ask-new-conversation"],
        "system-status": ["show-system-status"],
        "translator": ["select-translation", "screenshot-translation"],
        "wallpaper": ["next", "previous", "toggle-rotation", "set-rotation-enabled", "apply-asset"],
        "window-layouts": ["toggle-full-screen", "left-half", "right-half", "top-half", "bottom-half", "top-left-quarter", "top-right-quarter", "bottom-left-quarter", "bottom-right-quarter", "maximize", "maximize-height", "maximize-width", "center", "reasonable-size", "move-to-top-edge", "move-to-bottom-edge", "move-to-left-edge", "move-to-right-edge", "first-third", "first-two-thirds", "center-third", "last-two-thirds", "last-third", "first-fourth", "second-fourth", "third-fourth", "last-fourth", "top-left-sixth", "top-center-sixth", "top-right-sixth", "bottom-left-sixth", "bottom-center-sixth", "bottom-right-sixth", "increase-width", "decrease-width", "increase-height", "decrease-height", "move-to-next-display", "move-to-previous-display", "restore-previous-frame", "custom-command"],
        "window-switcher": ["switch", "switch-current-app"],
        "xcode-clean": ["scan-and-review"],
    ]
}
