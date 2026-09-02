//
//  PodTypeO5Tests.swift
//  OmniTests
//

import XCTest
@testable import OmnipodKit

class PodTypeO5Tests: XCTestCase {

    func testO5PodTypeFlags() {
        XCTAssertTrue(omnipod5Type.isO5)
        XCTAssertFalse(omnipod5Type.isDash)
        XCTAssertFalse(omnipod5Type.isEros)
    }

    func testBlePodProfileForO5() {
        let layout = omnipod5Type.blePodProfile.packetLayout
        XCTAssertEqual(layout.maxPayloadSize, 244)
        XCTAssertEqual(OmniTestFixtures.o5BlePacketLayout.maxPayloadSize, 244)
    }
}
