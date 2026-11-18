# Network Speed Row Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only status-panel row between the network and VPN rows showing live upload and download throughput.

**Architecture:** A `sysctl` counter reader plus pure rate math, an injectable reader, and a demand-gated `@MainActor` sampler owned by the panel view model. A pure mapper turns each reading into a localized row state.

**Tech Stack:** Swift 6 / SwiftPM, Darwin `sysctl(NET_RT_IFLIST2)`, Combine, SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-18-network-speed-design.md`

## Global Constraints

- macOS 13+, Swift 6 strict concurrency, no `isolated deinit`, no actor-isolated method as a function value.
- Unprivileged reads only; no Helper, entitlement, or permission changes.
- No logging, telemetry, persistence, or background sampling.
- All new strings in the 12 `*.lproj` files; `LocalizationParityTests` must stay green.
- Never weaken a test to go green.
- `bash scripts/verify-local.sh full` is the delivery gate; focused filters while iterating.

## Review Focus

- VPN active (`utun*` carrying everything): the rate must match what leaves the physical interface, never roughly double it.
- Interface disappears or its counters reset (Wi-Fi off, cable pulled): no negative or huge spike; the row recovers on the next sample.
- Panel closed or section hidden: zero further reads, immediately.
- No network at all: `↑ — · ↓ —`, not `0 B/s` pretending to be a measurement.
- First second after enabling: placeholders, then real rates.

---

### Task 1: Counter reader and rate math

**Files:**
- Create: `Sources/StatusTrioCore/Monitoring/NetworkThroughputMonitor.swift`
- Test: `Tests/StatusTrioCoreTests/NetworkThroughputMathTests.swift`

**Interfaces:**
- Produces:
  - `struct NetworkByteCounters: Equatable, Sendable { let receivedBytes: UInt64; let sentBytes: UInt64 }`
  - `struct NetworkThroughputReading: Equatable, Sendable { let receivedBytes: UInt64?; let sentBytes: UInt64? }`
  - `enum NetworkThroughputMath { static func bytesPerSecond(current:previous:elapsed:) -> Double? }`
  - `struct LiveNetworkCounterReader: Sendable { func read() -> NetworkByteCounters? }`

- [ ] **Step 1: Write the failing tests**

```swift
final class NetworkThroughputMathTests: XCTestCase {
    func testRateUsesTheElapsedTime() {
        XCTAssertEqual(
            NetworkThroughputMath.bytesPerSecond(
                current: NetworkByteCounters(receivedBytes: 2_000_000, sentBytes: 1_000_000),
                previous: NetworkByteCounters(receivedBytes: 1_000_000, sentBytes: 500_000),
                elapsed: 2
            ),
            500_000,
            accuracy: 0.001
        )
    }

    func testCounterResetYieldsNoRate() { /* current < previous on either side */ }

    func testZeroElapsedYieldsNoRate() { /* elapsed <= 0 */ }

