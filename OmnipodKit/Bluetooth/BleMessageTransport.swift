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
import CryptoKit
import os.log

struct BleMessageTransportState: MessageTransportState {
    typealias RawValue = [String: Any]

    var ck: Data?
    var noncePrefix: Data?
    var eapSeq: Int // per session sequence #
    var msgSeq: Int // 8-bit Dash MessagePacket sequence # (with ck)
    var nonceSeq: Int // nonce sequence # (with noncePrefix)
    var messageNumber: Int // 4-bit Omnipod Message # (for Omnipod command/responses Messages)

    init() {
        self.init(ck: nil, noncePrefix: nil)
    }

    init(ck: Data?, noncePrefix: Data?, eapSeq: Int = 1, msgSeq: Int = 0, nonceSeq: Int = 0, messageNumber: Int = 0) {
        self.ck = ck
        self.noncePrefix = noncePrefix
        self.eapSeq = eapSeq
        self.msgSeq = msgSeq
        self.nonceSeq = nonceSeq
        self.messageNumber = messageNumber
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
    }

    var rawValue: RawValue {
        return [
            "ck": ck?.hexadecimalString ?? "",
            "noncePrefix": noncePrefix?.hexadecimalString ?? "",
            "eapSeq": eapSeq,
            "msgSeq": msgSeq,
            "nonceSeq": nonceSeq,
            "messageNumber": messageNumber,
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
        ].joined(separator: "\n")
    }

    var inlineDescription: String {
        "[eapSeq:\(eapSeq), msgSeq:\(msgSeq), nonceSeq:\(nonceSeq), messageNumber:\(messageNumber)]"
    }
}

class BlePodMessageTransport: MessageTransport {
    private let COMMAND_PREFIX = "S0.0="
    private let COMMAND_SUFFIX = ",G0.0"
    private let RESPONSE_PREFIX = "0.0="

    // O5 AID-specific responses use "3.12=" prefix (used only as fallback in parseResponse)
    private let O5_RESPONSE_PREFIX = "3.12="

    private let manager: PeripheralManager

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

    private let myId: UInt32
    private let podId: UInt32

    private var signingKey: Data? // O5 only

    weak var messageLogger: MessageLogger?
    weak var delegate: MessageTransportDelegate?

    private static var lastSuccessfulExchangeTime: Date?

    static func mostRecentSuccessfulExchangeTime() -> Date? {
        return lastSuccessfulExchangeTime
    }

    init(manager: PeripheralManager, myId: UInt32, podId: UInt32, state: BleMessageTransportState, signingKey: Data?) {
        self.manager = manager
        self.myId = myId
        self.podId = podId
        self.state = state
        
        guard let noncePrefix = self.noncePrefix, let ck = self.ck else { return }
        self.nonce = Nonce(prefix: noncePrefix)
        self.enDecrypt = EnDecrypt(nonce: self.nonce!, ck: ck)
        self.signingKey = signingKey
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

    /// Sends the given pod message over the encrypted BLE transport and returns the pod's response.
    /// Handles both DASH and O5 Type 1 messages as well as O5 Type 4 signed messages as needed.
    /// The ECDSA signature covers the complete encrypted message: AAD(16) + ciphertext + tag(8).
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
        log.bleDebug("[transport] send phase=write msgSeq=%{public}lld nonceSeq=%{public}lld messageNumber=%{public}lld",
                    msgSeq, nonceSeq, messageNumber)

        let writeResult = manager.sendMessagePacket(sendMessage)
        switch writeResult {
        case .sentWithAcknowledgment:
            break;
        case .sentWithError(let error):
            log.error("[transport] failed phase=write-ack msgSeq=%{public}lld nonceSeq=%{public}lld messageNumber=%{public}lld error=%{public}@",
                      msgSeq, nonceSeq, messageNumber, String(describing: error))
            messageLogger?.didError("Unacknowledged message. seq:\(message.sequenceNum), error = \(error)")
            throw PodCommsError.unacknowledgedMessage(sequenceNumber: message.sequenceNum, error: error)
        case .unsentWithError(let error):
            log.error("[transport] failed phase=write msgSeq=%{public}lld nonceSeq=%{public}lld messageNumber=%{public}lld error=%{public}@",
                      msgSeq, nonceSeq, messageNumber, String(describing: error))
            throw PodCommsError.commsError(error: error)
        }

        do {
            let response = try readAndAckResponse()
            incrementMessageNumber() // bump the 4-bit Omnipod Message number
            return response
        } catch {
            log.error("[transport] failed phase=read/ack msgSeq=%{public}lld nonceSeq=%{public}lld messageNumber=%{public}lld error=%{public}@",
                      msgSeq, nonceSeq, messageNumber, String(describing: error))
            messageLogger?.didError("Unacknowledged message. seq:\(message.sequenceNum), error = \(error)")
            throw PodCommsError.unacknowledgedMessage(sequenceNumber: message.sequenceNum, error: error)
        }
    }

