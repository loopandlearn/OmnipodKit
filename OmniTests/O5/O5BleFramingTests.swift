//
//  O5BleFramingTests.swift
//  OmniTests
//
//  PayloadSplitter / PayloadJoiner round-trip for BlePodProfile.omnipod5 (244-byte MTU).
//

import XCTest
@testable import OmnipodKit

final class O5BleFramingTests: XCTestCase {

    private let layout = OmniTestFixtures.o5BlePacketLayout

    private func splitPacketCount(for payload: Data) -> Int {
        PayloadSplitter(payload: payload, layout: layout).splitInPackets().count
    }

    private func assertSplitJoinRoundTrip(
        _ payload: Data,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        let packets = PayloadSplitter(payload: payload, layout: layout).splitInPackets()
        XCTAssertFalse(packets.isEmpty, file: file, line: line)
        var joiner = try PayloadJoiner(firstPacket: packets[0].toData(layout: layout), layout: layout)
        for packet in packets.dropFirst() {
            try joiner.accumulate(packet: packet.toData(layout: layout))
        }
        let joined = try joiner.finalize()
        XCTAssertEqual(joined, payload, file: file, line: line)
    }

    private func firstBlePacket(from payload: Data) throws -> FirstBlePacket {
        let wire = PayloadSplitter(payload: payload, layout: layout).splitInPackets()[0].toData(layout: layout)
        return try FirstBlePacket.parse(payload: wire, layout: layout)
    }

    func testO5BlePacketLayout_matchesOmnipod5Profile() {
        let profile = BlePodProfile.omnipod5.packetLayout
        XCTAssertEqual(layout.maxPayloadSize, 244)
        XCTAssertEqual(layout.maxFragments, 15)
        XCTAssertEqual(layout.firstPacketCapacityWithoutMiddlePackets, 237)
        XCTAssertEqual(layout.firstPacketCapacityWithMiddlePackets, 242)
        XCTAssertEqual(layout.firstPacketCapacityWithOptionalPlusOnePacket, 242)
        XCTAssertEqual(layout.middlePacketCapacity, 243)
        XCTAssertEqual(layout.lastPacketCapacity, 238)
        XCTAssertEqual(profile.maxPayloadSize, layout.maxPayloadSize)
        XCTAssertEqual(profile.firstPacketCapacityWithMiddlePackets, layout.firstPacketCapacityWithMiddlePackets)
    }

    func testSplitJoin_roundTrip_emptyPayload() throws {
        try assertSplitJoinRoundTrip(Data())
        XCTAssertEqual(splitPacketCount(for: Data()), 1)
    }

    func testSplitJoin_roundTrip_boundary242() throws {
        let payload = O5BleFramingFixtures.generatedPayload(count: 242, seed: 0xA5)
        try assertSplitJoinRoundTrip(payload)
        XCTAssertEqual(splitPacketCount(for: payload), 2)
    }

    func testSplitJoin_roundTrip_boundary243() throws {
        let payload = O5BleFramingFixtures.generatedPayload(count: 243, seed: 0x5A)
        try assertSplitJoinRoundTrip(payload)
        XCTAssertEqual(splitPacketCount(for: payload), 2)
    }

    func testSplitJoin_roundTrip_medium500() throws {
        let payload = O5BleFramingFixtures.generatedPayload(count: 500, seed: 0x11)
        try assertSplitJoinRoundTrip(payload)
        XCTAssertEqual(splitPacketCount(for: payload), 3)
    }

    func testSplitJoin_roundTrip_sweep1to800() throws {
        for count in 1...800 {
            let payload = O5BleFramingFixtures.generatedPayload(count: count, seed: UInt8(count & 0xFF))
            try assertSplitJoinRoundTrip(payload)
        }
    }

    func testSplit_packetCount_monotonic() {
        XCTAssertEqual(splitPacketCount(for: O5BleFramingFixtures.generatedPayload(count: 100)), 1)
        XCTAssertEqual(splitPacketCount(for: O5BleFramingFixtures.generatedPayload(count: 300)), 2)
        XCTAssertEqual(splitPacketCount(for: O5BleFramingFixtures.generatedPayload(count: 953, seed: 0x01)), 4)
    }

    func testSplit_firstPacket_fullFragments_953() throws {
        let payload = O5BleFramingFixtures.generatedPayload(count: 953, seed: 0x02)
        let first = try firstBlePacket(from: payload)
        XCTAssertEqual(first.fullFragments, 3)
        XCTAssertEqual(splitPacketCount(for: payload), 4)
    }

