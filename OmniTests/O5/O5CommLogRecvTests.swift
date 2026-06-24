//
//  O5CommLogRecvTests.swift
//  OmniTests
//

import XCTest
@testable import OmnipodKit

final class O5CommLogRecvTests: XCTestCase {

    func testTargetBgProfileRecv_matchesSendProfile() {
        XCTAssertEqual(O5CommLogFixtures.targetBgProfileRecvBody.count, 194)
        XCTAssertEqual(O5CommLogFixtures.targetBgProfileRecvBody[0], 0x00)
        XCTAssertEqual(O5CommLogFixtures.targetBgProfileRecvBody[1], 0xc0)
        let profileBytes = O5CommLogFixtures.targetBgProfileRecvBody.subdata(in: 2..<194)
        for offset in stride(from: 0, to: profileBytes.count, by: 4) {
            let mgdl = profileBytes.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            }
            XCTAssertEqual(mgdl, O5CommLogFixtures.targetMgdl)
        }
    }

    func testTdiRecv_matchesDefaultBinary() {
        XCTAssertEqual(O5CommLogFixtures.tdiRecvBody, O5AidCommands.TdiCommand.defaultBinaryData)
    }

    func testUtcRecv_isAsciiZero() {
        XCTAssertEqual(String(data: O5CommLogFixtures.utcRecvBody, encoding: .utf8), "0")
    }

    func testDiaRecv_matchesDefault() {
        XCTAssertEqual(String(data: O5CommLogFixtures.diaRecvBody, encoding: .utf8), O5AidCommands.DiaCommand.defaultValue)
    }

    func testEgvRecv_matchesFixtureValue() {
        XCTAssertEqual(String(data: O5CommLogFixtures.egvRecvBody, encoding: .utf8), O5CommLogFixtures.egvValue)
    }

    func testInsulinHistoryRecv_isAsciiZero() {
        XCTAssertEqual(String(data: O5CommLogFixtures.insulinHistoryRecvBody, encoding: .utf8), "0")
    }
}
