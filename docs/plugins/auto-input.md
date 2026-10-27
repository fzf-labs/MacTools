# Auto Input

Auto Input switches input sources using available website rules, application rules,
remembered application choices, and the optional default input source, in that order.
An unavailable input source is skipped. A failed system switch reports an error
instead of trying a different input source.

## Website rules

Open Auto Input settings and add a website rule. Select a supported browser or all
supported browsers, a match type, a pattern, and an input source. Rules are evaluated
from top to bottom; the first enabled matching rule with an available input source
wins. Move more specific rules above broader rules.

- **Domain and subdomains:** `example.com` matches both `example.com` and
  `work.example.com`, but not `notexample.com`.
- **Exact domain:** `example.com` matches only that host.
- **URL regular expression:** `^https://example\.com/work/` matches a page URL.
  Expressions are case insensitive and limited to 512 characters. Matching has a
  progress deadline, and page URLs longer than 8,192 UTF-16 code units are ignored.

Website rules require Accessibility permission. Without it, ordinary application
rules, memory, and the default input source continue to work. Editing the address
bar suspends website matching; uncommitted address text is never treated as a
visited page. Browser internal pages and non-HTTP(S) URLs do not match.

The plugin reads the foreground browser's focused window through native
Accessibility APIs. It observes focus, window, title, and web-area changes, with a
two-second fallback while a supported browser with applicable rules is active.
Remote Accessibility reads run on a dedicated worker with bounded traversal and
messaging timeouts. Switching applications, disabling automatic switching, or
deactivating the plugin stops browser observation and rejects retired callbacks.

Safari, Chrome, Chromium, Edge, Brave, Firefox and compatible browsers are listed
in the browser selector. Availability depends on the browser exposing its current
page through Accessibility; no browser extension or Automation permission is used.
If a browser does not expose its page URL, application-level behavior remains
available. Split-view and browser-sidebar layouts need browser-specific manual
verification.

Website-forced input sources do not overwrite application memory. Leaving a
matching website restores the applicable application rule, memory, or default;
when none exists, it restores the input source used before the website override.
Changing the default does not erase remembered application choices.

## Privacy

Page URLs are processed locally in memory. The plugin does not save browsing
history, log visited URLs, contact websites, or send URLs to a service. Only rules
explicitly entered by the user are persisted. URL rules can themselves contain
private information, so review them before sharing settings.

## Implementation reference

The [Input Source Pro browser reader](https://github.com/runjuu/InputSourcePro/blob/main/Input%20Source%20Pro/Utilities/BrowserURL.swift)
and [application observer](https://github.com/runjuu/InputSourcePro/blob/main/Input%20Source%20Pro/Models/ApplicationVM.swift)
were reviewed as technical references. MacTools implements its own native reader
and integrates it with the existing plugin lifecycle, permission checks, and
application-memory rules; no upstream dependency or implementation is bundled.

## Verification

Run focused `AutoInputWebsiteRuleTests`, `AutoInputStoreTests`, and
`AutoInputControllerTests`. On an active desktop, verify Safari and Chrome with
two tabs using different rules, navigation within one tab, address-bar composition,
window switching, leaving a matched website, permission denial/revocation, and
plugin deactivation. Confirm the HUD can remain disabled while website switching
works, and that typing in another application's window is unaffected.
