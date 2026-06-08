//
//  O5AidCommandsTests.swift
//  OmniTests
//

import XCTest
@testable import OmnipodKit

class O5AidCommandsTests: XCTestCase {

    func testUtcCommand() {
        let (payload, prefix) = O5AidCommands.UtcCommand.payload(timestamp: O5CommLogFixtures.utcTimestamp)
        XCTAssertEqual(payload, O5CommLogFixtures.utcSend)
        XCTAssertEqual(prefix, "ES255.2=")
        XCTAssertEqual(String(data: O5CommLogFixtures.utcRecvBody, encoding: .utf8), "0")
    }

    func testTdiCommand() {
        let (payload, prefix) = O5AidCommands.TdiCommand.payload()
        XCTAssertEqual(payload, O5CommLogFixtures.tdiSend)
        XCTAssertEqual(prefix, "3.2=")
        XCTAssertEqual(O5CommLogFixtures.tdiRecvBody, O5AidCommands.TdiCommand.defaultBinaryData)
    }

    func testTargetBgProfile() {
        let (payload, prefix) = O5AidCommands.TargetBgProfileCommand.payload()
        XCTAssertEqual(payload, O5CommLogFixtures.targetBgProfileSend)
        XCTAssertEqual(prefix, "3.1=")
        XCTAssertEqual(O5CommLogFixtures.targetBgProfileRecvBody.count, 194)
    }

    func testDiaCommand() {
        let (payload, prefix) = O5AidCommands.DiaCommand.payload()
        XCTAssertEqual(payload, O5CommLogFixtures.diaSend)
        XCTAssertEqual(prefix, "3.9=")
        XCTAssertEqual(String(data: O5CommLogFixtures.diaRecvBody, encoding: .utf8), O5AidCommands.DiaCommand.defaultValue)
    }

    func testEgvCommand() {
        let (payload, prefix) = O5AidCommands.EgvCommand.payload(value: O5CommLogFixtures.egvValue)
        XCTAssertEqual(payload, O5CommLogFixtures.egvSend)
        XCTAssertEqual(prefix, "3.7=")
        XCTAssertEqual(String(data: O5CommLogFixtures.egvRecvBody, encoding: .utf8), O5CommLogFixtures.egvValue)
    }

    func testAlgorithmInsulinHistory() {
        let (payload, prefix) = O5AidCommands.AlgorithmInsulinHistoryCommand.payload()
        XCTAssertEqual(payload, O5CommLogFixtures.algorithmInsulinHistorySend)
        XCTAssertEqual(prefix, "SE2.1=")
        XCTAssertEqual(String(data: O5CommLogFixtures.insulinHistoryRecvBody, encoding: .utf8), "0")
    }

    func testTargetBgProfile_payloadSize() {
        let (payload, _) = O5AidCommands.TargetBgProfileCommand.payload()
        XCTAssertEqual(payload.count, 204)
    }

    func testAlgorithmInsulinHistory_payloadSize() {
        let (payload, _) = O5AidCommands.AlgorithmInsulinHistoryCommand.payload()
        XCTAssertEqual(payload.count, 176)
        let prefix = Data("SE2.1=".utf8)
        XCTAssertTrue(payload.starts(with: prefix))
        XCTAssertEqual(payload[prefix.count], 0x00)
        XCTAssertEqual(payload[prefix.count + 1], 0xA8)
    }

    func testAidPodStatus_getOnly() {
        let (g311, p311) = O5AidCommands.AidPodStatusCommand.payload()
        XCTAssertEqual(g311, Data("G3.11".utf8))
        XCTAssertEqual(p311, "3.11=")

        let (g312, p312) = O5AidCommands.UnifiedAidPodStatusCommand.payload()
        XCTAssertEqual(g312, Data("G3.12".utf8))
        XCTAssertEqual(p312, "3.12=")
    }

    func testResponsePrefixes() {
        XCTAssertEqual(O5AidCommands.responsePrefix(feature: "3", attribute: "9"), "3.9=")
        XCTAssertEqual(O5AidCommands.extendedSetResponsePrefix(feature: "255", attribute: "2"), "ES255.2=")
    }
}
