# Screenshot recording expansion

Date: October 28, 2026

Status: Implemented in source with Swift compilation and synthetic export validation. A signed Debug test app and 32 focused XCTest cases have been verified; live capture, full-suite validation, and hardware acceptance remain pending.

## Baseline reviewed before implementation

Before this change, the plugin implemented silent region recording on macOS 15 or later. The initial review identified system audio, microphone recording, and identity-based display/window/application recording as additions.

| Finding | Source |
| --- | --- |
| Both `capturesAudio` and `captureMicrophone` are explicitly false. | `Plugins/Screenshot/Sources/CaptureSessionPreparation.swift` |
| `Recorder` uses `SCRecordingOutput` to save MOV, with hardware codec checks and separate native-stop/file-completion coordination. | `Plugins/Screenshot/Sources/Record.swift`, `RecordingLifecycle.swift`, `CaptureStreamSession.swift` |
| Window selection retains rectangles, not window or application identity. Clicking a window can therefore define a recording region, but does not create a window capture filter. | `Plugins/Screenshot/Sources/CaptureController.swift`, `Overlay.swift`, `CaptureRegion.swift` |
| Auto zoom is enabled by default. The exporter operates on the original AVAsset; an existing synthetic test checks preservation of one audio track. This does not establish actual dual-source capture or playback behavior. | `ScreenshotEnvironment.swift`, `RecordingZoomExporter.swift`, `Plugins/Screenshot/Tests/RecordingZoomExporterTests.swift` |
| The plugin declares Screen Recording permission. Neither the public PluginKit permission enum nor the host permission center currently supports microphone permission. | `ScreenshotPlugin.swift`, `Sources/MacToolsPluginKit/PluginModels.swift`, `Sources/Core/Permissions/PermissionCoordinator.swift` |
| The host has no `NSMicrophoneUsageDescription`. Its existing system-audio purpose string says audio is never recorded or saved. Both the base plist and localized purpose strings need review before adding recording. | `Configs/MacTools-Info.plist`, `Sources/Resources/Localization/InfoPlist.xcstrings` |
| The plugin currently declares PluginKit v7 and minimum host 2.0.1. New host permission/privacy support must be reflected in its eventual minimum-host requirement. | `Plugins/Screenshot/plugin.json` |

The existing user guide already accurately documents silent region recording. Do not describe planned additions as available before they ship.

## Product scope and defaults

Keep the plugin name and current screenshot entry points. Recording remains available on macOS 15+, while the other existing features continue supporting macOS 14+.

Recording preparation offers:

- Target: Region, Display, Window, or Application.
- System Audio: an independent switch, initially off.
- Microphone: Off, System Default, or an available input device, initially off.
- Auto Zoom: preserve the existing preference for region/display recording. Disable it with an explanation for window/application recording in the first release, because current pointer coordinates assume a fixed display region.

Persist audio choices and microphone device UID, but resolve current authorization and device availability for every recording. Do not persist a window ID or process ID as a reusable recording target across launches. Selecting a device does not start capture.

Freeze target and audio configuration when recording starts. The first release does not add pause/resume, live source switching, gain controls, monitoring, noise suppression, camera overlay, HDR, or custom multi-display composition.

### Target behavior

| Target | Intended behavior |
| --- | --- |
| Region | Preserve the existing pixel-aligned crop of one display, including its validation and outline. |
| Display | Capture one selected display without manual dragging; exclude the recording controls. |
| Window | Capture the selected window's content through a window filter, rather than its former screen rectangle. Other overlapping windows must not appear. Use a fixed output canvas and preserve aspect ratio when the window is resized. |
| Application | Capture the selected running application's windows on one selected display. New windows from that application on that display are included. Other apps, desktop, and Dock are excluded. No automatic stitching across displays. |

For application recording, show the display explicitly in preparation. For window capture, moving/resizing, minimization, full-screen transitions, and closing must be verified against actual ScreenCaptureKit behavior before documenting guarantees. A closed target or terminated application ends recording and finalizes the existing file; a minimized/unavailable target must never silently fall back to desktop capture.

### Audio behavior

