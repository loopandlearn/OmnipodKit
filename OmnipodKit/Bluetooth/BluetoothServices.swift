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
    case command = "1A7E2441-E3ED-4464-8B7E-751E03D0DC5F"       // dashOmnipodServiceUUID.service s/4024/2441/
    case data =    "1A7E2442-E3ED-4464-8B7E-751E03D0DC5F"       // dashOmnipodServiceUUID.service s/4024/2442/
}

enum o5OmnipodServiceUUID: String, CBUUIDRawValue {
    case advertisement = "CE1F923D-C539-48EA-7300-0AFFFFFFFE00" // Completely different than DASH & includes the podId
    case service =       "1A7E4024-E3ED-4464-8B7E-751E03D0DC5F" // Same as DASH
}

enum o5OmnipodCharacteristicUUID: String, CBUUIDRawValue {
    case command = "1A7E2441-E3ED-4464-8B7E-751E03D0DC5F"       // Same as DASH, dashOmnipodServiceUUID.service s/4024/2441/
    case data =    "1A7E2443-E3ED-4464-8B7E-751E03D0DC5F"       // dashOmnipodServiceUUID.service s/4024/2443/, O5 has 1A7E2443- while DASH has 1A7E2442-
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

extension PeripheralManager.Configuration {
    static var omnipodDash: PeripheralManager.Configuration {
        return PeripheralManager.Configuration(
            serviceCharacteristics: [
                dashOmnipodServiceUUID.service.cbUUID: [
                    dashOmnipodCharacteristicUUID.command.cbUUID,
                    dashOmnipodCharacteristicUUID.data.cbUUID,
                ]
            ],
            notifyingCharacteristics: [
                dashOmnipodServiceUUID.service.cbUUID: [
//                    dashOmnipodCharacteristicUUID.command.cbUUID,
//                    dashOmnipodCharacteristicUUID.data.cbUUID,
                ]
            ],
            valueUpdateMacros: [
                dashOmnipodCharacteristicUUID.command.cbUUID: { (manager: PeripheralManager) in
                    guard let characteristic = manager.peripheral.getCommandCharacteristic() else { return }
                    guard let value = characteristic.value else { return }

                    manager.log.default("[BLE RAW] CMD RECV: %{public}@", value.hexadecimalString)
                    manager.queueLock.lock()
                    manager.cmdQueue.append(value)
                    manager.queueLock.signal()
                    manager.queueLock.unlock()
                },
                dashOmnipodCharacteristicUUID.data.cbUUID: { (manager: PeripheralManager) in
                    guard let characteristic = manager.peripheral.getDataCharacteristic() else { return }
                    guard let value = characteristic.value else { return }

                    manager.log.default("[BLE RAW] DATA RECV: %{public}@", value.hexadecimalString)
                    manager.queueLock.lock()
                    manager.dataQueue.append(value)
                    manager.queueLock.signal()
                    manager.queueLock.unlock()
                }
            ]
        )
    }

