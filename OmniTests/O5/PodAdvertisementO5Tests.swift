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

    func testO5UnpairedAdvertisementOnEveryStatusSuffixIsPairable() {
        XCTAssertEqual(o5UnpairedAdvertisementUUIDs.map { $0.uuidString }, [
            "CE1F923D-C539-48EA-7300-0AFFFFFFFE00",
            "CE1F923D-C539-48EA-7300-0AFFFFFFFE01",
            "CE1F923D-C539-48EA-7300-0AFFFFFFFE02",
            "CE1F923D-C539-48EA-7300-0AFFFFFFFE03",
        ])
        for (suffix, uuid) in o5UnpairedAdvertisementUUIDs.enumerated() {
            let ad = PodAdvertisement(advertisementData(serviceUUID: uuid), podType: omnipod5Type)
            XCTAssertNotNil(ad)
            XCTAssertTrue(ad!.pairable, uuid.uuidString)
            XCTAssertEqual(ad!.o5PdmId, 0xFFFFFFFE)
            XCTAssertEqual(ad!.o5StatusSuffix, UInt8(suffix))
        }
    }

    func testO5UnpairedAdvertisementOutsideTheKnownSuffixesIsNotPairable() {
        let uuid = CBUUID(string: "CE1F923D-C539-48EA-7300-0AFFFFFFFE04")
        let ad = PodAdvertisement(advertisementData(serviceUUID: uuid), podType: omnipod5Type)
        XCTAssertNotNil(ad)
        XCTAssertFalse(ad!.pairable)
        XCTAssertEqual(ad!.o5StatusSuffix, 0x04)
    }

    func testO5AdvertisementWithAnotherPrefixIsNotPairable() {
        let uuid = CBUUID(string: "CE1F923D-C539-48EA-7300-0BFFFFFFFE00")
        let ad = PodAdvertisement(advertisementData(serviceUUID: uuid), podType: omnipod5Type)
        XCTAssertNotNil(ad)
        XCTAssertFalse(ad!.pairable)
    }

    func testO5PairedAttentionAdvertisementIsNotPairable() {
        let controllerId: UInt32 = 0x002A1C6C
        let ad = PodAdvertisement(advertisementData(serviceUUID: o5FaultAdvertisementUUID(controllerId)), podType: omnipod5Type)
        XCTAssertNotNil(ad)
        XCTAssertFalse(ad!.pairable)
        XCTAssertEqual(ad!.o5PdmId, controllerId)
        XCTAssertEqual(ad!.o5StatusSuffix, 0x02)
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
        // An arbitrary second service UUID (formerly the unused O5 "heartbeat" service):
        // any extra service beyond the O5 advertisement makes the advert invalid.
        let uuid2 = CBUUID(string: "ECF301E2-674B-4474-94D0-364F3AA653E6")
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
