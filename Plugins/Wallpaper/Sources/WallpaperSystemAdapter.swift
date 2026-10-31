import AppKit
import CoreGraphics

@MainActor
protocol WallpaperSystemControlling {
    func displays() -> [WallpaperDisplay]
    func read(displayID: String) -> WallpaperDesktopState?
    func apply(_ url: URL, displayID: String, fill: Bool) throws
}

@MainActor
final class WallpaperSystemAdapter: WallpaperSystemControlling {
    private func identity(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private func screen(_ id: String) -> NSScreen? {
        NSScreen.screens.first { identity($0) == id }
    }

    func displays() -> [WallpaperDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = identity(screen),
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return WallpaperDisplay(id: id, name: screen.localizedName,
                                    width: CGDisplayPixelsWide(number.uint32Value),
                                    height: CGDisplayPixelsHigh(number.uint32Value))
        }
    }

    func read(displayID: String) -> WallpaperDesktopState? {
        guard let screen = screen(displayID), let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen)
        return WallpaperDesktopState(url: url.standardizedFileURL,
                                     fill: options?[.allowClipping] as? Bool ?? false,
                                     scaling: (options?[.imageScaling] as? NSNumber)?.uintValue ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue)
    }

    func apply(_ url: URL, displayID: String, fill: Bool) throws {
        guard let screen = screen(displayID) else { throw WallpaperFailure.disconnected }
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { throw WallpaperFailure.missingFile }
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: fill,
        ])
    }
}
