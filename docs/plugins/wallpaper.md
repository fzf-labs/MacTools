# Wallpaper

Wallpaper manages static desktop images from selected local folders and Wallhaven. It requires macOS 14 or later and does not need Accessibility or Screen Recording access for ordinary wallpaper changes.

## Start with local images

Open the Wallpaper settings workspace and choose Add Folder. You can add multiple folders. Adding a folder scans its JPEG, PNG, and static HEIC files without replacing the current desktop.

The workspace uses Local Photos, Online Wallpapers, Favorites, and History tabs. Changing the tab, local folder, or search/filter conditions starts the gallery at the top; loading and empty results remain visible outside the image grid. Select an image to open its larger preview, then choose Apply Wallpaper. Adding folders and browsing images never changes the desktop by itself. More Settings contains folder management, including subfolders, rotation inclusion, Reveal in Finder, and removal from the library. Removing a folder never deletes original files. Filesystem links and package contents are not followed during scans.

If a folder becomes unavailable or its scan is incomplete, its warning remains visible. Reconnect its volume, restore access, or select the folder again. Previously discovered data is not treated as a complete empty folder after a failed scan.

## Online discovery and favorites

Choose Online Wallpapers to browse Wallhaven. Searches and thumbnails are fetched directly from Wallhaven; installing or activating the plugin alone does not search online. Public SFW content needs no API key or account. Nature, Cities, and Minimal provide quick search starting points. The Filters menu contains categories, sorting, orientation, and resolution matching. Empty results offer Retry and Relax Filters; loading has a separate progress state. Resolution matching uses physical display pixels, and Relax Filters explicitly disables that constraint.

Apply downloads and validates the full image before changing the desktop. Favorite retains a full image for offline use. If a favorite download fails, the item remains in Favorites; select it and choose the favorite control again to retry. An incomplete favorite is not eligible for offline rotation. Removing a completed favorite leaves any currently applied copy protected.

Change Wallpaper and enabling Automatic Rotation explicitly use the currently browsed Local Photos, Favorites, or online search as the rotation collection. In History they retain the configured collection. Browsing a different tab or search alone does not change a running rotation. The enabled rotation control labels its interval explicitly; the rotation collection is available in More Settings. View Source opens the provider page; the uploader is not assumed to be the artist. Rights information may be unspecified. API access does not grant permission to redistribute images. The preview has a close button at the leading top corner and a top toolbar for Favorite, Apply Wallpaper, and source-specific actions. Online images offer Save Image and View Source; local images offer Show in Finder. Save Image writes a single original image file to the selected location. Source and uploader metadata remain in the plugin library.

Unsplash, Bing, and Wikimedia Commons are not included providers. No third-party image pack, MacTools image server, telemetry, or cloud account is involved.

## Rotation and displays

Automatic Rotation is directly available at the top of the workspace. More Settings contains the collection, interval, shuffle order, display selection, image fit, folders, and storage controls in a separate native form. Automatic rotation starts paused with a 30-minute default interval. A 24-hour interval means elapsed duration rather than a particular time of day.

The display picker supports all connected displays or one display. Independent Displays pauses existing rotation and allows a separate collection, interval, fit, and rotation state for each display. Select each display to configure it. Equal display names include a short stable identifier. A new display is not automatically taken over by a previously running all-display profile; explicitly resume or apply to include it.

Next and Previous actions work while automatic rotation is paused and remain available through shortcuts and panel controls. The workspace presents Change Wallpaper as its primary switching button and History for reviewing past images. Previous traverses retained managed history and requires a readable saved image. Next after moving backward follows history forward before selecting a new candidate. Applying a different image branches history. Manual switching does not silently resume automatic rotation.

Rotation runs while MacTools and the plugin are active. Sleep, display sleep, and screen lock suspend changes. Wake/unlock reconciles the current desktop before performing at most one overdue switch. Quitting or disabling the plugin preserves the last applied image. The plugin creates no separate login item or background agent.

Wallpaper periodically checks the desktop while rotating and checks again before automatic writes. A detected external change pauses the affected scope. Detection is not instantaneous and cannot provide atomic coordination with another wallpaper manager. Use one automatic wallpaper manager at a time. Resume explicitly accepts the currently visible desktop as the new baseline.

The supported target is the desktop context macOS exposes for each connected screen. The plugin does not claim arbitrary Space selection, lock-screen customization, dynamic HEIC playback, video/web wallpapers, or panorama spanning. Switching Spaces can pause rotation when ownership cannot be established. Previous restores managed images, not the original system wallpaper/slideshow configuration.

## Storage and recovery

The plugin never modifies local originals. Before applying an image it saves a stable managed copy. Current images, offline favorites, and images previously applied to potentially hidden Spaces are protected from automatic cleanup. This conservative protection means managed-image storage can grow independently of the evictable thumbnail cache.

More Settings shows managed-image and cache usage separately. The thumbnail cache defaults to 1 GB, with 256 MB and 5 GB options. Clear Cache removes eligible cache and unused managed files without removing protected images or user exports. Ordinary uninstall follows the host's data-preservation policy.

Downloads are limited to 50 MB per image; images above 100 megapixels, damaged files, animated/multipage images, and recognized dynamic-desktop assets are rejected. A failed download or invalid image leaves the desktop unchanged. Offline rotation may use already validated images from the same configured collection; it never changes to another collection silently. Transient failures retry with backoff, then pause for recovery.

Multiple-display updates cannot be atomic. Partial completion is reported and pauses automatic rotation for that scope. Successfully changed displays keep their new image; disconnected or failed displays retain their previous desktop. Reconnect the target or correct the error, then apply or resume explicitly.

If library metadata cannot be decoded, the original file is preserved and actions remain unavailable. Back up the plugin support directory before attempting manual recovery. Low disk space or write failures require recovery before reliable rotation can resume.

## Development

Source and tests live in `Plugins/Wallpaper/`. Plugin ID `wallpaper` and action IDs `next`, `previous`, `toggle-rotation`, `set-rotation-enabled`, and `apply-asset` are stable. The asset action accepts an existing library ID and optional validated scope, never an arbitrary file path or URL.

Use `make build-plugin PLUGIN=Wallpaper` for packaging and `make test TEST_FILTER="WallpaperControllerTests WallhavenWallpaperSourceTests"` for focused behavior checks. Tests use temporary files and a fake desktop adapter; they do not replace the developer's actual wallpaper. Follow the [design contract](../superpowers/specs/2026-10-29-wallpaper-plugin.md) for integration boundaries and hardware acceptance.
