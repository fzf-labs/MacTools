import Foundation
import MacToolsPluginKit

/// Host-owned macOS commands are independent of plugin discovery and lifecycle.
enum LauncherSystemAction: String, CaseIterable, Sendable {
    case lockScreen = "lock-screen", sleep, sleepDisplays = "sleep-displays"
    case restart, shutDown = "shut-down", logOut = "log-out"
    case screenSaver = "screen-saver", showDesktop = "show-desktop", missionControl = "mission-control"
    case playPause = "play-pause", nextTrack = "next-track", previousTrack = "previous-track"
    case toggleMute = "toggle-mute", toggleMicrophoneMute = "toggle-microphone-mute"
    case volumeUp = "volume-up", volumeDown = "volume-down"
    case volume0 = "volume-0", volume25 = "volume-25", volume50 = "volume-50", volume75 = "volume-75", volume100 = "volume-100"
    case toggleAppearance = "toggle-appearance", openTrash = "open-trash", emptyTrash = "empty-trash"
    case hideOtherApps = "hide-other-apps", unhideAllApps = "unhide-all-apps"

    static let providerID = "mactools-system-actions"
    var reference: ActionReference { .init(key: .init(providerID: Self.providerID, actionID: rawValue)) }
    var identity: String { "system-action." + rawValue }
    var englishTitle: String {
        switch self {
        case .lockScreen: "Lock Screen"
        case .sleep: "Sleep"
        case .sleepDisplays: "Sleep Displays"
        case .restart: "Restart"
        case .shutDown: "Shut Down"
        case .logOut: "Log Out"
        case .screenSaver: "Start Screen Saver"
        case .showDesktop: "Show Desktop"
        case .missionControl: "Mission Control"
        case .playPause: "Play / Pause"
        case .nextTrack: "Next Track"
        case .previousTrack: "Previous Track"
        case .toggleMute: "Toggle Mute"
        case .toggleMicrophoneMute: "Toggle Microphone Mute"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .volume0: "Set Volume to 0%"
        case .volume25: "Set Volume to 25%"
        case .volume50: "Set Volume to 50%"
        case .volume75: "Set Volume to 75%"
        case .volume100: "Set Volume to 100%"
        case .toggleAppearance: "Toggle Light / Dark Appearance"
        case .openTrash: "Open Trash"
        case .emptyTrash: "Empty Trash"
        case .hideOtherApps: "Hide Other Apps"
        case .unhideAllApps: "Show All Hidden Apps"
        }
    }
    var title: String { LauncherText.systemActionTitle(self) }
    var systemImage: String {
        switch self {
        case .lockScreen: "lock"
        case .sleep: "moon.zzz"
        case .sleepDisplays: "display"
        case .restart: "arrow.clockwise"
        case .shutDown: "power"
        case .logOut: "rectangle.portrait.and.arrow.right"
        case .screenSaver: "sparkles.rectangle.stack"
        case .showDesktop: "macwindow"
        case .missionControl: "rectangle.3.group"
        case .playPause: "playpause"
        case .nextTrack: "forward.end"
        case .previousTrack: "backward.end"
        case .toggleMute: "speaker.slash"
        case .toggleMicrophoneMute: "mic.slash"
        case .volumeUp: "speaker.plus"
        case .volumeDown: "speaker.minus"
        case .volume0, .volume25, .volume50, .volume75, .volume100: "speaker.wave.2"
        case .toggleAppearance: "circle.lefthalf.filled"
        case .openTrash: "trash"
        case .emptyTrash: "trash.slash"
        case .hideOtherApps: "eye.slash"
        case .unhideAllApps: "eye"
        }
    }
    var requiresConfirmation: Bool { [.restart, .shutDown, .logOut, .emptyTrash].contains(self) }
    var definition: ActionDefinition {
        .init(key: reference.key, title: title, description: LauncherText.systemOperations,
              keywords: [englishTitle], systemImage: systemImage,
              risk: requiresConfirmation ? .confirmationRequired : .safe,
              confirmation: requiresConfirmation ? .init(title: title,
                  message: self == .emptyTrash ? LauncherText.trashWarning : LauncherText.sessionWarning,
                  confirmButtonTitle: title) : nil,
              externalInvocationPolicy: .unavailable, capabilities: [.foregroundInteractive, .cancellable])
    }
}
