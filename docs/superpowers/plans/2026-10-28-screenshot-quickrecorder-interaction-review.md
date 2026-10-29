# Recording interaction review: QuickRecorder

Date: October 28, 2026

Status: Source review completed; the approved interaction changes are implemented in MacTools. QuickRecorder was not installed or executed, and no source code was copied.

Reviewed repository: [lihaoyun6/QuickRecorder](https://github.com/lihaoyun6/QuickRecorder), `main` at commit `e82051787f013ec2e811fcceab2d7de80e9d4dbe`. The public GitHub repository metadata identifies its license as AGPL-3.0. This document describes behavior and architecture rather than incorporating its implementation.

## Main finding

QuickRecorder puts source selection, reusable recording options, and Start in the same preparation context. It has source selectors, but does not require opening a second generic configuration window after selecting a source just to reach Start.

For area recording, the flow is:

1. Choose Screen Area from the main panel.
2. Adjust the area while a floating recording bar is available.
3. Optionally change inline recording options.
4. Press Start; the saved countdown runs only if configured.

The important reduction is the removal of a mandatory transition between selection and recording, rather than simply remembering settings.

## Source evidence

| Concern | Verified implementation | Reference |
| --- | --- | --- |
| Direct source entry | The main panel offers separate Screen, Screen Area, Application, and Window actions. | [ContentView.swift, lines 160–200](https://github.com/lihaoyun6/QuickRecorder/blob/e82051787f013ec2e811fcceab2d7de80e9d4dbe/QuickRecorder/ViewModel/ContentView.swift#L160-L200) |
| Area controls next to Start | `AreaSelector` embeds `OptionsView()` in the same horizontal control bar as Start. | [AreaSelector.swift, lines 151–185](https://github.com/lihaoyun6/QuickRecorder/blob/e82051787f013ec2e811fcceab2d7de80e9d4dbe/QuickRecorder/ViewModel/AreaSelector.swift#L151-L185) |
| Shared settings across targets | Area, screen, application, and window selectors all use `OptionsView`. | `AreaSelector.swift:151`, `ScreenSelector.swift:109`, `AppSelector.swift:119`, `WinSelector.swift:193` |
| Persistent audio choices | `OptionsView` binds microphone enablement, microphone device, and captured application audio to `@AppStorage`. They are inline controls, not a required settings detour. | [AppSelector.swift, lines 203–217](https://github.com/lihaoyun6/QuickRecorder/blob/e82051787f013ec2e811fcceab2d7de80e9d4dbe/QuickRecorder/ViewModel/AppSelector.swift#L203-L217), [lines 306–345](https://github.com/lihaoyun6/QuickRecorder/blob/e82051787f013ec2e811fcceab2d7de80e9d4dbe/QuickRecorder/ViewModel/AppSelector.swift#L306-L345) |
| Less frequent operations | Resizing and automatic stop use a sheet/popover reached from the recording bar. Start remains independently accessible. | [AreaSelector.swift, lines 119–185](https://github.com/lihaoyun6/QuickRecorder/blob/e82051787f013ec2e811fcceab2d7de80e9d4dbe/QuickRecorder/ViewModel/AreaSelector.swift#L119-L185) |
| Optional countdown | `createCountdownPanel` executes its completion immediately when the saved countdown is zero. The registered default is zero. | [ContentView.swift, lines 372–386](https://github.com/lihaoyun6/QuickRecorder/blob/e82051787f013ec2e811fcceab2d7de80e9d4dbe/QuickRecorder/ViewModel/ContentView.swift#L372-L386), `QuickRecorderApp.swift:226` |
| Reusable area | The last area is stored and restored for its display, while dimensions also have persisted settings. | `RecordEngine.swift:101–104`, `AreaSelector.swift:280–295` |
| Target semantics | An independent-window filter captures one actual window; display/application/area paths build distinct filters before streaming. | [RecordEngine.swift, lines 87–137](https://github.com/lihaoyun6/QuickRecorder/blob/e82051787f013ec2e811fcceab2d7de80e9d4dbe/QuickRecorder/RecordEngine.swift#L87-L137) |
| Audio output | The engine uses ScreenCaptureKit samples plus a custom AVAssetWriter pipeline, with a microphone capture path and optional post-recording track mixing. | `RecordEngine.swift:285–295`, `RecordEngine.swift:415–465`, `SCContext.swift:363–364`, `SCContext.swift:714` |

The source contains both `ContentView` and `ContentViewNew`: the latter is also used in the status-bar popover. This review therefore follows the shared selectors and `OptionsView`, rather than treating either entry view as the only active UI.

## Comparison with the previous MacTools implementation

MacTools already persists `recordingAudio` and `recordingAutoZoom` through `ScreenshotEnvironment`. Adding persistence again would not address the reported inconvenience.

The previous unnecessary transition was explicit in the callback chain:

`Overlay.startRecord` → `CaptureController.onRecord` → `ScreenshotCoordinator.prepareRecording` → `RecordingPreparationPanel` → Start → `Recorder`.

The previous overlay's primary recording action was titled Recording Options. Choosing recording mode before selecting an area also opens this generic panel. The panel presents target and audio choices even when the user has already selected the intended region and wants to reuse the previous options.

## Proposed MacTools flow

For normal region recording:

`Choose Recording → Select/adjust region → Start Recording`.

The selection toolbar should expose:

- The selected target and an optional target chooser.
- An independent System Audio switch.
- Microphone Off, System Default, or a specific device.
- Auto Zoom where the target supports it.
- Optional additional settings.
- A primary Start Recording action.

All controls share the existing environment preferences. A user can reuse them without reopening another window. Changing a preference updates the shared state immediately. Preserve the current initially-off audio choices; QuickRecorder's different defaults are not a reason to start capturing audio implicitly.

For display, window, and application recording, keep the options and Start beside the target selection. An explicit target change can open a selector, but confirming a target must not lead to another mandatory generic configuration page. Saved process or window identifiers must still be resolved as live targets before capture.

Use an optional menu or popover for less frequent settings. Keep the primary bar compact rather than copying QuickRecorder's complete set of resolution, quality, background, HDR, and timer controls. Match MacTools' existing native capsule controls and `PluginTypography`.

## Implementation boundaries

| File or owner | Proposed responsibility |
| --- | --- |
| `Overlay.swift` | Show direct Start plus shared audio controls; keep Recording mode available for area selection instead of immediately opening a separate panel. |
| `CaptureController.swift` | Pass the selected target and audio configuration as a recording request, preserving selection while a recoverable authorization or validation step is pending. |
| `CaptureController.swift` and `RecordingStartGate.swift` | Keep preparation owned through cancellation-safe microphone authorization and direct request startup. A cancelled permission result must not start recording later. |
| `RecordingApplicationPicker.swift` | Select the application from an icon-and-name grid and the display inline in the bottom toolbar; keep discovery cancellable and validate disappearing targets. |
| `ScreenshotEnvironment.swift` | Continue owning persisted choices and synchronize every recording surface. |
| `Recorder`, `CaptureStreamSession`, `RecordingLifecycle` | Retain native output ownership, real stop/finalization acknowledgements, source validation, and original-file recovery. |

QuickRecorder's custom writer and microphone engines support its broader output and compatibility scope. MacTools can adopt the interaction organization while continuing to use its existing macOS 15+ `SCRecordingOutput` path and verified audio export processing.

When adapting the UI, preserve MacTools' microphone device UID matching and explicit unavailable-device guidance. The reviewed QuickRecorder UI stores device display names and may reset an unavailable device to Default; that behavior should not replace the current identity and permission boundaries.

## Focused acceptance

- Region selection exposes a working Start action without visiting Recording Options.
- Audio choices on the bar are the exact choices carried into the request and remain consistent on reopening.
- Denied microphone authorization leaves the user able to turn off the microphone and proceed, with the intended region retained where possible.
- Cancelling during preparation or authorization cannot start capture later.
- Changing target modes does not silently broaden the chosen source or lose the visible audio configuration.
- A compact selection, multiple displays, long device names, keyboard navigation, and both appearances remain usable with native control sizing.
- Existing recording lifecycle and synthetic dual-audio export checks continue to pass.

The current review establishes source-level behavior. It does not claim a runtime test of QuickRecorder, and it does not add its camera, HDR, pause/resume, or editor features to the MacTools scope.

## Product proposal: convenient everyday recording

The primary experience is `Open Recording → Select an area → Start`. Opening Recording enters selection immediately. The initial target type is Region; users do not have to configure recording before drawing a selection.

### One preparation surface

The compact selection bar contains a target menu, System Audio, Microphone, Start Recording, and an overflow menu. The primary action is always Start Recording. It is enabled when the current target is valid. Pressing Return performs the same action; Escape cancels preparation.

System Audio and Microphone display explicit on/off states. The microphone control provides an adjacent device selector showing the selected input name, or System Default and its resolved input name. Long names truncate with a full-name tooltip. First-use audio defaults remain off. Changes persist immediately, so ordinary repeat recordings can reuse the visible choices without reopening settings.

The target menu offers Region, Entire Display, Window, and Application. Display selection uses a direct display choice. Window selection uses hover/click targeting with the actual window identity. Application selection expands an app icon-and-name grid and display picker inside the bottom recording toolbar. Highlight the single selected app with a checkmark and allow vertical scrolling. Each target path exposes Start in its existing preparation context; it does not route through a second generic options window.

### Progressive disclosure

Auto Zoom and the save-folder action belong in the overflow menu, with the existing recording preferences shared across surfaces. Keep the initial bar focused on the target and the two sound sources. Resolution, frame rate, codec, camera, countdown, and pause/resume are outside this interaction revision.

### Start, stop, and recovery

- Start begins recording with the visible source/audio choices. No additional app confirmation or save dialog is required.
- The recording surface replaces preparation controls with elapsed time and an obvious Stop action. Source choices remain fixed for that recording.
- Stop finalizes and saves to the existing save location automatically. Completion identifies the saved movie and offers a Show in Finder action. Processing remains visible when audio mixing or auto zoom is still running.
- A missing microphone permission is handled only when the selected audio configuration needs it. If authorization fails, retain recoverable selection state and offer an explicit way to turn the microphone off and continue.
- An unavailable device or target is explained in place. Do not silently switch to another source or start with different audio choices.

### User-facing acceptance criteria

1. A user who already has permissions can record an area without opening Recording Options or Settings.
2. The current microphone and system-audio states are understandable before Start, including when reusing saved choices.
3. Changing the target does not discard sound preferences or require configuring the same choices again.
4. A recording can be stopped and found without navigating through settings or choosing a filename.
5. Denied microphone access does not force the user to select the area again just to continue without microphone audio.

Implementation and manual testing continue in the existing MacTools Dev app and its normal configuration scope. This proposal does not call for a separate test application.

## Implementation outcome

The region and display paths now call the recorder directly through a cancellation-safe authorization gate. The shared preparation controls save audio changes immediately, keep microphone device selection beside its independent checkbox, and put Auto Zoom and folder selection under More. Window capture uses the visible window snapshot to highlight and select an actual window ID and owner PID; the stream resolves that identity again before recording. Application selection expands its icon-and-name grid and display picker in the same bottom toolbar as Start, without a separate window. Its native collection view supports selection, scrolling, keyboard navigation, and accessibility. Cancelling the save-folder panel returns to selection. Denied microphone access preserves selection and shows an inline error. Completion and preserved-original notifications offer Show in Finder.

The native light/dark toolbar preview uses synthetic pixels and does not request recording permissions. Focused XCTest covers direct Start/Return, frontmost window identity, persistent audio choices, denied microphone retry, cancellation of pending authorization, media mixing, recording lifecycle, and host permissions. Live desktop recording and microphone consent remain manual acceptance checks in the original MacTools Dev app.

## Toolbar interaction audit

Recording keyboard input stays within recording actions: Tab and Shift-Tab navigate its controls, and screenshot editing shortcuts no longer run while preparing a recording. Application recording requires explicit selection, exposes a Refresh Apps action, and shows loading, empty, and missing-target states inline. Refreshes coalesce notifications received during discovery and preserve a valid selection and scroll position. Capture authorization errors remain independent from application-list status.

The control groups wrap without shrinking their text when the available width is narrow. The application header and icon grid adapt to the same width and height budget. Microphone input selection follows its enablement, and Auto Zoom does not appear checked for targets that cannot use it. Native light/dark previews cover wide and narrow layouts.
