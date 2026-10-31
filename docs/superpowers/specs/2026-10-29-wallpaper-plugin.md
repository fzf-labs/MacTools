# Wallpaper plugin design

Date: 2026-10-29
Status: Implemented locally; focused automated validation and simulated native rendering are recorded below. Physical display/Spaces acceptance and release publication remain separate.

## Product decision

Build one native static-wallpaper plugin named Wallpaper, with plugin ID `wallpaper`. The complete delivery includes local folders, Wallhaven discovery, favorites, history, manual switching, automatic rotation, and connected-display targeting. Local and online sources share the same library and application pipeline.

The plugin works locally without an account, backend, subscription, or network access. Online access starts only after an explicit Wallhaven interaction or enabling a Wallhaven rotation profile. Opening a panel or activating the plugin must not initiate an unrequested online search.

The release targets macOS 14 or later and follows the repository's current PluginKit compatibility inventory. Implementation milestones below are dependencies within this delivery, not separate product editions.

## Scope and defaults

| Area | Delivery contract | Default |
| --- | --- | --- |
| Local sources | Multiple selected folders; optional subfolder scanning per folder | No selected folder; recursion off |
| Image formats | JPEG, PNG, and static HEIC decoded with ImageIO | Reject animated, multipage, and dynamic-desktop assets with an explanation |
| Online discovery | Wallhaven public SFW search, preview, and explicit application | Disabled until selected; landscape query; General category |
| Search filters | Keywords, General/Anime/People categories, orientation, minimum pixel dimensions, latest/popular/random sorting | SFW fixed; dimensions derived from the target display |
| Library | Favorites, per-display managed history, source details, and export | Local metadata only |
| Selection | Apply a selected asset, next candidate, or previous managed entry | Explicit application required after source selection |
| Rotation | Sequential or shuffled selection; pause/resume | Paused; shuffled; 30-minute interval |
| Intervals | 5, 15, 30, or 60 minutes; 6, 12, or 24 hours | 24 hours means elapsed duration, not a calendar-time trigger |
| Display scope | Synchronized image on all connected displays, one display, or independent profiles per display | All connected displays, synchronized |
| Rendering | Fill or fit with preserved aspect ratio | Fill; system background color for unused space |
| Shortcuts | Next, previous, and pause/resume through the host | No default global bindings |
| External changes | Pause the affected rotation scope when a confirmed external image change is detected | Enabled; detection limitations are visible in help |

No bundled wallpaper pack, provider proxy, account system, cloud synchronization, AI generation, video/web wallpaper, HEIC dynamic-desktop authoring, panorama spanning, lock-screen customization, or arbitrary Space targeting is included. A static HEIC that can be decoded is not automatically evidence that dynamic-desktop playback is supported.

## User journeys

### First use and local selection

1. The empty panel offers Choose Wallpaper Folder and Browse Online.
2. Choose Wallpaper Folder opens the native directory chooser. Selection indexes readable supported files without changing the desktop.
3. The workspace displays thumbnails, usable-image count, and scan status. Partial discovery is labeled as partial until enumeration completes.
4. Selecting a thumbnail opens its inspector; Apply changes the chosen display scope. Next also explicitly authorizes the first application from the active rotation collection.
5. Enabling rotation applies one eligible candidate and starts the interval only after a successful application. If no candidate succeeds, rotation remains paused with a recoverable explanation.

Additional folders appear in the same library. Each folder can be included in the local rotation collection or removed from the index. Removing a folder never deletes its contents.

### Online discovery

1. Selecting Wallhaven initiates a bounded first-page search and explains that images are downloaded directly from the provider.
2. Search/filter changes are debounced, cancel obsolete requests, and retain visible results until replacement results are available.
3. Results use thumbnails. Selecting a result shows source information; Apply downloads and validates the full image before changing any display.
4. Favorite explicitly downloads and pins the full image for offline reuse. An interrupted download leaves a visibly incomplete favorite that is ineligible for offline rotation and can be retried or removed.
5. Use Search for Rotation saves the current provider query as the selected rotation collection. Browsing or changing a search does not silently replace an existing rotation collection.
6. An unavailable provider leaves the current wallpaper intact. Previously validated candidates from that same saved query can be used offline; the plugin never silently switches to another source.

