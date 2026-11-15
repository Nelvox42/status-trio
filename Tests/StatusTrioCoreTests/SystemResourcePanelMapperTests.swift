import XCTest
@testable import StatusTrioCore

@MainActor
final class SystemResourcePanelMapperTests: XCTestCase {
    func testPlaceholderBeforeTheFirstRead() {
        let state = SystemResourcePanelMapper.map(nil, localization: Self.localization())
        XCTAssertEqual(state.subtitle, "CPU — · Memory —")
        XCTAssertEqual(state.accessibilityValue, "CPU —, memory — of —")
        XCTAssertNil(state.cpuFraction)
        XCTAssertNil(state.memoryFraction)
    }

    func testMemoryIsShownBeforeTheFirstCPUDelta() {
        let state = SystemResourcePanelMapper.map(
            SystemResourceStatus(cpuUsage: nil, usedMemoryBytes: 9_663_676_416,
                                 totalMemoryBytes: 17_179_869_184, hasReading: true),
            localization: Self.localization()
        )
        XCTAssertEqual(state.subtitle, "CPU — · Memory 9 GB / 16 GB")
    }

    func testReadingsAreFormattedWithThePercentAndByteFormatters() {
        let state = SystemResourcePanelMapper.map(
            SystemResourceStatus(cpuUsage: 0.183, usedMemoryBytes: 9_663_676_416,
                                 totalMemoryBytes: 17_179_869_184, hasReading: true),
            localization: Self.localization()
        )
        XCTAssertEqual(state.subtitle, "CPU 18% · Memory 9 GB / 16 GB")
        XCTAssertEqual(state.cpuFraction!, 0.183, accuracy: 0.0001)
        XCTAssertEqual(state.memoryFraction!, 0.5625, accuracy: 0.0001)
    }

    func testAccessibilityNamesBothReadings() {
        let state = SystemResourcePanelMapper.map(
            SystemResourceStatus(cpuUsage: 0.5, usedMemoryBytes: 4_294_967_296,
                                 totalMemoryBytes: 8_589_934_592, hasReading: true),
            localization: Self.localization()
        )
        XCTAssertEqual(state.accessibilityValue, "CPU 50%, memory 4 GB of 8 GB")
    }

    func testEmptyMatchesThePlaceholderMapping() {
        let localization = Self.localization()
        XCTAssertEqual(
            SystemResourcePanelState.empty(localization: localization),
            SystemResourcePanelMapper.map(nil, localization: localization)
        )
    }

    private static func localization(language: String = "en") -> Localization {
        let defaults = UserDefaults(
            suiteName: "SystemResourcePanelMapperTests.\(UUID().uuidString)"
        )!
        return Localization(defaults: defaults, preferredLanguages: [language])
    }
}
