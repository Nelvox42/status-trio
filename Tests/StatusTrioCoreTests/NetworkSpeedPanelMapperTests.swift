import XCTest
@testable import StatusTrioCore

@MainActor
final class NetworkSpeedPanelMapperTests: XCTestCase {
    func testPlaceholderBeforeTwoSamples() {
        let state = NetworkSpeedPanelMapper.map(nil, localization: Self.localization())
        XCTAssertEqual(state.subtitle, "↑ — · ↓ —")
        XCTAssertEqual(state.accessibilityValue, "Up —, down —")
    }

    func testRatesAreFormattedPerSecond() {
        let state = NetworkSpeedPanelMapper.map(
            NetworkThroughputReading(receivedBytesPerSecond: 8_400_000, sentBytesPerSecond: 1_200_000),
            localization: Self.localization()
        )
        XCTAssertEqual(state.subtitle, "↑ 1.2 MB/s · ↓ 8.4 MB/s")
        XCTAssertEqual(state.accessibilityValue, "Up 1.2 MB/s, down 8.4 MB/s")
    }

    func testAMissingHalfKeepsItsDash() {
        let state = NetworkSpeedPanelMapper.map(
            NetworkThroughputReading(receivedBytesPerSecond: nil, sentBytesPerSecond: 0),
            localization: Self.localization()
        )
        XCTAssertEqual(state.subtitle, "↑ 0 bytes/s · ↓ —")
    }

    func testEmptyMatchesThePlaceholderMapping() {
        let localization = Self.localization()
        XCTAssertEqual(
            NetworkSpeedPanelState.empty(localization: localization),
            NetworkSpeedPanelMapper.map(nil, localization: localization)
        )
    }

    private static func localization(language: String = "en") -> Localization {
        let defaults = UserDefaults(suiteName: "NetworkSpeedPanelMapperTests.\(UUID().uuidString)")!
        return Localization(defaults: defaults, preferredLanguages: [language])
    }
}
