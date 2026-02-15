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

        // O5 uses writeWithoutResponse on command characteristic (confirmed by btsnoop).
        // DASH uses writeWithResponse.
        let type: CBCharacteristicWriteType = (podType == omnipod5Type) ? .withoutResponse : .withResponse
        try writeValue(Data([PodCommand.HELLO.rawValue, 0x01, 0x04]) + controllerId, for: characteristic, type: type, timeout: 5)
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
                log.default("[sendMessagePacket] Sending RTS...")
                try requestToSend()
                log.default("[sendMessagePacket] Waiting for CTS...")
                try waitForCommand(PodCommand.CTS, timeout: 5)
                log.default("[sendMessagePacket] Got CTS")
            } else {
                log.default("[sendMessagePacket] Skipping RTS/CTS (doRTS=false), writing data directly. peripheral state=%{public}@", peripheral.state.description)
            }

            let splitter = PayloadSplitter(payload: message.asData(forEncryption: forEncryption))
            let packets = splitter.splitInPackets()
            log.default("[sendMessagePacket] Split payload into %{public}d packet(s), total payload %{public}d bytes", packets.count, message.payload.count)

            for (index, packet) in packets.enumerated() {
                // Consider starting the last packet send as the point at which the message may be received by the pod.
                // A failure after data is actually sent, but before the sendData() returns can still be received.
                if index == packets.count - 1 {
                    didSend = true
                }
                let packetData = packet.toData()
                log.default("[sendMessagePacket] Writing data packet %{public}d/%{public}d (%{public}d bytes)... peripheral state=%{public}@",
                            index + 1, packets.count, packetData.count, peripheral.state.description)
                try sendData(packetData, timeout: 5)
                log.default("[sendMessagePacket] Data packet %{public}d/%{public}d written. Peeking for NACK...", index + 1, packets.count)
                try self.peekForNack()
            }

            log.default("[sendMessagePacket] All packets written. Waiting for SUCCESS... peripheral state=%{public}@", peripheral.state.description)
            try waitForCommand(PodCommand.SUCCESS, timeout: 5)
            log.default("[sendMessagePacket] SUCCESS received. peripheral state=%{public}@", peripheral.state.description)
        } catch {
            log.error("[sendMessagePacket] Error (didSend=%{public}@): %{public}@. peripheral state=%{public}@",
                      String(describing: didSend), String(describing: error), peripheral.state.description)
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
                log.default("[readMessagePacket] Waiting for RTS from pod...")
                try waitForCommand(PodCommand.RTS)
                log.default("[readMessagePacket] Got RTS, sending CTS...")
                try sendCommandType(PodCommand.CTS)
                log.default("[readMessagePacket] CTS sent")
            } else {
                log.default("[readMessagePacket] Skipping RTS/CTS (doRTS=false), waiting for data. peripheral state=%{public}@", peripheral.state.description)
            }

            var expected: UInt8 = 0

            log.default("[readMessagePacket] Waiting for first data packet (seq 0)... peripheral state=%{public}@", peripheral.state.description)
            let firstPacket = try waitForData(sequence: expected, timeout: 5)
            log.default("[readMessagePacket] First data packet received (%{public}d bytes)", firstPacket.count)

            let joiner = try PayloadJoiner(firstPacket: firstPacket)
            let totalFragments = joiner.fullFragments + (joiner.oneExtraPacket ? 1 : 0)
            log.default("[readMessagePacket] Expecting %{public}d more fragment(s) (fullFragments=%{public}d, oneExtra=%{public}@)",
                        totalFragments, joiner.fullFragments, String(describing: joiner.oneExtraPacket))

            if joiner.fullFragments > 0 {
                for i in 1...joiner.fullFragments {
                    expected += 1
                    log.default("[readMessagePacket] Waiting for fragment %{public}d (seq %{public}d)... peripheral state=%{public}@",
                                i, expected, peripheral.state.description)
                    let packet = try waitForData(sequence: expected, timeout: 5)
                    log.default("[readMessagePacket] Fragment %{public}d received (%{public}d bytes)", i, packet.count)
                    try joiner.accumulate(packet: packet)
                }
            }
            if joiner.oneExtraPacket {
                expected += 1
                log.default("[readMessagePacket] Waiting for extra fragment (seq %{public}d)... peripheral state=%{public}@",
                            expected, peripheral.state.description)
                let packet = try waitForData(sequence: expected, timeout: 5)
                log.default("[readMessagePacket] Extra fragment received (%{public}d bytes)", packet.count)
                try joiner.accumulate(packet: packet)
            }
            let fullPayload = try joiner.finalize()
            log.default("[readMessagePacket] All fragments received, total payload %{public}d bytes. Sending SUCCESS...", fullPayload.count)
            try  sendCommandType(PodCommand.SUCCESS)
            log.default("[readMessagePacket] SUCCESS sent. Parsing message...")
            packet = try MessagePacket.parse(payload: fullPayload)
            log.default("[readMessagePacket] Message parsed successfully. peripheral state=%{public}@", peripheral.state.description)
        } catch {
            log.error("[readMessagePacket] Error reading message: %{public}@. peripheral state=%{public}@", String(describing: error), peripheral.state.description)
            if let error = error as? PeripheralManagerError, error.isSymptomaticOfUnresponsivePod {
                if peripheral.state == .connected {
                    log.error("[readMessagePacket] Disconnecting due to unresponsive pod error while reading")
                    central?.cancelPeripheralConnection(peripheral)
                } else {
                    log.error("[readMessagePacket] Pod already not connected (state=%{public}@), skipping disconnect", peripheral.state.description)
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

        guard let characteristic = peripheral.getCommandCharacteristic() else {
            throw PeripheralManagerError.notReady
        }

        // O5 uses writeWithoutResponse on command characteristic (confirmed by btsnoop).
        // DASH uses writeWithResponse.
        let type: CBCharacteristicWriteType = (podType == omnipod5Type) ? .withoutResponse : .withResponse
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
                    log.default("waitForCommand: got expected 0x%{public}02x, full data=%{public}@ (%{public}d bytes)",
                                command.rawValue, value.hexadecimalString, value.count)
                    queueLock.unlock()
                    commandLock.unlock()
                    return // Got expected command
                }

                // During O5 pairing, pod sends intermediate PAIR_STATUS (0x08) commands
                // before SUCCESS. Log and continue waiting for the expected command.
                if value[0] == PodCommand.PAIR_STATUS.rawValue {
                    log.default("waitForCommand: skipping intermediate PAIR_STATUS (0x08), data=%{public}@, waiting for 0x%{public}02x",
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
                log.error("waitForCommand failed. rawValue != value[0] (%d != %d); data=%@", command.rawValue, value[0], value.hexadecimalString)
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

        guard let characteristic = peripheral.getDataCharacteristic() else {
            log.error("Unable to get characteristic... peripheral status: %{PUBLIC}@", peripheral.state.description)
            throw PeripheralManagerError.notReady
        }

        var type: CBCharacteristicWriteType
        switch self.podType {
        case omnipod5Type:
            type = .withoutResponse
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
