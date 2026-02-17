//
//  BleMessageTransport.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/PumpManager/MessageTransport.swift
//  Based on OmniKit/MessageTransport/MessageTransport.swift
//  Created by Pete Schwamb on 8/5/18.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import Foundation
import os.log

struct BleMessageTransportState: MessageTransportState {
    typealias RawValue = [String: Any]

    var ck: Data?
    var noncePrefix: Data?
    var eapSeq: Int // per session sequence #
    var msgSeq: Int // 8-bit Dash MessagePacket sequence # (with ck)
    var nonceSeq: Int // nonce sequence # (with noncePrefix)
    var messageNumber: Int // 4-bit Omnipod Message # (for Omnipod command/responses Messages)
    var cmdSeqCounter: Int // O5 command sequence counter (increments per signed command exchange)

    init() {
        self.init(ck: nil, noncePrefix: nil)
    }

    init(ck: Data?, noncePrefix: Data?, eapSeq: Int = 1, msgSeq: Int = 0, nonceSeq: Int = 0, messageNumber: Int = 0, cmdSeqCounter: Int = 0) {
        self.ck = ck
        self.noncePrefix = noncePrefix
        self.eapSeq = eapSeq
        self.msgSeq = msgSeq
        self.nonceSeq = nonceSeq
        self.messageNumber = messageNumber
        self.cmdSeqCounter = cmdSeqCounter
    }

    // RawRepresentable
    init?(rawValue: RawValue) {
        guard
            let ckString = rawValue["ck"] as? String,
            let noncePrefixString = rawValue["noncePrefix"] as? String,
            let msgSeq = rawValue["msgSeq"] as? Int,
            let nonceSeq = rawValue["nonceSeq"] as? Int,
            let messageNumber = rawValue["messageNumber"] as? Int
            else {
                return nil
        }
        self.ck = Data(hex: ckString)
        self.noncePrefix = Data(hex: noncePrefixString)
        self.eapSeq = rawValue["eapSeq"] as? Int ?? 1
        self.msgSeq = msgSeq
        self.nonceSeq = nonceSeq
        self.messageNumber = messageNumber
        self.cmdSeqCounter = rawValue["cmdSeqCounter"] as? Int ?? 0
    }

    var rawValue: RawValue {
        return [
            "ck": ck?.hexadecimalString ?? "",
            "noncePrefix": noncePrefix?.hexadecimalString ?? "",
            "eapSeq": eapSeq,
            "msgSeq": msgSeq,
            "nonceSeq": nonceSeq,
            "messageNumber": messageNumber,
            "cmdSeqCounter": cmdSeqCounter
        ]
    }

    mutating func incrementEapSeq() -> Int {
        self.eapSeq += 1
        return eapSeq
    }
}

extension BleMessageTransportState: CustomDebugStringConvertible {
    var debugDescription: String {
        return [
            "## BleMessageTransportState",
            "eapSeq: \(eapSeq)",
            "msgSeq: \(msgSeq)",
            "nonceSeq: \(nonceSeq)",
            "messageNumber: \(messageNumber)",
            "cmdSeqCounter: \(cmdSeqCounter)",
        ].joined(separator: "\n")
    }
}

class BlePodMessageTransport: MessageTransport {
    private let COMMAND_PREFIX = "S0.0="
    private let COMMAND_SUFFIX = ",G0.0"
    private let RESPONSE_PREFIX = "0.0="

    // O5 AID-specific responses use "3.12=" prefix (used only as fallback in parseResponse)
    private let O5_RESPONSE_PREFIX = "3.12="

    private let manager: PeripheralManager

    /// O5 pods never use RTS/CTS; DASH pods always do
    private var useRTS: Bool {
        return manager.podType != omnipod5Type
    }

    private var nonce: Nonce?
    private var enDecrypt: EnDecrypt?

    // Keep this non-implementation specific to not break parsers looking for this particular Category
    private let log = OSLog(category: "PodMessageTransport")

    private(set) var state: BleMessageTransportState {
        didSet {
            self.delegate?.messageTransport(self, didUpdate: state)
        }
    }

    private(set) var ck: Data? {
        get {
            return state.ck
        }
        set {
            state.ck = newValue
        }
    }

