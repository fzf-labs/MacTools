# Disk Cleanup Core Expansion Plan

## Goal and Agreed Scope

Expand the existing `disk-clean` plugin into six common storage-management workflows:

1. Application, browser, and supported system-state cache and log cleanup.
2. Leftover installer discovery and removal.
3. Rebuildable developer-artifact cleanup.
4. Third-party application uninstallation.
5. Already-uninstalled application leftover review and removal.
6. Navigation to the existing Storage Explorer plugin for large-file and disk-usage analysis.

All new cleanup and uninstall surfaces belong to Disk Clean. Storage Explorer retains its own scanner, review UI, and deletion implementation. Implement and validate the work incrementally, but deliver the selected scope together rather than publishing incomplete feature batches.

### User-Confirmed Defaults

- Support ordinary writable third-party applications. Do not introduce administrator elevation, a privileged helper, system-service removal, or vendor-uninstaller execution.
- Preserve personal settings and application support data by default. Allow explicit per-path selection when ownership and safety can be established.
- Always protect credentials, browser identity data, shared containers, and data whose exclusive ownership cannot be established.
- Default file cleanup to Trash. Preserve the existing explicitly confirmed permanent-delete option for existing cleanup workflows. New application uninstall operations are Trash-only, regardless of the stored cleanup mode.
- Preserve existing whitelist, permission guidance, preview, history, identity checks, staging, and recovery behavior.
- Do not include system repair, DNS refresh, database maintenance, architecture slimming, scheduled scans, automatic cleanup, CLI interfaces, or report export.

This is an expansion of the current implementation under `Plugins/DiskClean`, not a replay of the original April 2026 implementation plan. Use the current source as the implementation baseline. Preserve unrelated working-tree changes; do not automatically branch, commit, sign, tag, or publish.

## Mole Reference and Adaptation Policy