System Audio means audio eligible for capture under the selected content filter: the display/region scope for those targets and the selected application's scope for window/application recording. A region does not spatially crop sound, and a window does not imply per-window audio isolation. Explain this in concise preparation help. Confirm these scopes with two synthetic audio-producing applications before release.

All four combinations must work: silent, system only, microphone only, and both. A finished movie must play both selected sources in ordinary playback without requiring manual audio-track selection. Native straight-to-file support is the preferred path; verify its actual track/mixing behavior rather than assuming that one file implies one mixed audio track.

If a requested permission or device is unavailable before recording, return to preparation with guidance. Continuing without that source requires an explicit user choice. During capture, an unrecoverable selected-source failure stops and finalizes the recording with an explanation; do not report a complete recording while silently dropping requested audio. Normal silence is not an error.

## Architecture

### Recording request and target resolution

Introduce plugin-private `RecordingRequest`, `RecordingTarget`, and `RecordingAudioOptions` models. Keep them separate from `CaptureRegion`, which is also used by scrolling capture. Keep native ScreenCaptureKit objects on their documented actor/queue boundaries.

Resolve a request into a prepared filter, output dimensions, control placement, audio configuration, and lifecycle observers immediately before start. Region and display filters reuse current exact control-window exclusion. Window filters use `SCContentFilter(desktopIndependentWindow:)`. Application filters use `SCContentFilter(display:including:exceptingWindows:)` with the selected running application and display.

Do not convert a selected window back to a display crop. If custom overlay selection is used, carry its window ID and owning process identity through selection, then resolve a fresh `SCWindow` before starting. Validate that the process/window is still the chosen instance; do not redirect to a relaunched process or another window with the same title.

Prefer Apple's shared `SCContentSharingPicker` for supported native target selection, subject to the milestone-zero integration gate below. Keep its returned filter opaque wherever possible. `includedDisplays`, `includedApplications`, and `includedWindows` are macOS 15.2+ APIs in the reviewed SDK; a macOS 15.0 path must not depend on them. `excludedWindowIDs` prevents picking those windows; it is not proof that the windows are excluded from a display recording.

The required first-release semantics are one display for application capture and exact exclusion of control windows. If the system picker cannot supply these semantics on macOS 15.0, use a compact native AppKit target chooser backed by `SCShareableContent`, with the explicit filter constructors above. Choose this path before building the full UI; do not raise the recording OS minimum merely to inspect a picker result. Do not rebuild an opaque picker filter with broader scope.

Keep content discovery asynchronous, bounded, and tied to explicit preparation. Refresh the chooser on application/window/display changes while visible; cancel stale discovery when it closes. No new idle capture, screenshot-thumbnail polling, or broad desktop recording is needed for discovery tests.

### Audio capture and output

Extend only recording configuration with `capturesAudio`, `captureMicrophone`, and `microphoneCaptureDeviceID`. Shared scrolling configuration remains silent. Use ScreenCaptureKit's system-audio format configuration and let the selected microphone use its supported native format; do not assume both sources have the same sample format.

Keep `SCRecordingOutput`, existing hardware encoding checks, MOV output, and the two-part completion contract. Adding audio does not require a virtual audio driver or third-party library.

Milestone zero must establish whether native output satisfies dual-source playback and synchronization requirements. If it does not, prefer a bounded AVFoundation postprocessing mix that preserves the original recording. A custom real-time `AVAssetWriter` pipeline is a separately estimated fallback, not a prerequisite for the feature. Do not ship two selectable tracks as if simultaneous playback were established.

Preserve all captured audio through auto-zoom export and Keep Original/cancellation recovery. Extend the adjacent exporter test with distinguishable signals only where necessary to verify the actual output structure and decoded content; do not duplicate its existing video geometry and original-file preservation coverage.

### Permissions and host compatibility

Add `NSMicrophoneUsageDescription` to the host and localized purpose strings. Update `NSAudioCaptureUsageDescription` so it accurately distinguishes local App Volume processing from user-initiated recording that saves audio. Review microphone audio-input entitlement requirements for the actual signed Hardened Runtime configuration; do not enable App Sandbox as part of this feature.

