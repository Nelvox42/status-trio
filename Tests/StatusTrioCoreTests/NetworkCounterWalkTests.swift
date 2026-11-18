import XCTest
@testable import StatusTrioCore

/// The routing-table walk over synthetic messages, so the interface filter and the
/// malformed-input paths are pinned without depending on this Mac's interfaces.
final class NetworkCounterWalkTests: XCTestCase {
    func testSumsOnlyPhysicalUpInterfaces() {
        var bytes: [UInt8] = []
        bytes += message(index: 1, flags: IFF_UP, received: 100, sent: 10)
        bytes += message(index: 2, flags: IFF_UP, received: 900, sent: 90)
        bytes += message(index: 3, flags: IFF_UP, received: 500, sent: 50)
        bytes += message(index: 4, flags: IFF_UP, received: 7, sent: 3)
        let names: [UInt16: String] = [1: "en0", 2: "utun0", 3: "lo0", 4: "en1"]

        let counters = LiveNetworkCounterReader.counters(
            in: bytes,
            length: bytes.count,
            interfaceName: { names[$0] }
        )

        // en0 + en1 only: the VPN tunnel and loopback must never be summed.
        XCTAssertEqual(counters, NetworkByteCounters(receivedBytes: 107, sentBytes: 13))
    }

    func testInterfaceThatIsDownIsIgnored() {
        let bytes = message(index: 1, flags: 0, received: 100, sent: 10)
        XCTAssertNil(
            LiveNetworkCounterReader.counters(in: bytes, length: bytes.count) { _ in "en0" }
        )
    }

    func testZeroMessageLengthStopsWithoutReadingPastTheBuffer() {
        var bytes = message(index: 1, flags: IFF_UP, received: 5, sent: 2)
        var broken = if_msghdr()
        broken.ifm_msglen = 0
        broken.ifm_type = UInt8(RTM_IFINFO2)
        bytes += withUnsafeBytes(of: broken) { Array($0) }

        XCTAssertEqual(
            LiveNetworkCounterReader.counters(in: bytes, length: bytes.count) { _ in "en0" },
            NetworkByteCounters(receivedBytes: 5, sentBytes: 2)
        )
    }

    func testTruncatedTailIsIgnored() {
        var bytes = message(index: 1, flags: IFF_UP, received: 5, sent: 2)
        bytes += [UInt8](repeating: 0, count: 40)

        XCTAssertEqual(
            LiveNetworkCounterReader.counters(in: bytes, length: bytes.count) { _ in "en0" },
            NetworkByteCounters(receivedBytes: 5, sentBytes: 2)
        )
    }

    func testNonInterfaceMessagesAreSkipped() {
        var address = if_msghdr()
        address.ifm_msglen = UInt16(MemoryLayout<if_msghdr>.size)
        address.ifm_type = UInt8(RTM_NEWADDR)
        var bytes = withUnsafeBytes(of: address) { Array($0) }
        bytes += message(index: 1, flags: IFF_UP, received: 9, sent: 4)

        XCTAssertEqual(
            LiveNetworkCounterReader.counters(in: bytes, length: bytes.count) { _ in "en0" },
            NetworkByteCounters(receivedBytes: 9, sentBytes: 4)
        )
    }

    private func message(index: UInt16, flags: Int32, received: UInt64, sent: UInt64) -> [UInt8] {
        var header = if_msghdr2()
        header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        header.ifm_type = UInt8(RTM_IFINFO2)
        header.ifm_index = index
        header.ifm_flags = flags
        header.ifm_data.ifi_ibytes = received
        header.ifm_data.ifi_obytes = sent
        return withUnsafeBytes(of: header) { Array($0) }
    }
}
