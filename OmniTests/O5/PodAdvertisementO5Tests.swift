//
//  PodAdvertisementO5Tests.swift
//  OmniTests
//

import XCTest
import CoreBluetooth
@testable import OmnipodKit

class PodAdvertisementO5Tests: XCTestCase {

    private func advertisementData(serviceUUID: CBUUID) -> [String: Any] {
        ["kCBAdvDataServiceUUIDs": [serviceUUID]]
    }

    func testO5PairableAdvertisement() {
        let uuid = CBUUID(string: o5OmnipodServiceUUID.advertisement.rawValue)
        let ad = PodAdvertisement(advertisementData(serviceUUID: uuid), podType: omnipod5Type)
        XCTAssertNotNil(ad)
        XCTAssertTrue(ad!.pairable)
        XCTAssertEqual(ad!.serviceUUIDs.count, 1)
    }

    func testO5PdmIdDecoding() {
        let uuid = CBUUID(string: o5OmnipodServiceUUID.advertisement.rawValue)
        let ad = PodAdvertisement(advertisementData(serviceUUID: uuid), podType: omnipod5Type)
        XCTAssertNotNil(ad)

        let idString = uuid.uuidString
        let pdmIdStr = idString.subString(location: 26, length: 8)
        XCTAssertEqual(UInt32(pdmIdStr, radix: 16), 0xFFFFFFFE)
    }

    func testO5PdmIdDecoding_afterPairingFormat() {
        let controllerId: UInt32 = 0x002A1C6C
        let uuid = o5ServiceAdvertisementUUID(controllerId)
        XCTAssertEqual(uuid.uuidString, String(format: "CE1F923D-C539-48EA-7300-0A%08X00", controllerId))

        let ad = PodAdvertisement(advertisementData(serviceUUID: uuid), podType: omnipod5Type)
        XCTAssertNotNil(ad)
        XCTAssertFalse(ad!.pairable)

        let pdmIdStr = uuid.uuidString.subString(location: 26, length: 8)
        XCTAssertEqual(UInt32(pdmIdStr, radix: 16), controllerId)
    }

    func testO5InvalidServiceCount() {
        let uuid1 = CBUUID(string: o5OmnipodServiceUUID.advertisement.rawValue)
        let uuid2 = CBUUID(string: o5Omnipod5HeartbeatServiceUUID.advertisement.rawValue)
        XCTAssertNotNil(PodAdvertisement(advertisementData(serviceUUID: uuid1), podType: omnipod5Type))
        XCTAssertNil(
            PodAdvertisement(
                ["kCBAdvDataServiceUUIDs": [uuid1, uuid2]],
                podType: omnipod5Type
            )
        )
        XCTAssertNil(PodAdvertisement([:], podType: omnipod5Type))
    }
}
