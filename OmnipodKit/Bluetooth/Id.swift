//
//  Id.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/Id.swift
//  Created by Randall Knutson on 8/5/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import Foundation

// For O5, the controller ID comes from the TLS certificate's pdmid via O5CertificateStore.
// For DASH, the controller ID is randomly generated with the pod type's topIdByte.

class Id: Equatable {

    static func fromInt(_ v: Int) -> Id {
        return Id(Data(bigEndian: v).subdata(in: 4..<8))
    }

    static func fromUInt32(_ v: UInt32) -> Id {
        return Id(Data(bigEndian: v))
    }

    let address: Data

    init(_ address: Data) {
        guard address.count == 4 else {
            // TODO: Should probably throw an error here.
            //        require(address.size == 4)
            self.address = Data([0x00, 0x00, 0x00, 0x00])
            return
        }
        self.address = address
    }

    func toInt64() -> Int64 {
        return address.toBigEndian(Int64.self)
    }

    func toUInt32() -> UInt32 {
        return address.toBigEndian(UInt32.self)
    }

    // MARK: Comparable

    static func == (lhs: Id, rhs: Id) -> Bool {
        return lhs.address == rhs.address
    }
}

/// Return the next (controllerId, podId) for the given pod type and current values (0 = not set).
/// The controllerId and set of 3 podId's will be used until the pump manager is deleted
/// or in the case of the O5, the certificate store no longer has data for our controllerId.
/// For O5 will initialize or reset controllerId based on the O5 certificate
/// store and will return with a controllerId of 0 if no certificates are available.
///
/// The Dash PDM uses the PDM's SN shifted left 2 for the bottom 5 nibbles with
/// some unknown values for the top 3 nibbles of its fixed 32-bit controller ID.
/// The Dash & OmniBLE podId's cycle between 3 #'s of controllerId+1, +2, +3, +1, ...
/// OmniBLE faked this by using a random 22-bit number shifted left 2 for the controllerId
/// and using a unique nibble top byte value of 0x17 (similar to Eros using a fixed 0x1F here).
///
/// The O5 PDM also uses the original PDM's SN shifted left 2 for the basis of its controllerId,
/// however this value is stored in the certificate and apparently checked by the pod so it can't
/// be used as a base for a set of rotating podIds that will be semi-unique across for all users.
func nextIds(podType: PodType, controllerId: UInt32 = 0, podId: UInt32 = 0) -> (controllerId: UInt32, podId: UInt32) {
    var myControllerId = controllerId
    var basePodId = podId

    if podType.isDash {
        if controllerId == 0 {
            // Create a new semi-randomized base DASH controllerId
            myControllerId = createControllerId(podType: podType)
            basePodId = myControllerId // so nextPodId will be myControllerId + 1
        }
        // else a typical situation to keep the controllerId and rotate the podId
    } else {
        // For O5, the created controllerId must match a value in the O5 CertificateStore
        if controllerId == 0 || !O5CertificateStore.contains(controllerId) {
            // Select a new controllerId, will be 0 if none currently available
            myControllerId = O5CertificateStore.pickControllerId
            basePodId = myControllerId // so nextPodId will be myControllerId + 1
        }
        // else a typical situation to keep the controllerId and rotate the podId
    }

    if controllerId == 0 {
        // Return the newly created controllerId with a podId of one more
        return (controllerId: myControllerId, podId: myControllerId + 1)
    }

    // Return the original controllerId and the next podId in the rotation
    return (controllerId: myControllerId, podId: nextPodId(lastPodId: basePodId))
}

/// The podId's cycle between 3 #'s of +1,+2,+3,+1, ...
/// This seems to be required for O5 pods, but not for DASH pods
fileprivate let controllerIdBitMask: UInt32 = 0b11

/// Returns the controllerId for the specified podId
func controllerIdForPodId(podId: UInt32) -> UInt32 {
    return podId & ~controllerIdBitMask
}

fileprivate func nextPodId(lastPodId: UInt32) -> UInt32 {
    if (lastPodId & controllerIdBitMask) == controllerIdBitMask {
        // start over at the base + 1
        return (lastPodId & ~controllerIdBitMask) + 1
    }
    // return the next sequential podId #
    return lastPodId + 1
}

/// Creates a base controllerId to be used directly (DASH) or as a fake
/// controllerId base to be used as the base for the rotating podId's (O5).
/// The top byte will be set for the given pod type, the bottom 2 bits will be
/// clear for use with the cycling 3 podIds, while the other 22 bits are random.
fileprivate func createControllerId(podType: PodType) -> UInt32 {
    return (UInt32(podType.topIdByte) << 24) | ((arc4random() & 0x003FFFFF) << 2)
}
