//
//  BluetoothServices.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/BluetoothServices.swift
//  Created by Randall Knutson on 11/01/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import CoreBluetooth

protocol CBUUIDRawValue: RawRepresentable {}
extension CBUUIDRawValue where RawValue == String {
    var cbUUID: CBUUID {
        return CBUUID(string: rawValue)
    }
}

enum PodCommand: UInt8 {
    case RTS = 0x00
    case CTS = 0x01
    case NACK = 0x02
    case ABORT = 0x03
    case SUCCESS = 0x04
    case FAIL = 0x05
    case HELLO = 0x06
    case PAIR_STATUS = 0x08  // Intermediate status during O5 pairing, skip while waiting for SUCCESS
    case INCORRECT = 0x09
}

enum dashOmnipodServiceUUID: String, CBUUIDRawValue {
    case advertisement = "00004024-0000-1000-8000-00805f9b34fb"
    case service =       "1A7E4024-E3ED-4464-8B7E-751E03D0DC5F"
}

enum dashOmnipodCharacteristicUUID: String, CBUUIDRawValue {
    case command = "1A7E2441-E3ED-4464-8B7E-751E03D0DC5F"       // Similar to service UUID, but with 2441 instead of 4024
    case data =    "1A7E2442-E3ED-4464-8B7E-751E03D0DC5F"       // Similar to service UUID, but with 2442 instead of 4024
}

// The o5OmnipodServiceUUID advertisement changes when paired to include the pdmId
func o5ServiceAdvertisementUUID(_ pdmId: UInt32) -> CBUUID {
    // See o5OmnipodServiceUUID.advertisement for the initial value
    let uuidString = String(format: "CE1F923D-C539-48EA-7300-0A%08llX00", pdmId)
    return CBUUID(string: uuidString)
}

enum o5OmnipodServiceUUID: String, CBUUIDRawValue {
    case advertisement = "CE1F923D-C539-48EA-7300-0AFFFFFFFE00" // i.e., o5ServiceAdvertisementUUID(0xFFFFFFFE).uuidString
    case service =       "1A7E4024-E3ED-4464-8B7E-751E03D0DC5F" // Same as DASH
}

enum o5OmnipodCharacteristicUUID: String, CBUUIDRawValue {
    case command = "1A7E2441-E3ED-4464-8B7E-751E03D0DC5F"       // Same as DASH
    case data =    "1A7E2443-E3ED-4464-8B7E-751E03D0DC5F"       // Similar to DASH, but with 2443 instead of 2442
}

// Omnipod 5 Heartbeat Service - used for O5 pod keep-alive
enum o5Omnipod5HeartbeatServiceUUID: String, CBUUIDRawValue {
    case advertisement = "ECF301E2-674B-4474-94D0-364F3AA653E6"
    case service =       "7DED7A6C-CA72-46A7-A3A2-6061F6FDCAEB"
}

enum o5Omnipod5HeartbeatCharacteristicUUID: String, CBUUIDRawValue {
    // The heartbeat characteristic UUID - to be confirmed via BLE service discovery
    case heartbeat = "7DED7A6D-CA72-46A7-A3A2-6061F6FDCAEB"
}