    private(set) var noncePrefix: Data? {
        get {
            return state.noncePrefix
        }
        set {
            state.noncePrefix = newValue
        }
    }

    private(set) var eapSeq: Int {
        get {
            return state.eapSeq
        }
        set {
            state.eapSeq = newValue
        }
    }

    private(set) var msgSeq: Int {
        get {
            return state.msgSeq
        }
        set {
            state.msgSeq = newValue
        }
    }

    private(set) var nonceSeq: Int {
        get {
            return state.nonceSeq
        }
        set {
            state.nonceSeq = newValue
        }
    }

    private(set) var messageNumber: Int {
        get {
            return state.messageNumber
        }
        set {
            state.messageNumber = newValue
        }
    }

    private(set) var cmdSeqCounter: Int {
        get {
            return state.cmdSeqCounter
        }
        set {
            state.cmdSeqCounter = newValue
        }
    }

    private let myId: UInt32
    private let podId: UInt32
    
    weak var messageLogger: MessageLogger?
    weak var delegate: MessageTransportDelegate?

    init(manager: PeripheralManager, myId: UInt32, podId: UInt32, state: BleMessageTransportState) {
        self.manager = manager
        self.myId = myId
        self.podId = podId
        self.state = state
        
        guard let noncePrefix = self.noncePrefix, let ck = self.ck else { return }
        self.nonce = Nonce(prefix: noncePrefix)
        self.enDecrypt = EnDecrypt(nonce: self.nonce!, ck: ck)
    }

    private func incrementMsgSeq(_ count: Int = 1) {
        msgSeq = ((msgSeq) + count) & 0xff // msgSeq is the 8-bit Dash MessagePacket sequence #
    }

    private func incrementNonceSeq(_ count: Int = 1) {
        nonceSeq = nonceSeq + count
    }

    private func incrementMessageNumber(_ count: Int = 1) {
        messageNumber = ((messageNumber) + count) & 0b1111 // messageNumber is the 4-bit Omnipod Message #
    }

    /// Sends the given pod message over the encrypted Dash transport and returns the pod's response
    func sendMessage(_ message: Message) throws -> Message {

        guard manager.peripheral.state == .connected else {
            throw PodCommsError.podNotConnected
        }

        messageNumber = message.sequenceNum // reset our Omnipod message # to given value

        incrementMessageNumber() // bump to match expected Omnipod message # in response

        let dataToSend = message.encoded()
        log.default("Send(Hex): %{public}@", dataToSend.hexadecimalString)
        messageLogger?.didSend(dataToSend)

        let sendMessage = try getCmdMessage(cmd: message)

        let writeResult = manager.sendMessagePacket(sendMessage, doRTS: useRTS)
        switch writeResult {
        case .sentWithAcknowledgment:
            break;
        case .sentWithError(let error):
            messageLogger?.didError("Unacknowledged message. seq:\(message.sequenceNum), error = \(error)")
            throw PodCommsError.unacknowledgedMessage(sequenceNumber: message.sequenceNum, error: error)
        case .unsentWithError(let error):
            throw PodCommsError.commsError(error: error)
        }

        do {
            let response = try readAndAckResponse()
            incrementMessageNumber() // bump the 4-bit Omnipod Message number
            return response
        } catch {
            messageLogger?.didError("Unacknowledged message. seq:\(message.sequenceNum), error = \(error)")
            throw PodCommsError.unacknowledgedMessage(sequenceNumber: message.sequenceNum, error: error)
        }
    }

    private func getCmdMessage(cmd: Message) throws -> MessagePacket {
        guard let enDecrypt = self.enDecrypt else {
            throw PodCommsError.podNotConnected
        }

        incrementMsgSeq()

        // Standard Omnipod commands always use ",G0.0" for both O5 and DASH.
        // AID-specific commands (3.2, 3.12, etc.) use their own suffixes via sendO5AidCommand().
        let wrapped = StringLengthPrefixEncoding.formatKeys(
            keys: [COMMAND_PREFIX, COMMAND_SUFFIX],
            payloads: [cmd.encoded(), Data()]
        )

        let msg = MessagePacket(
            type: MessageType.ENCRYPTED,
            source: self.myId,
            destination: self.podId,
            payload: wrapped,
            sequenceNumber: UInt8(msgSeq),
            eqos: 1
        )

        incrementNonceSeq()
        return try enDecrypt.encrypt(msg, nonceSeq)
    }

