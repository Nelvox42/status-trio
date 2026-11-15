# System Resource Section Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only status-panel row that shows live whole-machine CPU usage and physical-memory usage while the panel is open.

**Architecture:** A pure `SystemResourceMath` value layer over unprivileged mach counters, an injectable reader, and a `@MainActor` sampler that only runs while the popover is visible and the section is enabled. The panel view model maps the sampler's status into a presentation state; a small SwiftUI row renders it.

**Tech Stack:** Swift 6 / SwiftPM, Darwin mach APIs, Combine, SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-15-system-resource-section-design.md`

## Global Constraints

- macOS 13+ deployment; Swift 6 strict concurrency.
- Do not pass actor-isolated methods as function values; use explicit closures.
- Do not use `isolated deinit`; no `weak let`.
- Unprivileged mach reads only: no Helper, entitlement, or permission changes.
- No logging, telemetry, persistence, or background sampling.
- All new user-facing strings ship in the 12 `*.lproj` files; `LocalizationParityTests` must stay green.
- Never weaken a test to go green; a behavior change updates its test deliberately.
- Commit with `git commit` using the messages the tasks specify.

## Review Focus

- Panel opened while a detail route is active: the sampler may run, the row is not drawn, and returning to the summary shows a live reading, never a blank row.
- Section toggled off while the panel is open: sampling stops on the same runloop and the row disappears.
- First frame after enabling and after reopening: `CPU — · Memory —`, never `0%` or `0 bytes`.
- Tick-counter wrap and page-size differences: no negative, NaN, or >100% reading; used memory never exceeds total.
- An older settings-transfer document with a custom order: import keeps the order and appends the new section instead of resetting to defaults.

---

### Task 1: Reading types, math, and live reader (green tree)

**Files:**
- Rewrite: `Sources/StatusTrioCore/Monitoring/SystemResourceMonitor.swift`
- Modify: `Sources/StatusTrioCore/UI/StatusPopoverView.swift:283-289` (placeholder case)
- Test: `Tests/StatusTrioCoreTests/SystemResourceMathTests.swift` (create)

**Interfaces:**
- Produces:
  - `struct CPUUsageTicks: Equatable, Sendable { let user, system, idle, nice: UInt64 }`
  - `struct SystemResourceSample: Equatable, Sendable { let cpuTicks: CPUUsageTicks?; let usedMemoryBytes: UInt64; let totalMemoryBytes: UInt64 }`
  - `struct SystemResourceStatus: Equatable, Sendable { let cpuUsage: Double?; let usedMemoryBytes: UInt64; let totalMemoryBytes: UInt64; let hasReading: Bool }`
  - `enum SystemResourceMath { static func cpuUsage(current:previous:) -> Double?; static func usedMemoryBytes(internalPages:purgeablePages:wiredPages:compressedPages:pageSize:totalBytes:) -> UInt64 }`
  - `protocol SystemResourceReadingProviding: Sendable { func read() -> SystemResourceSample? }`
  - `struct LiveSystemResourceReader: SystemResourceReadingProviding { init() }`

- [ ] **Step 1: Write the failing tests**

```swift
// SystemResourceMathTests.swift
import XCTest
@testable import StatusTrioCore

final class SystemResourceMathTests: XCTestCase {
    func testCPUUsageUsesOnlyTheDelta() {
        let previous = CPUUsageTicks(user: 100, system: 50, idle: 850, nice: 0)
        let current = CPUUsageTicks(user: 150, system: 70, idle: 980, nice: 0)
        // active delta 70 over total delta 150
        XCTAssertEqual(
            SystemResourceMath.cpuUsage(current: current, previous: previous)!,
            70.0 / 150.0,
            accuracy: 0.0001
        )
    }

    func testCPUUsageSurvivesA32BitTickWrap() {
        let previous = CPUUsageTicks(user: UInt64(UInt32.max - 5), system: 0, idle: 0, nice: 0)
        let current = CPUUsageTicks(user: 3, system: 0, idle: 0, nice: 0)
        XCTAssertEqual(
            SystemResourceMath.cpuUsage(current: current, previous: previous)!,
            1.0,
            accuracy: 0.0001
        )
    }

    func testCPUUsageIsNilWithoutAnyTickDelta() {
        let ticks = CPUUsageTicks(user: 10, system: 0, idle: 10, nice: 0)
        XCTAssertNil(SystemResourceMath.cpuUsage(current: ticks, previous: ticks))
    }