Use `AVCaptureDevice.authorizationStatus(for: .audio)` and explicit, user-initiated authorization for microphone recording. Activation and ordinary screenshots must not request microphone permission. Permission denial must not disable screenshots or silent recording. ScreenCaptureKit system audio should follow its own capture/authorization path; do not reuse App Volume's Core Audio capture implementation just because both concern audio.

Integrate microphone status, request action, System Settings routing, and activation refresh into the host permission center. Follow the existing stable-permission-ID resolution precedent used by `system-audio-recording`, rather than casually adding a case to the public PluginKit v7 enum. Review the descriptor and host mapping together. If the existing public descriptor cannot represent this accurately, resolve the ABI design before implementation.

The microphone requirement is optional for the common screenshot action. Only a recording request with microphone enabled gates on microphone authorization. Permission cards and error state still come through the host's existing rendering and state-change hooks. Audio levels, if added later, should not trigger host-wide rebuilds for every sample.

Raise `Screenshot`'s minimum host to the actual release containing microphone privacy and permission support. Do not invent a release number. An old host must reject the new package before plugin activation; the old compatible package remains usable on the new host. Preserve signed historical catalogs. This requires an app release and a plugin release, not merely republishing the plugin.

### Lifecycle and presentation

Reuse `ScreenshotCoordinator`, `CaptureStreamSession`, and `RecordingLifecycle`. The coordinator owns preparation before any asynchronous permission, picker, or device work, and releases it on cancellation. No late callback may start capture after Escape, deactivation, or a newer session.

Register device, target, and display observers for the active preparation/recording lifetime. Reuse host display-topology notifications. Stop on invalidated target geometry where continuing cannot preserve the selected scope; finalize before reporting completion. Remove observers and picker registrations on all completion paths.

Reuse the existing preparation and status capsule appearance, `PluginTypography`, and declarative Recording settings section. Keep source controls out of screenshot/scroll modes. Resolve permissions while preparation is visible and avoid presenting a native picker behind the full-screen capture overlay. Provide keyboard navigation, accessibility labels, and a visible stop control on every target mode.

For display/region output, continue excluding this session's exact controls. For application output, do not accidentally add MacTools control windows through the exception list. Prevent selecting recording-control windows as targets. Preserve the ability to record other MacTools content only if its controls can be excluded reliably; otherwise explain that target restriction.

## Implementation milestones

| Milestone | Work | Exit condition |
| --- | --- | --- |
| 0. Native feasibility | Build a temporary synthetic capture probe for the four audio combinations, picker integration, target filters, control exclusion, fixed-canvas resizing, and auto-zoom audio export. Check macOS 15.0 API availability explicitly. | Record actual output track/playback behavior, source scope, and picker limitations. Choose native or explicit target selection and establish whether any mixing step is needed. No production UI until these decisions are recorded. |
| 1. Audio for existing region recording | Add request/audio models, host privacy and microphone permission support, independent audio controls, device selection, and recording configuration. Preserve existing lifecycle and auto zoom. | All four audio combinations are playable and synchronized; denial, cancellation, disconnect, and original-file recovery work. Silent recording and scrolling remain unchanged. |
| 2. Display and window recording | Add resolved target preparation and selection UI; preserve window identity; generalize recorder geometry, controls, and termination handling. | Direct display selection and occlusion-independent window capture work; controls are absent; closing/resizing/moving a target has defined outcomes. |
| 3. Application recording and release integration | Add display-scoped application filters, source-scope help, live window membership, manifest privacy updates, translations, guides, and compatibility gating. | Only the chosen app appears; unrelated app audio does not leak; new windows, app exit, and display removal behave correctly; app/plugin packaging checks pass. |

Each milestone should remain a focused reviewable change. This plan does not authorize signing, tagging, notarization, or publishing.

## Validation

Reuse and extend adjacent tests for distinct contracts:

- Request resolution/configuration: audio combinations, live target validation, and exact exclusion, without capturing the user's desktop.
- Permission/coordinator integration: microphone denial leaves screenshots and silent capture usable; cancelled authorization/picker results cannot start a session.
- Lifecycle: target/device loss triggers a real stop and waits for native termination and file finalization; reuse existing `RecorderTests` completion coverage.
- Export: decoded output contains both distinguishable synthetic sources when selected, stays aligned with video, and preserves the recoverable original on failure/cancellation. Track count alone is insufficient.
- Compatibility: manifest minimum-host gating and old-plugin/new-host behavior. Add public API inventory coverage only if public API is introduced or newly consumed.