    private func readAndAckResponse() throws -> Message {
        guard let enDecrypt = self.enDecrypt else { throw PodCommsError.podNotConnected }

        let readResponse = try manager.readMessagePacket(doRTS: useRTS)
        guard let readMessage = readResponse else {
            throw PodProtocolError.messageIOException("Could not read response")
        }

        incrementNonceSeq()
        let decrypted = try enDecrypt.decrypt(readMessage, nonceSeq)

        let response = try parseResponse(decrypted: decrypted)

        incrementMsgSeq()
        incrementNonceSeq()
        let ack = try getAck(response: decrypted)
        let ackResult = manager.sendMessagePacket(ack, doRTS: useRTS)
        guard case .sentWithAcknowledgment = ackResult else {
            throw PodProtocolError.messageIOException("Could not write $msgType: \(ackResult)")
        }

        // verify that the Omnipod message # matches the expected value
        guard response.sequenceNum == messageNumber else {
            throw MessageError.invalidSequence
        }

        return response
    }

    private func parseResponse(decrypted: MessagePacket) throws -> Message {

        // Try standard "0.0=" prefix first (works for DASH and some O5 responses like unsolicited status)
        // Then try O5 "3.12=" prefix if "0.0=" fails
        let data: Data
        do {
            data = try StringLengthPrefixEncoding.parseKeys([RESPONSE_PREFIX], decrypted.payload)[0]
        } catch {
            if isO5 {
                log.debug("O5: Standard '0.0=' prefix not found, trying '3.12=' prefix")
                data = try StringLengthPrefixEncoding.parseKeys([O5_RESPONSE_PREFIX], decrypted.payload)[0]
            } else {
                throw error
            }
        }
        log.debug("Received decrypted response: %{public}@ in packet: %{public}@", data.hexadecimalString, decrypted.payload.hexadecimalString)

        // Dash pods generates a CRC16 for Omnipod Messages, but the actual algorithm is not understood and doesn't match the CRC16
        // that the pod enforces for incoming Omnipod command message. The Dash PDM explicitly ignores the CRC16 for incoming messages,
        // so we ignore them as well and rely on higher level BLE & Dash message data checking to provide data corruption protection.
        let response = try Message(encodedData: data, checkCRC: false)

        log.default("Recv(Hex): %{public}@", data.hexadecimalString)
        messageLogger?.didReceive(data)

        return response
    }

    private func getAck(response: MessagePacket) throws -> MessagePacket {
        guard let enDecrypt = self.enDecrypt else { throw PodCommsError.podNotConnected }

        let ackNumber = (UInt(response.sequenceNumber) + 1) & 0xff
        let msg = MessagePacket(
            type: MessageType.ENCRYPTED,
            source: response.destination.toUInt32(),
            destination: response.source.toUInt32(),
            payload: Data(),
            sequenceNumber: UInt8(msgSeq),
            ack: true,
            ackNumber: UInt8(ackNumber),
            eqos: 0
        )
        return try enDecrypt.encrypt(msg, nonceSeq)
    }

    /// Whether the pod is an Omnipod 5 (vs DASH)
    var isO5: Bool {
        return manager.podType == omnipod5Type
    }

    // MARK: - O5 Raw Data Send/Receive

