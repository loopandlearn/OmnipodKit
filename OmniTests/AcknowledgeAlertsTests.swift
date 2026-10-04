//
//  AcknowledgeAlertsTests.swift
//  OmniTests
//
//  From OmniBLE/OmniBLETests/AcknowledgeAlertsTests.swift
//  Created by Eelke Jager on 18/09/2018.
//  Copyright © 2018 Pete Schwamb. All rights reserved.
//
import Foundation

import XCTest
@testable import OmnipodKit

class AcknowledgeAlertsTests: XCTestCase {
    func testAcknowledgeLowReservoirAlert() {
        // 11 05 2f9b5b2f 10
        do {
            // Encode
            let encoded = AcknowledgeAlertCommand(nonce: 0x2f9b5b2f, alerts: AlertSet(rawValue: 0x10))
            XCTAssertEqual("11052f9b5b2f10", encoded.data.hexadecimalString)
            
            // Decode
            let cmd = try AcknowledgeAlertCommand(encodedData: Data(hexadecimalString: "11052f9b5b2f10")!)
            XCTAssertEqual(.acknowledgeAlert,cmd.blockType)
            XCTAssertEqual(0x2f9b5b2f, cmd.nonce)
            XCTAssert(cmd.alerts.contains(.slot4LowReservoir))
        } catch (let error) {
            XCTFail("message decoding threw error: \(error)")
        }
    }

    func testAcknowledgeExpiredAlertWithExpirationReminder() {
        // 11 05 494e532e 88: slot 7 (expired) and slot 3 (expiration reminder) together
        let encoded = AcknowledgeAlertCommand(nonce: 0x494e532e, alerts: AlertSet(slots: [.slot7Expired, .slot3ExpirationReminder]))
        XCTAssertEqual("1105494e532e88", encoded.data.hexadecimalString)
    }
}
