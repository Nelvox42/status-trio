import Darwin
import Foundation

// MARK: - Raw counters

/// One `host_cpu_load_info` reading. The kernel keeps these as 32-bit counters;
/// they are widened here and each delta is masked back to 32 bits before use.
struct CPUUsageTicks: Equatable, Sendable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
}

/// One unprivileged reading of the machine. `cpuTicks` is raw so the sampler can
/// compute a delta; `nil` means the host call failed for this sample.
struct SystemResourceSample: Equatable, Sendable {
    let cpuTicks: CPUUsageTicks?
    let usedMemoryBytes: UInt64
    let totalMemoryBytes: UInt64
}

// MARK: - Published status

struct SystemResourceStatus: Equatable, Sendable {
    /// CPU usage fraction in `0...1`, or `nil` until a second sample exists.
    let cpuUsage: Double?
    let usedMemoryBytes: UInt64
    let totalMemoryBytes: UInt64
    /// False only until the first successful read; the panel shows placeholders
    /// rather than a fabricated `0` before then.
    let hasReading: Bool

    static let placeholder = SystemResourceStatus(
        cpuUsage: nil,
        usedMemoryBytes: 0,
        totalMemoryBytes: 0,
        hasReading: false
    )

    var memoryUsageFraction: Double {
        guard totalMemoryBytes > 0 else { return 0 }
        return Double(usedMemoryBytes) / Double(totalMemoryBytes)
    }
}

// MARK: - Math

enum SystemResourceMath {
    private static let tickMask: UInt64 = 0xFFFF_FFFF

    /// Active-tick delta over total-tick delta. `nil` when the machine produced no
    /// ticks between the two samples, so the caller keeps the previous reading.
    static func cpuUsage(current: CPUUsageTicks, previous: CPUUsageTicks) -> Double? {
        let user = delta(current.user, previous.user)
        let system = delta(current.system, previous.system)
        let nice = delta(current.nice, previous.nice)
        let idle = delta(current.idle, previous.idle)
        let total = user &+ system &+ nice &+ idle
        guard total > 0 else { return nil }
        let active = user &+ system &+ nice
        return min(1, max(0, Double(active) / Double(total)))
    }

    /// Activity Monitor's "Memory Used": app memory (internal minus purgeable)
    /// plus wired plus compressed, clamped to the physical total.
    static func usedMemoryBytes(
        internalPages: UInt64,
        purgeablePages: UInt64,
        wiredPages: UInt64,
        compressedPages: UInt64,
        pageSize: UInt64,
        totalBytes: UInt64
    ) -> UInt64 {
        let appPages = internalPages >= purgeablePages ? internalPages - purgeablePages : 0
        let pages = appPages &+ wiredPages &+ compressedPages
        return min(pages &* pageSize, totalBytes)
    }

    private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        (current &- previous) & tickMask
    }
}

// MARK: - Live reader

protocol SystemResourceReadingProviding: Sendable {
    func read() -> SystemResourceSample?
}

struct LiveSystemResourceReader: SystemResourceReadingProviding, Sendable {
    func read() -> SystemResourceSample? {
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0, let ticks = readCPUTicks(), let statistics = readMemoryStatistics() else {
            return nil
        }
        let pageSize = Self.pageSize
        return SystemResourceSample(
            cpuTicks: ticks,
            usedMemoryBytes: SystemResourceMath.usedMemoryBytes(
                internalPages: UInt64(statistics.internal_page_count),
                purgeablePages: UInt64(statistics.purgeable_count),
                wiredPages: UInt64(statistics.wire_count),
                compressedPages: UInt64(statistics.compressor_page_count),
                pageSize: pageSize,
                totalBytes: total
            ),
            totalMemoryBytes: total
        )
    }

    /// `host_page_size` rather than the `vm_kernel_page_size` global: Swift 6
    /// rejects that mutable global as shared state.
    private static var pageSize: UInt64 {
        var size: vm_size_t = 0
        guard host_page_size(mach_host_self(), &size) == KERN_SUCCESS, size > 0 else {
            return 4096
        }
        return UInt64(size)
    }

    private func readCPUTicks() -> CPUUsageTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // CPU_STATE_USER, SYSTEM, IDLE, NICE in that order.
        return CPUUsageTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    private func readMemoryStatistics() -> vm_statistics64? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? statistics : nil
    }
}

// MARK: - Demand-gated sampler

/// Samples whole-machine CPU and memory only while one surface needs it.
///
/// The owner is the panel view model: it activates the monitor when the section
/// is visible and enabled, and stops it when the panel closes. Nothing here runs
/// on a timer while the app is at rest.
@MainActor
final class SystemResourceMonitor: ObservableObject {
    typealias Reader = @Sendable () -> SystemResourceSample?

    @Published private(set) var status: SystemResourceStatus = .placeholder

    private let reader: Reader
    private let interval: Duration
    private var pollTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var previousTicks: CPUUsageTicks?
    private var isActive = false

    init(
        reader: @escaping Reader = { LiveSystemResourceReader().read() },
        interval: Duration = .seconds(2)
    ) {
        self.reader = reader
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
        previousTicks = nil
        // A reopen must not draw the reading from before the pause as if it were
        // live: the next sample republishes memory and waits for its own delta.
        if status != .placeholder { status = .placeholder }
    }

    /// One synchronous sample. Kept internal so tests can drive the delta
    /// arithmetic without waiting on the timer.
    func sampleNow() {
        guard let sample = reader() else { return }
        var usage = status.cpuUsage
        if let ticks = sample.cpuTicks {
            if let previous = previousTicks,
               let measured = SystemResourceMath.cpuUsage(current: ticks, previous: previous) {
                usage = measured
            }
            previousTicks = ticks
        }
        let next = SystemResourceStatus(
            cpuUsage: usage,
            usedMemoryBytes: sample.usedMemoryBytes,
            totalMemoryBytes: sample.totalMemoryBytes,
            hasReading: true
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
