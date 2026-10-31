# Application Uninstall: Final Functional Specification

Date: 2026-10-30
Status: Implemented for the supported ordinary-application scope. Verification and deliberate review-only boundaries are recorded below.
Plugin: `Plugins/DiskClean`

This specification supersedes the application-uninstall discovery, association, and presentation details in the [core expansion plan](../plans/2026-10-29-disk-clean-core-expansion.md). Existing Trash-only execution, personal-data defaults, and filesystem safety boundaries remain requirements.

## Product outcome

Opening Application Uninstall lists installed applications automatically. Inspecting an application analyzes its related files and presents five familiar categories: application files, support files, caches, preferences, and sandbox files. Users do not need to select scan folders before using the feature.

Coverage means examining documented locations and supported ownership evidence, with visible gaps. It does not mean proving that an application has no files anywhere on the computer.

## Mole research baseline

The inspected open-source CLI revision is [08c229bc5935610f81e43a33fc9a3d6dda72139e](https://github.com/tw93/Mole/tree/08c229bc5935610f81e43a33fc9a3d6dda72139e), retrieved on 2026-10-30. The separate native Mole application and its advertised rule coverage are not evidence for this repository's capabilities. Upstream scripts were inspected, not executed against user data.

| Source | Verified behavior | MacTools decision |
| --- | --- | --- |
| [`bin/uninstall.sh`](https://github.com/tw93/Mole/blob/08c229bc5935610f81e43a33fc9a3d6dda72139e/bin/uninstall.sh) | Discovers application directories, including additional supported locations; maintains application metadata and refreshes size information. | Automatically load inventory, supplement standard roots with system discovery, and defer related-file analysis until an app is inspected or selected. |
| [`lib/core/app_protection.sh`](https://github.com/tw93/Mole/blob/08c229bc5935610f81e43a33fc9a3d6dda72139e/lib/core/app_protection.sh) | Combines Bundle IDs, application-name variants, product rules, ByHost preferences, web storage, derived extension paths, UUID container metadata, and system-file discovery. | Expand discovery coverage. Name variants and identifier prefixes create candidates, not deletion authority. Validate metadata and exclusive ownership separately. |
| [`lib/uninstall/review.sh`](https://github.com/tw93/Mole/blob/08c229bc5935610f81e43a33fc9a3d6dda72139e/lib/uninstall/review.sh) | Separates disposable leftovers from personal data; personal data is normally retained. Special caches can contain personal data. | Preserve personal data by default and classify by content/rule semantics rather than directory name alone. |
| [`lib/uninstall/batch.sh`](https://github.com/tw93/Mole/blob/08c229bc5935610f81e43a33fc9a3d6dda72139e/lib/uninstall/batch.sh) | Reviews batches, guards surviving installations, handles background components, and reports retained paths and partial outcomes. | Reuse batch review and fresh ownership/copy checks. Background components remain visible manual-action items. |
| [`lib/uninstall/brew.sh`](https://github.com/tw93/Mole/blob/08c229bc5935610f81e43a33fc9a3d6dda72139e/lib/uninstall/brew.sh) | Detects Homebrew ownership and provides a cask uninstall path that can use `--zap`. | Detect and label package-manager installations; allow reviewed application bundles and selected data to move to Trash while retaining package-manager records. Do not run an unreviewed zap script. |
| [`docs/SECURITY_DESIGN.md`](https://github.com/tw93/Mole/blob/08c229bc5935610f81e43a33fc9a3d6dda72139e/docs/SECURITY_DESIGN.md) | Uninstall defaults to Trash; an explicit permanent-delete mode is also available. | Keep application uninstall Trash-only. |

## User flow

1. Enter Application Uninstall: show the available inventory immediately, then refresh it in the background. Never preselect applications for removal.
2. Search by application name or Bundle ID and sort by name or application size. Keep separate physical copies identifiable by location.
3. Inspect an application: show its five-category review, progressively populate counts and measured sizes, and retain already reviewed selections during sorting and searching.
4. Explicitly select an application for removal: select its bundle and eligible, verified regenerable cache/log paths. Keep settings, support data, sandbox data, and sensitive paths unselected.
5. Allow explicit selection of eligible personal-data paths in the category review. Category selection cannot select protected, shared, ambiguous, or unreadable paths.
6. Confirm once using a native sheet listing applications, selected category totals, and any selected personal data. Present retention or manual-action reasons where they affect the operation.
7. Execute the reviewed plan, then report moved, retained, failed, and cancelled items. Provide Finder/Trash access and history; do not claim that moving to Trash immediately freed disk space.

Inspection and removal selection are distinct: clicking a row opens its details; its checkbox selects it for uninstall. Multi-app selection produces a batch review with independent per-app choices.

## Discovery

- Use `/Applications` and `~/Applications` automatically, including bounded vendor subdirectories. Do not recursively enumerate an entire home directory or disk.
- Supplement discovery with available Launch Services and Spotlight metadata. Validate returned local paths; an unavailable or empty index is not proof that no copy exists.
- Preserve physical identity, Bundle ID, localized display name, icon, version, location, installation source, running state, and measured/unknown application size.
- Do not list nested helpers as independent installed apps. Inspect embedded helpers and extensions separately to derive ownership evidence.
- Additional app locations belong in secondary settings. Configured roots must supplement the standard roots; removing optional locations cannot remove the default inventory roots.
- Invalidate snapshots on application installation, removal, replacement, root changes, and relevant permission changes. Debounce refreshes; never scan synchronously from panel getters.

## Five related-file categories

| Category | Locations and association scope | Selection default |
| --- | --- | --- |
| Application files | Selected `.app` bundle, with embedded helpers/extensions counted inside it. Detect additional installed copies separately. | Selected only after explicit uninstall selection. |
| Support files | Exact application-owned leaves under user `Library/Application Support`; verified vendor/product subdirectories; owned external updater/crash-report support. | Retain. User-created projects, models, downloads, and shared vendor roots are excluded from automatic selection. |
| Caches | Owned leaves under user `Library/Caches`, logs, the current user’s Darwin cache directory, NSURLSession downloads, and verified updater/crash-cache locations. | Select verified regenerable paths after app selection; retain offline content and other personal-data exceptions. |
| Preferences | Exact preference files/directories, bounded ByHost variants, saved application state, and supported synchronized preference files. | Retain. |
| Sandbox files | Main app and verified extension containers, metadata-attributed UUID containers, Application Scripts, App Groups, and owned WebKit/HTTPStorage/Cookie paths. | Retain. Shared containers and credential-bearing identity data remain protected. |

Web storage is displayed with sandbox/web data even for nonsandboxed applications. The category is a presentation choice, not evidence that the data is disposable. Container contents are not duplicated under other categories when the whole container is already represented.

Verified app-owned LaunchAgents, LaunchDaemons, declared signed helpers, and exact system-level data leaves may be selected explicitly. Unproven or shared services and system extensions remain in the manual-action area and are excluded from selectable totals. Loaded-job configuration and program paths are checked before stopping a selected service.

## Ownership and coverage

- Build an application identity graph from the main Bundle ID, embedded signed component identities, signature Team ID, container metadata, explicit App Group declarations, and reviewed product rules.
- Confirm exact main-app ownership from the installed bundle independently of unrelated component-scan failures. Known conflicting owners still block removal. Same-team signed components in the main app namespace carry explicit private ownership evidence; other components and suspected leftovers require a complete claim check. Exact executable names may attribute bounded force-quit timestamp records only when their path, UUID, contents, and absence of other executable-name claimants are verified. Preserve this distinction during execution.
- Do not treat a shared Team ID or a Bundle-ID prefix as sufficient proof of exclusive ownership. Extension IDs must be derived from actual application components.
- Product rules identify exact leaves by Bundle ID and declare personal-data and review-only semantics. Channel-specific paths remain separate; uncertain historical or shared paths never authorize removal. Version/name stripping is candidate discovery only, not version-specific ownership evidence. Never delete an entire Tencent, Microsoft, Adobe, Google, or other vendor root on a name match.
- App-name variants, old product names, and vendor nesting can discover candidates. Candidates without sufficient ownership evidence are review-only.
- App Groups require checking other installed claimants. Shared, unknown, or incompletely checked ownership remains protected even when the selected app declares the group.
- Count a physical path once across categories and applications. Parent/child overlap must not inflate sizes or generate duplicate operations.
- Show one of: analyzing, checked with results, checked with no results, permission required, incomplete, or unsupported. A failed read never becomes a zero-item result.
- Attempt allowed reads first. When a required location is inaccessible, explain the affected category and offer Full Disk Access guidance, then rescan after authorization. Do not require permission before listing ordinary applications.
- Full Disk Access does not establish ownership, grant administrator privileges, or override sensitive-path protection.

## Interface contract

- Keep the existing Disk Clean navigation, colored icons, native controls, and fixed action bar.
- Inside Application Uninstall, use an application list and an adjacent detail area at comfortable widths. At narrow widths, show one app review with a native back action rather than squeezing three sidebars together.
- Put search, sorting, and refresh in the toolbar. Move optional application roots into secondary settings; replace the prominent scan-folder step with automatic discovery.
- Show only nonempty category headers with count, size, and selection state. File groups are expanded by default and remain manually collapsible. Show individual files with name, selection, size, and an info action for path and ownership evidence.
- Keep full paths, technical IDs, and explanations in details unless required to distinguish copies or explain an error. No repeated descriptive paragraphs or duplicate page title.
- Show selected application count and deduplicated selected size in the fixed footer. Unknown or partial sizes remain visibly unknown and cannot silently authorize deletion.
- Preserve native List keyboard navigation, search focus, accessibility labels, selection visibility, system accent color, light/dark appearance, increased contrast, and reduced transparency.

## Execution and special installations

- Reuse `DiskCleanSafetyPolicy`, allowlists, no-follow filesystem identity checks, protected-content checks, staging reconciliation, and the serial executor.
- Freeze exactly the paths and ownership evidence shown in the review. Newly found files require a new review; do not add them during execution.
- Recheck copies, processes, permissions, ownership, and filesystem identities before writes. If a selected app is running, ask the user to quit it and refresh; do not silently terminate it.
- Move the selected application bundle first. Remove selected associated data only after every selected copy succeeds and no surviving copy or unresolved ownership remains.
- If the bundle move fails, retain its associated data. Report failures after a successful bundle move as partial completion. Cancellation stops at the next safe boundary.
- Installation-source labels and installer declarations do not block moving a verified third-party application bundle to Trash. Retain and disclose Homebrew installation records, external system services, and privileged helpers that the selected-path Trash operation does not handle; do not claim that those components were removed.
- No administrator helper, forced process termination, service unload, package-receipt deletion, arbitrary vendor scripts, or permanent-delete mode is added in this scope.
- Suspected Leftovers reuses the same identity graph and category resolver, remains separate from installed-app uninstall, and rechecks for reinstallation immediately before removal.

## Implementation order and acceptance

1. Automatic inventory and lifecycle: remove the folder prerequisite; preserve standard roots; separate inventory from bounded, cancellable on-demand association analysis.
2. Ownership resolver: implement the five categories, component identities, UUID containers, reviewed product leaves, shared-owner checks, and per-category coverage reporting.
3. Review UI: add category-level inspection, individual personal-data choices, batch review, responsive details, and one final confirmation.
4. Execution integration: retain existing protections, deduplicate selected paths, support partial results, and integrate the resolver with suspected leftovers.

Completion requires these user outcomes:

- A normal app appears on opening the page without selecting a folder or manually starting inventory discovery.
- A representative ordinary app with all five types of fixtures shows the corresponding paths in all five categories. Real-app read-only comparisons cover a sandboxed app, an Electron app, and a vendor-nested support directory; differences from a reference tool are investigated rather than blindly copied.
- Duplicate installations and shared vendor/App Group data remain protected; extension and UUID-container fixtures are attributed using metadata rather than name guessing.
- Missing permissions and incomplete inspections are visible per category. Personal data remains unselected after inspecting, searching, sorting, or selecting applications.
- Whitelisted or sensitive descendants, path replacement, symlink aliases, active processes, reinstallations, failed bundle moves, interrupted operations, and partial batches cannot cause unreviewed data removal.
- Automated mutation checks use temporary fixtures and fake Trash stores. Native visual verification covers light/dark and narrow layouts with keyboard navigation.

The existing implementation's prior build/test success is evidence for that baseline only. It is not acceptance evidence for these new capabilities.

## Implementation and verification record

- Automatic inventory preserves the standard roots, supplements them with system discovery, and refreshes after application changes. Related files and suspected leftovers are analyzed on demand rather than scanning every app’s data on page entry.
- Five category reviews, batch selection, explicit personal-data choices, the final confirmation sheet, responsive detail navigation, permission coverage, partial measurements, and result history are implemented in Disk Clean.
- The resolver includes ByHost preferences, signed embedded component identities, UUID container metadata, web storage, application-name aliases, vendor-nested candidates, exact product leaves, and current-user Darwin caches. Logical aliases survive physical normalization so existing whitelist checks remain effective.
- Shared runtime identities, App Groups, name-only candidates, services, and uncertain claims remain review-only. Ownership and container metadata are checked again at execution; newly installed owners and derived cache names cannot silently become removable leftovers.
- The broad Disk Clean suite passed before the final cache refinements; the focused ownership, model, inventory, scan-engine, planner, and executor suites passed after those refinements. Script validation passed 237 tests. Final delivery also checks the plugin’s permission contract and signed development build.
- Native fixture verification covered automatic listing, on-demand analysis, five categories, cache-only defaults, confirmation cancellation, light/dark appearance, and compact detail navigation. Its executor rejected all writes. Real staging outcomes remain covered using temporary directories and fake Trash stores.

### Read-only comparison with Lemon

| Sample | Findings and deliberate differences |
| --- | --- |
| Cursor (Electron) | Found the support directory, preferences, updater cache, and signed helper cache. Comparison exposed the Darwin user-cache location, which was added with exact component ownership. Shared Electron runtime cache stays protected. CrashReporter name matches remain review-only. |
| WeChat (sandboxed) | Found the application and user-cache locations. The development host lacked Full Disk Access and explicitly reported sandbox coverage as unavailable, while Lemon could display its containers. Positive container attribution is verified with main/extension IDs and metadata-owned UUID fixtures; no permission was granted automatically. |
| Chrome (vendor-nested data) | Found the curated `Google/Chrome` support and cache leaves and verified helper identities. Browser identity data and the shared Google updater stay protected. Chrome for Testing and unverified name-derived records displayed by the reference tool are not assigned to ordinary Chrome solely by their prefix. |

The comparison checks locations and attribution, not byte-for-byte totals. Indexed sizes, allocated sizes, live application activity, and the reference tool’s broader candidate matching can produce different totals. No real application or personal data was removed during this verification, and no release was published.

## P0 coverage refinement

The common-app registry replaces the original support-directory dictionary with structured exact leaves, aliases, categories, and personal/review-only semantics. Hidden directory candidates and additional separator/channel/version name variants expand read-only discovery. Generic and curated records retain fresh ownership, content, path-identity, whitelist, and Trash-only validation. Shared, historical, and name-only paths remain protected.

The per-app Scan Coverage sheet reports each probed location and its discovery source, with separate found, absent, permission-required, and incomplete states. It also reports whether a product profile exists and whether identity/other-owner checks completed. The report is on demand to keep the main review compact. It does not assert coverage of arbitrary user-selected storage, other users, disconnected volumes, cloud data, or privileged services.

The remediation update adds graceful and explicit force quitting, verified service stopping, native authorized Trash, independent size/safety evidence, and retry of unfinished paths after bundle removal. Package-receipt removal, vendor uninstall scripts, system-extension management, and post-uninstall residual discovery remain separate product work.


P0 verification: 331 Disk Clean tests and 237 script tests passed, including temporary-fixture rule isolation and coverage-state checks. Native read-only validation covered light/dark appearance, compact navigation, search, the incomplete-only filter, empty results, and Escape dismissal. A signed development build was synchronized to MacTools Dev; a real Cursor review showed the curated updater cache and explicit sandbox/ownership gaps. No real user application or data was removed.


### Explicit application session-data choice

On 2026-10-30 the user approved moving an app's own login/session data to Trash when its personal data is explicitly selected. This refines the earlier blanket browser-state protection for application uninstall only. The scoped exception covers exclusively attributed support/web-storage/container leaves and ordinary cookie/session state. Personal data remains off by default; ordinary cache cleanup, suspected leftovers, shared groups, whitelists, system keychains, key material, saved-password databases, and unknown ownership retain their protections. Frozen scope evidence, app-first ordering, fresh ownership/content checks, and Trash-only execution remain required.


Verification of this refinement: 339 Disk Clean tests and 237 script tests passed. Temporary fixtures covered explicit personal selection, scoped session removal, fresh sensitive-file retention, private/shared helpers, executable-name collisions, and whitelist boundaries. Native ZCode review confirmed its support folder is selectable after the application is selected, remains off by default, and clears its selection when the application is deselected. The signed development app and plugin were rebuilt and synchronized; no real application or data was removed.


## Single-application interaction revision (2026-10-30)

This revision supersedes the earlier batch-selection and optional-root interaction. Uninstall operates on the currently inspected application only. The app list has no batch checkboxes; choosing another app, returning to the list, or searching clears the previous selection. Cached and in-flight analyses cannot restore selections from a different app. The model and execution entry point enforce the single-owner boundary.

Name/size sorting is visible directly in the toolbar. Application discovery is automatic; uninstall has no scan-folder control. Empty categories remain hidden, populated groups open expanded, and personal data remains off by default. Selecting a related data file automatically includes the required application bundle, avoiding a separate unlock step.

Ordinary name-matched paths become explicit review candidates for an installed app. They are selectable but never recommended or automatically selected. The final sheet lists selected name candidates for ownership confirmation. Frozen paths, narrow discovery roots, fresh name/identifier claims, sensitive-path checks, whitelists, no-follow inspection, and Trash-only execution remain required. Known shared product paths, services, protected data, unreadable locations, and uncertain leftovers remain excluded rather than becoming force-delete actions.


Verification of the single-application revision: the Disk Clean suite passed 341 tests, followed by three focused model tests for final size-cache and cached-leftover refinements. The script suite passed 237 tests. Read-only native checks covered direct name/size sorting, retained measured sizes, single-app switching, manual name-candidate selection, single-app confirmation/cancellation, cleared selections on back navigation, and light/dark compact layouts. The final signed development app and Disk Clean package were rebuilt, synchronized, and opened on the uninstall page. No real application or data was removed.
