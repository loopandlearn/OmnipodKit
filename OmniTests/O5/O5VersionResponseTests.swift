//
//  O5VersionResponseTests.swift
//  OmniTests
//

import XCTest
@testable import OmnipodKit

final class O5VersionResponseTests: XCTestCase {

    func testParsingShortO5AssignVersionResponse() throws {
        let config = try VersionResponse(encodedData: O5CommLogFixtures.assignVersionResponse)
        XCTAssertEqual(config.data.count, 23)
        XCTAssertTrue(config.isAssignAddressVersionResponse)
        XCTAssertEqual(String(describing: config.firmwareVersion), "9.0.3")
        XCTAssertEqual(String(describing: config.iFirmwareVersion), "6.0.2")
        XCTAssertEqual(config.podType, omnipod5Type)
        XCTAssertEqual(config.podProgressStatus, .reminderInitialized)
        XCTAssertEqual(config.lot, O5CommLogFixtures.capturedLot)
        XCTAssertEqual(config.tid, O5CommLogFixtures.capturedTid)
        XCTAssertEqual(config.address, O5CommLogFixtures.assignVersionResponseAddress)
        XCTAssertNil(config.gain)
        XCTAssertNil(config.rssi)
        XCTAssertNil(config.pulseSize)
    }

    func testParsingLongO5SetupVersionResponse() throws {
        let config = try VersionResponse(encodedData: O5CommLogFixtures.setupVersionResponse)
        XCTAssertEqual(config.data.count, 29)
        XCTAssertTrue(config.isSetupPodVersionResponse)
        XCTAssertEqual(String(describing: config.firmwareVersion), "9.0.3")
        XCTAssertEqual(String(describing: config.iFirmwareVersion), "6.0.2")
        XCTAssertEqual(config.podType, omnipod5Type)
        XCTAssertEqual(config.podProgressStatus, .pairingCompleted)
        XCTAssertEqual(config.lot, O5CommLogFixtures.capturedLot)
        XCTAssertEqual(config.tid, O5CommLogFixtures.capturedTid)
        XCTAssertEqual(config.address, O5CommLogFixtures.capturedPodAddress)
        XCTAssertNil(config.gain)
        XCTAssertNil(config.rssi)
        XCTAssertEqual(Pod.pulseSize, config.pulseSize)
        XCTAssertEqual(Pod.secondsPerBolusPulse, config.secondsPerBolusPulse)
        XCTAssertEqual(Pod.secondsPerPrimePulse, config.secondsPerPrimePulse)
        XCTAssertEqual(Pod.primeUnits, config.primeUnits)
        XCTAssertEqual(Pod.cannulaInsertionUnits, config.cannulaInsertionUnits)
        XCTAssertEqual(Pod.serviceDuration, config.serviceDuration)
    }

    func testVersionResponse_o5NotErosOrDash() throws {
        let assign = try VersionResponse(encodedData: O5CommLogFixtures.assignVersionResponse)
        let setup = try VersionResponse(encodedData: O5CommLogFixtures.setupVersionResponse)
        for config in [assign, setup] {
            XCTAssertTrue(config.podType.isO5)
            XCTAssertFalse(config.podType.isEros)
            XCTAssertFalse(config.podType.isDash)
        }
    }
}
