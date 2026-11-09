//
//  PodStateTests.swift
//  OmniTests
//
//  From OmniBLE/OmniBLETests/PodStateTests.swift
//  Created by Pete Schwamb on 10/13/17.
//  Copyright © 2017 Pete Schwamb. All rights reserved.
//

import XCTest
@testable import OmnipodKit

class PodStateTests: XCTestCase {
    
    func testErrorResponse() {
        do {
            let errorResponse = try ErrorResponse(encodedData: Data(hexadecimalString: "0603070008019a")!)

            switch errorResponse.errorResponseType {
            case .nonretryableError(let errorCode, let faultEventCode, let podProgress):
                XCTAssertEqual(7, errorCode)
                XCTAssertEqual(.noFaults, faultEventCode.faultType)
                XCTAssertEqual(.aboveFiftyUnits, podProgress)
                break
            default:
                XCTFail("Unexpected bad nonce response")
                break
            }
        } catch (let error) {
            XCTFail("message decoding threw error: \(error)")
        }
    }

    func testLTKAndBLEIdentifierDecodeIndependently() throws {
        let ltk = Data(hexadecimalString: "fedcba98765432100123456789abcdef")!
        let handle = "0B1D2C3E-0000-4000-8000-00000000A001"
        let pod = PodState(address: 0x17A6219A, firmwareVersion: "4.10.0", iFirmwareVersion: "1.1.0",
                           lotNo: 43620, lotSeq: 560313, insulinType: .novolog, podType: dashType,
                           ltk: ltk, bleIdentifier: handle)

        var withoutHandle = pod.rawValue
        withoutHandle.removeValue(forKey: "bleIdentifier")
        let decodedWithoutHandle = try XCTUnwrap(PodState(rawValue: withoutHandle))
        XCTAssertEqual(decodedWithoutHandle.ltk, ltk)
        XCTAssertNil(decodedWithoutHandle.bleIdentifier)

        var withoutKey = pod.rawValue
        withoutKey.removeValue(forKey: "ltk")
        let decodedWithoutKey = try XCTUnwrap(PodState(rawValue: withoutKey))
        XCTAssertNil(decodedWithoutKey.ltk)
        XCTAssertEqual(decodedWithoutKey.bleIdentifier, handle)
    }
}