Use the open-source [tw93/Mole CLI](https://github.com/tw93/Mole) as an explicit reference for all applicable workflows, including application uninstallation. Its separate proprietary native application and advertised application-rule counts are outside this comparison and implementation scope.

| Area | Upstream references | What to study and adapt |
| --- | --- | --- |
| Cache and log rules | `lib/clean/user.sh`, `lib/clean/app_caches.sh`, `lib/clean/caches.sh`, `lib/clean/dev.sh` | Regenerable cache locations, application-specific exclusions, running-process protection, and truthful skip reasons. |
| Developer artifacts | `lib/clean/project.sh`, `lib/clean/purge_shared.sh` | Project markers, artifact types, recent activity, Git-tracked content, nested repositories, and deployment-key protection. |
| Installers | `bin/installer.sh` | Source directories, supported installer formats, ZIP-content inspection, and deletion-boundary revalidation. |
| Application uninstall | `bin/uninstall.sh`, `lib/uninstall/` | Application discovery, batch selection, association evidence, personal-data choices, multiple copies, shared data, process checks, and partial outcomes. |
| Orphaned application data | `lib/clean/apps.sh` | Installed-application evidence, candidate attribution, shared ownership, and execution-time ownership rechecks. |
| Safety contracts | `SECURITY.md`, `SECURITY_AUDIT.md` | Relevant deletion, permission, and uncertainty boundaries; review applicability against the current MacTools pipeline. |

Before adapting each area, inspect the upstream implementation at one recorded commit. Record the commit SHA and source paths in the implementation review notes; do not silently track a moving upstream branch or execute downloaded cleanup scripts against the developer machine.

For each adopted rule, record the upstream location, MacTools category, ownership evidence, process guard, default selection, and protected-data exclusions. Classify it as retained, adapted, or intentionally excluded. Existing MacTools rules are not removed merely because they are absent upstream.

Implement the behavior in native Swift using Foundation, AppKit, and the existing MacTools filesystem and process abstractions. Do not ship or invoke Mole as the cleanup backend. Keep MacTools' default-to-Trash behavior and existing deletion protections even when Mole's corresponding command permanently deletes files.

Follow `LICENSING.md`. Retain applicable upstream copyright and license notices for copied or adapted implementation material and update the canonical third-party notices inventory when distribution includes that material. Research-only references do not become distribution components. Avoid introducing a third-party runtime dependency.

## Feature Specification

### 1. Cache and Log Cleanup

- Preserve current categories, stable target IDs, whitelist matching, and supported application rules.
- Audit common browser, communication, office, AI, and developer-tool rules. Add only locations supported by inspected upstream code or explicit application metadata and confirmed to contain regenerable caches or historical logs.
- Do not widen cache rules into entire application-support directories, model libraries, user documents, browser profiles, or synchronized content.
- Show ownership/category, path, measured or unknown size, cleanup consequence, selection state, and skip reason.
- Guard attributed caches against relevant running applications and processes. Unknown process state must not authorize deletion.
- Keep denied access, partial scans, unavailable locations, and empty results distinct. Unsupported system-owned locations remain skipped; this plan does not expand privileged cleanup.

### 2. Leftover Installers

- Keep Downloads top-level scanning as the default. Desktop and additional user-chosen directories are opt-in and also scanned at the top level; do not introduce recursive installer discovery in this release.
- Support DMG, PKG, MPKG, ISO, XIP, and ZIP files positively identified as containing installer/application content. Treat directory-based installer packages as indivisible candidates.
- Inspect ZIP directory metadata only, with bounded subprocess output, cancellation, and timeout handling. Do not extract archives or execute their contents. Corrupt, encrypted, unreadable, or incompletely inspected archives are not deletable installer candidates.
- Keep installers modified within seven days unselected by default. ZIP candidates are always unselected by default.
- Group results by source. Normalize and deduplicate scan roots; do not follow child symlinks, hydrate cloud placeholders, or traverse unsupported volumes.
- Extend the existing scan-root configuration pattern for installer roots without changing stored developer roots. Resetting installer roots restores Downloads only.

### 3. Developer Artifacts

Support these explicit project/target combinations:

| Project | Targets and required evidence |
| --- | --- |
| Node.js | `node_modules`, `build`, and `dist` with `package.json`. |
| Next.js | `.next` with a Next.js dependency in `package.json`. |
| Nuxt | `.nuxt` and `.output` with a Nuxt dependency in `package.json`. |
| Rust | `target` with `Cargo.toml`. |
| SwiftPM | `.build` with `Package.swift`. |
| Python | `build`, `dist`, `.pytest_cache`, `.mypy_cache`, and `.ruff_cache` with `pyproject.toml` or `setup.py`; `venv` and `.venv` additionally require `pyvenv.cfg`. Preserve existing `__pycache__` discovery. |
| Gradle/Android | `build` and `.gradle` with `build.gradle` or `build.gradle.kts`. |
| Flutter | `build` and `.dart_tool` with a Flutter dependency in `pubspec.yaml`. |
| .NET | `bin` and `obj` alongside a `.csproj`, `.fsproj`, or `.vbproj` file. |
| PHP Composer | `vendor` with `composer.json`, `composer.lock`, and Composer-installed package metadata inside the target. Do not generalize to other `vendor` directories. |

- Keep configured project roots and the current six-level discovery depth. Prune after finding a candidate to prevent nested duplicates.
- Add explicit candidate-content protection before broadening target types: block Git-tracked files, nested repositories, deployment-key files, and existing sensitive-data classes. A failed protection probe blocks deletion.
- Preserve warnings for uncommitted or unpushed changes. Such projects, artifacts with activity within seven days, and artifacts whose activity cannot be established remain unselected by default.
- Check relevant active build/development processes before execution. Unknown activity must not count as idle.
- Revalidate project evidence, protected content, and process state at execution. Do not equate a clean Git working tree with disposable contents.
- Keep global Xcode cache behavior in existing rules; do not duplicate the full Xcode Clean plugin manager.

### 4. Application Uninstallation

#### Discovery and Association

- Scan `/Applications` and `~/Applications`, plus explicitly added application roots. Support vendor subfolders with a bounded six-level discovery depth; stop at each `.app` bundle and do not descend into app internals.
- Display application name, icon, Bundle ID, location, and size. Support name/Bundle ID search, size sorting, individual selection, and batch selection.
- Identify application copies by physical path plus filesystem identity, not Bundle ID alone. Present separate copies as separate rows.
- Share an installed-application inventory with leftover discovery. Supplement configured-root discovery with available Launch Services and system-search evidence; preserve probe completeness and uncertainty.
- Associate user-level caches, logs, preferences, containers, and application-support paths using exact Bundle IDs, explicit container metadata, or curated exact ownership mappings. Never use fuzzy display-name or vendor-prefix deletion rules.
- Show the ownership evidence for each association. Curated mappings must declare exclusions and shared ownership rather than assuming an entire vendor directory belongs to one application.

#### Preview and Protection

- Group each application's review into application bundle, regenerable caches, optional personal data, and protected/manual-action items.
- Do not preselect applications when opening the page. After explicit application selection, eligible associated caches may be selected; settings and personal support data remain unselected.
- Offer per-path personal-data selection without an implicit "remove everything" mode. Browser identity data, password-manager data, credentials, shared App Groups, synchronized data, and ambiguous associations remain protected.
- Exclude macOS/system applications, MacTools itself, running applications or associated active processes, and bundles containing protected or separately owned nested applications.
- Do not silently quit applications. Offer refresh and Finder reveal with a reason when users must quit an app or perform manual removal.
- Check the actual ability to move the bundle to Trash, including its parent and destination. Failures involving permissions, locked files, special uninstall requirements, or protected helpers produce actionable results without privilege escalation.
- System-level LaunchAgents, LaunchDaemons, privileged helpers, and vendor-managed services are review/manual items only. Do not disable or remove them as an uninstall side effect.
- Preserve associated data whenever another valid installed copy with the same Bundle ID remains. If ownership or copy-discovery completeness is uncertain, application-only removal may proceed, but associated-data removal must remain blocked.

#### Execution and Recovery

- Freeze the reviewed application identities and per-path choices into a validated, Trash-only operation group. Recheck inventory, ownership, processes, safety, and identities before writes.
- Move application bundles before associated data. When multiple selected copies share a Bundle ID, remove associated data only after all selected copies succeeded and no remaining copy is found.
- If bundle removal fails, skip its associated data. If data removal fails after bundle removal, report the real partial outcome; do not claim full success or promise automatic cross-path rollback.
- Preserve the existing per-path staging journal, audit log, and interrupted-operation reconciliation. Never overwrite a recreated original path during recovery.
- Cancellation stops before the next safe operation; already completed moves remain in Trash and are recorded.

### 5. Already-Uninstalled Application Leftovers

- Reuse the installed-application inventory and exact ownership resolver from uninstall. Scan supported user-level cache, log, preference, container, and support roots without descending into unrelated personal content.
- A valid installed copy suppresses the corresponding leftover candidate. No search result is not proof of global absence: present eligible items as suspected leftovers with their attribution evidence and searched scope.
- Default all leftover selections to off, with personal data separated from regenerable caches.
- Incomplete inventory, shared ownership, conflicting metadata, or an unavailable required probe makes associated leftovers review-only. Do not label an empty/failed probe as "application uninstalled."
- Recheck installed-application evidence immediately before deletion. Reinstallation or newly discovered copies invalidate the affected operation group.
- Apply exactly the same whitelist, sensitive-data, directory-content, identity, and Trash protections used by other cleanup workflows.

### 6. Large Files and Disk Usage

- Add a Space Analysis destination to the Disk Clean workspace.
- Use the existing `mactools://app/settings/plugins/...` navigation pattern to open `com.mactools.plugin.storage-explorer`. Follow the existing Mac Settings provider-navigation pattern for unavailable plugins, including marketplace detail fallback.
- Do not automatically install or enable the other plugin. Do not add cross-plugin scan-result synchronization or change Storage Explorer's deletion policy.

## Architecture and Interaction

### Workspace

Keep `disk-clean` as the plugin ID and preserve existing menu-bar row/action IDs. Use a native workspace with six destinations: caches/logs, installers, developer artifacts, uninstall, leftovers, and space analysis. Whitelist, removal-mode settings, and history remain common secondary destinations.

Each workflow owns its scan and review state. Do not add a cross-workflow "delete all" button. Keep menu-bar scan/review behavior aligned with its current cache-cleanup scope; open the full workspace for uninstall and other expanded workflows.

Reuse host-owned page headers, permission cards, navigation, `PluginSettingsTheme`, and existing settings typography. Use concise Chinese user-facing copy and localized resources. Start protected scans only after an explicit user action, not from `panelItems` getters or page construction.

### Internal Services and Types

- Add plugin-internal installed-application inventory, ownership resolution, project-protection, and grouped-uninstall coordination services behind injectable protocols.
- Extend internal scan scopes, candidate facts, validated-plan evidence, and audit records with application identity, ownership evidence, data class, and operation-group association where needed.
- Feed new discovery results into the existing scan/safety/sizing/selection/planning pipeline. Coordinate uninstall ordering above the existing validated per-path removal primitives; do not add unrestricted filesystem deletion beside them.
- Serialize all Disk Clean mutations across sections and startup reconciliation. Do not allow overlapping operation groups to mutate the same path.
- Keep expensive filesystem, process, archive, and application inventory work off the main actor. Bound workers, retained results, probe lifetimes, and notifications; reuse the existing filesystem reader and subprocess runner.
- Observe relevant application launch/termination, installation-directory changes, and permission/configuration changes. Invalidate affected results, debounce repeated events, and perform fresh execution checks. Plugin deactivation cancels work and removes observers; reject late callbacks.
- Do not add a public PluginKit API, change an existing public stored layout, or introduce direct dependencies between plugin implementations. Use existing host navigation for Space Analysis.

### Safety and Compatibility

- Preserve the current five-minute result expiry, whitelist matching across logical aliases, reserved-root checks, no-follow path handling, supported-volume restrictions, and filesystem identity checks. Expiry is not a substitute for execution-time validation.
- Validate protected descendants before deleting directory candidates. An application-support parent cannot be selected to bypass protection of credentials, shared data, or browser identity files beneath it.
- Preserve old whitelist entries, project scan roots, removal-mode preferences, and history. New persisted fields use optional decoding and explicit defaults; old records remain readable.
- Treat moved-to-Trash bytes as estimated processed size, not immediately reclaimed free space. Distinguish successful, skipped, failed, cancelled, and partial outcomes.
- Keep sensitive contents out of diagnostics. Retain current bounded audit rotation and record path-level action outcomes without reading user document or credential contents into logs.

## Implementation Sequence

- [ ] **1. Record upstream evidence and extend internal contracts.** Review Mole at a recorded commit; document adopted/excluded behavior, ownership rules, operation grouping, and migration defaults. Add inventory and safety seams without changing public PluginKit interfaces.
- [ ] **2. Strengthen project protection and existing cleanup.** Implement protected-content and activity checks, expand the explicit project matrix, audit cache rules, and extend installer roots and ZIP/MPKG identification.
- [ ] **3. Implement native application uninstall.** Build discovery, association review, personal-data choices, multiple-copy protection, ordered Trash execution, cancellation, and partial-result reporting. Verify this flow against Mole's uninstall implementation as well as MacTools safety contracts.
- [ ] **4. Implement suspected-leftover review.** Reuse inventory/ownership services, preserve uncertainty, add reinstallation checks, and connect selected paths to the validated cleanup pipeline.
- [ ] **5. Complete workspace integration.** Add the six destinations, shared settings/history access, permission and stale-result states, menu-bar consistency, and Storage Explorer navigation/fallback.
- [ ] **6. Validate and prepare the complete delivery.** Finish localization, focused tests, native review, plugin metadata, documentation, notices where required, and final compatibility checks. Do not publish individual incomplete milestones.

Update the source plugin manifest and related-plugin metadata for the expanded capabilities. Regenerate site metadata through its generator instead of editing generated JSON by hand. Maintain the durable plugin guide and `CONTRIBUTING.md`; add concise English plugin changelog fragments and a separate host fragment only if a user-visible host change actually requires one. Keep each changelog entry within repository limits.

## Validation and Acceptance

### Automated Behavior Coverage

Use adjacent Disk Clean tests and add focused suites for new inventory, ownership, protection, and uninstall behavior. Use temporary directories, synthetic `.app` bundles, fake application inventories, and fake process/archive probes; never delete real applications or user data.

| Area | Required scenarios |
| --- | --- |
| Existing cleanup | Preview/select/execute still works; running/unknown application state, denied permission, unknown sizes, and partial scans cannot authorize deletion. |
| Installers | Supported formats, ordinary ZIP versus installer ZIP, corrupt/encrypted/unreadable archive, recent files, duplicate roots, MPKG bundle handling, and replaced targets. |
| Projects | Each distinct project-marker family, unrelated same-name directory, tracked content, nested repository, deployment keys, recent/unknown activity, and changed execution-time evidence. |
| Uninstall | Individual and batch removal, default personal-data retention, explicit per-path data choice, multi-copy sharing, system/self protection, active processes, permissions, bundle failure, data failure, cancellation, and interrupted staging. |
| Leftovers | Existing valid copy, no installed evidence, incomplete inventory, conflicting/shared ownership, reinstallation, and protected descendants. |
| Integration | Result invalidation, serialized writes across sections, old preferences/history decoding, and installed/unavailable Storage Explorer navigation. |

Retain existing meaningful deletion-boundary tests rather than duplicating all outcomes in every discovery suite. Do not add fixed wording, spacing, icon, or test-count assertions.

Run the smallest affected classes first with `make test TEST_FILTER='<RelatedTestClasses>'`. Run `make script-tests` and `make validate-changelog`; finish with `make ci` because the work changes shared execution behavior and integration. Use `make generate` after project configuration changes and `make build-plugin PLUGIN=DiskClean` to verify packaging/build integration. If adaptation adds distribution notices, include the repository's notice-generation and licensing checks.

### Native Review

- Walk all six destinations in a test account; use disposable fixtures for destructive operations.
- Verify preview, explicit confirmation, Trash recovery, batch uninstall, partial failure, and history.
- Verify operation without Full Disk Access: readable locations remain usable, denied locations are explained, and no admin flow appears.
- Check light/dark appearance, keyboard navigation, long names and paths, resizing, loading/error/empty states, and cancellation.
- Check Storage Explorer navigation when available and marketplace fallback when unavailable.
- Compare representative scans using the same build configuration; record workload, first useful results, total duration, retained memory, and idle behavior. Confirm no long main-thread stalls, overlapping collectors, or work retained after deactivation; do not invent universal speed thresholds.

### Release Acceptance

All six user workflows must be complete before handoff. Personal data is retained unless explicitly and safely selected, protected/shared data cannot be selected indirectly, and permission or discovery uncertainty cannot silently authorize removal. Results must distinguish partial completion from success, existing settings and history must remain usable, and the implementation must document how Mole informed both cleanup and application uninstall.
