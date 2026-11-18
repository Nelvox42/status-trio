# Network throughput in the status panel

A read-only status-panel row that reports live upload and download throughput while
the panel is open. It sits between the network row and the VPN row, follows the same
row grammar as the CPU and memory row, and has no controls.

## Intent

The panel already answers "am I connected, and how strong is the link". It does not
answer "is anything actually moving". Upload and download rates are the missing half
of that question, and the user asked for them in the panel rather than in the menu bar.

## Goals

- Show `↑ 1.2 MB/s · ↓ 8.4 MB/s` for the machine's physical network interfaces.
- Sample once a second, only while the popover is open **and** the section is enabled;
  closing the panel or hiding the section stops the sampler synchronously.
- Never double-count VPN traffic: the Clash TUN interface (`utun*`) is excluded, while
  the physical interface that carries the encrypted bytes is counted.
- Report an honest placeholder (`↑ — · ↓ —`) until two samples exist, and never show a
  negative or absurd rate after an interface reset.
- Ship in all 12 languages.

## Non-goals

- Menu-bar or Dock rates; the icon renderer is untouched.
- Per-process or per-connection accounting, historical graphs, data caps, or totals.
- Interface-level selection UI.
- Notifications, background sampling, telemetry, or persistence.

## Anti-goals

- Summing `utun*` alongside the physical interface, which would roughly double the
  reported rate whenever a VPN is on.
- A gauge that looks draggable.
- A new stored preference beyond the existing section checkbox.

## Decisions

**Placement.** `PopupSection.networkSpeed`, appended last to the enum (so the settings
transfer legacy rule keeps working) and placed between `.network` and `.vpn` in
`SettingsStore.defaultPopupSectionOrder`. Off by default, like the CPU and memory row.

**Reading.** One `sysctl(NET_RT_IFLIST2)` walk yields 64-bit `ifi_ibytes` and
`ifi_obytes` per interface. Only interfaces whose name starts with `en` or `pdp_ip` are
summed, and only while they carry `IFF_UP`; that covers Wi-Fi, Ethernet, USB and
Thunderbolt adapters, and iPhone USB, while `utun*` (VPN), `awdl*`/`llw*` (AirDrop and
AirPlay) and `lo0` stay out. Documented limitation: two physical links active at once
are summed, because there is no per-service picker in v1.

**Rate.** Bytes delta over monotonic uptime delta (`ProcessInfo.systemUptime`), so a
wall-clock change cannot distort the rate. A negative delta — counter reset, interface
re-plugged — yields `nil` for that sample instead of a nonsense spike; the next sample
recovers. Both rates are published together; the row shows `—` for a nil half.

**Sampling.** 1-second cadence. The panel view model owns the monitor and reconciles it
in `reconcileSourceSubscriptions`, exactly like the CPU and memory row: `start()` on
demand, `stop()` on hide, `stop()` in `StatusPanelViewModel.stop()` and in
`releaseInactivePresentationState`, plus a generation guard so a cancelled tick cannot
publish.

**Presentation.** `NetworkSpeedPanelState` holds localized strings and the two optional
rates, built by a pure mapper:

- title: `networkSpeed.title` ("Network Speed")
- subtitle: `↑ 1.2 MB/s · ↓ 8.4 MB/s`, arrows literal, rates through
  `ByteCountFormatStyle(.decimal)` (network rates are decimal, unlike memory) plus a
  localized `/s`, and `—` for a half that is not available yet
- accessibility: `networkSpeed.accessibility` ("Up %@, down %@") with `—` filling gaps
- symbol: `arrow.up.arrow.down`

New localization keys (12 languages): `settings.popup.order.networkSpeed`,
`networkSpeed.title`, `networkSpeed.accessibility`.

**Settings transfer.** Adding a second new case makes a shipped v1.9.6 document miss
two cases, so `CompletedOrder` stops requiring "at most one missing" and accepts any
non-empty suffix of `PopupSection.allCases` as the set of sections a document may
predate, provided the document still names the eight sections that shipped with
settings transfer. A shorter or middle-gapped order stays a warning.

## Approaches considered

1. **Separate read-only row following the physical interfaces (chosen).** Matches the
   CPU and memory row, keeps the crowded network subtitle untouched, and is honest
   about VPN traffic.
2. **Fold the rates into the network subtitle.** No new row, but that line already
   carries SSID, IP, band and RSSI and would truncate at the panel width.
3. **Menu-bar rates.** Closer to iStat-style tools, but it needs icon-scene work, Menu
   Bar/Dock parity tests, a new preference, and the user already has a menu-bar tool
   showing rates.

## Constraints

- macOS 13+, Swift 6 strict concurrency; `sysctl` is unprivileged, no Helper change.
- Sampling plus a new `@MainActor` lifecycle: the **full** local profile is the gate.
- No visible UI tests.
- README bullet in the 10 translated READMEs (no Italian or Arabic README exists).

## Left to the builder

- Exact translated wording of the three new keys.
- Test file names and the counter fixture shape for `NET_RT_IFLIST2`.
- Whether the rate formatter drops `.0` for whole numbers, matching the panel's style.
