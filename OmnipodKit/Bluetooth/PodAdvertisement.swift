//
//  PodAdvertisement.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/PumpManager/PodAdvertisement.swift
//  Created by Pete Schwamb on 1/13/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import CoreBluetooth

extension String {
    func subString(location: Int, length: Int? = nil) -> String {
      let start = min(max(0, location), self.count)
      let limitedLength = min(self.count - start, length ?? Int.max)
      let from = index(startIndex, offsetBy: start)
      let to = index(startIndex, offsetBy: start + limitedLength)
      return String(self[from..<to])
    }
}

struct PodAdvertisement {
    let DASH_MAIN_SERVICE_UUID = "4024"
    let DASH_UNKNOWN_THIRD_SERVICE_UUID = "000A"

    var podType: PodType

    var serviceUUIDs: [CBUUID]

    var pairable: Bool {
        if podType.isDash {
            // For DASH, serviceUUIDs 3 & 4 are the podId and will be "FFFF" & "FFFE" only before pairing
            return serviceUUIDs.count >= 5 &&
                   serviceUUIDs[3].uuidString.uppercased() == "FFFF" &&
                   serviceUUIDs[4].uuidString.uppercased() == "FFFE"
        }

        if podType.isO5 {
            // For O5, serviceUUID[0] will have an imbedded pdmId of "FFFFFFFE" only before pairing
            return serviceUUIDs[0].uuidString == o5OmnipodServiceUUID.advertisement.rawValue
        }

        return false
    }

    init?(_ advertisementData: [String: Any], podType: PodType) {
        guard let serviceUUIDs = advertisementData["kCBAdvDataServiceUUIDs"] as? [CBUUID] else {
            return nil
        }

        self.serviceUUIDs = serviceUUIDs
        self.podType = podType

        switch podType {
        case dashType:
            guard serviceUUIDs.count == 9 else {
                return nil
            }

            guard serviceUUIDs[0].uuidString == DASH_MAIN_SERVICE_UUID else {
                return nil
            }

            guard serviceUUIDs[2].uuidString == DASH_UNKNOWN_THIRD_SERVICE_UUID else {
                return nil
            }

            guard let decodedPodId = UInt32(serviceUUIDs[3].uuidString + serviceUUIDs[4].uuidString, radix: 16) else {
                return nil
            }

            let lotNoString: String = serviceUUIDs[5].uuidString + serviceUUIDs[6].uuidString + serviceUUIDs[7].uuidString
            guard let decodedLotNo = UInt64(lotNoString[lotNoString.startIndex..<lotNoString.index(lotNoString.startIndex, offsetBy: 10)], radix: 16) else {
                return nil
            }

            let seqString: String = serviceUUIDs[7].uuidString + serviceUUIDs[8].uuidString
            guard let decodedSeqNo = UInt32(seqString[seqString.index(seqString.startIndex, offsetBy: 2)..<seqString.endIndex], radix: 16) else {
                return nil
            }

            print("DASH advertisement: pod id: \(decodedPodId), lot: \(decodedLotNo), seq: \(decodedSeqNo)")

        case omnipod5Type:

            // serviceUUIDs.count[0] is "CE1F923D-C539-48EA-7300-0AFFFFFFFE00" before pairing
            guard serviceUUIDs.count == 1 else {
                return nil
            }

            let idString = serviceUUIDs[0].uuidString
            guard strlen(idString) == 36 else {
                print("Unexpected length of UUID string: \(idString): \(strlen(idString))")
                return nil
            }

            // idString is "CE1F923D-C539-48EA-7300-0A<hexPdmId>00" (pdmID = 0xFFFFFFFE before pairing)
            //              012345678901234567890123456789012345
            //                        1         2         3
            let pdmIdStr = idString.subString(location: 26, length: 8)
            guard let decodedPdmId = UInt32(pdmIdStr, radix: 16) else {
                print("Could not decode pdmId from \(idString)")
                return nil
            }

            print("O5 advertisement PDM id: \(decodedPdmId)")

        default:
            return nil
        }
    }
}
