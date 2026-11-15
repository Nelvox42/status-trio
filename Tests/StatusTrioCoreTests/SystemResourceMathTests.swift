import XCTest
@testable import StatusTrioCore

final class SystemResourceMathTests: XCTestCase {
    func testCPUUsageUsesOnlyTheDelta() {
        let previous = CPUUsageTicks(user: 100, system: 50, idle: 850, nice: 0)
        let current = CPUUsageTicks(user: 150, system: 70, idle: 980, nice: 0)
        // active delta 70 over total delta 200 (idle also moved 850 -> 980)
        XCTAssertEqual(
            SystemResourceMath.cpuUsage(current: current, previous: previous)!,
            70.0 / 200.0,
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