    func testUsedMemoryCountsInternalWiredAndCompressed() {
        XCTAssertEqual(
            SystemResourceMath.usedMemoryBytes(
                internalPages: 100, purgeablePages: 10, wiredPages: 20,
                compressedPages: 5, pageSize: 4096, totalBytes: 1_000_000
            ),
            115 * 4096
        )
    }

    func testUsedMemoryNeverExceedsTotal() {
        XCTAssertEqual(
            SystemResourceMath.usedMemoryBytes(
                internalPages: 1_000, purgeablePages: 0, wiredPages: 1_000,
                compressedPages: 1_000, pageSize: 4096, totalBytes: 4096
            ),
            4096
        )
    }

    func testLiveReaderReportsPhysicalTotal() {
        let sample = LiveSystemResourceReader().read()
        XCTAssertNotNil(sample)
        XCTAssertEqual(sample?.totalMemoryBytes, ProcessInfo.processInfo.physicalMemory)
        XCTAssertLessThanOrEqual(sample?.usedMemoryBytes ?? 0, sample?.totalMemoryBytes ?? 0)
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `bash scripts/test.sh 'SystemResourceMathTests'`
Expected: compile failure — `SystemResourceMath` is undefined (the current tree is also red on `vm_kernel_page_size`; this rewrite removes that).

- [ ] **Step 3: Rewrite `SystemResourceMonitor.swift` with types, math, and reader**

Keep the four types above and implement:
- `cpuUsage`: widen the 32-bit counters before subtracting, mask each delta to 32 bits,
  return `nil` when the total delta is zero, otherwise clamp `active/total` to `0...1`.
- `usedMemoryBytes`: `(internal − purgeable + wired + compressed) * pageSize`, saturated at zero, clamped to `totalBytes`.
- `LiveSystemResourceReader.read()`: `host_cpu_load_info` for ticks (`cpu_ticks.0...3` = user, system, idle, nice), `host_statistics64(HOST_VM_INFO64)` for `internal_page_count`, `purgeable_count`, `wire_count`, `compressor_page_count`, page size from `host_page_size(mach_host_self(), &size)` — never the `vm_kernel_page_size` global. Return `nil` when the host calls fail or `physicalMemory` is zero.

- [ ] **Step 4: Add the placeholder panel case so the module compiles**

In `StatusPopoverView.popupSection(_:)` add:

```swift
case .systemResource:
    // Replaced by SystemResourceStatusView in Task 4.
    EmptyView()
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `bash scripts/test.sh 'SystemResourceMathTests'`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/StatusTrioCore/Monitoring/SystemResourceMonitor.swift Sources/StatusTrioCore/UI/StatusPopoverView.swift Tests/StatusTrioCoreTests/SystemResourceMathTests.swift
git commit -m "feat(panel): add CPU and memory reading math"
```

### Task 2: Demand-gated sampler

**Files:**
- Modify: `Sources/StatusTrioCore/Monitoring/SystemResourceMonitor.swift` (append the monitor)
- Test: `Tests/StatusTrioCoreTests/SystemResourceMonitorTests.swift` (create)

**Interfaces:**
- Consumes: `SystemResourceSample`, `SystemResourceStatus`, `SystemResourceMath`, `SystemResourceReadingProviding`.
- Produces: `@MainActor final class SystemResourceMonitor: ObservableObject` with
  `init(reader: @escaping @Sendable () -> SystemResourceSample?, interval: Duration = .seconds(2))`,
  `@Published private(set) var status: SystemResourceStatus`,
  `func setActive(_ active: Bool)`, `func stop()`, `func sampleNow()`.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
final class SystemResourceMonitorTests: XCTestCase {
    final class Counter: @unchecked Sendable { var value = 0 }

    func testFirstSamplePublishesMemoryWithoutCPU() {
        let monitor = SystemResourceMonitor(reader: { Self.sample(cpuTicks: Self.ticks(100)) })
        monitor.sampleNow()
        XCTAssertTrue(monitor.status.hasReading)
        XCTAssertNil(monitor.status.cpuUsage)
        XCTAssertEqual(monitor.status.usedMemoryBytes, 4096)
        XCTAssertEqual(monitor.status.totalMemoryBytes, 8192)
    }

    func testSecondSamplePublishesTheCPUDelta() {
        let counter = Counter()
        let monitor = SystemResourceMonitor(reader: {
            counter.value += 1
            return Self.sample(cpuTicks: Self.ticks(counter.value == 1 ? 100 : 175))
        })
        monitor.sampleNow()
        monitor.sampleNow()
        XCTAssertEqual(monitor.status.cpuUsage!, 0.5, accuracy: 0.0001)
    }

    func testInactiveMonitorNeverReads() async throws {
        let counter = Counter()
        let monitor = SystemResourceMonitor(reader: { counter.value += 1; return Self.sample(cpuTicks: Self.ticks(0)) },
                                           interval: .milliseconds(20))
        monitor.setActive(false)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(counter.value, 0)
    }

    func testStopEndsSampling() async throws {
        let counter = Counter()
        let monitor = SystemResourceMonitor(reader: { counter.value += 1; return Self.sample(cpuTicks: Self.ticks(0)) },
                                           interval: .milliseconds(20))
        monitor.setActive(true)
        try await Task.sleep(for: .milliseconds(60))
        monitor.stop()
        let stopped = counter.value
        XCTAssertGreaterThan(stopped, 1)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(counter.value, stopped)
    }

    private static func ticks(_ user: UInt64) -> CPUUsageTicks {
        CPUUsageTicks(user: user, system: 0, idle: user, nice: 0)
    }

    private static func sample(cpuTicks: CPUUsageTicks?) -> SystemResourceSample {
        SystemResourceSample(cpuTicks: cpuTicks, usedMemoryBytes: 4096, totalMemoryBytes: 8192)
    }
}
```

The reader closure is `@Sendable`, so tests mutate a `Counter` reference rather than capturing a `var`.

- [ ] **Step 2: Run to see it fail**

Run: `bash scripts/test.sh 'SystemResourceMonitorTests'`
Expected: compile failure — `SystemResourceMonitor` is undefined.

- [ ] **Step 3: Implement the monitor**

`setActive(true)` starts a repeating `Task` that samples immediately and then every `interval`; `setActive(false)` and `stop()` cancel it and bump a generation so a late tick cannot publish. Each read that returns `nil` keeps the previous status. Publish only when the new status differs. `hasReading` becomes true on the first non-nil read and never goes back to false.

- [ ] **Step 4: Run to see it pass**

Run: `bash scripts/test.sh 'SystemResourceMonitorTests'`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusTrioCore/Monitoring/SystemResourceMonitor.swift Tests/StatusTrioCoreTests/SystemResourceMonitorTests.swift
git commit -m "feat(panel): sample system resources on demand"
```

### Task 3: Presentation state, mapper, and 12-language copy

**Files:**
- Create: `Sources/StatusTrioCore/Presentation/Panel/SystemResourcePanelState.swift`
- Create: `Sources/StatusTrioCore/Presentation/Panel/SystemResourcePanelMapper.swift`
- Modify: `Sources/StatusTrioCore/Localization/LocalizationKey.swift`
- Modify: all 12 `Sources/StatusTrioCore/Resources/*.lproj/Localizable.strings`
- Test: `Tests/StatusTrioCoreTests/SystemResourcePanelMapperTests.swift` (create)

**Interfaces:**
- Consumes: `SystemResourceStatus`, `Localization`.
- Produces:
  - `struct SystemResourcePanelState: Equatable, Sendable { let title: String; let subtitle: String; let accessibilityValue: String; let cpuFraction: Double?; let memoryFraction: Double?; static func empty(localization: Localization) -> SystemResourcePanelState }`
  - `@MainActor enum SystemResourcePanelMapper { static func map(_ status: SystemResourceStatus?, localization: Localization) -> SystemResourcePanelState }`
  - `LocalizationKey.systemResourceTitle`, `.systemResourceCpu`, `.systemResourceMemory`, `.systemResourceAccessibility`

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
final class SystemResourcePanelMapperTests: XCTestCase {
    func testPlaceholderBeforeTheFirstRead() {
        let state = SystemResourcePanelMapper.map(nil, localization: Self.localization())
        XCTAssertEqual(state.subtitle, "CPU — · Memory —")
        XCTAssertNil(state.cpuFraction)
        XCTAssertNil(state.memoryFraction)
    }

    func testMemoryIsShownBeforeTheFirstCPUDelta() {
        let state = SystemResourcePanelMapper.map(
            SystemResourceStatus(cpuUsage: nil, usedMemoryBytes: 9_000_000_000,
                                 totalMemoryBytes: 16_000_000_000, hasReading: true),
            localization: Self.localization()
        )
        XCTAssertEqual(state.subtitle, "CPU — · Memory 9 GB / 16 GB")
    }

    func testReadingsAreFormattedWithThePercentAndByteFormatters() {
        let state = SystemResourcePanelMapper.map(
            SystemResourceStatus(cpuUsage: 0.183, usedMemoryBytes: 9_000_000_000,
                                 totalMemoryBytes: 16_000_000_000, hasReading: true),
            localization: Self.localization()
        )
        XCTAssertEqual(state.subtitle, "CPU 18% · Memory 9 GB / 16 GB")
        XCTAssertEqual(state.cpuFraction!, 0.183, accuracy: 0.0001)
    }

    func testAccessibilityNamesBothReadings() {
        let state = SystemResourcePanelMapper.map(
            SystemResourceStatus(cpuUsage: 0.5, usedMemoryBytes: 4_000_000_000,
                                 totalMemoryBytes: 8_000_000_000, hasReading: true),
            localization: Self.localization()
        )
        XCTAssertEqual(state.accessibilityValue, "CPU 50%, memory 4 GB of 8 GB")
    }

    private static func localization() -> Localization {
        let defaults = UserDefaults(suiteName: "SystemResourcePanelMapperTests.\(UUID().uuidString)")!
        return Localization(defaults: defaults, preferredLanguages: ["en"])
    }
}
```

Exact byte strings depend on `ByteCountFormatter`; if it yields `8.79 GB` adjust the expectation to the formatter's actual output in the same commit, not a looser assertion.

- [ ] **Step 2: Run to see it fail**

Run: `bash scripts/test.sh 'SystemResourcePanelMapperTests'`
Expected: compile failure — mapper and keys are undefined.

- [ ] **Step 3: Add keys and copy**

Add the four `LocalizationKey` cases and one line per language:

| key | en |
| --- | --- |
| `systemResource.title` | `CPU & Memory` |
| `systemResource.cpu` | `CPU` |
| `systemResource.memory` | `Memory` |
| `systemResource.accessibility` | `CPU %@, memory %@ of %@` |

Translate `.title`, `.memory`, and `.accessibility` for the other 11 files (`CPU` stays `CPU`). Keep the `%@` placeholders exactly; `LocalizationParityTests` enforces the key set and placeholder parity.

- [ ] **Step 4: Implement state and mapper**

- Subtitle: `"\(cpuLabel) \(cpuText) · \(memoryLabel) \(memoryText)"`.
- `cpuText`: `cpuUsage.formatted(.percent.precision(.fractionLength(0)).locale(locale))`, else `"—"`.
- `memoryText`: used bytes + `" / "` + total bytes, both through `ByteCountFormatter` (`countStyle = .memory`, `allowedUnits = [.useGB, .useMB]`), else `"—"` when `hasReading` is false. With no reading, both halves are `—`.
- Fractions: `cpuUsage` and `used/total` (0 when total is 0).
- Accessibility: `String(format: accessibilityFormat, locale:, arguments: [cpuText, usedText, totalText])` with `—` for unknown parts.
- `empty(localization:)` equals `map(nil, localization:)`.

- [ ] **Step 5: Run to see it pass**

Run: `bash scripts/test.sh 'SystemResourcePanelMapperTests'`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/StatusTrioCore/Presentation/Panel/SystemResourcePanelState.swift Sources/StatusTrioCore/Presentation/Panel/SystemResourcePanelMapper.swift Sources/StatusTrioCore/Localization/LocalizationKey.swift Sources/StatusTrioCore/Resources Tests/StatusTrioCoreTests/SystemResourcePanelMapperTests.swift
git commit -m "feat(panel): present CPU and memory readings in 12 languages"
```

### Task 4: Row view and panel wiring

**Files:**
- Create: `Sources/StatusTrioCore/UI/SystemResourceStatusView.swift`
- Modify: `Sources/StatusTrioCore/UI/StatusPopoverView.swift` (replace placeholder)
- Modify: `Sources/StatusTrioCore/Presentation/Panel/StatusPanelViewModel.swift`
- Modify: `Tests/StatusTrioCoreTests/StatusPanelViewModelTests.swift:1172-1188` (`makePanel`)
- Test: `Tests/StatusTrioCoreTests/StatusPanelDemandTests.swift` (extend)

**Interfaces:**
- Consumes: `SystemResourceMonitor`, `SystemResourcePanelMapper`, `SystemResourcePanelState`.
- Produces: `@Published private(set) var systemResource: SystemResourcePanelState` on the view model; `init(..., systemResourceMonitor: SystemResourceMonitor? = nil)`.

- [ ] **Step 1: Write the failing tests**

Extend `StatusPanelDemandTests`:

```swift
func testSystemResourceSamplesOnlyWhileEnabledAndVisible() async {
    let fixture = PanelStoreFixture()
    for section in PopupSection.allCases { fixture.settings.setPopupSection(section, enabled: false) }
    let counter = ReadCounter()
    let monitor = SystemResourceMonitor(reader: {
        counter.value += 1
        return SystemResourceSample(cpuTicks: CPUUsageTicks(user: 1, system: 0, idle: 1, nice: 0),
                                    usedMemoryBytes: 1024, totalMemoryBytes: 2048)
    }, interval: .milliseconds(20))
    let panel = fixture.makePanel(systemResourceMonitor: monitor)
    panel.start()
    fixture.store.setPopoverVisible(true)
    defer { panel.stop(); fixture.store.setPopoverVisible(false); fixture.store.stop() }

    try? await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(counter.value, 0, "a hidden section must not sample")

    fixture.settings.setPopupSection(.systemResource, enabled: true)
    try? await Task.sleep(for: .milliseconds(60))
    XCTAssertGreaterThan(counter.value, 0)
    XCTAssertTrue(panel.systemResource.subtitle.contains("CPU"))

    fixture.settings.setPopoverVisible(false) // use the store: fixture.store.setPopoverVisible(false)
    let stopped = counter.value
    try? await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(counter.value, stopped)
}
```

Use `fixture.store.setPopoverVisible(false)`. Add a `final class ReadCounter: @unchecked Sendable { var value = 0 }` helper in the test file.

Also add to `StatusPanelViewModelTests`:

```swift
func testHidingTheSystemResourceSectionStopsItsMonitor() { /* enable, start, hide, assert no further reads */ }

func testSamplingContinuesWhileADetailRouteIsOpen() async {
    // Enable .systemResource and .inputSource, start the panel, open the input
    // source page, sample, and assert the monitor kept reading while
    // panel.isShowingDetailPage is true.
}
```

- [ ] **Step 2: Run to see it fail**

Run: `bash scripts/test.sh 'StatusPanelDemandTests'`
Expected: compile failure — `makePanel(systemResourceMonitor:)` and `panel.systemResource` do not exist.

- [ ] **Step 3: Implement the row**

`SystemResourceStatusView` mirrors `InputSourceStatusView`'s layout: `PanelSymbolView(source: .symbol(name: "cpu", variableValue: nil, fallback: nil))` in a 24×24 frame, `.foregroundStyle(.secondary)`, `Text(state.title).font(.headline)`, `Text(state.subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)`, `Spacer(minLength: 0)`, and a combined accessibility element whose label is `state.title` and value is `state.accessibilityValue`.

- [ ] **Step 4: Wire the view model**

- Add `private let systemResourceMonitor: SystemResourceMonitor`, the init parameter (default `SystemResourceMonitor()`), and `systemResource = SystemResourcePanelMapper.map(nil, localization: localization)` before `refreshAll()`.
- Add `static let systemResource = SourceDemand(rawValue: 1 << 6)` and `if isVisible(.systemResource) { demand.insert(.systemResource) }`.
- In the subscription block: when demand contains `.systemResource`, subscribe to `monitor.$status` (no `dropFirst`) and publish through the mapper guarded by `isVisible(.systemResource)`; when it does not, call `monitor.setActive(false)` and set `systemResource = .empty(localization: localization)`.
- Call `systemResourceMonitor.setActive(true)` after the subscription is attached.
- `refreshAll()`: publish from `monitor.status` when the section is visible.
- `releaseInactivePresentationState()`: reset to `.empty(localization:)` when the section is not visible.
- `stop()`: `systemResourceMonitor.stop()`.

- [ ] **Step 5: Run to see it pass**

Run: `bash scripts/test.sh 'StatusPanelDemandTests'` and `bash scripts/test.sh 'StatusPanelViewModelTests'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/StatusTrioCore/UI/SystemResourceStatusView.swift Sources/StatusTrioCore/UI/StatusPopoverView.swift Sources/StatusTrioCore/Presentation/Panel/StatusPanelViewModel.swift Tests/StatusTrioCoreTests/StatusPanelDemandTests.swift Tests/StatusTrioCoreTests/StatusPanelViewModelTests.swift
git commit -m "feat(panel): render the CPU and memory row"
```

### Task 5: Default order and settings-transfer compatibility

**Files:**
- Modify: `Sources/StatusTrioCore/Settings/SettingsStore.swift:196-199`
- Modify: `Sources/StatusTrioCore/Settings/SettingsPreferenceCatalog.swift:334-343`
- Test: `Tests/StatusTrioCoreTests/SettingsStoreTests.swift:1492-1498`, `Tests/StatusTrioCoreTests/SettingsPreferenceCatalogTests.swift`

**Interfaces:**
- Consumes: `PopupSection.systemResource`.
- Produces: no new public API; `popupSectionOrder` now ends with `.systemResource` by default, and legacy transfer documents are completed instead of rejected.

- [ ] **Step 1: Write the failing tests**

```swift
func testSystemResourceSectionIsOffByDefaultAndSortsLast() {
    let store = SettingsStore(defaults: makeSuite().defaults)
    XCTAssertEqual(store.popupSectionOrder.last, .systemResource)
    XCTAssertFalse(store.enabledPopupSections.contains(.systemResource))
}

func testLegacyOrderDocumentKeepsItsOrderAndAppendsTheNewSection() {
    let legacy = [PopupSection.volume, .brightness, .battery, .network, .vpn,
                  .bluetooth, .audioInput, .inputSource]
    let prepared = SettingsPreferenceCatalog.prepare(
        ["popupSectionOrder": .array(legacy.map { .string($0.rawValue) })]
    )
    XCTAssertTrue(prepared.warnings.isEmpty)
    let store = SettingsStore(defaults: makeSuite().defaults)
    SettingsPreferenceCatalog.apply(prepared.values, to: store)
    XCTAssertEqual(store.popupSectionOrder, legacy + [.systemResource])
}
```

Keep the existing `prepare(["popupSectionOrder": .array([.string("battery")])])` warning test as is: an order that drops a section the legacy build already had stays invalid.

- [ ] **Step 2: Run to see them fail**

Run: `bash scripts/test.sh 'SettingsStoreTests'` and `bash scripts/test.sh 'SettingsPreferenceCatalogTests'`
Expected: default-order test fails (`.systemResource` missing); the legacy case fails with a warning and a reordered panel.

- [ ] **Step 3: Implement**

- Append `.systemResource` to `defaultPopupSectionOrder` (leave `defaultEnabledPopupSections` unchanged).
- In `sections(_:requiresFullOrder:)`, when the parsed set is incomplete, accept it only if it equals the set of `defaultPopupSectionOrder` entries before the first missing default entry, then append the missing tail in default order. Otherwise return `nil` (existing behavior). Update the doc comment to say earlier builds exported a prefix of today's default order.
- Update `testPopupSectionOrderDefaultsToBrightnessBelowAudioInput` to expect `.systemResource` last, and any other exact-order assertion the run reports.

- [ ] **Step 4: Run to see them pass**

Run: `bash scripts/test.sh 'Settings'`
Expected: PASS, including `VPNRowSettingsTests`.

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusTrioCore/Settings Tests/StatusTrioCoreTests/SettingsStoreTests.swift Tests/StatusTrioCoreTests/SettingsPreferenceCatalogTests.swift
git commit -m "feat(settings): enable the CPU and memory section by default order"
```

### Task 6: Documentation

**Files:**
- Modify: `README.md` and the 10 translated READMEs (`README.de.md`, `es`, `fr`, `ja`, `ko`, `pt-BR`, `ru`, `zh-Hans`, `zh-Hant`; `README.zh-CN.md` is a pointer stub)

**Interfaces:** none.

- [ ] **Step 1: Add one feature bullet per README**

In the feature list, after the input-source bullet, add a bullet in the file's language: the status panel can show a live CPU and memory row, off by default, enabled under Settings › Status Panel › Order. Do not create new README files or translate the bullet into a language the file does not already use.

- [ ] **Step 2: Verify no broken localization or shell checks**

Run: `bash scripts/verify-local.sh docs`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add README*.md
git commit -m "docs: note the CPU and memory status row"
```

### Final verification

- [ ] `bash scripts/test.sh 'SystemResource'` → PASS
- [ ] `bash scripts/verify-local.sh full` → PASS on the final tree, recording branch, SHA, and any `NOT RUN` runtime items honestly.