    /// Sends raw data (not a standard Omnipod Message) as an encrypted Type 1 message,
    /// reads and ACKs the pod response, and returns the raw decrypted response payload.
    ///
    /// This is used for O5-specific operations like registration payload delivery (setPodUid)
    /// where the payload is NOT a standard Omnipod command message.
    ///
    /// The data is wrapped in SLPE format: "S0.0=" + len + data + ",G3.12"
    /// The response is unwrapped from whichever SLPE prefix the pod uses.
    ///
    /// - Parameter rawData: The raw bytes to send (will be SLPE-wrapped and encrypted)
    /// - Returns: The raw decrypted response payload (after SLPE unwrapping)
    func sendRawO5Data(_ rawData: Data) throws -> Data {
        guard let enDecrypt = self.enDecrypt else {
            throw PodCommsError.podNotConnected
        }

        guard manager.peripheral.state == .connected else {
            throw PodCommsError.podNotConnected
        }

        // Wrap the raw data in SLPE format — standard Omnipod commands use ",G0.0"
        let wrapped = StringLengthPrefixEncoding.formatKeys(
            keys: [COMMAND_PREFIX, COMMAND_SUFFIX],
            payloads: [rawData, Data()]
        )

        incrementMsgSeq()

        let msg = MessagePacket(
            type: MessageType.ENCRYPTED,
            source: self.myId,
            destination: self.podId,
            payload: wrapped,
            sequenceNumber: UInt8(msgSeq),
            eqos: 1
        )

        incrementNonceSeq()
        let encrypted = try enDecrypt.encrypt(msg, nonceSeq)

        log.default("O5 SendRaw(Hex): %{public}@ (%{public}d bytes)", rawData.hexadecimalString, rawData.count)
        messageLogger?.didSend(rawData)

        let writeResult = manager.sendMessagePacket(encrypted, doRTS: useRTS)
        switch writeResult {
        case .sentWithAcknowledgment:
            break
        case .sentWithError(let error):
            throw PodCommsError.commsError(error: error)
        case .unsentWithError(let error):
            throw PodCommsError.commsError(error: error)
        }

        // Read and ACK the response
        let readResponse = try manager.readMessagePacket(doRTS: useRTS)
        guard let readMessage = readResponse else {
            throw PodProtocolError.messageIOException("Could not read raw O5 response")
        }

        incrementNonceSeq()
        let decrypted = try enDecrypt.decrypt(readMessage, nonceSeq)

        // Extract the raw response payload from SLPE wrapping
        // Try "0.0=" first, then "3.12="
        let responseData: Data
        do {
            responseData = try StringLengthPrefixEncoding.parseKeys([RESPONSE_PREFIX], decrypted.payload)[0]
        } catch {
            do {
                responseData = try StringLengthPrefixEncoding.parseKeys([O5_RESPONSE_PREFIX], decrypted.payload)[0]
            } catch {
                // If neither prefix works, return the raw payload as-is
                log.debug("O5 Raw response has no recognized SLPE prefix, returning raw payload")
                responseData = decrypted.payload
            }
        }

        log.default("O5 RecvRaw(Hex): %{public}@ (%{public}d bytes)", responseData.hexadecimalString, responseData.count)
        messageLogger?.didReceive(responseData)

        // Send ACK
        incrementMsgSeq()
        incrementNonceSeq()
        let ack = try getAck(response: decrypted)
        let ackResult = manager.sendMessagePacket(ack, doRTS: useRTS)
        guard case .sentWithAcknowledgment = ackResult else {
            throw PodProtocolError.messageIOException("Could not send ACK for raw O5 response")
        }

        return responseData
    }

    // MARK: - O5 AID Command Support

