# Launcher integration

The launcher is a shortcut to existing capabilities: applications, macOS System Settings pages, system operations, and enabled plugin features. Option-Space toggles it. An empty query shows only favorites and recent successful operations; a new installation shows a search prompt. Command-K opens actions, Escape dismisses actions or the launcher, and Command-comma opens its independent Settings category.

## Built-in system actions

System Actions includes a host-owned catalog even when no plugins are installed or enabled. It covers locking, system/display sleep, session-ending operations, screen saver, desktop and Mission Control, media transport, output volume presets and stepping, output/input mute, appearance, Trash, and application visibility. These are fixed commands, not an arbitrary script runtime.

The host registers canonical definitions with the existing ActionExecutor. Restart, shutdown, logout, and emptying Trash require confirmation. Media transport requires Accessibility; fixed Finder/System Events adapters report Automation denial with recovery guidance. Unsupported audio controls fail explicitly. Discovery and search never execute commands or probe the pasteboard.

System Actions contains only host-owned commands that directly operate macOS. Its references and identities do not depend on plugin declarations, installation, or lifecycle. There is no plugin override or fallback. Plugin-owned commands appear under Plugin Features with their provider name, even when their effect controls the system. Inclusion, favorites, aliases, hidden state, and usage remain independent for each owner; existing plugin preferences and stored identities are preserved.

## Canonical actions and discovery

Implement the optional `PluginLauncherActionProviding` protocol and return a `LauncherActionRole` for existing `ActionReference` values. Use `.pluginFeature` for plugin functionality. The `.systemOperation` enum case remains ABI-compatible for existing clients, but current hosts normalize that plugin declaration to Plugin Features; it cannot add or replace built-in system commands. Return `nil` for configuration, permission setup, shortcut management, import/export, and internal plumbing. Classification is synchronous, read-only, and must not inspect the pasteboard, perform scans, or execute actions.

The host reads existing canonical catalog entries; it does not ask plugins for launcher-specific business pages or dynamic content. Titles, symbols, parameter bindings, availability, permissions, confirmation, and concurrency remain owned by the existing action system. References must be complete and valid before being listed. Existing `ActionInputDescriptor` entries route to the current composer rather than a new launcher form.

Official older packages use the reviewed compatibility inventory in `LauncherActionPolicy`. Unknown providers default to excluded until they adopt the protocol. The explicit protocol takes precedence, including a `nil` result. A provider's enabled/isolated state is checked during discovery and again immediately before execution. Newly added official actions require an explicit review before becoming searchable; never infer intent from localized names or action-ID substrings.

## Functionality versus configuration

An action that opens a task workspace is a feature even when that workspace is hosted in Settings: disk cleanup and Xcode cleanup keep their existing review pages. Mac Settings is itself a functional settings utility, so its existing feature actions remain available. General plugin preferences and host Settings navigation are not ordinary search results. Recovery links may be shown only after an execution failure.

Key Statistics, Storage Explorer, and System Data have reviewed workspace entries because their primary functionality lives in Settings and they have no canonical task entry. Status-only components and configuration-only plugins without an existing task action do not receive synthetic operations. They remain available through their existing panels and Settings.

The compatibility inventory covers the official manifest action providers individually. Activity Bar tracking/reset configuration is excluded. Clipboard exposes its history window, sequential-paste controls, and current-clipboard clearing; collection preferences and history management are excluded. Parameterized app, display, preset, shortcut, script, and window entries use only the concrete references already published by their providers. No arbitrary code execution or new processing capability is introduced.

## Host settings and data

Settings > Launcher groups General, Applications, System Settings, System Actions, and Plugin Features as sidebar destinations. The group can be collapsed; direct navigation reveals the requested child. These controls only change launcher inclusion, favorites, and aliases; they never disable a plugin or change its other shortcuts. Per-plugin business configuration stays in the plugin's Settings page. Application search can include additional directories or individual app bundles and offers manual refresh.

Launcher Settings shares one state model across its pages, caches source snapshots until relevant data changes, and renders long catalogs with reusable native table cells inside a single scrolling form. Embedded catalogs must not introduce their own scroll views. Page navigation must reuse the application snapshot; first use, filesystem events, scope changes, and explicit refresh own scanning.

Application scanning runs off-main and observes directory changes. System Settings discovery reads installed ExtensionKit metadata on a worker and shares the application bundle name reader for system-language titles and aliases. Its cache tracks directory modification, OS version, languages, hardware, and fallback labels. The original twenty IDs remain stable; new pages use bundle IDs.

Only settings extensions with navigation support are included. Known internal pages, unverified availability callbacks, account-dependent pages, and disconnected mouse/trackpad pages are excluded. Discovery never executes private availability code, reads account state, captures input, or prompts for authentication. Login Password and Energy labels adapt to the hardware. Conditional headphone personalities remain excluded when public metadata cannot establish a standalone destination.

Read failure uses installed common pages as an uncached fallback. Seven explicit privacy links require their parent Privacy & Security pane. Opening revalidates the extension identity and relevant hardware, and failure offers System Settings home. Discovery refreshes on presentation, app activation, wake, locale and directory changes; Launcher Settings also offers manual refresh. Search and discovery never open apps or change settings.

Portable personalization uses the existing backup system. Application paths, additional search scopes, and usage stay local. Unavailable favorites and removed draft-tool entries remain stored but are absent from the launcher. No plugin data is deleted. Ordinary text paste edits the query; images and file drops do not invoke content processing.

## Compatibility and validation

The new declaration protocol and shared application-catalog bridge require host 2.2.0 and retain PluginKit 7. Consumers declare that minimum. Published ABI layouts remain unchanged; the draft tool-page/session APIs were never published and have been removed. New hosts continue to support existing plugin binaries through canonical actions and the reviewed inventory.

Test inclusion/exclusion, complete references, provider invalidation, stable selection, application scope changes, and settings navigation with fake services or temporary directories. Run `make script-tests` and `make ci` for shared changes, including minimum-host and frozen-client checks. Physical shortcut delivery, IME candidates, Spaces, accessibility, appearance, and focus handoff require dedicated desktop acceptance.