### Daily controls

- Next uses the selected rotation collection and skips the current asset when alternatives exist. Manual use works while automatic rotation is paused and does not resume it.
- Previous uses successfully applied managed history for the selected scope; it is unavailable without a retained readable previous asset. Moving backward does not append duplicate history. Next after a history move follows the existing history forward before requesting a new candidate.
- Applying an image manually while rotation is running resets its interval. Applying from a different collection leaves the configured collection unchanged.
- Favorites can be used as their own rotation collection. The selected collection is explicit: included local folders, favorites, or one saved Wallhaven search.
- View Source opens the provider's image page. Save Image uses a native save panel to write one original supported image file; source metadata remains in the plugin library. Saved images are user-owned and outside plugin cleanup.

## Presentation

### Menu-bar panel and widget

Publish a stable declarative row with title, status, primary Next action, and detail content. Status identifies the selected scope and either the next scheduled switch, a pause reason, loading state, or a recoverable error.

The detail presents a current-image preview, Previous, Next, Favorite, automatic-rotation state, display-scope selection, and Open Wallpaper Settings. When independent profiles show different images, the preview explicitly identifies the selected display; do not imply that one thumbnail represents every display.

Publish a library-only compact Next icon widget through the shared `iconWidget` factory. It uses the same controller and canonical action as the row. Do not introduce another persistent status-item menu. Preview rendering never starts scans, downloads, or rotation.

### Settings workspace

Use `PluginSettingsPage.workspace` because the primary task is browsing and managing an image library. The host owns the page title, description, shortcut guidance, and common chrome.

The workspace contains:

- A source selector with four tabs: Local Photos, Online Wallpapers, Favorites, and History. Do not nest another navigation sidebar inside the host settings sidebar.
- A compact playback bar: Automatic Rotation, interval/collection when enabled, Change Wallpaper, and a labeled More Settings button. A current-wallpaper card appears once a managed image has been applied.
- Source-appropriate search, local folder filtering, and online topic shortcuts; advanced online filters use a menu.
- A virtualized thumbnail grid with selected/current/favorite states and bounded pagination for online results.
- An image selection opens a dedicated preview sheet with a leading close control and a top toolbar for Favorite, source-specific file actions, and Apply. Local files offer Reveal in Finder; online files offer Save Image and View Source. Selection never applies a wallpaper by itself.
- A separate More Settings sheet uses a grouped native form for rotation collection/order/interval, display profiles, image fit, folders, and storage usage. Forward locale and layout direction into both sheets.
- Source-specific empty states provide Add Folder, Browse Online Wallpapers, Retry, or explicit filter relaxation as appropriate. Loading is distinct from an empty result, and pagination requires a completed first page and visible results.

The 2026-10-30 interaction refinement makes Change Wallpaper and explicitly enabling rotation use the currently browsed collection/query. Merely browsing tabs or editing a search leaves the configured rotation source unchanged. Reusing the same query does not reset its shuffle bag.

Use the Fan Control preset manager as the custom-content typography baseline. Reuse `PluginSettingsTheme`, shared spacing roles, native controls, and semantic backgrounds. Give toolbar controls stable widths; retain selection on resize and runtime language changes. Inspector collapse must preserve keyboard access to its actions. Avoid nested cards inside grouped forms.

Visible product copy is localized, concise, and primarily Chinese in the Chinese locale. Supply every required locale and English fallback. Review keyboard navigation, VoiceOver labels, long paths, Arabic layout direction, light/dark appearance, increased contrast, and reduced transparency.

## Provider policy

### Local folders

Persist selected URLs with bookmarks and handle stale bookmarks, access denial, unmounted volumes, and missing folders. Use security-scoped access only when required by the deployment environment. Request access through native selection rather than broad system permissions.