Run focused classes as affected, starting with `RecorderTests`, `ScreenshotCoordinatorTests`, `ScreenshotPluginTests`, `CaptureRegionTests`, and `RecordingZoomExporterTests`. New focused types may use `RecordingRequestTests` and `RecordingPermissionTests` if their behavior is not already covered nearby.

Implementation validation includes:

```sh
make test TEST_FILTER=<AffectedTestClass>
make script-tests
make build-plugin PLUGIN=Screenshot
make ci
```

`make ci` is required for the eventual cross-module host/permission changes. `make script-tests` covers manifest/localization/compatibility checks; `make validate-changelog` is required when adding release fragments. Use `make generate` if a project configuration changes.

Manual acceptance covers macOS 15 and a current supported macOS version; macOS 14 recording availability; Apple silicon and available Intel hardware; mixed-scale displays; headphones/Bluetooth/USB microphone changes; revoked permissions; minimized/closed/resized windows; Space/full-screen changes; display disconnect; and both normal and auto-zoom output. Use synthetic content and explicit consent for any microphone capture. Compare a short clip with a longer clip to detect accumulating audio drift; preflight must set a measured acceptance tolerance before release claims.

At implementation time, update `docs/plugins/screenshot.md`, `CONTRIBUTING.md` for manifest/permission requirements, plugin privacy/localized metadata, and both app and plugin changelog fragments. Describe host permission support and plugin recording capabilities separately. Update root product overviews only if the final capability change warrants it.

## References reviewed

- [Apple: Capture HDR content with ScreenCaptureKit, WWDC24](https://developer.apple.com/videos/play/wwdc2024/10088/) — microphone and straight-to-file recording support, particularly 7:13–10:44.
- [Apple: SCRecordingOutput](https://developer.apple.com/documentation/screencapturekit/screcordingoutput) — macOS 15 minimum and native recording output.
- [Apple: SCContentFilter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter) — display, independent-window, and application filter constructors.
- [Apple: SCContentSharingPicker](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker) — shared native picker and observer lifecycle.
- Local SDK headers `SCStream.h`, `SCContentSharingPicker.h`, and `SCRecordingOutput.h` — microphone UID semantics, macOS 15.2 filter introspection availability, picker exclusion semantics, and recording completion.

The documentation and SDK establish available APIs. They do not replace the milestone-zero capture/playback evidence or the acceptance matrix above.

## Implementation update — October 28, 2026

Implemented the plugin-private recording request, native AppKit preparation chooser, independent audio choices, optional host microphone authorization, target-specific filters, source-loss handling, and audio mixing during export. The chooser uses explicit content discovery/filter constructors to retain macOS 15.0 support and exact control exclusions. Window/application targets disable auto zoom. MacTools itself is excluded as an independent target until its recording controls can be excluded from all application-filter paths.

The host capability key and purpose-string check gate audio on older hosts without changing PluginKit v7 or guessing the next app release number. The release preflight must assign the plugin's final minimum-host version after the actual host release is selected.

Swift 6 compilation and synthetic media export checks are available in the current Command Line Tools environment; full Xcode/XCTest, signed live capture, hardware behavior, and supported-version acceptance remain release prerequisites. No microphone or desktop content was captured by the synthetic media checks.

The subsequent installation turn located Xcode 27.1, passed all 32 focused XCTest cases, built the Debug host with its recording entitlement, and installed an isolated ad-hoc signed MacTools Recording Test app with the new Screenshot package loaded. The existing development app remains available. Full-suite CI and manual live capture acceptance are still separate follow-ups.

The user clarified that manual testing should use the existing MacTools Dev installation. The host was rebuilt with its original bundle identifier and storage scope, then reinstalled at the existing path with the previous app and Screenshot package retained in a recovery backup. Only Screenshot was synchronized into the existing plugin store. The original Dev process was confirmed running with the updated Screenshot binary loaded and its microphone permission card visible. The extra isolated test app was stopped and moved out of Applications; its separate data was left intact.