    /// Creates either a Type 1 (encrypted) or Type 4 (encrypted+signed) command MessagePacket (if certStore != nil)
    private func getCmdMessage(cmd: Message) throws -> MessagePacket {
        guard let enDecrypt = self.enDecrypt else {
            throw PodCommsError.podNotConnected
        }

        incrementMsgSeq()

        let privateKey: P256.Signing.PrivateKey?
        if manager.podType.isO5 && requiresType4Signing(for: cmd.messageBlocks) {
            // Need to use a Type 4 (ECDSA signed) message for this O5 command.
            // Verify we can have the needed signingKey before proceeding.
            if signingKey == nil {
                // This happens if running in a limited mode w/o the needed cert data
                throw PodCommsError.noCertificateFound
            }
            privateKey = try P256.Signing.PrivateKey(rawRepresentation: signingKey!)
        } else {
            privateKey = nil
        }

        // Standard Omnipod commands always use ",G0.0" for both O5 and DASH.
        // AID-specific commands (3.2, 3.12, etc.) use their own suffixes via sendO5AidCommand().
        let wrapped = StringLengthPrefixEncoding.formatKeys(
            keys: [COMMAND_PREFIX, COMMAND_SUFFIX],
            payloads: [cmd.encoded(), Data()]
        )

        let msg = MessagePacket(
            type: privateKey != nil ? MessageType.ENCRYPTED_SIGNED : MessageType.ENCRYPTED,
            source: myId,
            destination: podId,
            payload: wrapped,
            sequenceNumber: UInt8(msgSeq),
            eqos: 1
        )

        incrementNonceSeq()
        let encrypted = try enDecrypt.encrypt(msg, nonceSeq)

        guard let signingKey = privateKey else {
            return encrypted // no signingKey, so we're all done
        }

        let signingInput = encrypted.asData(forEncryption: false).prefix(16) + encrypted.payload
        log.bleDebug("signing input (%{public}lld bytes): AAD=%{public}@ payload=%{public}lld bytes",
                  signingInput.count, signingInput.prefix(16).hexadecimalString, encrypted.payload.count)

        let signed = try signingKey.signature(for: signingInput)
        let signature = Data(signed.rawRepresentation)
        assert(signature.count == 64, "ECDSA raw signature must be 64 bytes")

        // Store signature separately — it's appended after payload in asData()
        // but NOT counted in the header size field (size = ciphertext only)
        var signedPacket = encrypted
        signedPacket.signatureData = signature

        return signedPacket
    }

    private func readAndAckResponse() throws -> Message {
        guard let enDecrypt = self.enDecrypt else { throw PodCommsError.podNotConnected }

        log.bleDebug("[transport] receive phase=read msgSeq=%{public}lld nonceSeq=%{public}lld messageNumber=%{public}lld",
                    msgSeq, nonceSeq, messageNumber)
        let readResponse = try manager.readMessagePacket()
        guard let readMessage = readResponse else {
            log.error("[transport] failed phase=read-empty msgSeq=%{public}lld nonceSeq=%{public}lld messageNumber=%{public}lld",
                      msgSeq, nonceSeq, messageNumber)
            throw PodProtocolError.messageIOException("Could not read response")
        }

        incrementNonceSeq()
        let decrypted: MessagePacket
        do {
            decrypted = try enDecrypt.decrypt(readMessage, nonceSeq)
        } catch {
            log.error("[transport] failed phase=decrypt msgSeq=%{public}lld nonceSeq=%{public}lld messageNumber=%{public}lld error=%{public}@",
                      msgSeq, nonceSeq, messageNumber, String(describing: error))
            throw error
        }

        let response: Message
        do {
            response = try parseResponse(decrypted: decrypted)
        } catch {
            log.error("[transport] failed phase=parse msgSeq=%{public}lld nonceSeq=%{public}lld messageNumber=%{public}lld error=%{public}@",
                      msgSeq, nonceSeq, messageNumber, String(describing: error))
            throw error
        }

        incrementMsgSeq()
        incrementNonceSeq()
        let ack = try getAck(response: decrypted)
        let ackResult = manager.sendMessagePacket(ack)
        guard case .sentWithAcknowledgment = ackResult else {
            log.error("[transport] failed phase=ack-write msgSeq=%{public}lld nonceSeq=%{public}lld messageNumber=%{public}lld ackResult=%{public}@",
                      msgSeq, nonceSeq, messageNumber, String(describing: ackResult))
            throw PodProtocolError.messageIOException("Could not write $msgType: \(ackResult)")
        }

        // verify that the Omnipod message # matches the expected value
        guard response.sequenceNum == messageNumber else {
            log.error("[transport] failed phase=message-number-validation expected=%{public}lld received=%{public}lld msgSeq=%{public}lld nonceSeq=%{public}lld",
                      messageNumber, response.sequenceNum, msgSeq, nonceSeq)
            throw MessageError.invalidSequence
        }

        BlePodMessageTransport.lastSuccessfulExchangeTime = Date()
        log.bleDebug("[transport] exchange success msgSeq=%{public}lld nonceSeq=%{public}lld messageNumber=%{public}lld",
                    msgSeq, nonceSeq, messageNumber)

        return response
    }