Index asynchronously with the shared `MacToolsFileSystem` metadata reader and batched enumeration. Do not descend into packages or follow directory symlinks. Recursive scans use a tree event observer with debounced invalidation and rescan/reconciliation after dropped events, mount changes, and wake. Never enumerate the entire library from a panel getter.

Image identity survives a rename where file resource identity permits it. Content hashes computed during managed import deduplicate identical payloads across providers; scanning does not eagerly hash every original. Never modify originals or mark a failed/partial scan as a complete empty folder.

### Wallhaven

Use the documented v1 API and direct provider image URLs. Public SFW discovery requires no user developer account. Keep `purity=100` fixed in this release and validate returned content classification before admitting an asset. API keys, private collections, and adult-content controls are outside this delivery.

Apply orientation and minimum dimensions using physical pixel dimensions, not screen points. Synchronized mode requests sufficient resolution for the largest selected target. If filters produce no results, offer explicit filter relaxation rather than silently using unsuitable images.

Use bounded pagination, request coalescing, cache reuse, and one shared provider limiter below the documented ceiling of 45 API requests per minute. Honor HTTP 429/Retry-After and back off on transient errors. Preload at most the next two full-image candidates for an enabled online rotation scope; coalesce shared candidates across profiles. Never crawl the provider library or download all search results.

Store provider page, upstream source link, uploader, artist when actually identified, and license information when available. An uploader is not assumed to be the artist, and missing rights metadata is displayed as unspecified. API access is not a blanket license to redistribute images. Do not bundle or mirror provider images in plugin packages or a MacTools-hosted gallery.

### Additional providers

Wikimedia Commons is an extension candidate rather than a required provider for this delivery. Its adapter must retrieve per-file metadata and represent attribution/license requirements before shipping. Bing is deferred pending a reviewed access and image-use contract. Unsplash is excluded because its current API guidelines explicitly restrict wallpaper applications; user-supplied developer keys are not a workaround.

Keep provider adapters private to the plugin until another plugin has a concrete reuse need. Do not introduce a public PluginKit provider abstraction just for hypothetical future sources.

## Files, history, and storage

Use `PluginRuntimeContext.storage` for small preferences; versioned, atomically replaced metadata in `supportDirectory` for the library/profiles/history; `supportDirectory` for pinned full images; `cacheDirectory` for evictable thumbnails and unpinned downloads; and `temporaryDirectory` for incomplete transfers.

Before application, import or promote the full image into stable managed storage. Pin all currently referenced images, one previous recoverable image per display, and explicit offline favorites. Current references include configured disconnected displays and managed images known to have been applied on another Space; public APIs cannot prove every hidden Space has released an asset. Do not evict those assets automatically just because a different image is currently visible.

Retain at most 100 history metadata entries per display. Keep older history payloads only while available under the storage policy; mark metadata-only entries as requiring their original local file or a provider redownload. Previous is enabled only for a locally readable predecessor. Favorite removal releases only the favorite pin, never an active-display pin.

Default evictable cache budget is 1 GB, adjustable to 256 MB, 1 GB, or 5 GB. Pinned images are reported separately and never silently evicted to satisfy that budget. Expose total usage and Clear Cache. Cleanup touches only plugin-owned, unpinned assets; it never follows links outside managed roots. If pins prevent freeing requested space, report the retained amount.

Use a 50 MB per-file download ceiling and a 100-megapixel decoded-image ceiling as initial operational limits. Check actual streamed bytes as well as headers, validate ImageIO type/frame count/dimensions, downsample previews, and reject invalid or unsupported payloads before applying. These are resource safeguards, not a promise to accept all smaller images. Validate HTTPS provider endpoints and redirect hosts; never decode provider HTML metadata as executable content or open unvalidated URL schemes.

No original local-file deletion operation is exposed. Removing a favorite, history entry, or folder removes its library relationship only. Clear Cache and uninstall preserve user exports. Follow host uninstall preservation policy; do not register private-data destruction that could remove a still-used desktop image without a separate recovery design.

## Application and display ownership