    func testLiveReaderReturnsCounters() { /* read() non-nil; both >= 0 */ }
}
```

`bytesPerSecond` returns the **received** rate; the sent rate is a second call with swapped
arguments — keep one pure function and let the monitor call it twice.

- [ ] **Step 2: Run to see it fail** — `bash scripts/test.sh 'NetworkThroughputMathTests'` → cannot find `NetworkThroughputMath`.

- [ ] **Step 3: Implement**

- `NetworkThroughputReading` keeps both rates as `Double?` for the mapper.
- `LiveNetworkCounterReader.read()`: `sysctl([CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0])` into a `[UInt8]` buffer; walk `if_msghdr2` messages with `ifm_msglen`; take `if_indextoname(ifm_index)`; sum `ifm_data.ifi_ibytes` and `ifm_data.ifi_obytes` over interfaces whose name starts with `en` or `pdp_ip` and whose `ifm_flags` has `IFF_UP`. Return `nil` when `sysctl` fails or the buffer holds no eligible interface.
- Add `case .networkSpeed: EmptyView()` to `StatusPopoverView.popupSection(_:)` so the module compiles before Task 4.

- [ ] **Step 4: Run to see it pass** — same filter, green.

- [ ] **Step 5: Commit** — `feat(panel): read physical network counters`

### Task 2: Demand-gated sampler

**Files:**
- Modify: `Sources/StatusTrioCore/Monitoring/NetworkThroughputMonitor.swift`
- Test: `Tests/StatusTrioCoreTests/NetworkThroughputMonitorTests.swift`

**Interfaces:**
- Produces: `@MainActor final class NetworkThroughputMonitor: ObservableObject` with
  `init(reader: @escaping @Sendable () -> NetworkByteCounters?, uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, interval: Duration = .seconds(1))`,
  `@Published private(set) var status: NetworkThroughputReading`,
  `func setActive(_ active: Bool)`, `func stop()`, `func sampleNow()`.

- [ ] **Step 1: Write failing tests**: first sample publishes placeholders with `hasReading` false semantics (both rates `nil`); second sample publishes rates from the delta; counter reset publishes `nil` for that sample; `stop()` cancels sampling (counter stops growing); inactive monitor never reads. Reuse the `Counter`/`@unchecked Sendable` pattern from `SystemResourceMonitorTests`.
- [ ] **Step 2: Run to fail** — filter `NetworkThroughputMonitorTests`.
- [ ] **Step 3: Implement** — same shape as `SystemResourceMonitor`: generation-guarded `Task`, immediate first sample, `stop()` cancels and resets to the empty reading so a reopen cannot show a stale rate.
- [ ] **Step 4: Run to pass**.
- [ ] **Step 5: Commit** — `feat(panel): sample network throughput on demand`

### Task 3: Localization, state, and mapper

**Files:**
- Create: `Sources/StatusTrioCore/Presentation/Panel/NetworkSpeedPanelState.swift`
- Create: `Sources/StatusTrioCore/Presentation/Panel/NetworkSpeedPanelMapper.swift`
- Modify: `Sources/StatusTrioCore/Localization/LocalizationKey.swift`
- Modify: all 12 `Sources/StatusTrioCore/Resources/*.lproj/Localizable.strings`
- Test: `Tests/StatusTrioCoreTests/NetworkSpeedPanelMapperTests.swift`

**Interfaces:**
- Consumes: `NetworkThroughputReading`, `Localization`.
- Produces: `struct NetworkSpeedPanelState: Equatable, Sendable { let title: String; let subtitle: String; let accessibilityValue: String; static func empty(localization:) }` and `@MainActor enum NetworkSpeedPanelMapper { static func map(_ reading: NetworkThroughputReading?, localization:) }`.

- [ ] **Step 1: Write failing tests** — placeholders `↑ — · ↓ —`; formatted `↑ 1.2 MB/s · ↓ 8.4 MB/s` for 1_200 and 8_400 bytes/s; accessibility `Up 1.2 MB/s, down 8.4 MB/s`; a nil half keeps its dash while the other formats; `empty` equals `map(nil)`.
- [ ] **Step 2: Run to fail** — filter `NetworkSpeedPanelMapperTests`.
- [ ] **Step 3: Implement** keys and copy:

| key | en |
| --- | --- |
| `settings.popup.order.networkSpeed` | `Network Speed` |
| `networkSpeed.title` | `Network Speed` |
| `networkSpeed.accessibility` | `Up %@, down %@` |

Rates: `ByteCountFormatStyle(.decimal)` on the per-second value, then `"/s"` (localize the
suffix only if a language needs it). Arrows stay literal.
- [ ] **Step 4: Run to pass**, plus `LocalizationParityTests`.
- [ ] **Step 5: Commit** — `feat(panel): present network throughput in 12 languages`

### Task 4: Row view and panel wiring

**Files:**
- Create: `Sources/StatusTrioCore/UI/NetworkSpeedStatusView.swift`
- Modify: `Sources/StatusTrioCore/UI/StatusPopoverView.swift`
- Modify: `Sources/StatusTrioCore/Presentation/Panel/StatusPanelViewModel.swift`
- Modify: `Tests/StatusTrioCoreTests/StatusPanelViewModelTests.swift` (`makePanel`)
- Test: `Tests/StatusTrioCoreTests/StatusPanelDemandTests.swift`

- [ ] **Step 1: Write failing tests** — enabling the section starts sampling; hiding it stops; `panel.stop()` stops; sampling continues while a detail route is open. Mirror the existing `testSystemResource…` tests with a `NetworkThroughputMonitor` and a `NetworkByteCounters`-returning reader.
- [ ] **Step 2: Run to fail**.
- [ ] **Step 3: Implement** — `NetworkSpeedStatusView` copies `SystemResourceStatusView`'s layout with symbol `arrow.up.arrow.down`; the view model gains `networkSpeed`, a `networkSpeed` demand bit, the subscription, `refreshAll`/release/stop handling, and an init parameter.
- [ ] **Step 4: Run to pass** — `StatusPanelDemandTests`, `StatusPanelViewModelTests`.
- [ ] **Step 5: Commit** — `feat(panel): render the network speed row`

### Task 5: Default order and legacy transfer documents

**Files:**
- Modify: `Sources/StatusTrioCore/Settings/SettingsStore.swift`
- Modify: `Sources/StatusTrioCore/Settings/SettingsPreferenceCatalog.swift`
- Test: `Tests/StatusTrioCoreTests/SettingsStoreTests.swift`, `Tests/StatusTrioCoreTests/SettingsPreferenceCatalogTests.swift`, `Tests/StatusTrioCoreTests/InputSourceSettingsTests.swift`

- [ ] **Step 1: Write failing tests** — default order places `.networkSpeed` between `.network` and `.vpn`; a v1.9.6 eight-section document (missing both new cases) imports with its order preserved and both cases appended; a document missing an older section still warns.
- [ ] **Step 2: Run to fail**.
- [ ] **Step 3: Implement** — append `.networkSpeed` to `PopupSection` (last) and insert it after `.network` in `defaultPopupSectionOrder`; in `completedOrder`, accept a missing set that is any non-empty suffix of `allCases` (drop the one-missing count guard) and append it.
- [ ] **Step 4: Run to pass** — the `Settings` filter.
- [ ] **Step 5: Commit** — `feat(settings): place the network speed row and keep legacy orders importable`

### Task 6: Documentation

- [ ] Add one feature bullet to the 10 translated READMEs.
- [ ] `bash scripts/verify-local.sh docs` → PASS.
- [ ] Commit — `docs: note the network speed row`

### Final

- [ ] `bash scripts/verify-local.sh full` → PASS; record the SHA and any `NOT RUN` runtime items.
- [ ] Rebuild the app, install, relaunch, publish the fork release.
