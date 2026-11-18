import XCTest
@testable import StatusTrioCore

@MainActor
final class NetworkThroughputMonitorTests: XCTestCase {
    final class Counter: @unchecked Sendable {
        var value = 0
    }

    func testFirstSamplePublishesPlaceholders() {
        let reads = Counter()
        let clock = Clock()
        let monitor = NetworkThroughputMonitor(
            reader: {
                reads.value += 1
                return Self.counters(received: 1_000, sent: 500)
            },
            uptime: { clock.value },
            interval: .milliseconds(20)
        )
        clock.value = 100
        monitor.sampleNow()
        XCTAssertEqual(reads.value, 1)
        XCTAssertNil(monitor.status.receivedBytesPerSecond)
        XCTAssertNil(monitor.status.sentBytesPerSecond)
    }

    func testOfflineReadClearsTheRowInsteadOfFreezingIt() {
        let clock = Clock()
        let reads = Counter()
        let monitor = NetworkThroughputMonitor(
            reader: {
                reads.value += 1
                if reads.value == 3 { return nil }
                return Self.counters(
                    received: reads.value == 1 ? 1_000 : 2_001_000,
                    sent: 0
                )
            },
            uptime: { clock.value },
            interval: .milliseconds(20)
        )
        clock.value = 100
        monitor.sampleNow()
        clock.value = 101
        monitor.sampleNow()
        XCTAssertNotNil(monitor.status.receivedBytesPerSecond)

        clock.value = 102
        monitor.sampleNow()
        XCTAssertEqual(monitor.status, .placeholder, "no interface must show dashes, not a stale live rate")
    }

    func testAPauseInTheClockYieldsNoRate() {
        let reads = Counter()
        let monitor = NetworkThroughputMonitor(
            reader: {
                reads.value += 1
                return Self.counters(
                    received: reads.value == 1 ? 1_000 : 3_000,
                    sent: reads.value == 1 ? 500 : 1_500
                )
            },
            uptime: { 100 },
            interval: .milliseconds(20)
        )
        monitor.sampleNow()
        monitor.sampleNow()
        XCTAssertEqual(reads.value, 2, "both samples must actually run")
        XCTAssertNil(monitor.status.receivedBytesPerSecond)
    }

    func testRatesUseOneSecondOfUptime() {
        let clock = Clock()
        let reads = Counter()
        let monitor = NetworkThroughputMonitor(
            reader: {
                reads.value += 1
                return Self.counters(
                    received: reads.value == 1 ? 1_000 : 2_001_000,
                    sent: reads.value == 1 ? 0 : 500_000
                )
            },
            uptime: { clock.value },
            interval: .milliseconds(20)
        )
        clock.value = 100
        monitor.sampleNow()
        clock.value = 101
        monitor.sampleNow()
        XCTAssertEqual(monitor.status.receivedBytesPerSecond!, 2_000_000, accuracy: 0.001)
        XCTAssertEqual(monitor.status.sentBytesPerSecond!, 500_000, accuracy: 0.001)
    }

    func testBothHalvesResettingKeepsThePreviousReading() {
        let clock = Clock()
        let reads = Counter()
        let pairs: [(UInt64, UInt64)] = [(1_000, 1_000), (2_001_000, 501_000), (10, 10)]
        let monitor = NetworkThroughputMonitor(
            reader: {
                let pair = pairs[min(reads.value, pairs.count - 1)]
                reads.value += 1
                return Self.counters(received: pair.0, sent: pair.1)
            },
            uptime: { clock.value },
            interval: .milliseconds(20)
        )
        clock.value = 100
        monitor.sampleNow()
        clock.value = 101
        monitor.sampleNow()
        let measured = monitor.status
        XCTAssertEqual(measured.receivedBytesPerSecond!, 2_000_000, accuracy: 0.001)
        clock.value = 102
        monitor.sampleNow()
        XCTAssertEqual(monitor.status, measured)
    }

    func testCounterResetKeepsThePreviousReading() {
        let clock = Clock()
        let reads = Counter()
        let received: [UInt64] = [1_000, 2_001_000, 10]
        let monitor = NetworkThroughputMonitor(
            reader: {
                let value = received[min(reads.value, received.count - 1)]
                reads.value += 1
                return Self.counters(received: value, sent: 0)
            },
            uptime: { clock.value },
            interval: .milliseconds(20)
        )
        clock.value = 100
        monitor.sampleNow()
        clock.value = 101
        monitor.sampleNow()
        let measured = monitor.status
        XCTAssertEqual(measured.receivedBytesPerSecond!, 2_000_000, accuracy: 0.001)
        clock.value = 102
        monitor.sampleNow()
        XCTAssertNil(monitor.status.receivedBytesPerSecond, "a reset half reads as unavailable, never negative")
        XCTAssertEqual(monitor.status.sentBytesPerSecond, 0)
    }

    func testInactiveMonitorNeverReads() async throws {
        let reads = Counter()
        let monitor = NetworkThroughputMonitor(
            reader: {
                reads.value += 1
                return Self.counters(received: 1, sent: 1)
            },
            uptime: { 0 },
            interval: .milliseconds(20)
        )
        monitor.setActive(false)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(reads.value, 0)
    }

    func testStopEndsSamplingAndResetsTheReading() async throws {
        let reads = Counter()
        let monitor = NetworkThroughputMonitor(
            reader: {
                reads.value += 1
                return Self.counters(received: 1, sent: 1)
            },
            uptime: { 0 },
            interval: .milliseconds(20)
        )
        monitor.setActive(true)
        try await Task.sleep(for: .milliseconds(60))
        monitor.stop()
        let stopped = reads.value
        XCTAssertGreaterThan(stopped, 1)
        XCTAssertEqual(monitor.status, .placeholder)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(reads.value, stopped)
    }

    private func makeMonitor(
        reader: @escaping @Sendable () -> NetworkByteCounters?
    ) -> NetworkThroughputMonitor {
        NetworkThroughputMonitor(reader: reader, uptime: { 0 }, interval: .milliseconds(20))
    }

    private final class Clock: @unchecked Sendable {
        var value: TimeInterval = 0
    }

    nonisolated private static func counters(received: UInt64, sent: UInt64) -> NetworkByteCounters {
        NetworkByteCounters(receivedBytes: received, sentBytes: sent)
    }
}