Use `NSWorkspace.setDesktopImageURL(_:for:options:)`, `desktopImageURL(for:)`, and `desktopImageOptions(for:)` through a small `@MainActor` system adapter. Downloading, scanning, hashing, metadata persistence, and preview decoding run outside the main actor. Do not use AppleScript, mutate macOS wallpaper databases, or load private frameworks for ordinary wallpaper setting.

Identify displays by stable system display UUID when available, not their index or localized name. Distinguish equal display names in UI. Implement `DisplayTopologyRefreshing` so the existing host display observer drives reconciliation. Disconnecting a target retains its profile and last asset but suspends writes; reconnecting revalidates the image and display before resuming. A newly connected display in synchronized mode requires explicit opt-in before its existing wallpaper is replaced.

The public API targets an `NSScreen` and has no arbitrary Space selector. The supported contract is the desktop context exposed by macOS for each connected display. Do not advertise control over every Space or the lock screen. A Space transition refreshes observable state and conservatively pauses an affected rotating scope when ownership cannot be established; it does not automatically copy the last managed image into the newly exposed desktop.

Every scope has an operation generation and a serialized application coordinator. A source/profile/scope change or deactivation invalidates obsolete work. Recheck target connection, file validity, generation, and current ownership immediately before each system write. One desktop operation runs at a time; overlapping Next requests are rejected as busy, matching the host action concurrency policy. The workspace offers cancellation rather than accumulating pending downloads.

Multiple-display application is not atomic. Record successes and failures per display, persist the actual successful state, report partial completion, and pause automatic changes for the affected synchronized scope. Do not claim all-screen success or repeatedly overwrite successful screens to hide a failure. Cancellation after a successful system write does not undo that write; reconciliation records the actual outcome. An interrupted persistence transaction is reconciled against live state at activation rather than blindly reapplied.

### External changes and recovery

Do not assume a public wallpaper-change notification exists. While rotation is active, use a coalesced 60-second read-back check with timer tolerance, plus refresh on wake, desktop-context transitions, and immediately before automatic writes. Disable that ownership timer when paused. Opening a visible view can refresh once but is not the only refresh trigger.

Compare the observable image identity and relevant rendering options with the last successful managed state. Allow bounded settling after our own writes. A confirmed mismatch pauses the affected profile, or the synchronized scope, and preserves the user's image. An unreadable or ambiguous state suspends automatic writes and offers Retry/Resume rather than asserting that the user changed the wallpaper. This detects observable external changes; it cannot identify the user or guarantee detection of every internal dynamic-wallpaper transition.

The check and system write are not atomic; do not promise race-free coordination with another wallpaper manager. Explain in help that automatic rotation should have one active owner. Explicit Apply/Next remains an intentional replacement and may proceed after target validation while rotation stays paused.

Previous restores a managed image only. Do not advertise restoration of the original dynamic/system wallpaper or exact system slideshow configuration. Deactivation and app exit retain the last applied image and cancel all outstanding work; they do not restore an earlier wallpaper automatically.

## Scheduling and failure behavior

Store rotation intent, last successful application, next deadline, collection revision, and pause reason per scope. Resuming establishes the currently observable desktop as the starting baseline without immediately replacing it, then schedules the next interval. Initial enablement follows the first-use flow above. User-paused and externally paused states remain paused across restart.

An explicitly enabled profile can resume on app launch only after the stored ownership baseline is observable and still matches. Otherwise preserve the desktop and request explicit resume. The plugin creates no LaunchAgent or login item; host launch-at-login behavior remains authoritative.

Suspend changes and optional prefetch during display sleep, system sleep, and screen lock. On unlock/wake, reconcile ownership first, then perform at most one overdue switch; never replay missed intervals. Use monotonic time while running and reconcile persisted deadlines/time changes on relaunch. Once an application succeeds, the next interval starts from that success.

