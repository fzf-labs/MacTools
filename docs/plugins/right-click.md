# Right Click

Right Click provides native Finder context menus and a Finder toolbar menu. Settings have two tabs: Function Settings and Menu Layout. Function Settings organizes actions by Create, Organize Files, Open and Go, Copy Information, and File Tools. Menu Layout places categories on the left and the selected category's actions on the right, with an on-demand preview. Enable the MacTools Finder extension in System Settings before using Finder menus.

## Actions and menus

Enable actions in their functional category. Actions with settings expand in place; actions without settings have only an enable switch. New File includes text types, creation behavior, and imported templates; Copy To, Move To, and location actions share one locations editor; application actions share one application list; Open in Terminal has its own terminal settings; Set Folder Icon includes icon imports. Opening one action closes the previous action. Action names are built in; the workspace has no custom action names, favorites, search, filters, or action counts.

Switching tabs preserves the selected category, expanded editor, and scroll position. Menu Layout controls category and action ordering, icons, and selection previews. Actions appear in their categories in the configured order, without favorite promotion. Drag categories and actions using the handles at the right edge of each row, or press Command-Option-Up/Down on a focused item. A compact native preview follows the pointer while rows make room around an insertion marker. Hover previews stay local until the drop is saved; cancellation keeps the original order. Reduced Motion disables row animation. Move Up and Move Down remain available to assistive technology; no arrow buttons occupy the layout. Disabled actions remain visible for arrangement. Choose Function Settings from an action's context menu to switch tabs and navigate to its settings; actions without settings are brought into view without expanding. Menu Layout does not duplicate action switches. The toolbar holds Show Icons and Preview Menu. Show Icons controls category and action icons in both arrangement columns, their drag previews, the menu preview, and Finder menus. Preview Menu opens a dismissible popover using the same selection rules as Finder across five scenarios; the selected scenario is remembered while the settings workspace remains open. Both arrangement columns stay visible without a permanent preview column, with independent scrolling and narrower category widths on smaller windows.

The extension captures the exact selection and directory when building a menu. It never switches to newly selected files after an action is clicked. Empty groups and incompatible image, folder, and multi-selection actions are omitted. Directory operations on document packages are rejected.

New configurations enable creation, copy information, application and terminal actions, Copy To, Move To, Go to Location, and session Undo. Other tools are opt-in. Action switches use one set of stable operation IDs.

## Resources

Locations are shared by Go To, Copy To, and Move To. Desktop, Downloads, and Documents are suggested initially. Update an unavailable location rather than silently redirecting it.

Applications have an optional extension filter and a files/folders scope. The preferred application must be configured explicitly. Terminal remains the default terminal. Warp uses its directory URI, while iTerm2 uses a fixed built-in automation adapter; macOS may request Automation permission for iTerm2. There is no user script editor or arbitrary command execution.

Templates and folder icons are copied into managed storage beside the right-click configuration. Import an actual Office/iWork document to create that format; changing an empty file's extension does not produce a valid document. The original thirteen text/code types remain available, with per-type switches, optional naming, and optional opening after creation.

Preferences Backup includes settings and resource metadata, not template or image content. Use the workspace options menu to export a separate `.mactoolsresources` package containing templates and icons to move those contents to another Mac. Importing preserves existing files with fresh resource identities, or reconnects matching missing metadata restored from Preferences Backup. Imports validate the whole package before committing any payload. Limits are 64 MiB per file, 256 MiB per package, 256 resources per package, and 4,096 payload entries. Symbolic-link payloads and path traversal are rejected.

## File operations and recovery

Copy and move default to Keep Both. Existing names can be skipped or replaced after confirmation; folders are never merged. Replaced destinations go to Trash. Failed replacement attempts restore the previous destination where possible and report its recovery location otherwise.

Mutating URL requests require review of their targets. File tasks run on one background worker and report progress by item. AppKit icon writes stay on the main actor, with background thumbnail preparation and cancellation between items. Cancellation takes effect at the next safe checkpoint; an in-flight system copy or image encode must finish before it can be cleaned up. Completed items remain in place, and partial results are reported.

Cross-volume movement copies before removing the source. A failed copy preserves the source. When source removal fails, both copies are retained and the result reports their location. Selecting a directory and one of its descendants transfers the directory only once. Links are copied as links, rather than traversed; attribute, alias, and image tools reject symbolic-link input.

The latest undoable move, rename, folder organization, or icon change can be undone during the current app session. Enable **Undo Last File Operation** under Organize Files to expose the menu entry; it appears only while a record exists. Undo validates the recorded file identities and metadata, including directory descendants, before changing paths. An occupied original path or an externally modified result stops undo. Undo is not persistent across application restarts.

Cut records file URLs without moving or hiding files. Move Here is invalidated when the clipboard changes or the application session ends. Dissolve Folder moves direct children only and trashes the original folder only after every child succeeds and the folder is empty. Application and document packages cannot be dissolved.

Batch Rename offers literal replacement, prefix/suffix, numbering, and extension preservation. Preview detects invalid or duplicate destinations before execution. Two-phase renaming supports recovery without overwriting an existing file.

## File tools

Image conversion supports PNG, JPEG, HEIC, and TIFF when the system encoder is available. Resize preserves aspect ratio without upscaling. Both create new outputs and retain the original. Multi-frame images are rejected rather than silently dropping frames. JPEG outputs flatten transparency against white. Conversion normalizes orientation and preserves available metadata; it is not a metadata-removal tool.

Folder icons can be imported, applied, restored, and undone. The first original icon is retained locally for restoration. File Information reads direct attributes and does not recursively compute folder sizes. Hidden-item and hidden-extension actions change the selected items only; they do not change global Finder visibility preferences.

ZIP compression uses the system `ditto` tool with staged output. Archive extraction is handed to Apple's Archive Utility; Right Click does not implement an extractor or support 7z creation.

## Configuration and delivery

Right Click accepts only the current configuration schema and `/perform` requests. Older schemas, individual action URL routes, custom action names, favorite fields, and legacy settings pages are not supported. Invalid or incomplete configuration leaves Finder menus inactive. Request versions, file URLs, operation enablement, and resources are validated before execution.

The host executor, embedded Finder extension, and settings plugin must be delivered together. The plugin manifest's minimum host version must match the first released app containing this implementation before publication; the current development version is not a compatibility promise for older released builds. No PluginKit ABI changes are required. Preferences backups must use the current schema; there is no automatic migration.

Debug, Nightly, and Release keep separate configuration and resource directories. iCloud and OneDrive integration, global input gestures, custom scripts, permanent deletion, bulk access-permission changes, and cross-plugin actions are outside this implementation. Registering Finder monitoring directories does not guarantee menus in every filesystem provider.

Manual acceptance should cover real Finder menus and toolbar entry points, macOS 14 and a newer system, local and external disks, mixed selections, Unicode paths, read-only/offline destinations, terminal working directories and denied automation, cancellation/recovery, and settings accessibility in light/dark appearance. Unit tests do not establish those desktop and hardware outcomes.
