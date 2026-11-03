//
//  SqnEncodingTests.swift
//  OmniTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
@testable import OmnipodKit

class SqnEncodingTests: XCTestCase {

    func testEapSqnRoundTrip() throws {
        let sqn = try EapSqn(data: Data(hexadecimalString: "000000000423")!)
        XCTAssertEqual(sqn.toInt(), 1059)
        XCTAssertEqual(EapSqn(int: 1059).data.hexadecimalString, "000000000423")
        XCTAssertEqual(sqn.increment().data.hexadecimalString, "000000000424")
    }

    func testEapSqnUsesAllSixBytes() throws {
        let sqn = try EapSqn(data: Data(hexadecimalString: "0102030405ff")!)
        XCTAssertEqual(sqn.toInt(), 0x0102030405ff)
    }

    func testNonceSqnBytes() {
        let prefix = Data(hexadecimalString: "6cff5d18b7616cae")!
        let nonce = Nonce(prefix: prefix)
        XCTAssertEqual(nonce.toData(sqn: 23, podReceiving: true).hexadecimalString, "6cff5d18b7616cae0000000017")
        XCTAssertEqual(nonce.toData(sqn: 23, podReceiving: false).hexadecimalString, "6cff5d18b7616cae8000000017")
    }

    func testIdFromInt() {
        XCTAssertEqual(Id.fromInt(136326824).toUInt32(), 136326824)
    }
}
