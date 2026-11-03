import Foundation
import MacToolsPluginKit

/// Host-owned launcher copy. Plugins retain their own business UI and localization.
enum LauncherText {
    static var about: String { PluginRuntimeLocalization.string("launcher.about", defaultValue: "About", table: "Launcher", bundle: .main) }
    static var accessibility: String { PluginRuntimeLocalization.string("launcher.accessibility", defaultValue: "Accessibility", table: "Launcher", bundle: .main) }
    static var actions: String { PluginRuntimeLocalization.string("launcher.actions", defaultValue: "Actions", table: "Launcher", bundle: .main) }
    static var addScope: String { PluginRuntimeLocalization.string("launcher.addScope", defaultValue: "Add Folder or Application…", table: "Launcher", bundle: .main) }
    static var alias: String { PluginRuntimeLocalization.string("launcher.alias", defaultValue: "Alias", table: "Launcher", bundle: .main) }
    static var aliasConflict: String { PluginRuntimeLocalization.string("launcher.aliasConflict", defaultValue: "Alias is already in use.", table: "Launcher", bundle: .main) }
    static var appearance: String { PluginRuntimeLocalization.string("launcher.appearance", defaultValue: "Appearance", table: "Launcher", bundle: .main) }
    static var applications: String { PluginRuntimeLocalization.string("launcher.applications", defaultValue: "Applications", table: "Launcher", bundle: .main) }
    static var battery: String { PluginRuntimeLocalization.string("launcher.battery", defaultValue: "Battery", table: "Launcher", bundle: .main) }
    static var bluetooth: String { PluginRuntimeLocalization.string("launcher.bluetooth", defaultValue: "Bluetooth", table: "Launcher", bundle: .main) }
    static var cancel: String { PluginRuntimeLocalization.string("launcher.cancel", defaultValue: "Cancel", table: "Launcher", bundle: .main) }
    static var clearHistory: String { PluginRuntimeLocalization.string("launcher.clearHistory", defaultValue: "Clear History", table: "Launcher", bundle: .main) }
    static var copyPath: String { PluginRuntimeLocalization.string("launcher.copyPath", defaultValue: "Copy Path", table: "Launcher", bundle: .main) }
    static var dateTime: String { PluginRuntimeLocalization.string("launcher.dateTime", defaultValue: "Date & Time", table: "Launcher", bundle: .main) }
    static var description: String { PluginRuntimeLocalization.string("launcher.description", defaultValue: "Open apps, system settings, and enabled plugin features.", table: "Launcher", bundle: .main) }
    static var displays: String { PluginRuntimeLocalization.string("launcher.displays", defaultValue: "Displays", table: "Launcher", bundle: .main) }
    static var emptyHome: String { PluginRuntimeLocalization.string("launcher.emptyHome", defaultValue: "Search for an app, setting, or action.", table: "Launcher", bundle: .main) }
    static var favorite: String { PluginRuntimeLocalization.string("launcher.favorite", defaultValue: "Favorites", table: "Launcher", bundle: .main) }
    static var general: String { PluginRuntimeLocalization.string("launcher.general", defaultValue: "General", table: "Launcher", bundle: .main) }
    static var hide: String { PluginRuntimeLocalization.string("launcher.hide", defaultValue: "Hide", table: "Launcher", bundle: .main) }
    static var keyboard: String { PluginRuntimeLocalization.string("launcher.keyboard", defaultValue: "Keyboard", table: "Launcher", bundle: .main) }
    static var loginItems: String { PluginRuntimeLocalization.string("launcher.loginItems", defaultValue: "Login Items", table: "Launcher", bundle: .main) }
    static var mouse: String { PluginRuntimeLocalization.string("launcher.mouse", defaultValue: "Mouse", table: "Launcher", bundle: .main) }
    static var moveUp: String { PluginRuntimeLocalization.string("launcher.moveUp", defaultValue: "Move Up", table: "Launcher", bundle: .main) }
    static var network: String { PluginRuntimeLocalization.string("launcher.network", defaultValue: "Network", table: "Launcher", bundle: .main) }
    static var noResults: String { PluginRuntimeLocalization.string("launcher.noResults", defaultValue: "No Results", table: "Launcher", bundle: .main) }
    static var notifications: String { PluginRuntimeLocalization.string("launcher.notifications", defaultValue: "Notifications", table: "Launcher", bundle: .main) }
    static var open: String { PluginRuntimeLocalization.string("launcher.open", defaultValue: "Open", table: "Launcher", bundle: .main) }
    static var openLauncher: String { PluginRuntimeLocalization.string("launcher.openLauncher", defaultValue: "Open Launcher", table: "Launcher", bundle: .main) }
    static var openSystemSettings: String { PluginRuntimeLocalization.string("launcher.openSystemSettings", defaultValue: "Open System Settings", table: "Launcher", bundle: .main) }
    static var pluginFeatures: String { PluginRuntimeLocalization.string("launcher.pluginFeatures", defaultValue: "Plugin Features", table: "Launcher", bundle: .main) }
    static var privacySecurity: String { PluginRuntimeLocalization.string("launcher.privacySecurity", defaultValue: "Privacy & Security", table: "Launcher", bundle: .main) }
    static var recent: String { PluginRuntimeLocalization.string("launcher.recent", defaultValue: "Recent", table: "Launcher", bundle: .main) }
    static var refresh: String { PluginRuntimeLocalization.string("launcher.refresh", defaultValue: "Refresh", table: "Launcher", bundle: .main) }
    static var remove: String { PluginRuntimeLocalization.string("launcher.remove", defaultValue: "Remove", table: "Launcher", bundle: .main) }
    static var restoreHidden: String { PluginRuntimeLocalization.string("launcher.restoreHidden", defaultValue: "Restore Hidden Items", table: "Launcher", bundle: .main) }
    static var reveal: String { PluginRuntimeLocalization.string("launcher.reveal", defaultValue: "Show in Finder", table: "Launcher", bundle: .main) }
    static var run: String { PluginRuntimeLocalization.string("launcher.run", defaultValue: "Run", table: "Launcher", bundle: .main) }
    static var running: String { PluginRuntimeLocalization.string("launcher.running", defaultValue: "Running", table: "Launcher", bundle: .main) }
    static var save: String { PluginRuntimeLocalization.string("launcher.save", defaultValue: "Save", table: "Launcher", bundle: .main) }
    static var search: String { PluginRuntimeLocalization.string("launcher.search", defaultValue: "Search apps, settings, and actions", table: "Launcher", bundle: .main) }
    static var searchScopes: String { PluginRuntimeLocalization.string("launcher.searchScopes", defaultValue: "Search Scopes", table: "Launcher", bundle: .main) }
    static var settings: String { PluginRuntimeLocalization.string("launcher.settings", defaultValue: "Settings", table: "Launcher", bundle: .main) }
    static var settingsFailed: String { PluginRuntimeLocalization.string("launcher.settingsFailed", defaultValue: "Unable to open this settings page.", table: "Launcher", bundle: .main) }
    static var sharing: String { PluginRuntimeLocalization.string("launcher.sharing", defaultValue: "Sharing", table: "Launcher", bundle: .main) }
    static var softwareUpdate: String { PluginRuntimeLocalization.string("launcher.softwareUpdate", defaultValue: "Software Update", table: "Launcher", bundle: .main) }
    static var sound: String { PluginRuntimeLocalization.string("launcher.sound", defaultValue: "Sound", table: "Launcher", bundle: .main) }
    static var storage: String { PluginRuntimeLocalization.string("launcher.storage", defaultValue: "Storage", table: "Launcher", bundle: .main) }
    static var systemOperations: String { PluginRuntimeLocalization.string("launcher.systemOperations", defaultValue: "System Actions", table: "Launcher", bundle: .main) }
    static var systemSettings: String { PluginRuntimeLocalization.string("launcher.systemSettings", defaultValue: "System Settings", table: "Launcher", bundle: .main) }
    static var title: String { PluginRuntimeLocalization.string("launcher.title", defaultValue: "Launcher", table: "Launcher", bundle: .main) }
    static var trackpad: String { PluginRuntimeLocalization.string("launcher.trackpad", defaultValue: "Trackpad", table: "Launcher", bundle: .main) }
    static var unavailable: String { PluginRuntimeLocalization.string("launcher.unavailable", defaultValue: "Unavailable", table: "Launcher", bundle: .main) }
    static var wifi: String { PluginRuntimeLocalization.string("launcher.wifi", defaultValue: "Wi-Fi", table: "Launcher", bundle: .main) }
    static var additionalScopes: String { PluginRuntimeLocalization.string("launcher.additionalScopes", defaultValue: "Additional Locations", table: "Launcher", bundle: .main) }
    static var applicationsDescription: String { PluginRuntimeLocalization.string("launcher.applicationsDescription", defaultValue: "Choose which Mac apps appear in launcher searches.", table: "Launcher", bundle: .main) }
    static var clearSearch: String { PluginRuntimeLocalization.string("launcher.clearSearch", defaultValue: "Clear Search", table: "Launcher", bundle: .main) }
    static var defaultScopes: String { PluginRuntimeLocalization.string("launcher.defaultScopes", defaultValue: "Default Locations", table: "Launcher", bundle: .main) }
    static var done: String { PluginRuntimeLocalization.string("launcher.done", defaultValue: "Done", table: "Launcher", bundle: .main) }
    static var favoritesHint: String { PluginRuntimeLocalization.string("launcher.favoritesHint", defaultValue: "Add favorites from an item’s action menu.", table: "Launcher", bundle: .main) }
    static var filterItems: String { PluginRuntimeLocalization.string("launcher.filterItems", defaultValue: "Filter items", table: "Launcher", bundle: .main) }
    static var noApplications: String { PluginRuntimeLocalization.string("launcher.noApplications", defaultValue: "Refresh the app list or add a search scope.", table: "Launcher", bundle: .main) }
    static var noAvailableItems: String { PluginRuntimeLocalization.string("launcher.noAvailableItems", defaultValue: "No available items. Enable a related plugin to add its features.", table: "Launcher", bundle: .main) }
    static var noFavorites: String { PluginRuntimeLocalization.string("launcher.noFavorites", defaultValue: "No Favorites Yet", table: "Launcher", bundle: .main) }
    static var noRecent: String { PluginRuntimeLocalization.string("launcher.noRecent", defaultValue: "No Recent Activity", table: "Launcher", bundle: .main) }
    static var pluginFeaturesDescription: String { PluginRuntimeLocalization.string("launcher.pluginFeaturesDescription", defaultValue: "Choose feature shortcuts from enabled plugins. Plugin preferences stay in plugin settings.", table: "Launcher", bundle: .main) }
    static var recentHint: String { PluginRuntimeLocalization.string("launcher.recentHint", defaultValue: "Items used in the launcher appear here.", table: "Launcher", bundle: .main) }
    static var removeFavorite: String { PluginRuntimeLocalization.string("launcher.removeFavorite", defaultValue: "Remove from Favorites", table: "Launcher", bundle: .main) }
    static var shortcut: String { PluginRuntimeLocalization.string("launcher.shortcut", defaultValue: "Keyboard Shortcut", table: "Launcher", bundle: .main) }
    static var sourceHint: String { PluginRuntimeLocalization.string("launcher.sourceHint", defaultValue: "Include this category in launcher searches.", table: "Launcher", bundle: .main) }
    static var systemOperationsDescription: String { PluginRuntimeLocalization.string("launcher.systemOperationsDescription", defaultValue: "Choose system actions provided by enabled plugins.", table: "Launcher", bundle: .main) }
    static var systemSettingsDescription: String { PluginRuntimeLocalization.string("launcher.systemSettingsDescription", defaultValue: "Choose macOS settings pages to open from the launcher.", table: "Launcher", bundle: .main) }
    static var tryAnotherSearch: String { PluginRuntimeLocalization.string("launcher.tryAnotherSearch", defaultValue: "Try another search term.", table: "Launcher", bundle: .main) }
    static var energy: String { PluginRuntimeLocalization.string("launcher.energy", defaultValue: "Energy", table: "Launcher", bundle: .main) }
    static var loginPassword: String { PluginRuntimeLocalization.string("launcher.loginPassword", defaultValue: "Login Password", table: "Launcher", bundle: .main) }
    static var camera: String { PluginRuntimeLocalization.string("launcher.camera", defaultValue: "Camera", table: "Launcher", bundle: .main) }
    static var microphone: String { PluginRuntimeLocalization.string("launcher.microphone", defaultValue: "Microphone", table: "Launcher", bundle: .main) }
    static var screenRecording: String { PluginRuntimeLocalization.string("launcher.screenRecording", defaultValue: "Screen Recording", table: "Launcher", bundle: .main) }
    static var fullDiskAccess: String { PluginRuntimeLocalization.string("launcher.fullDiskAccess", defaultValue: "Full Disk Access", table: "Launcher", bundle: .main) }
    static var inputMonitoring: String { PluginRuntimeLocalization.string("launcher.inputMonitoring", defaultValue: "Input Monitoring", table: "Launcher", bundle: .main) }
    static var automation: String { PluginRuntimeLocalization.string("launcher.automation", defaultValue: "Automation", table: "Launcher", bundle: .main) }
}