    static var omnipod5: PeripheralManager.Configuration {
        return PeripheralManager.Configuration(
            serviceCharacteristics: [
                o5OmnipodServiceUUID.service.cbUUID: [
                    o5OmnipodCharacteristicUUID.command.cbUUID,
                    o5OmnipodCharacteristicUUID.data.cbUUID,
                ],
                // Discover the heartbeat service and its characteristic for O5 keep-alive
                o5Omnipod5HeartbeatServiceUUID.service.cbUUID: [
                    o5Omnipod5HeartbeatCharacteristicUUID.heartbeat.cbUUID,
                ]
            ],
            notifyingCharacteristics: [
                o5OmnipodServiceUUID.service.cbUUID: [
//                    o5OmnipodCharacteristicUUID.command.cbUUID,
//                    o5OmnipodCharacteristicUUID.data.cbUUID,
                ],
                // Subscribe to heartbeat notifications for O5 pod keep-alive
                o5Omnipod5HeartbeatServiceUUID.service.cbUUID: [
                    o5Omnipod5HeartbeatCharacteristicUUID.heartbeat.cbUUID,
                ]
            ],
            valueUpdateMacros: [
                o5OmnipodCharacteristicUUID.command.cbUUID: { (manager: PeripheralManager) in
                    guard let characteristic = manager.peripheral.getCommandCharacteristic() else { return }
                    guard let value = characteristic.value else { return }

                    manager.log.default("[BLE RAW] CMD RECV: %{public}@", value.hexadecimalString)
                    manager.queueLock.lock()
                    manager.cmdQueue.append(value)
                    manager.queueLock.signal()
                    manager.queueLock.unlock()
                },
                o5OmnipodCharacteristicUUID.data.cbUUID: { (manager: PeripheralManager) in
                    guard let characteristic = manager.peripheral.getDataCharacteristic() else { return }
                    guard let value = characteristic.value else { return }

                    manager.log.default("[BLE RAW] DATA RECV: %{public}@", value.hexadecimalString)
                    manager.queueLock.lock()
                    manager.dataQueue.append(value)
                    manager.queueLock.signal()
                    manager.queueLock.unlock()
                },
                // Handle heartbeat notifications from the pod
                o5Omnipod5HeartbeatCharacteristicUUID.heartbeat.cbUUID: { (manager: PeripheralManager) in
                    manager.handleHeartbeat()
                }
            ]
        )
    }
}

// Quick hack to deal with DASH and O5 BLE Service and Attribute differences
private var servicePodType: PodType = dashType

func setServicePodType(podType: PodType) {
    assert(podType == dashType || podType == omnipod5Type)
    servicePodType = podType

    // JJJ update the former constant MAX_SIZE for packets
    // JJJ figure out a cleaner way to do manage this and
    // other such constants which vary between DASH and O5.
    if podType == dashType {
        BlePacket_MAX_PAYLOAD_SIZE = 20
    } else {
        // The max BLE Packet size is 256, but there is a 12 byte header that is invisible to us, so for our purposes the max is 256-12=244.
        BlePacket_MAX_PAYLOAD_SIZE = 244
    }

    FirstBlePacket_CAPACITY_WITHOUT_MIDDLE_PACKETS = BlePacket_MAX_PAYLOAD_SIZE - BleFirstPacket_HEADER_SIZE_WITHOUT_MIDDLE_PACKETS
    FirstBlePacket_CAPACITY_WITH_MIDDLE_PACKETS = BlePacket_MAX_PAYLOAD_SIZE - BleFirstPacket_HEADER_SIZE_WITH_MIDDLE_PACKETS
    FirstBlePacket_CAPACITY_WITH_THE_OPTIONAL_PLUS_ONE_PACKET = FirstBlePacket_CAPACITY_WITH_MIDDLE_PACKETS

    MiddleBlePacket_CAPACITY = BlePacket_MAX_PAYLOAD_SIZE - 1

    LastBlePacket_CAPACITY = BlePacket_MAX_PAYLOAD_SIZE - LastBlePacket_HEADER_SIZE
}

var OmnipodServiceUUID_advertisement_cbUUID: CBUUID {
    if servicePodType == omnipod5Type {
        return o5OmnipodServiceUUID.advertisement.cbUUID
    }
    return dashOmnipodServiceUUID.advertisement.cbUUID
}

var OmnipodServiceUUID_service_cbUUID: CBUUID {
    if servicePodType == omnipod5Type {
        return o5OmnipodServiceUUID.service.cbUUID
    }
    return dashOmnipodServiceUUID.service.cbUUID
}

var OmnipodCharacteristicUUID_command_cbUUID: CBUUID {
    if servicePodType == omnipod5Type {
        return o5OmnipodCharacteristicUUID.command.cbUUID
    }
    return dashOmnipodCharacteristicUUID.command.cbUUID
}

var OmnipodCharacteristicUUID_data_cbUUID: CBUUID {
    if servicePodType == omnipod5Type {
        return o5OmnipodCharacteristicUUID.data.cbUUID
    }
    return dashOmnipodCharacteristicUUID.data.cbUUID
}
