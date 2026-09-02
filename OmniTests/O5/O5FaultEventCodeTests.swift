//
//  O5FaultEventCodeTests.swift
//  OmniTests
//

import XCTest
@testable import OmnipodKit

final class O5FaultEventCodeTests: XCTestCase {

    private let o5OnlyRawValues: [UInt8] = [
        0x98, 0x99, 0x9A,
        0xA3, 0xA4, 0xA5,
        0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF,
        0xC4, 0xC5, 0xC7, 0xC8, 0xC9, 0xCA,
        0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9,
    ]

    private let dashAndO5RawValues: [UInt8] = [
        0xA0, 0xA1, 0xA2, 0xA6, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAF,
        0xB1, 0xB2, 0xB4,
        0xC0, 0xC1, 0xC2, 0xC3,
    ]

    func testO5OnlyFault_rawValues_matchEnum() {
        for raw in o5OnlyRawValues {
            let code = FaultEventCode(rawValue: raw)
            XCTAssertNotNil(code.faultType, "O5-only fault 0x\(String(raw, radix: 16)) must map to FaultEventType")
        }
    }

    func testO5OnlyFault_descriptions_nonEmpty() {
        for raw in o5OnlyRawValues {
            let description = FaultEventCode(rawValue: raw).faultDescription
            XCTAssertFalse(description.isEmpty, "O5-only fault 0x\(String(raw, radix: 16)) needs a description")
            XCTAssertNotEqual(description, "Unknown fault", "O5-only fault 0x\(String(raw, radix: 16)) must not fall through to unknown")
            XCTAssertNotEqual(description, "Unknown fault code", "O5-only fault 0x\(String(raw, radix: 16)) must not fall through to unknown")
        }
    }

    func testDashAndO5SharedFault_descriptions_nonEmpty() {
        for raw in dashAndO5RawValues {
            let description = FaultEventCode(rawValue: raw).faultDescription
            XCTAssertFalse(description.isEmpty, "DASH/O5 fault 0x\(String(raw, radix: 16)) needs a description")
            XCTAssertNotEqual(description, "Unknown fault")
            XCTAssertNotEqual(description, "Unknown fault code")
        }
    }

    func testFaultEventCode_equatable() {
        XCTAssertEqual(FaultEventCode(rawValue: 0x98), FaultEventCode(rawValue: 0x98))
        XCTAssertNotEqual(FaultEventCode(rawValue: 0x98), FaultEventCode(rawValue: 0x99))
    }
}
