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

    func testCancelAfterScheduledEndAppliesBolusNotDelivered() {
        var podState = PodState(address: 521580830, firmwareVersion: "2.7.0", iFirmwareVersion: "2.7.0", lotNo: 43620, lotSeq: 560313, insulinType: .novolog, podType: dashType, ltk: Data(hexadecimalString: "fedcba98765432100123456789abcdef")!, bleIdentifier: "0000-0000")
        let start = Date().addingTimeInterval(.hours(-1))
        podState.unfinalizedBolus = UnfinalizedDose(doseId: nil, bolusAmount: 4, startTime: start, scheduledCertainty: .certain, insulinType: .novolog)
        let rate = podState.unfinalizedBolus!.rate

        _ = podState.handleCancelDosing(deliveryType: .all, bolusNotDelivered: 1.8, at: Date())

        XCTAssertEqual(2.2, podState.unfinalizedBolus!.units, accuracy: 0.01)
        XCTAssertEqual(start.addingTimeInterval(.hours(2.2 / rate)).timeIntervalSince1970, podState.unfinalizedBolus!.finishTime!.timeIntervalSince1970, accuracy: 1)
    }

    func testCancelDoesNotSubtractBolusNotDeliveredTwice() {
        var podState = PodState(address: 521580830, firmwareVersion: "2.7.0", iFirmwareVersion: "2.7.0", lotNo: 43620, lotSeq: 560313, insulinType: .novolog, podType: dashType, ltk: Data(hexadecimalString: "fedcba98765432100123456789abcdef")!, bleIdentifier: "0000-0000")
        let start = Date().addingTimeInterval(.hours(-1))
        podState.unfinalizedBolus = UnfinalizedDose(doseId: nil, bolusAmount: 4, startTime: start, scheduledCertainty: .certain, insulinType: .novolog)
        let canceledAt = start.addingTimeInterval(.seconds(30))
        // A recovered unacknowledged cancel has already applied the remaining 1 U
        podState.unfinalizedBolus!.cancel(at: canceledAt, withRemaining: 1)

        for faultTime in [start.addingTimeInterval(.seconds(20)), start.addingTimeInterval(.seconds(40))] {
            var state = podState
            _ = state.handleCancelDosing(deliveryType: .all, bolusNotDelivered: 1, at: faultTime)
            XCTAssertEqual(3, state.unfinalizedBolus!.units, accuracy: 0.01)
        }
    }
}

