import XCTest
@testable import StatusTrioCore

@MainActor
final class SystemResourceMonitorTests: XCTestCase {
    final class Counter: @unchecked Sendable {
        var value = 0
    }

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
        let monitor = SystemResourceMonitor(
            reader: {
                counter.value += 1
                return Self.sample(cpuTicks: Self.ticks(0))
            },
            interval: .milliseconds(20)
        )
        monitor.setActive(false)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(counter.value, 0)
    }

    func testStopEndsSampling() async throws {
        let counter = Counter()
        let monitor = SystemResourceMonitor(
            reader: {
                counter.value += 1
                return Self.sample(cpuTicks: Self.ticks(0))
            },
            interval: .milliseconds(20)
        )
        monitor.setActive(true)
        try await Task.sleep(for: .milliseconds(60))
        monitor.stop()
        let stopped = counter.value
        XCTAssertGreaterThan(stopped, 1)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(counter.value, stopped)
    }

    func testFailedReadKeepsThePreviousReading() {
        let counter = Counter()
        let monitor = SystemResourceMonitor(reader: {
            counter.value += 1
            return counter.value == 1 ? Self.sample(cpuTicks: Self.ticks(0)) : nil
        })
        monitor.sampleNow()
        let first = monitor.status
        monitor.sampleNow()
        XCTAssertEqual(monitor.status, first)
    }

    func testStopResetsTheReadingSoAReopenCannotShowStaleValues() {
        let monitor = SystemResourceMonitor(reader: { Self.sample(cpuTicks: Self.ticks(10)) })
        monitor.setActive(true)
        XCTAssertTrue(monitor.status.hasReading)
        monitor.stop()
        XCTAssertFalse(monitor.status.hasReading)
    }

    nonisolated private static func ticks(_ user: UInt64) -> CPUUsageTicks {
        CPUUsageTicks(user: user, system: 0, idle: user, nice: 0)
    }

    nonisolated private static func sample(cpuTicks: CPUUsageTicks?) -> SystemResourceSample {
        SystemResourceSample(cpuTicks: cpuTicks, usedMemoryBytes: 4096, totalMemoryBytes: 8192)
    }
}