    /// Sends a pre-SLPE-wrapped AID command through the encrypted transport and returns
    /// the raw response data after SLPE unwrapping.
    ///
    /// AID commands use ASCII key-value protocol (e.g., `S3.2=0003000E00,G3.2`)
    /// that is already SLPE-wrapped by `O5AidCommands`. This method handles the
    /// encrypt/send/receive/decrypt/ACK cycle and extracts the response payload.
    ///
    /// - Parameters:
    ///   - wrappedPayload: SLPE-wrapped command data (from O5AidCommands)
    ///   - responsePrefix: The SLPE key to extract from the response (e.g., "3.2=", "ES255.2=")
    /// - Returns: The raw response data after SLPE unwrapping
    func sendO5AidCommand(_ wrappedPayload: Data, responsePrefix: String) throws -> Data {
        guard let enDecrypt = self.enDecrypt else {
            throw PodCommsError.podNotConnected
        }

        guard manager.peripheral.state == .connected else {
            throw PodCommsError.podNotConnected
        }

        incrementMsgSeq()

        let msg = MessagePacket(
            type: MessageType.ENCRYPTED,
            source: self.myId,
            destination: self.podId,
            payload: wrappedPayload,
            sequenceNumber: UInt8(msgSeq),
            eqos: 1
        )

        incrementNonceSeq()
        let encrypted = try enDecrypt.encrypt(msg, nonceSeq)

        log.default("O5 AID Send (%{public}d bytes wrapped): %{public}@",
                     wrappedPayload.count, wrappedPayload.hexadecimalString)
        messageLogger?.didSend(wrappedPayload)

        let writeResult = manager.sendMessagePacket(encrypted, doRTS: useRTS)
        switch writeResult {
        case .sentWithAcknowledgment:
            break
        case .sentWithError(let error):
            throw PodCommsError.commsError(error: error)
        case .unsentWithError(let error):
            throw PodCommsError.commsError(error: error)
        }

        // Read the response
        let readResponse = try manager.readMessagePacket(doRTS: useRTS)
        guard let readMessage = readResponse else {
            throw PodProtocolError.messageIOException("Could not read AID command response")
        }

        incrementNonceSeq()
        let decrypted = try enDecrypt.decrypt(readMessage, nonceSeq)

        // Extract response data using the caller-provided response prefix.
        // AID responses use plain ASCII key=value format (no SLPE length prefix),
        // so we just strip the prefix and return everything after it.
        let prefixData = Data(responsePrefix.utf8)
        guard decrypted.payload.count >= prefixData.count,
              decrypted.payload.prefix(prefixData.count) == prefixData else {
            log.error("O5 AID response prefix '%{public}@' not found in payload: %{public}@",
                       responsePrefix, decrypted.payload.hexadecimalString)
            throw PodProtocolError.messageIOException("AID response prefix '\(responsePrefix)' not found in payload")
        }
        let responseData = decrypted.payload.suffix(from: prefixData.count)

        log.default("O5 AID Recv (%{public}d bytes): %{public}@",
                     responseData.count, responseData.hexadecimalString)
        messageLogger?.didReceive(responseData)

        // Send ACK
        incrementMsgSeq()
        incrementNonceSeq()
        let ack = try getAck(response: decrypted)
        let ackResult = manager.sendMessagePacket(ack, doRTS: useRTS)
        guard case .sentWithAcknowledgment = ackResult else {
            throw PodProtocolError.messageIOException("Could not send ACK for AID command response")
        }

        return responseData
    }

    // MARK: - O5 Signed (Type 4) Message Support

    /// Sends an Omnipod Message as a Type 4 (encrypted + signed) message for O5 steady-state commands.
    /// The ECDSA signature covers the complete encrypted message: AAD(16) + ciphertext + tag(8).
    /// Returns the pod's decrypted response.
    func sendO5SignedMessage(_ message: Message, certStore: O5CertificateStore) throws -> Message {
        guard manager.peripheral.state == .connected else {
            throw PodCommsError.podNotConnected
        }

        messageNumber = message.sequenceNum
        incrementMessageNumber()

        let dataToSend = message.encoded()
        log.default("O5Sign Send(Hex): %{public}@", dataToSend.hexadecimalString)
        messageLogger?.didSend(dataToSend)

        let sendMessage = try getO5SignedCmdMessage(cmd: message, certStore: certStore)

        let writeResult = manager.sendMessagePacket(sendMessage, doRTS: false) // O5 never uses RTS
        switch writeResult {
        case .sentWithAcknowledgment:
            break
        case .sentWithError(let error):
            messageLogger?.didError("Unacknowledged signed message. seq:\(message.sequenceNum), error = \(error)")
            throw PodCommsError.unacknowledgedMessage(sequenceNumber: message.sequenceNum, error: error)
        case .unsentWithError(let error):
            throw PodCommsError.commsError(error: error)
        }

        do {
            let response = try readAndAckO5SignedResponse(certStore: certStore)
            incrementMessageNumber()
            cmdSeqCounter += 1  // increment command sequence counter after successful exchange
            return response
        } catch {
            messageLogger?.didError("Unacknowledged signed message. seq:\(message.sequenceNum), error = \(error)")
            throw PodCommsError.unacknowledgedMessage(sequenceNumber: message.sequenceNum, error: error)
        }
    }

