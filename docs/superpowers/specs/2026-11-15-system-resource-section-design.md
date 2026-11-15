# CPU and memory readings in the status panel

A read-only status-panel summary section that reports whole-machine CPU usage and
physical-memory usage while the panel is open. One row, same shape as the battery,
network, and input-source rows: a symbol, a title, and a subtitle carrying both
readings. No controls, no chevron, no settings toggle of its own beyond the section
checkbox the panel order list already provides.

## Intent

The panel answers "what is the machine doing right now" for power, network, audio,
and displays. CPU and memory are the missing part of that answer. The value is
glanceable occupancy while the panel is open, not monitoring, history, or diagnosis.

Chosen by the user: the panel summary row (option A), not a gauge variant and not a
detail page. Menu-bar display is explicitly out of scope.

## Goals

- Show CPU usage and used/total physical memory in one summary row, live while the
  panel is open.
- Sample only while the popover is open **and** the section is enabled. Closing the
  panel or hiding the section stops the sampler synchronously. Detail routes keep
  the sampler running: the panel is still on screen, the row returns on
  `showSummaryPage()`, and route transitions would otherwise need their own demand
  reconcile.
- Report honest values: before the first successful read, both halves show an em
  dash instead of a fabricated `0%` or `0 bytes`.
- Ship in all 12 existing languages with the same layout budget as the other rows.

## Non-goals

- Menu-bar or Dock text/icon display; the icon scene, renderer, parity tests, and
  cache keys are untouched.
- Per-application ranking or a detail page (the existing `ApplicationEnergyReader`
  already supports a later phase).
- History, graphs, sparklines, per-core CPU, swap, memory pressure, or thermal state.
- Notifications, background monitoring while the panel is closed, persistence of
  readings, telemetry, or logging.

## Anti-goals

- A draggable-looking gauge: the panel's volume/brightness capsules are interactive
  AppKit sliders, and a read-only mimic would invite drag attempts.
- A new stored preference. Section enablement and order already exist; adding a
  second switch for the same row would be redundant state.
- Wall-clock polling with no owner: the `AGENTS.md` low-power invariant requires the
  sampler to have both an owner and a stop path.

## Decisions

**Placement.** `PopupSection.systemResource` (already added) sorts last in
`SettingsStore.defaultPopupSectionOrder` and joins `sanitizedPopupSectionOrder`'s
append path, so existing stored orders gain it at the end without rewriting the
user's list. It is **off by default**, like the VPN and Bluetooth rows: a fresh
install shows nothing new until the row is checked under Settings › Status Panel ›
Order.

**Sampling.** 2-second cadence. Demand is `store.isPopoverVisible &&
settings.enabledPopupSections.contains(.systemResource)`, reconciled by
`StatusPanelViewModel.reconcileSourceSubscriptions` the same way the VPN tunnel is
activated and deactivated. `SystemStatusStore.stop()` stops the sampler too. A
repeating `Task` owns the timer; `stop()` cancels it and bumps a generation so a
late tick cannot publish after teardown.

**CPU definition.** Delta of `host_cpu_load_info` ticks between samples:
`(active delta) / (total delta)`, where active is user + system + nice and total adds
idle. Each 32-bit tick counter is widened before subtraction and the delta masked to
32 bits, so a counter wrap between samples cannot produce a bogus reading. Zero total
delta keeps the previous value instead of publishing a placeholder.

**Memory definition.** Used = `(internal − purgeable) + wired + compressed` pages ×
page size, clamped to total; total = `ProcessInfo.physicalMemory`. This tracks
Activity Monitor's "Memory Used" closely enough to compare against it, and the code
comment states the formula so nobody has to guess. Page size comes from
`host_page_size`, never the `vm_kernel_page_size` global: Swift 6 rejects that global
as shared mutable state, which is the current build failure.

**Reading.** One injectable value-type reader returns both readings in a single call,
so tests exercise the arithmetic without mach calls. The published state carries a
`hasReading` flag: until the first successful read, both halves render the placeholder
(`CPU — · Memory —`), never `0%` / `0 bytes`. A later read failure keeps the last known
values instead of republishing zero.