    func testJoin_throwsOnTruncatedFragmentSequence() throws {
        let payload = O5BleFramingFixtures.generatedPayload(count: 500, seed: 0x33)
        let packets = PayloadSplitter(payload: payload, layout: layout).splitInPackets()
        XCTAssertGreaterThanOrEqual(packets.count, 3)
        var joiner = try PayloadJoiner(firstPacket: packets[0].toData(layout: layout), layout: layout)
        XCTAssertThrowsError(try joiner.accumulate(packet: packets[2].toData(layout: layout)))
    }

    func testSplitJoin_roundTrip_multiPacketSizes() throws {
        let sizes: [(Int, Int)] = [(641, 3), (642, 3), (893, 4), (953, 4)]
        for (byteCount, expectedPackets) in sizes {
            let payload = O5BleFramingFixtures.generatedPayload(count: byteCount, seed: UInt8(byteCount & 0xFF))
            try assertSplitJoinRoundTrip(payload)
            XCTAssertEqual(splitPacketCount(for: payload), expectedPackets, "byteCount=\(byteCount)")
        }
    }

    func testSplitJoin_roundTrip_utcSend() throws {
        XCTAssertEqual(O5CommLogFixtures.utcSend.count, 18)
        try assertSplitJoinRoundTrip(O5CommLogFixtures.utcSend)
        XCTAssertEqual(splitPacketCount(for: O5CommLogFixtures.utcSend), 1)
    }

    func testSplitJoin_roundTrip_tdiSend() throws {
        XCTAssertEqual(O5CommLogFixtures.tdiSend.count, 15)
        try assertSplitJoinRoundTrip(O5CommLogFixtures.tdiSend)
        XCTAssertEqual(splitPacketCount(for: O5CommLogFixtures.tdiSend), 1)
    }

    func testSplitJoin_roundTrip_diaSend() throws {
        XCTAssertEqual(O5CommLogFixtures.diaSend.count, 11)
        try assertSplitJoinRoundTrip(O5CommLogFixtures.diaSend)
        XCTAssertEqual(splitPacketCount(for: O5CommLogFixtures.diaSend), 1)
    }

    func testSplitJoin_roundTrip_egvSend() throws {
        XCTAssertEqual(O5CommLogFixtures.egvSend.count, 17)
        try assertSplitJoinRoundTrip(O5CommLogFixtures.egvSend)
        XCTAssertEqual(splitPacketCount(for: O5CommLogFixtures.egvSend), 1)
    }

    func testSplitJoin_roundTrip_targetBgProfileSend() throws {
        XCTAssertEqual(O5CommLogFixtures.targetBgProfileSend.count, 204)
        try assertSplitJoinRoundTrip(O5CommLogFixtures.targetBgProfileSend)
        XCTAssertEqual(splitPacketCount(for: O5CommLogFixtures.targetBgProfileSend), 1)
    }

    func testSplitJoin_roundTrip_algorithmInsulinHistorySend() throws {
        XCTAssertEqual(O5CommLogFixtures.algorithmInsulinHistorySend.count, 176)
        try assertSplitJoinRoundTrip(O5CommLogFixtures.algorithmInsulinHistorySend)
        XCTAssertEqual(splitPacketCount(for: O5CommLogFixtures.algorithmInsulinHistorySend), 1)
    }

    func testSplitJoin_roundTrip_oneUnitBolusExtra() throws {
        XCTAssertEqual(O5CommLogFixtures.oneUnitBolusExtra.count, 20)
        try assertSplitJoinRoundTrip(O5CommLogFixtures.oneUnitBolusExtra)
        XCTAssertEqual(splitPacketCount(for: O5CommLogFixtures.oneUnitBolusExtra), 1)
    }

    func testSplitJoin_roundTrip_primeBolusExtra() throws {
        XCTAssertEqual(O5CommLogFixtures.primeBolusExtra.count, 20)
        try assertSplitJoinRoundTrip(O5CommLogFixtures.primeBolusExtra)
        XCTAssertEqual(splitPacketCount(for: O5CommLogFixtures.primeBolusExtra), 1)
    }

    func testSplitJoin_roundTrip_cannulaBolusExtra() throws {
        XCTAssertEqual(O5CommLogFixtures.cannulaBolusExtra.count, 20)
        try assertSplitJoinRoundTrip(O5CommLogFixtures.cannulaBolusExtra)
        XCTAssertEqual(splitPacketCount(for: O5CommLogFixtures.cannulaBolusExtra), 1)
    }
}
