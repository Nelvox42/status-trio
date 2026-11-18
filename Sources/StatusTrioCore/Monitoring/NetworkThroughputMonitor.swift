import Darwin
import Foundation

// MARK: - Raw counters

/// Received and sent bytes summed over the machine's physical interfaces.
struct NetworkByteCounters: Equatable, Sendable {
    let receivedBytes: UInt64
    let sentBytes: UInt64
}

/// One published throughput reading. A `nil` half is a half the sampler could not
/// measure yet, which the row renders as a dash rather than `0 B/s`.
struct NetworkThroughputReading: Equatable, Sendable {
    let receivedBytesPerSecond: Double?
    let sentBytesPerSecond: Double?

    static let placeholder = NetworkThroughputReading(
        receivedBytesPerSecond: nil,
        sentBytesPerSecond: nil
    )
}

// MARK: - Math

enum NetworkThroughputMath {
    /// Bytes per second between two counter readings. A counter that went backwards
    /// (interface re-plugged, driver reset) or a non-positive interval has no rate.
    static func bytesPerSecond(current: UInt64, previous: UInt64, elapsed: TimeInterval) -> Double? {
        guard elapsed > 0, current >= previous else { return nil }
        return Double(current - previous) / elapsed
    }
}

// MARK: - Live reader

/// Sums the 64-bit counters of the physical interfaces.
///
/// `utun*` (VPN tunnels) are deliberately excluded: their bytes are already counted
/// on the interface that carries them, so including both would roughly double the
/// reported rate whenever a tunnel is up. `awdl*`/`llw*` (AirDrop, AirPlay) and
/// `lo0` are excluded for the same reason of not being user traffic.
struct LiveNetworkCounterReader: Sendable {
    func read() -> NetworkByteCounters? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: length)
        let result = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, u_int(mib.count), raw.baseAddress, &length, nil, 0)
        }
        guard result == 0 else { return nil }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var found = false

        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr2>.size <= length {
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                let messageLength = Int(message.ifm_msglen)
                guard messageLength > 0 else { break }
                if Int32(message.ifm_type) == RTM_IFINFO2,
                   message.ifm_flags & IFF_UP != 0,
                   let name = Self.interfaceName(index: message.ifm_index),
                   name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                    received &+= message.ifm_data.ifi_ibytes
                    sent &+= message.ifm_data.ifi_obytes
                    found = true
                }
                offset += messageLength
            }
        }

        guard found else { return nil }
        return NetworkByteCounters(receivedBytes: received, sentBytes: sent)
    }

    private static func interfaceName(index: UInt16) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ) + 1)
        guard if_indextoname(UInt32(index), &buffer) != nil else { return nil }
        return String(cString: buffer)
    }
}

// MARK: - Demand-gated sampler

/// Publishes throughput only while the panel row needs it.
///
/// The owner is the panel view model: it activates the monitor when the section is
/// visible and enabled and stops it when the panel closes. Nothing samples at rest.
@MainActor
final class NetworkThroughputMonitor: ObservableObject {
    typealias Reader = @Sendable () -> NetworkByteCounters?
    typealias Uptime = @Sendable () -> TimeInterval

    @Published private(set) var status: NetworkThroughputReading = .placeholder

    private let reader: Reader
    private let uptime: Uptime
    private let interval: Duration
    private var pollTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var previous: (counters: NetworkByteCounters, at: TimeInterval)?
    private var isActive = false

    init(
        reader: @escaping Reader = { LiveNetworkCounterReader().read() },
        uptime: @escaping Uptime = { ProcessInfo.processInfo.systemUptime },
        interval: Duration = .seconds(1)
    ) {
        self.reader = reader
        self.uptime = uptime
        self.interval = interval
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active {
            start()
        } else {
            stop()
        }
    }

    func stop() {
        isActive = false
        generation &+= 1
        pollTask?.cancel()
        pollTask = nil
        previous = nil
        // A reopen must not draw the rate from before the pause as live.
        if status != .placeholder { status = .placeholder }
    }

    /// One synchronous sample, kept internal so tests can drive the delta math.
    func sampleNow() {
        let now = uptime()
        guard let current = reader() else { return }
        let prior = previous
        previous = (current, now)
        guard let prior else { return }

        let elapsed = now - prior.at
        let received = NetworkThroughputMath.bytesPerSecond(
            current: current.receivedBytes,
            previous: prior.counters.receivedBytes,
            elapsed: elapsed
        )
        let sent = NetworkThroughputMath.bytesPerSecond(
            current: current.sentBytes,
            previous: prior.counters.sentBytes,
            elapsed: elapsed
        )
        // A reset produces no rate at all; keep the previous reading and let the
        // next sample recover instead of flashing a negative or zero value.
        guard received != nil || sent != nil else { return }
        let next = NetworkThroughputReading(
            receivedBytesPerSecond: received,
            sentBytesPerSecond: sent
        )
        if next != status { status = next }
    }

    private func start() {
        guard pollTask == nil else { return }
        generation &+= 1
        let currentGeneration = generation
        sampleNow()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await Task.sleep(for: self.interval)
                } catch {
                    return
                }
                guard self.generation == currentGeneration, self.isActive else { return }
                self.sampleNow()
            }
        }
    }
}