**Settings transfer.** A settings document exported by the shipped v1.9.6 build lists
the 8 sections that existed then, and `popupSectionOrder` import validates with
`requiresFullOrder: true`, which demands every current case. Without a catalog change,
importing an older document would warn, substitute `defaultPopupSectionOrder`, and
silently reorder the user's panel. Decision: relax that one validation path to accept a
document that lists a known, duplicate-free subset of the current cases, then fill the
missing cases at their `defaultPopupSectionOrder` positions (preserving the document's
relative order). A pre-feature fixture test proves the custom order survives. The
reverse direction — a document written by this build imported into v1.9.6 — stays
unsupported; the old build rejects the unknown raw value and falls back to its
defaults, and that limitation is stated next to the catalog code.

**Presentation.** `SystemResourcePanelState` holds localized strings and fractions,
built by a pure mapper like `InputSourcePanelMapper`:

- title: `systemResource.title` ("CPU & Memory")
- subtitle: `CPU 18% · Memory 9.2 GB / 16 GB`, assembled from `systemResource.cpu`,
  `systemResource.memory`, a localized byte formatter (`ByteCountFormatter`,
  `.memory` style, `.file`-free), and the localized percent format
- placeholder: an em dash for both halves until `hasReading` is true, so the row never
  claims `0%` or `0 bytes` as a measurement
- accessibility: one combined element, `systemResource.accessibility`
  ("CPU %@, memory %@ of %@")

New localization keys (12 languages): `systemResource.title`, `systemResource.cpu`,
`systemResource.memory`, `systemResource.accessibility`. The existing
`settings.popup.order.systemResource` title stays for the settings order list.

**Existing partial work.** Keep the `PopupSection` case, `LocalizationKey` entry, and
the 12 `settings.popup.order.systemResource` strings. `SystemResourceMonitor.swift`
is rewritten: its unused `SystemResourceReading`/`SystemResourceReadingProviding`/
`LiveSystemResourceReader` trio, the broken `updates` stream, the stray `Logger`, and
the `self as? SystemResourceMonitor` self-cast all go.

## Approaches considered

1. **A — single read-only row (chosen).** Matches the existing row grammar, adds the
   least height, and cannot be mistaken for a control. Costs the "at a glance" bar
   feel.
2. **B — two thin non-interactive bars.** Stronger visual occupancy read, but it must
   be deliberately stripped of the slider's thumb and hit area, and the panel already
   uses that capsule shape for interaction. Rejected for v1 ambiguity.
3. **C — row plus a details page of top processes.** Real diagnostic value, but it
   needs a new panel route, a ranking surface, and its own localization; roughly
   double the work. Deferred.

## Constraints

- macOS 13+, Swift 6 strict concurrency, no `isolated deinit`, no actor-isolated
  method passed as a function value.
- No Helper, privilege, entitlement, or permission changes: both readings are
  unprivileged mach calls.
- `SettingsPreferenceCatalog` already exports `popupSectionOrder` and
  `enabledPopupSections`; the new raw value must round-trip in this build, and the
  pre-feature document path above needs the one validation change and a fixture test.
- Polling plus a new `@MainActor` lifecycle means the **full** local profile is the
  delivery gate; focused `SystemResource` filters while iterating.
- No visible UI tests; the row renders in ordinary unit-testable state.
- Documentation: the repo has 11 README files (`README.md` plus 10 translations;
  Italian and Arabic have no README). Each gets one feature bullet in its existing
  list. No new translated READMEs are created for this change.

## Verified starting state

Measured on the tree at the time of writing, so the plan does not rediscover it:

- The tree is build-red in two places, not one. `SystemResourceMonitor.swift` uses the
  `vm_kernel_page_size` global, and `StatusPopoverView.popupSection(_:)` has no
  `.systemResource` case, so the enum addition alone already breaks the exhaustive
  switch. Fixing only the global surfaces the second error.
- `SettingsStore.defaultPopupSectionOrder` has 8 cases and no `.systemResource`, and
  `sanitizedPopupSectionOrder` only appends entries that appear in that array. Without
  the edit, the Settings order checkbox never appears and the row can never be enabled.
  `VPNRowSettingsTests.testStoredOrderPicksUpTheRow` asserts the sanitized order names
  every case, so it fails until the array is updated — a ready-made guard, not a new
  test.
- `presentPopover` sets `isPopoverVisible` before `panelViewModel.start()`, and the close
  paths clear it before `panelViewModel.stop()`, so demand evaluated in
  `reconcileSourceSubscriptions` needs no extra visibility subscription.

## Left to the builder

- Exact translated wording of the four new keys per language, matching each file's
  existing tone for "CPU" and "Memory".
- Test file names and fixture shape for the injected reader and the demand wiring.
- Whether the subtitle separator and byte-decimals follow the panel's existing
  `.formatted` conventions or a small shared formatter helper.
