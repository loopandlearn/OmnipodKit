//
//  PeripheralManager+OmnipodKit.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/PeripheralManager+OmniBLE.swift
//  Created by Randall Knutson on 11/2/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import os.log

fileprivate var bleDebugEnabled = false

extension OSLog {
    func bleDebug(_ message: StaticString, _ args: CVarArg...) {
        guard bleDebugEnabled else {
            return
        }
        let type: OSLogType = .default
        switch args.count {
        case 0:
            os_log(message, log: self, type: type)
        case 1:
            os_log(message, log: self, type: type, args[0])
        case 2:
            os_log(message, log: self, type: type, args[0], args[1])
        case 3:
            os_log(message, log: self, type: type, args[0], args[1], args[2])
        case 4:
            os_log(message, log: self, type: type, args[0], args[1], args[2], args[3])
        case 5:
            os_log(message, log: self, type: type, args[0], args[1], args[2], args[3], args[4])
        default:
            os_log(message, log: self, type: type, args)
        }
    }
}

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
        guard let characteristic = peripheral.getCommandCharacteristic(profile: profile) else {
            throw PeripheralManagerError.notReady
        }

        let type: CBCharacteristicWriteType = profile.commandWriteType
        try writeValue(Data([PodCommand.HELLO.rawValue, 0x01, 0x04]) + controllerId, for: characteristic, type: type, timeout: 5)
    }
    
    func enableNotifications() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let cmdChar = peripheral.getCommandCharacteristic(profile: profile) else {
            throw PeripheralManagerError.notReady
        }
        guard let dataChar = peripheral.getDataCharacteristic(profile: profile) else {
            throw PeripheralManagerError.notReady
        }
        try setNotifyValue(true, for: cmdChar, timeout: .seconds(2))
        try setNotifyValue(true, for: dataChar, timeout: .seconds(2))
    }
        
    func sendMessagePacket(_ message: MessagePacket, _ forEncryption: Bool = false) -> SendMessageResult {
        dispatchPrecondition(condition: .onQueue(queue))

        var didSend = false

        do {
            if podType.isDash {
                log.bleDebug("[sendMessagePacket] Sending RTS...")
                try requestToSend()
                log.bleDebug("[sendMessagePacket] Waiting for CTS...")
                try waitForCommand(PodCommand.CTS, timeout: 5)
                log.bleDebug("[sendMessagePacket] Got CTS")
            } else {
                log.bleDebug("[sendMessagePacket] Skipping RTS/CTS, writing data directly. peripheral state=%{public}@",
                             String(describing: peripheral.state))
            }

            let splitter = PayloadSplitter(payload: message.asData(forEncryption: forEncryption), layout: profile.packetLayout)
            let packets = splitter.splitInPackets()
            log.bleDebug("[sendMessagePacket] Split payload into %{public}lld packet(s), total payload %{public}lld bytes", packets.count, message.payload.count)

            for (index, packet) in packets.enumerated() {
                // Consider starting the last packet send as the point at which the message may be received by the pod.
                // A failure after data is actually sent, but before the sendData() returns can still be received.
                if index == packets.count - 1 {
                    didSend = true
                }
                let packetData = packet.toData(layout: profile.packetLayout)
                log.bleDebug("[sendMessagePacket] Writing data packet %{public}lld/%{public}lld (%{public}lld bytes)... peripheral state=%{public}@",
                            index + 1, packets.count, packetData.count, String(describing: peripheral.state))
                try sendData(packetData, timeout: 5)
                log.bleDebug("[sendMessagePacket] Data packet %{public}lld/%{public}lld written. Peeking for NACK...", index + 1, packets.count)
                try self.peekForNack()
            }

            log.bleDebug("[sendMessagePacket] All packets written. Waiting for SUCCESS... peripheral state=%{public}@",
                         String(describing: peripheral.state))
            try waitForCommand(PodCommand.SUCCESS, timeout: 5)
            log.bleDebug("[sendMessagePacket] SUCCESS received. peripheral state=%{public}@",
                         String(describing: peripheral.state))
        } catch {
            log.error("[sendMessagePacket] Error (didSend=%{public}@): %{public}@. peripheral state=%{public}@",
                      String(describing: didSend), String(describing: error), String(describing: peripheral.state))
            if didSend {
                return .sentWithError(error)
            } else {
                return .unsentWithError(error)
            }
        }
        return .sentWithAcknowledgment
    }
    
    /// - Throws: PeripheralManagerError
    func readMessagePacket() throws -> MessagePacket? {
        dispatchPrecondition(condition: .onQueue(queue))

        var packet: MessagePacket?

        do {
            if podType.isDash {
                log.bleDebug("[readMessagePacket] Waiting for RTS from pod...")
                try waitForCommand(PodCommand.RTS)
                log.bleDebug("[readMessagePacket] Got RTS, sending CTS...")
                try sendCommandType(PodCommand.CTS)
                log.bleDebug("[readMessagePacket] CTS sent")
            } else {
                log.bleDebug("[readMessagePacket] Skipping RTS/CTS, waiting for data. peripheral state=%{public}@",
                             String(describing: peripheral.state))
            }

            var expected: UInt8 = 0

            log.bleDebug("[readMessagePacket] Waiting for first data packet (seq 0)... peripheral state=%{public}@",
                         String(describing: peripheral.state))
            let firstPacket = try waitForData(sequence: expected, timeout: 5)
            log.bleDebug("[readMessagePacket] First data packet received (%{public}lld bytes)", firstPacket.count)

            let joiner = try PayloadJoiner(firstPacket: firstPacket, layout: profile.packetLayout)
            let totalFragments = joiner.fullFragments + (joiner.oneExtraPacket ? 1 : 0)
            log.bleDebug("[readMessagePacket] Expecting %{public}lld more fragment(s) (fullFragments=%{public}lld, oneExtra=%{public}@)",
                        totalFragments, joiner.fullFragments, String(describing: joiner.oneExtraPacket))

            if joiner.fullFragments > 0 {
                for i in 1...joiner.fullFragments {
                    expected += 1
                    log.bleDebug("[readMessagePacket] Waiting for fragment %{public}lld (seq %{public}lld)... peripheral state=%{public}@",
                                i, expected, String(describing: peripheral.state))
                    let packet = try waitForData(sequence: expected, timeout: 5)
                    log.bleDebug("[readMessagePacket] Fragment %{public}lld received (%{public}lld bytes)", i, packet.count)
                    try joiner.accumulate(packet: packet)
                }
            }
            if joiner.oneExtraPacket {
                expected += 1
                log.bleDebug("[readMessagePacket] Waiting for extra fragment (seq %{public}lld)... peripheral state=%{public}@",
                            expected, String(describing: peripheral.state))
                let packet = try waitForData(sequence: expected, timeout: 5)
                log.bleDebug("[readMessagePacket] Extra fragment received (%{public}lld bytes)", packet.count)
                try joiner.accumulate(packet: packet)
            }
            let fullPayload = try joiner.finalize()
            log.bleDebug("[readMessagePacket] All fragments received, total payload %{public}lld bytes. Sending SUCCESS...", fullPayload.count)
            try  sendCommandType(PodCommand.SUCCESS)
            log.bleDebug("[readMessagePacket] SUCCESS sent. Parsing message...")
            packet = try MessagePacket.parse(payload: fullPayload)
            log.bleDebug("[readMessagePacket] Message parsed successfully. peripheral state=%{public}@",
                         String(describing: peripheral.state))
        } catch {
            log.error("[readMessagePacket] Error reading message: %{public}@. peripheral state=%{public}@",
                      String(describing: error),
                      String(describing: peripheral.state))
            if let error = error as? PeripheralManagerError, error.isSymptomaticOfUnresponsivePod {
                if peripheral.state == .connected {
                    log.error("[readMessagePacket] Disconnecting due to unresponsive pod error while reading")
                    central?.cancelPeripheralConnection(peripheral)
                } else {
                    log.error("[readMessagePacket] Pod already not connected (state=%{public}@), skipping disconnect",
                              String(describing: peripheral.state))
                }
            } else {
                log.error("[readMessagePacket] Non-unresponsive error, sending NACK")
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

        guard let characteristic = peripheral.getCommandCharacteristic(profile: profile) else {
            throw PeripheralManagerError.notReady
        }

        let type: CBCharacteristicWriteType = profile.commandWriteType
        try writeValue(Data([command.rawValue]), for: characteristic, type: type, timeout: timeout)
    }

    /// - Throws: PeripheralManagerError
    func waitForCommand(_ command: PodCommand, timeout: TimeInterval = 5) throws {
        dispatchPrecondition(condition: .onQueue(queue))

        let deadline = Date().addingTimeInterval(timeout)

        while true {
            // Wait for data to be read.
            queueLock.lock()
            if cmdQueue.count == 0 {
                let remaining = deadline.timeIntervalSinceNow
                if remaining > 0 {
                    queueLock.wait(until: deadline)
                }
            }
            queueLock.unlock()

            commandLock.lock()

            // Lock to protect cmdQueue
            queueLock.lock()

            if cmdQueue.count > 0 {
                let value = cmdQueue.remove(at: 0)

                if command.rawValue == value[0] {
                    log.bleDebug("waitForCommand: got expected 0x%{public}02llx, full data=%{public}@ (%{public}lld bytes)",
                                command.rawValue, value.hexadecimalString, value.count)
                    queueLock.unlock()
                    commandLock.unlock()
                    return // Got expected command
                }

                // During O5 pairing, pod sends intermediate PAIR_STATUS (0x08) commands
                // before SUCCESS. Log and continue waiting for the expected command.
                if value[0] == PodCommand.PAIR_STATUS.rawValue {
                    log.bleDebug("waitForCommand: skipping intermediate PAIR_STATUS (0x08), data=%{public}@, waiting for 0x%{public}02llx",
                               value.hexadecimalString, command.rawValue)
                    queueLock.unlock()
                    commandLock.unlock()
                    // Check if we still have time left before looping
                    if Date() >= deadline {
                        throw PeripheralManagerError.emptyValue
                    }
                    continue // Loop and wait for next command
                }

                // Unexpected command that isn't PAIR_STATUS
                log.error("waitForCommand failed. rawValue != value[0] (%lld != %lld); data=%@", command.rawValue, value[0], value.hexadecimalString)
                queueLock.unlock()
                commandLock.unlock()
                throw PeripheralManagerError.incorrectResponse
            }

            queueLock.unlock()
            commandLock.unlock()

            // No data in queue and deadline reached
            if Date() >= deadline {
                throw PeripheralManagerError.emptyValue
            }
        }
    }

    /// - Throws: PeripheralManagerError
    func sendData(_ value: Data, timeout: TimeInterval) throws {
        dispatchPrecondition(condition: .onQueue(queue))

        guard let characteristic = peripheral.getDataCharacteristic(profile: profile) else {
            log.error("Unable to get characteristic... peripheral status: %{PUBLIC}@",
                      String(describing: peripheral.state))
            throw PeripheralManagerError.notReady
        }

        let type: CBCharacteristicWriteType = profile.commandWriteType
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
                log.error("waitForData failed data[0] != sequence (%lld != %lld).", data[0], sequence)
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
