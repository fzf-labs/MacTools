# Application uninstall remediation

## Outcome

Ordinary third-party applications remain selectable while running or requiring a privileged Trash operation. Uninstall preserves the reviewed selection, requests a graceful exit, refreshes evidence, then executes. A force quit requires a separate explicit user action. Failed paths stay available for review and retry, including associated data after the application bundle has moved.

## Boundaries

- Keep single-application review and one final Trash confirmation.
- Keep path policy, whitelists, credentials, shared ownership, volume boundaries, application-copy checks, and independent execution-time validation.
- Separate size measurement from complete content inspection. Only an installed-app candidate with a complete, identity-bound inspection can proceed with an unknown size. Other cleanup modes retain complete-size requirements.
- Use native Finder Trash operations for application paths, passing ephemeral file-reference URLs bound to the reviewed object. Recheck policy and identity before submission, verify the returned Trash object, and audit each outcome. Native permission cancellation is recoverable; never change directory ownership or permissions to manufacture access.
- Preserve original selection scope through refresh. Replaced objects require new selection. Rechecking must never add new personal-data paths automatically.
- Stop only selected, metadata-verified application services. Shared/system executables and unproven service ownership remain excluded. System authorization is interactive and never stores passwords.
- All filesystem mutation tests use temporary fixtures and injected Trash/service adapters. Never uninstall a real user application during validation.

## Work

1. Add independent application inspection evidence and planner support for unknown sizes.
2. Add identity-bound native Trash delegation and permission recovery.
3. Add graceful/explicit force-quit actions, rechecking, and selection restoration.
4. Add per-path partial-result review and retry after successful bundle removal.
5. Add verified service handling and concise remediation controls.
6. Validate safety boundaries, localized UI, packaging, and the installed Debug app.

## Verification

- The full Disk Clean suite passed 353 tests; repository script checks passed 237 tests. Focused checks cover preserving selection across detail refresh, graceful-quit refusal and explicit force, service attribution and loaded-job boundaries, native file references under pathname replacement, permission cancellation, retrying data after bundle removal, retaining an unavailable app’s detail during refresh, and reporting unprocessed paths when cancellation follows a completed bundle move.
- Native read-only preview confirmed version/build fallback and background size population before app selection, retained detail and personal-data selection after wide and narrow refreshes, and readable light/dark presentation.
- A local arm64 Debug diagnostic on macOS 27.2 measured inventory at 0.60 seconds and shared component discovery at 0.37 seconds. CC Switch discovery appeared at 1.15 seconds and inspection completed at 1.19 seconds; ZCode discovery appeared at 1.74 seconds and inspection completed at 3.69 seconds. Each review reused six size totals from content inspection. These are local observations with the existing filesystem cache, not latency guarantees; disposable preview copies were present in the inventory during measurement.
- Debug app/plugin delivery uses `make run PLUGIN=DiskClean`. No real user application, service, or data was removed during validation. Actual administrator dialogs and installed-app post-delivery UI require an unlocked desktop.