Sequential mode uses stable natural filename order for local collections. Shuffle mode persists a shuffled bag of known eligible IDs and avoids an immediate repeat across bag boundaries. Finite local/favorite collections exhaust the bag before reshuffling. Online searches are paginated and changing, so only promise no repeat within a bounded 100-item recent-ID window when alternatives are available. With one eligible asset, keep it without a redundant system write. With no usable assets, pause with an explanation.

Missing/corrupt local candidates are skipped within a bounded attempt budget of 10 per switch. Permission failures are surfaced for the affected folder, not silently treated as an empty library. Offline/API failures preserve the current image and retry after 1, 5, and 15 minutes, respecting a longer provider Retry-After; after exhaustion show a paused error requiring Retry. Validated candidates for the same collection can satisfy an offline switch. Disk-full and permission errors require user recovery rather than repeated download attempts. Manual source/filter changes cancel obsolete retries.

## Implementation structure

Create `Plugins/Wallpaper/` with `plugin.json`, `Sources/`, `Bundle/`, `Resources/`, and adjacent `Tests/`. Use the generator's ordinary bundle scheme and add plugin-local project overrides only if required. The official manifest uses the repository license, declares workspace settings, stable panel kinds, source domains/privacy behavior, localized product metadata, and canonical actions. Set minimum host compatibility from the APIs actually consumed and the first released host containing them.

| Type | Ownership |
| --- | --- |
| `WallpaperPlugin` | Cached panel/settings state, lifecycle, localization, and host action integration |
| `WallpaperController` | User intents, profiles, snapshots, and operation generations |
| `WallpaperSource` | Private asynchronous candidate/search/metadata interface |
| `WallpaperLibrary.scan` / `WallhavenWallpaperSource` | Folder discovery and provider-specific requests |
| `WallpaperLibrary` | Versioned asset index, references, favorites, history, and storage policy |
| `WallpaperTransferService` | Coalesced bounded transfers, validation, and managed-file promotion |
| `WallpaperController` scheduling / `WallpaperSelection` | Monotonic deadlines, selection bags, retries, and lifecycle suspension |
| `WallpaperSystemAdapter` | Public AppKit reads/writes and display identity |

Canonical action IDs are `next`, `previous`, `set-rotation-enabled`, `toggle-rotation`, and `apply-asset`. The toggle is convenient for shortcuts; workflows use the idempotent setter. `apply-asset` accepts a known library asset ID and validated display scope, not an arbitrary path or remote URL. Actions use the host registry/executor and declare interaction/network capabilities accurately. Settings selection is not an independent action implementation.

Plugin activation acquires observers and restores validated state; deactivation cancels scans, transfers, scheduled tasks, ownership checks, and observers. Public getters read snapshots only. Model state publication uses `onStateChange?()` with coalescing; view visibility controls preview work rather than the lifetime of enabled background rotation.

## Delivery sequence and acceptance

1. **System and local pipeline:** managed files, local folders, explicit application, display identity, and scoped failures.
2. **Library workspace:** bounded previews, favorites/history, storage controls, canonical actions, and host shortcuts.
3. **Automation:** selection bags, durable profiles, sleep/lock/restart behavior, external-change checks, and per-display rotation.
4. **Wallhaven:** discovery, metadata, provider limits, controlled prefetch, offline behavior, and source attribution.
5. **Release validation:** localization, packaging/compatibility, native interaction review, and hardware acceptance.

The complete release requires all five steps. No release, tag, signing, notarization, or publishing action is authorized by this design document.

Focused tests use fake providers/system adapters, temporary directories, and controllable clocks. Cover the main select/download/validate/apply outcome, per-display partial failure, no overwrite after detected ownership loss, current/favorite pin retention, folder permission recovery, bounded offline retries, and cancellation/deactivation suppressing late writes. Reuse adjacent coverage rather than testing every field or private call sequence. Never change the developer's real wallpaper in automated tests.