    /// Creates a Type 4 encrypted+signed command message.
    private func getO5SignedCmdMessage(cmd: Message, certStore: O5CertificateStore) throws -> MessagePacket {
        guard let enDecrypt = self.enDecrypt else {
            throw PodCommsError.podNotConnected
        }

        incrementMsgSeq()

        // Standard Omnipod commands use ",G0.0" even for O5 signed messages.
        // AID-specific commands use their own suffixes via sendO5AidCommand().
        let wrapped = StringLengthPrefixEncoding.formatKeys(
            keys: [COMMAND_PREFIX, COMMAND_SUFFIX],
            payloads: [cmd.encoded(), Data()]
        )

        // Create Type 4 message packet
        let msg = MessagePacket(
            type: MessageType.ENCRYPTED_SIGNED,
            source: self.myId,
            destination: self.podId,
            payload: wrapped,
            sequenceNumber: UInt8(msgSeq),
            eqos: 1
        )

        incrementNonceSeq()
        let encrypted = try enDecrypt.encrypt(msg, nonceSeq)

        // Sign: AAD (16 bytes TWi header) + ciphertext + tag (8 bytes)
        let signingInput = encrypted.asData(forEncryption: false).prefix(16) + encrypted.payload
        log.debug("O5Sign signing input (%{public}d bytes): AAD=%{public}@ payload=%{public}d bytes",
                  signingInput.count, signingInput.prefix(16).hexadecimalString, encrypted.payload.count)

        let signature = try certStore.signRaw(signingInput)
        assert(signature.count == 64, "ECDSA raw signature must be 64 bytes")

        // Store signature separately — it's appended after payload in asData()
        // but NOT counted in the header size field (size = ciphertext only)
        var signedPacket = encrypted
        signedPacket.signatureData = signature

        return signedPacket
    }

    /// Reads and ACKs a Type 4 signed response from the pod.
    /// Pod responses are Type 1 (ENCRYPTED), NOT Type 4. ACK is also Type 1 with no signature.
    private func readAndAckO5SignedResponse(certStore: O5CertificateStore) throws -> Message {
        guard let enDecrypt = self.enDecrypt else { throw PodCommsError.podNotConnected }

        let readResponse = try manager.readMessagePacket(doRTS: false) // O5 never uses RTS
        guard let readMessage = readResponse else {
            throw PodProtocolError.messageIOException("Could not read signed response")
        }

        incrementNonceSeq()
        let decrypted = try enDecrypt.decrypt(readMessage, nonceSeq)

        let response = try parseResponse(decrypted: decrypted)

        // Send Type 1 (encrypted, unsigned) ACK — matches official app behavior
        incrementMsgSeq()
        incrementNonceSeq()
        let ack = try getO5Ack(response: decrypted)
        let ackResult = manager.sendMessagePacket(ack, doRTS: false)
        guard case .sentWithAcknowledgment = ackResult else {
            throw PodProtocolError.messageIOException("Could not send ACK")
        }

        guard response.sequenceNum == messageNumber else {
            throw MessageError.invalidSequence
        }

        return response
    }

    /// Creates a Type 1 (encrypted, unsigned) ACK message for Type 4 command responses.
    /// Frida confirms: ACK after Type 4 command uses Type 1 (byte[3]=0x81), no ECDSA signature.
    private func getO5Ack(response: MessagePacket) throws -> MessagePacket {
        guard let enDecrypt = self.enDecrypt else { throw PodCommsError.podNotConnected }

        let ackNumber = (UInt(response.sequenceNumber) + 1) & 0xff
        let msg = MessagePacket(
            type: MessageType.ENCRYPTED,
            source: response.destination.toUInt32(),
            destination: response.source.toUInt32(),
            payload: Data(),
            sequenceNumber: UInt8(msgSeq),
            ack: true,
            ackNumber: UInt8(ackNumber),
            eqos: 0
        )
        return try enDecrypt.encrypt(msg, nonceSeq)
    }

    func assertOnSessionQueue() {
        dispatchPrecondition(condition: .onQueue(manager.queue))
    }
}

