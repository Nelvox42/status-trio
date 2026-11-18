import XCTest
@testable import StatusTrioCore

final class NetworkThroughputMathTests: XCTestCase {
    func testRateUsesTheElapsedTime() {
        XCTAssertEqual(
            NetworkThroughputMath.bytesPerSecond(current: 2_000_000, previous: 1_000_000, elapsed: 2)!,
            500_000,
            accuracy: 0.001
        )
    }

    func testCounterResetYieldsNoRate() {
        XCTAssertNil(NetworkThroughputMath.bytesPerSecond(current: 10, previous: 20, elapsed: 1))
    }

    func testZeroElapsedYieldsNoRate() {
        XCTAssertNil(NetworkThroughputMath.bytesPerSecond(current: 20, previous: 10, elapsed: 0))
    }

    func testLiveReaderSumsPhysicalInterfaces() {
        let counters = LiveNetworkCounterReader().read()
        XCTAssertNotNil(counters)
        XCTAssertGreaterThan(counters?.receivedBytes ?? 0, 0)
    }
}