    private func parseResponse(decrypted: MessagePacket) throws -> Message {

        let data: Data
        do {
            // Try standard "0.0=" prefix first (works for all DASH and most O5 responses)
            data = try StringLengthPrefixEncoding.parseKeys([RESPONSE_PREFIX], decrypted.payload)[0]
        } catch {
            // Try "3.12=" prefix for an O5 pod since "0.0=" prefix failed
            if manager.podType.isO5 {
                data = try StringLengthPrefixEncoding.parseKeys([O5_RESPONSE_PREFIX], decrypted.payload)[0]
            } else {
                throw error
            }
        }
        log.bleDebug("Received decrypted response: %{public}@ in packet: %{public}@", data.hexadecimalString, decrypted.payload.hexadecimalString)

        // Dash pods generates a CRC16 for Omnipod Messages, but the actual algorithm is not understood and doesn't match the CRC16
        // that the pod enforces for incoming Omnipod command message. The Dash PDM explicitly ignores the CRC16 for incoming messages,
        // so we ignore them as well and rely on higher level BLE & Dash message data checking to provide data corruption protection.
        // However the Omnipod 5 pods do generate the same expected CRC16 in their responses as Eros pods do so do check their CRC16.
        let response = try Message(encodedData: data, checkCRC: manager.podType.isO5)

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

        log.default("O5 SendRaw(Hex): %{public}@ (%{public}lld bytes)", rawData.hexadecimalString, rawData.count)
        messageLogger?.didSend(rawData)

        let writeResult = manager.sendMessagePacket(encrypted)
        switch writeResult {
        case .sentWithAcknowledgment:
            break
        case .sentWithError(let error):
            throw PodCommsError.commsError(error: error)
        case .unsentWithError(let error):
            throw PodCommsError.commsError(error: error)
        }

        // Read and ACK the response
        let readResponse = try manager.readMessagePacket()
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

        log.default("O5 RecvRaw(Hex): %{public}@ (%{public}lld bytes)", responseData.hexadecimalString, responseData.count)
        messageLogger?.didReceive(responseData)

        // Send ACK
        incrementMsgSeq()
        incrementNonceSeq()
        let ack = try getAck(response: decrypted)
        let ackResult = manager.sendMessagePacket(ack)
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

        log.default("O5 AID Send (%{public}lld bytes wrapped): %{public}@",
                     wrappedPayload.count, wrappedPayload.hexadecimalString)
        messageLogger?.didSend(wrappedPayload)

        let writeResult = manager.sendMessagePacket(encrypted)
        switch writeResult {
        case .sentWithAcknowledgment:
            break
        case .sentWithError(let error):
            throw PodCommsError.commsError(error: error)
        case .unsentWithError(let error):
            throw PodCommsError.commsError(error: error)
        }

        // Read the response
        let readResponse = try manager.readMessagePacket()
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

        log.default("O5 AID Recv (%{public}lld bytes): %{public}@",
                     responseData.count, responseData.hexadecimalString)
        messageLogger?.didReceive(responseData)

        // Send ACK
        incrementMsgSeq()
        incrementNonceSeq()
        let ack = try getAck(response: decrypted)
        let ackResult = manager.sendMessagePacket(ack)
        guard case .sentWithAcknowledgment = ackResult else {
            throw PodProtocolError.messageIOException("Could not send ACK for AID command response")
        }

        return responseData
    }

    func assertOnSessionQueue() {
        dispatchPrecondition(condition: .onQueue(manager.queue))
    }
}

/// Returns true if the message blocks contain a command type that requires Type 4 (ECDSA signed) sending on O5 pods.
private func requiresType4Signing(for blocks: [MessageBlock]) -> Bool {
    /// O5 command types that MUST be sent as Type 4 (ECDSA signed) messages.
    let o5SignedCommandTypes: Set<MessageBlockType> = [
        /// Just check for 0x1a command type which is always before one of the
        /// "extra" message types: 0x13 basal, 0x16 temp basal & 0x17 bolus.
        .setInsulinSchedule,  // 0x1a
        .deactivatePod,       // 0x1c
        .cancelDelivery,      // 0x1f
    ]

    return blocks.contains { o5SignedCommandTypes.contains($0.blockType) }
}
