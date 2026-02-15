//
//  PeripheralManager+OmnipodKit.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/PeripheralManager+OmniBLE.swift
//  Created by Randall Knutson on 11/2/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import CoreBluetooth


enum SendMessageResult {
    case sentWithAcknowledgment
    case sentWithError(Error)
    case unsentWithError(Error)
}

extension PeripheralManager {
    
    /// - Throws: PeripheralManagerError
    func sendHello(myId: UInt32) throws {
        dispatchPrecondition(condition: .onQueue(queue))

        let controllerId = Id.fromUInt32(myId).address
        guard let characteristic = peripheral.getCommandCharacteristic() else {
            throw PeripheralManagerError.notReady
        }

        try writeValue(Data([PodCommand.HELLO.rawValue, 0x01, 0x04]) + controllerId, for: characteristic, type: .withResponse, timeout: 5)
    }
    
    func enableNotifications() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let cmdChar = peripheral.getCommandCharacteristic() else {
            throw PeripheralManagerError.notReady
        }
        guard let dataChar = peripheral.getDataCharacteristic() else {
            throw PeripheralManagerError.notReady
        }
        try setNotifyValue(true, for: cmdChar, timeout: .seconds(2))
        try setNotifyValue(true, for: dataChar, timeout: .seconds(2))
    }
        
    func sendMessagePacket(_ message: MessagePacket, _ forEncryption: Bool = false, doRTS: Bool = true) -> SendMessageResult {
        dispatchPrecondition(condition: .onQueue(queue))
        
        var didSend = false

        do {
            if doRTS {
                try requestToSend()
                try waitForCommand(PodCommand.CTS, timeout: 5)
            }

            let splitter = PayloadSplitter(payload: message.asData(forEncryption: forEncryption))
            let packets = splitter.splitInPackets()

            for (index, packet) in packets.enumerated() {
                // Consider starting the last packet send as the point at which the message may be received by the pod.
                // A failure after data is actually sent, but before the sendData() returns can still be received.
                if index == packets.count - 1 {
                    didSend = true
                }
                try sendData(packet.toData(), timeout: 5)
                try self.peekForNack()
            }

            try waitForCommand(PodCommand.SUCCESS, timeout: 5)
        } catch {
            if didSend {
                return .sentWithError(error)
            } else {
                return .unsentWithError(error)
            }
        }
        return .sentWithAcknowledgment
    }
    
    /// - Throws: PeripheralManagerError
    func readMessagePacket(doRTS: Bool = true) throws -> MessagePacket? {
        dispatchPrecondition(condition: .onQueue(queue))

        var packet: MessagePacket?

        do {
            if doRTS {
                try waitForCommand(PodCommand.RTS)
                try sendCommandType(PodCommand.CTS)
            }

            var expected: UInt8 = 0

            let firstPacket = try waitForData(sequence: expected, timeout: 5)

            let joiner = try PayloadJoiner(firstPacket: firstPacket)

            if joiner.fullFragments > 0 {
                for _ in 1...joiner.fullFragments {
                    expected += 1
                    let packet = try waitForData(sequence: expected, timeout: 5)
                    try joiner.accumulate(packet: packet)
                }
            }
            if joiner.oneExtraPacket {
                expected += 1
                let packet = try waitForData(sequence: expected, timeout: 5)
                try joiner.accumulate(packet: packet)
            }
            let fullPayload = try joiner.finalize()
            try  sendCommandType(PodCommand.SUCCESS)
            packet = try MessagePacket.parse(payload: fullPayload)
        } catch {
            log.error("Error reading message: %{public}@", error.localizedDescription)
            if let error = error as? PeripheralManagerError, error.isSymptomaticOfUnresponsivePod {
                if peripheral.state == .connected {
                    log.error("Disconnecting due to error while reading pod response")
                    central?.cancelPeripheralConnection(peripheral)
                }
            } else {
                try? sendCommandType(PodCommand.NACK)
            }
            throw PeripheralManagerError.incorrectResponse
        }

        return packet
    }

    /// - Throws: PeripheralManagerError
    func peekForNack() throws -> Void {
        dispatchPrecondition(condition: .onQueue(queue))

        // Lock to protect cmdQueue
        queueLock.lock()
        defer {
            queueLock.unlock()
        }

        if cmdQueue.contains(where: { cmd in
            return cmd[0] == PodCommand.NACK.rawValue
        }) {
            throw PeripheralManagerError.nack
        }
    }

    func requestToSend() throws {
        clearCommsQueues()
        try sendCommandType(.RTS, timeout: 5)
    }
    
    /// - Throws: PeripheralManagerError
    func sendCommandType(_ command: PodCommand, timeout: TimeInterval = 5) throws  {
        dispatchPrecondition(condition: .onQueue(queue))
        
        guard let characteristic = peripheral.getCommandCharacteristic() else {
            throw PeripheralManagerError.notReady
        }
        
        try writeValue(Data([command.rawValue]), for: characteristic, type: .withResponse, timeout: timeout)
    }

    /// - Throws: PeripheralManagerError
    func waitForCommand(_ command: PodCommand, timeout: TimeInterval = 5) throws {
        dispatchPrecondition(condition: .onQueue(queue))

        // Wait for data to be read.
        queueLock.lock()
        if (cmdQueue.count == 0) {
            queueLock.wait(until: Date().addingTimeInterval(timeout))
        }
        queueLock.unlock()

        commandLock.lock()
        defer {
            commandLock.unlock()
        }

        // Lock to protect dataQueue
        queueLock.lock()
        defer {
            queueLock.unlock()
        }

        if (cmdQueue.count > 0) {
            let value = cmdQueue.remove(at: 0)

            if command.rawValue != value[0] {
                log.error("waitForCommand failed. rawValue != value[0] (%d != %d); data=%@", command.rawValue, value[0], value.hexadecimalString)
                throw PeripheralManagerError.incorrectResponse
            }

            return
        }

        throw PeripheralManagerError.emptyValue
    }

    /// - Throws: PeripheralManagerError
    func sendData(_ value: Data, timeout: TimeInterval) throws {
        dispatchPrecondition(condition: .onQueue(queue))

        guard let characteristic = peripheral.getDataCharacteristic() else {
            log.error("Unable to get characteristic... peripheral status: %{PUBLIC}@", peripheral.state.description)
            throw PeripheralManagerError.notReady
        }

        var type: CBCharacteristicWriteType
        switch self.podType {
        case omnipod5Type:
            type = .withoutResponse
            let maxWrite = peripheral.maximumWriteValueLength(for: .withoutResponse)
            if value.count > maxWrite {
                log.error("O5 sendData: packet size %{public}d exceeds maximumWriteValueLength %{public}d!", value.count, maxWrite)
            }
        case dashType:
            type = .withResponse
        default:
            throw PeripheralManagerError.unknownPodType
        }

        try writeValue(value, for: characteristic, type: type, timeout: timeout)
    }

    /// - Throws: PeripheralManagerError
    func waitForData(sequence: UInt8, timeout: TimeInterval) throws -> Data {
        dispatchPrecondition(condition: .onQueue(queue))

        // Wait for data to be read.
        queueLock.lock()
        if (dataQueue.count == 0) {
            queueLock.wait(until: Date().addingTimeInterval(timeout))
        }
        queueLock.unlock()

        commandLock.lock()
        defer {
            commandLock.unlock()
        }

        // Lock to protect dataQueue
        queueLock.lock()
        defer {
            queueLock.unlock()
        }

        if (dataQueue.count > 0) {
            let data = dataQueue.remove(at: 0)
            
            if (data[0] != sequence) {
                log.error("waitForData failed data[0] != sequence (%d != %d).", data[0], sequence)
                throw PeripheralManagerError.incorrectResponse
            }
            return data
        }
        
        throw PeripheralManagerError.emptyValue
    }
}


// Marks certain errors are the kinds we see from NXP pods that occasionally become unresponsive
extension PeripheralManagerError {
    var isSymptomaticOfUnresponsivePod: Bool {
        switch self {
        case .emptyValue, .incorrectResponse:
            return true
        default:
            return false
        }
    }
}