Manual acceptance covers macOS 14 and a current supported version, Intel/Apple silicon where available, local-only offline use, Retina/external portrait displays, hot-plug/disconnect/reconnect, multiple Spaces, screen lock/sleep/wake, external manual changes, Hide Notch coexistence, network failures, low storage, keyboard/VoiceOver, localization, and system appearance preferences. Confirm no Accessibility or Screen Recording permission is requested for ordinary operation. Measure closed-panel idle behavior and active online loading; no unnecessary animation, repeated scans, or duplicate timers should remain.

Run the smallest relevant `make test TEST_FILTER=<TestClassName>` checks during implementation, `make script-tests` for new PluginKit API consumption, localization validation, `make build-plugin PLUGIN=Wallpaper`, and changelog validation. Run `make ci` before pushing shared infrastructure or PluginKit changes. Add one plugin release fragment, update `docs/plugins/` with durable usage/recovery instructions and `CONTRIBUTING.md` for the new plugin integration as required. Do not edit generated or historical catalogs manually.

### Local implementation evidence

The implementation includes the plugin bundle, workspace, panel row and preview/compact widgets, provider adapter, scoped actions/shortcuts, persistent managed files, folder observation, and lifecycle-aware rotation. Image transfers share duplicate requests, allow at most three simultaneous transfers, and stop when their last consumer cancels. Directory scanning resolves physical roots with `realpath(3)` before using the shared no-follow reader; Foundation URL normalization does not expand every system alias.

Focused tests cover fake multi-display partial application, current-image retention during cleanup, corrupt metadata preservation, invalid-image rejection, no-follow folder discovery and access failure, ownership loss, exhausted provider retries, delayed provider callbacks after deactivation, provider filtering, shuffle/history behavior, and manifest action consistency. Tests never call the real desktop adapter's write method. Script validation additionally checks localization, plugin metadata, generated website data, and minimum-host compatibility.

Local validation on 2026-10-29 used Xcode 27.1 on arm64 macOS 27.0.1: all 11 focused tests and 237 script tests passed. The unsigned debug package and development catalog were generated under `build/WallpaperPackageValidation/`. Light/dark native workspace fixtures were rendered with synthetic local images, including expanded rotation settings and the selection inspector. A separate public-provider smoke check returned 24 eligible Wallhaven results and downloaded/validated a 3,759,732-byte, 5272-by-2962 image without applying it to the desktop.

On 2026-10-30, an isolated native workspace reproduced a blank gallery by scrolling a 72-image local collection to the bottom and switching to an 18-image provider result. The old lazy container retained an invalid viewport until manually scrolled. Gallery identity now follows the source, folder, and filter, with loading and empty states outside lazy content. After the fix, 16 repeated transitions across local, online, one-image favorites, and four-image history started at the top with visible content. Search misses and removing the final favorite also displayed their recovery guidance. This check used temporary files and a desktop adapter that rejects writes.

Physical hot-plug, screen lock, multiple Spaces, provider availability on other networks, minimum-OS behavior, keyboard/VoiceOver interaction, and energy measurements still need manual acceptance on the intended hardware. Simulated workspace rendering does not establish those outcomes. No release has been published.

## References

- [Plugin development standards](../../plugins/development-guidelines.md), [panel items](../../plugins/panel-items.md), [typography](../../plugins/typography.md), and [local plugin packaging](../../plugins/local-native-plugins.md).
- [Apple: setDesktopImageURL](https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl(_:for:options:)) and the local AppKit SDK `NSWorkspace.h` desktop-image contract.
- [Wallhaven API](https://www.whvn.cc/help/api), reviewed 2026-10-29. API availability does not establish image redistribution rights.
- [Unsplash API guidelines](https://help.unsplash.com/en/articles/2511245-unsplash-api-guidelines), reviewed 2026-10-29.
- [Wikimedia image metadata](https://www.mediawiki.org/wiki/API:Imageinfo) and [Commons reuse requirements](https://commons.wikimedia.org/wiki/Commons:Reusing_content_outside_Wikimedia).
- [desktoppr](https://github.com/scriptingosx/desktoppr), [Equinox](https://github.com/rlxone/Equinox), and [wallpapper](https://github.com/mczachurski/wallpapper) as research references only; no third-party code is included by this document.
