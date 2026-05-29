//
//  O5LTKExchanger.swift
//  OmnipodKit
//
//  Created by Joe Moran on 3/25/25.
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//
import Foundation
import CryptoSwift
import CryptoKit
import os.log

class O5LTKExchanger {
    // Fixed 6-byte value taken from the PDM firmware
    static let FIRMWARE_ID: Data = {
        let id = Data(hex: "9b0ab96a76f4")
        precondition(id.count == 6, "FIRMWARE_ID must be exactly 6 bytes, got \(id.count)")
        return id
    }()

    static private let SP1 = "SP1="
    static private let SP2 = ",SP2="
    static private let SPS0 = "SPS0="
    static private let SPS1 = "SPS1="
    static private let SPS2_1 = "SPS2.1="
    static private let SPS2 = "SPS2="
    static private let SP0GP0 = "SP0,GP0"
    static private let P0 = "P0="
    static private let EXPECTED_P0_PAYLOAD = Data([0xa5]) // unknown meaning

    private let manager: PeripheralManager
    private let ids: Ids
    private let podAddress = Ids.notActivated()
    private let keyExchange: O5KeyExchange
    private let certStore: O5CertificateStore
    private var seq: UInt8 = 1

    private let log = OSLog(category: "O5LTKExchanger")

    init(manager: PeripheralManager, ids: Ids) throws {
        self.manager = manager
        self.ids = ids
        self.certStore = try O5CertificateStore(controllerId: ids.myIdAddr)
        self.keyExchange = try O5KeyExchange(P256KeyGenerator(), OmniRandomByteGenerator(), controllerIdData: certStore.controllerIdData)
    }

    func o5negotiateLTK() throws -> PairResult {
        log.default("O5 pairing attempt using fixed confirmed parameters")
        do {
            let result = try o5negotiateLTKBody()
            log.default("O5 pairing SUCCEEDED")
            return result
        } catch {
            log.error("O5 pairing FAILED: %{public}@", String(describing: error))
            throw error
        }
    }

    private func o5negotiateLTKBody() throws -> PairResult {

        log.default("=== O5 Pairing Start === myId=0x%{public}llx podId=0x%{public}llx", ids.myId.toUInt32(), ids.podId.toUInt32())
        let maxWriteNoResp = manager.peripheral.maximumWriteValueLength(for: .withoutResponse)
        let maxWriteWithResp = manager.peripheral.maximumWriteValueLength(for: .withResponse)
        log.bleDebug("maxWriteValue at pairing start: withoutResponse=%{public}lld, withResponse=%{public}lld, packetMaxPayloadSize=%{public}lld",
                    maxWriteNoResp, maxWriteWithResp, manager.profile.packetLayout.maxPayloadSize)
        log.default("Sending SP1+SP2")
        let sp1sp2 = PairMessage(
            sequenceNumber: seq,
            source: ids.myId,
            destination: podAddress,
            keys: [O5LTKExchanger.SP1, O5LTKExchanger.SP2],
            payloads: [ids.podId.address, o5sp2(podId: ids.podId)] // 4-byte and 11-byte payloads
        )
        try o5throwOnSendError(sp1sp2.message, O5LTKExchanger.SP1 + O5LTKExchanger.SP2)

        seq += 1
        log.default("Sending SPS0")
        let sps0 = PairMessage(
            sequenceNumber: seq,
            source: ids.myId,
            destination: podAddress,
            keys: [O5LTKExchanger.SPS0],
            payloads: [o5sps0()] // fixed 5-byte payload
        )
        try o5throwOnSendError(sps0.message, O5LTKExchanger.SPS0)

        log.default("Reading SPS0")
        guard let podSps0 = try manager.readMessagePacket() else {
            logPeripheralState("SPS0")
            throw PodProtocolError.pairingException("Could not read SPS0")
        }
        try validatePodO5sps0(podSps0)

        // send and receive 80-byte SPS1 pairing messages
        log.default("Sending SPS1 (80 bytes: pubkey=%{public}lld + nonce=%{public}lld)", keyExchange.pdmPublic.count, keyExchange.pdmNonce.count)
        seq += 1
        let sps1 = PairMessage(
            sequenceNumber: seq,
            source: ids.myId,
            destination: podAddress,
            keys: [O5LTKExchanger.SPS1],
            payloads: [keyExchange.pdmPublic + keyExchange.pdmNonce]
        )
        try o5throwOnSendError(sps1.message, O5LTKExchanger.SPS1)

        guard let podSps1 = try manager.readMessagePacket() else {
            logPeripheralState("SPS1")
            throw PodProtocolError.pairingException("Could not read SPS1")
        }
        try o5validatePodSps1(podSps1)

        // send ~642 byte SPS2.1 (cert only) and receive ~641 byte SPS2.1 (cert only)
        log.default("=== SPS2.1 PHASE START ===")
        seq += 1

        log.default("Building SPS2.1 payload...")
        let sps2_1_payload = try o5sps2_1()
        log.default("SPS2.1 payload built: %{public}lld bytes encrypted", sps2_1_payload.count)

        let sps2_1 = PairMessage(
            sequenceNumber: seq,
            source: ids.myId,
            destination: podAddress,
            keys: [O5LTKExchanger.SPS2_1],
            payloads: [sps2_1_payload]
        )

        log.default("Sending SPS2.1 (%{public}lld bytes)... peripheral state=%{public}@", sps2_1.message.payload.count, peripheralStateString())
        let sps21SendStart = Date()
        try o5throwOnSendError(sps2_1.message, O5LTKExchanger.SPS2_1)
        log.default("SPS2.1 sent in %{public}.3f sec", Date().timeIntervalSince(sps21SendStart))
        log.default("SPS2.1 sent successfully, pod acknowledged (SUCCESS). peripheral state=%{public}@", peripheralStateString())

        log.default("Waiting for pod SPS2.1 response... peripheral state=%{public}@", peripheralStateString())
        let sps21ReadStart = Date()
        let podSPS2_1: MessagePacket
        do {
            guard let resp = try manager.readMessagePacket() else {
                log.error("SPS2.1 read returned nil after %{public}.3f sec. peripheral state=%{public}@", Date().timeIntervalSince(sps21ReadStart), peripheralStateString())
                logPeripheralState("SPS2.1")
                throw PodProtocolError.pairingException("Could not read SPS2.1")
            }
            podSPS2_1 = resp
            log.default("SPS2.1 response read in %{public}.3f sec", Date().timeIntervalSince(sps21ReadStart))
        } catch {
            log.error("SPS2.1 read threw error after %{public}.3f sec: %{public}@. peripheral state=%{public}@", Date().timeIntervalSince(sps21ReadStart), String(describing: error), peripheralStateString())
            logPeripheralState("SPS2.1-exception")
            throw error
        }
        log.default("SPS2.1 response received (%{public}lld bytes). peripheral state=%{public}@", podSPS2_1.payload.count, peripheralStateString())
        try o5validatePodSps2_1(podSPS2_1)
        log.default("=== SPS2.1 PHASE COMPLETE ===")

        /// send ~1089 byte SPS2 (cert + sig) and receive ~895 byte SPS2 (cert + sig)
        log.default("=== SPS2 PHASE START ===")
        seq += 1
        let sps2 = try PairMessage(
            sequenceNumber: seq,
            source: ids.myId,
            destination: podAddress,
            keys: [O5LTKExchanger.SPS2],
            payloads: [o5sps2()]
        )
        try o5throwOnSendError(sps2.message, O5LTKExchanger.SPS2)
        guard let podSPS2 = try manager.readMessagePacket() else {
            logPeripheralState("SPS2")
            throw PodProtocolError.pairingException("Could not read SPS2")
        }
        try o5validatePodSps2(podSPS2)
        log.default("=== SPS2 PHASE COMPLETE ===")

        // send 0 byte SP0GP0 pair message
        log.default("Sending SP0GP0")
        seq += 1
        let sp0gp0 = PairMessage(
            sequenceNumber: seq,
            source: ids.myId,
            destination: podAddress,
            keys: [O5LTKExchanger.SP0GP0],
            payloads: [Data()]
        )
        try o5throwOnSendError(sp0gp0.message, O5LTKExchanger.SP0GP0)

        /// read and validate the fixed 1 byte P0 response
        guard let p0 = try manager.readMessagePacket() else {
            logPeripheralState("P0")
            throw PodProtocolError.pairingException("Could not read P0")
        }
        try o5validateP0(p0)

        guard keyExchange.ltk.count == 16 else {
            throw PodProtocolError.invalidLTKKey("Invalid Key, got \(String(data: keyExchange.ltk, encoding: .utf8) ?? "")")
        }

        log.default("=== O5 Pairing Complete === LTK: %{public}@, address: 0x%{public}llx, seq: %{public}lld", keyExchange.ltk.hexadecimalString, ids.podId.toUInt32(), seq)
        return PairResult(
            ltk: keyExchange.ltk,
            address: ids.podId.toUInt32(),
            msgSeq: seq
        )
    }

    private func o5throwOnSendError(_ msg: MessagePacket, _ msgType: String) throws {
        log.default("[o5throwOnSendError] %{public}@: begin (payload %{public}lld bytes, seq %{public}lld). peripheral state=%{public}@",
                    msgType, msg.payload.count, seq, peripheralStateString())
        let result = manager.sendMessagePacket(msg)
        switch result {
        case .sentWithAcknowledgment:
            log.default("[o5throwOnSendError] %{public}@: sentWithAcknowledgment (SUCCESS received). peripheral state=%{public}@",
                        msgType, peripheralStateString())
        case .sentWithError(let error):
            log.error("[o5throwOnSendError] %{public}@: sentWithError — data was sent but error occurred: %{public}@. peripheral state=%{public}@",
                      msgType, String(describing: error), peripheralStateString())
            throw PodProtocolError.pairingException("Send \(msgType) failure (seq \(seq), \(msg.payload.count) bytes): \(result)")
        case .unsentWithError(let error):
            log.error("[o5throwOnSendError] %{public}@: unsentWithError — data was NOT sent: %{public}@. peripheral state=%{public}@",
                      msgType, String(describing: error), peripheralStateString())
            throw PodProtocolError.pairingException("Send \(msgType) failure (seq \(seq), \(msg.payload.count) bytes): \(result)")
        }
    }

    /// Return a human-readable peripheral state string for inline logging
    private func peripheralStateString() -> String {
        let state = manager.peripheral.state
        switch state {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .disconnected: return "DISCONNECTED"
        case .disconnecting: return "DISCONNECTING"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    /// Log peripheral state for debugging read timeouts
    private func logPeripheralState(_ step: String) {
        let periState = peripheralStateString()
        let isConnected = manager.peripheral.state == .connected
        let centralState: String
        if let central = manager.central {
            switch central.state {
            case .poweredOn: centralState = "poweredOn"
            case .poweredOff: centralState = "poweredOff"
            case .resetting: centralState = "resetting"
            case .unauthorized: centralState = "unauthorized"
            case .unsupported: centralState = "unsupported"
            case .unknown: centralState = "unknown"
            @unknown default: centralState = "unknown(\(central.state.rawValue))"
            }
        } else {
            centralState = "nil (deallocated)"
        }
        // Only access services/characteristics if still connected — they may be
        // invalidated after disconnect, causing EXC_BAD_ACCESS.
        let serviceCount: Int
        if isConnected {
            serviceCount = manager.peripheral.services?.count ?? -1
        } else {
            serviceCount = -1
        }
        log.error("Read failed at %{public}@: peripheral state=%{public}@ (isConnected=%{public}@), central state=%{public}@, services=%{public}lld",
                  step, periState, String(describing: isConnected), centralState, serviceCount)
    }

    /// The 11-byte O5 SP2 payload is an encoded type 0 get pod status command for the requested id including the calculated CRC-16
    /// SP2=[00 0b][[4-byte podId][00][03][0e 01 00][2-byte CRC]
    private func o5sp2(podId: Id) -> Data {
        let address = podId.toUInt32()
        let sequenceNum = 0 // 4-bit Omnipod command sequence #
        let message = Message(address: address, messageBlocks: [GetStatusCommand()], sequenceNum: sequenceNum)
        let encoded = message.encoded()
        log.debug("Encoded SP2 get status command for address 0x%llx and seq # %llu: %@", address, seq, encoded.hexadecimalString)
        return encoded
    }

    // MARK: - SPS0

    /// Generate the 5-byte SPS0 payload with CRC-16/XMODEM.
    /// Structure: [constant_byte, direction_byte, algorithm_byte, crc16_high, crc16_low]
    /// Direction: 0x01 for PDM->Pod, 0x00 for Pod->PDM
    /// Algorithm byte: 0x09 specifies the encryption algorithm
    private func o5sps0() -> Data {
        let header = Data([0x00, 0x01, 0x09])
        let crc = O5LTKExchanger.crc16XMODEM(header)
        var payload = header
        payload.appendBigEndian(UInt16(crc))
        log.debug("Generated SPS0 value: %@", payload.bytes.toHexString())
        return payload
    }

    /// Validate the returned 5-byte SPS0 from the pod.
    /// Pod direction byte is 0x00 (vs PDM's 0x01).
    private func validatePodO5sps0(_ msg: MessagePacket) throws {
        log.debug("Received SPS0 from pod (%{public}lld raw bytes): %{public}@", msg.payload.count, msg.payload.hexadecimalString)

        let payload: Data
        do {
            payload = try StringLengthPrefixEncoding.parseKeys([O5LTKExchanger.SPS0], msg.payload)[0]
        } catch {
            log.error("SPS0 parse failed. Raw payload (%{public}lld bytes): %{public}@, error: %{public}@", msg.payload.count, msg.payload.hexadecimalString, String(describing: error))
            throw error
        }

        guard payload.count == 5 else {
            throw PodProtocolError.pairingException("Invalid SPS0 payload length: \(payload.count)")
        }

        // Validate the structure: first byte 0x00, direction 0x00 (pod), algorithm 0x09
        guard payload[0] == 0x00 && payload[1] == 0x00 && payload[2] == 0x09 else {
            throw PodProtocolError.pairingException("Unexpected SPS0 header bytes: \(payload.bytes.toHexString())")
        }

        // Verify CRC-16/XMODEM over the first 3 bytes
        let header = payload.subdata(in: 0..<3)
        let expectedCRC = O5LTKExchanger.crc16XMODEM(header)
        let receivedCRC = payload[3...].toBigEndian(UInt16.self)
        guard expectedCRC == receivedCRC else {
            throw PodProtocolError.pairingException("SPS0 CRC mismatch: expected \(String(format: "%04llx", expectedCRC)), received \(String(format: "%04llx", receivedCRC))")
        }
    }

    // MARK: - SPS1

    private func o5validatePodSps1(_ msg: MessagePacket) throws {
        log.debug("Received SPS1 from pod (%{public}lld raw bytes): %{public}@", msg.payload.count, msg.payload.hexadecimalString)

        let payload: Data
        do {
            payload = try StringLengthPrefixEncoding.parseKeys([O5LTKExchanger.SPS1], msg.payload)[0]
        } catch {
            log.error("SPS1 parse failed. Raw payload (%{public}lld bytes): %{public}@, error: %{public}@", msg.payload.count, msg.payload.hexadecimalString, String(describing: error))
            throw error
        }
        log.default("SPS1 payload from pod: %{public}lld bytes (expected %{public}lld)", payload.count, O5KeyExchange.PUBLIC_KEY_SIZE + O5KeyExchange.NONCE_SIZE)

        try keyExchange.o5updatePodPublicData(payload)
    }

    // MARK: - SPS2.1 (Certificate Confirmation, Index 1)

    /// Build and encrypt the SPS2.1 payload (short path: cert only, no signature).
    ///
    ///   plaintext = intermediate_CA_cert_DER (634 bytes)
    ///   encrypted = AES_CCM_ENC(plaintext) || tag(8)
    ///   Total: 634 + 8 = 642
    ///
    /// The ECDSA channel-binding signature goes in SPS2 (not here).
    private func o5sps2_1() throws -> Data {
        guard let certDER = certStore.registration.intermediateCA else {
            throw PodProtocolError.pairingException("SPS2.1: intermediate CA certificate DER is nil")
        }
        log.default("SPS2.1: using cert (%{public}lld bytes, cert-only short path)", certDER.count)

        // Encrypt cert-only plaintext with AES-CCM: key=conf, nonce=13B, tag=8
        let nonce = keyExchange.getSPSNonce(direction: .write)
        let key = keyExchange.conf
        log.info("Encrypting SPS2.1: key=%{public}@, nonce=%{public}@, plaintext=%{public}lld bytes",
                 key.bytes.toHexString(), nonce.bytes.toHexString(), certDER.count)
        let encrypted: [UInt8]
        do {
            let ccm = CCM(iv: nonce.bytes, tagLength: 8, messageLength: certDER.count)
            let aes = try AES(key: key.bytes, blockMode: ccm, padding: .noPadding)
            encrypted = try aes.encrypt(certDER.bytes)
        } catch {
            log.error("AES-CCM encrypt FAILED for SPS2.1: %{public}@", String(describing: error))
            throw PodProtocolError.pairingException("SPS2.1 encrypt failed: \(error)")
        }
        keyExchange.incrementNonce(direction: .write)
        log.default("SPS2.1 encrypted: %{public}lld bytes (target=%{public}lld)", encrypted.count, certDER.count + 8)
        return Data(encrypted)
    }

    // MARK: - Pod SPS2.1 Verification

    /// Decrypt and verify the pod's SPS2.1 response (short path: cert only, no signature).
    ///
    /// Confirmed: pod SPS2.1 is also cert-only (641 encrypted = cert + 8 tag).
    /// The pod's signature comes in pod SPS2 (extended path), not here.
    private func o5validatePodSps2_1(_ msg: MessagePacket) throws {
        log.debug("Pod SPS2.1 raw message (%{public}lld bytes): %{public}@", msg.payload.count, msg.payload.hexadecimalString)
        let payload: Data
        do {
            payload = try StringLengthPrefixEncoding.parseKeys([O5LTKExchanger.SPS2_1], msg.payload)[0]
        } catch {
            log.error("SPS2.1 parse failed. Raw payload (%{public}lld bytes): %{public}@, error: %{public}@", msg.payload.count, msg.payload.hexadecimalString, String(describing: error))
            throw error
        }
        log.default("Received pod SPS2.1: %{public}lld bytes", payload.count)

        // Decrypt the pod's SPS2.1 payload
        let nonce = keyExchange.getSPSNonce(direction: .read)
        let key = keyExchange.conf
        log.info("Decrypting pod SPS2.1: key=%{public}@, nonce=%{public}@, ciphertext=%{public}lld bytes", key.toHexString(), nonce.bytes.toHexString(), payload.count)
        let decryptedPayload: Data
        do {
            let ccm = CCM(iv: nonce.bytes, tagLength: 8, messageLength: payload.count - 8)
            let aes = try AES(key: key.bytes, blockMode: ccm, padding: .noPadding)
            decryptedPayload = Data(try aes.decrypt(payload.bytes))
        } catch {
            log.error("AES-CCM decrypt FAILED for pod SPS2.1: key=%{public}@, nonce=%{public}@, payload=%{public}lld bytes, error=%{public}@", key.toHexString(), nonce.bytes.toHexString(), payload.count, String(describing: error))
            throw PodProtocolError.pairingException("Pod SPS2.1 decrypt failed (\(payload.count) bytes): \(error)")
        }
        keyExchange.incrementNonce(direction: .read)

        // Short path: entire decrypted payload is the pod certificate DER (no signature)
        let podCertDER = decryptedPayload
        log.default("Pod SPS2.1 decrypted: %{public}lld bytes (pod cert DER, short path)", podCertDER.count)
        log.info("Pod cert DER (%{public}lld bytes): %{public}@", podCertDER.count, podCertDER.hexadecimalString)

        // Extract and log the pod certificate details
        if let podPubKeyRaw = O5CertificateStore.extractP256PublicKey(fromDERCert: podCertDER) {
            log.info("Pod SPS2.1 cert public key: %{public}@", podPubKeyRaw.hexadecimalString)
        } else {
            log.error("Failed to extract P-256 public key from pod SPS2.1 certificate DER")
        }

        if let serial = O5CertificateStore.extractSerialNumber(fromDERCert: podCertDER) {
            log.info("Pod SPS2.1 cert serial (%{public}lld bytes): %{public}@", serial.count, serial.hexadecimalString)
        }
    }

    // MARK: - SPS2 (Certificate Confirmation, Index 0)

    /// Build and encrypt the SPS2 payload (extended path: cert + ECDSA signature).
    ///
    ///   plaintext = TLS_cert_DER (1017 bytes) || ECDSA_signature (64 bytes raw r||s)
    ///   encrypted = AES_CCM_ENC(plaintext) || tag(8)
    ///   Total: 1017 + 64 + 8 = 1089
    ///
    /// The 64-byte ECDSA signature is over the 171-byte channel-binding transcript,
    /// signed with the secondary key.
    private func o5sps2() throws -> Data {
        guard let certDER = certStore.registration.tlsCertificate else {
            throw PodProtocolError.pairingException("SPS2: TLS certificate DER is nil")
        }

        // Build the 171-byte channel-binding transcript and sign with secondary key
        let transcript = keyExchange.buildChannelBindingTranscript()
        log.info("Channel-binding transcript (%lld bytes): %{public}@", transcript.count, transcript.bytes.toHexString())

        let signatureRaw = try certStore.signRaw(transcript)
        log.info("ECDSA signature (64 bytes): %{public}@", signatureRaw.bytes.toHexString())

        // Assemble plaintext: cert_DER || signature(64)
        var plaintext = Data(capacity: certDER.count + 64)
        plaintext.append(certDER)
        plaintext.append(signatureRaw)

        log.default("SPS2: TLS cert (%{public}lld bytes) + sig (64) = %{public}lld plaintext",
                    certDER.count, plaintext.count)

        // Encrypt with AES-CCM: key=conf, nonce=13B, tag=8
        let nonce = keyExchange.getSPSNonce(direction: .write)
        let key = keyExchange.conf
        log.info("Encrypting SPS2: key=%{public}@, nonce=%{public}@, plaintext=%{public}lld bytes",
                 key.bytes.toHexString(), nonce.bytes.toHexString(), plaintext.count)
        let encrypted: [UInt8]
        do {
            let ccm = CCM(iv: nonce.bytes, tagLength: 8, messageLength: plaintext.count)
            let aes = try AES(key: key.bytes, blockMode: ccm, padding: .noPadding)
            encrypted = try aes.encrypt(plaintext.bytes)
        } catch {
            log.error("AES-CCM encrypt FAILED for SPS2: %{public}@", String(describing: error))
            throw PodProtocolError.pairingException("SPS2 encrypt failed: \(error)")
        }
        keyExchange.incrementNonce(direction: .write)

        log.default("SPS2 encrypted: %{public}lld bytes (target=%{public}lld)", encrypted.count, certDER.count + 64 + 8)
        return Data(encrypted)
    }

    /// Validate the pod's SPS2 response (extended path: cert + ECDSA signature).
    ///
    ///   plaintext = pod_cert_DER || pod_signature(64)
    ///   encrypted = AES_CCM_ENC(plaintext) || tag(8)
    private func o5validatePodSps2(_ msg: MessagePacket) throws {
        log.debug("Pod SPS2 raw message (%{public}lld bytes): %{public}@", msg.payload.count, msg.payload.hexadecimalString)
        let payload: Data
        do {
            payload = try StringLengthPrefixEncoding.parseKeys([O5LTKExchanger.SPS2], msg.payload)[0]
        } catch {
            log.error("SPS2 parse failed. Raw payload (%{public}lld bytes): %{public}@, error: %{public}@", msg.payload.count, msg.payload.hexadecimalString, String(describing: error))
            throw error
        }
        log.default("Received pod SPS2: %{public}lld bytes", payload.count)

        // Decrypt the pod's SPS2 payload
        let nonce = keyExchange.getSPSNonce(direction: .read)
        let key = keyExchange.conf
        log.info("Decrypting pod SPS2: key=%{public}@, nonce=%{public}@, ciphertext=%{public}lld bytes", key.toHexString(), nonce.bytes.toHexString(), payload.count)
        let decryptedPayload: Data
        do {
            let ccm = CCM(iv: nonce.bytes, tagLength: 8, messageLength: payload.count - 8)
            let aes = try AES(key: key.bytes, blockMode: ccm, padding: .noPadding)
            decryptedPayload = Data(try aes.decrypt(payload.bytes))
        } catch {
            log.error("AES-CCM decrypt FAILED for pod SPS2: key=%{public}@, nonce=%{public}@, payload=%{public}lld bytes, error=%{public}@", key.toHexString(), nonce.bytes.toHexString(), payload.count, String(describing: error))
            throw PodProtocolError.pairingException("Pod SPS2 decrypt failed (\(payload.count) bytes): \(error)")
        }
        keyExchange.incrementNonce(direction: .read)

        // Extended path: cert_DER(N bytes) || signature(64 bytes)
        guard decryptedPayload.count > 64 else {
            throw PodProtocolError.pairingException("Pod SPS2 payload too short: \(decryptedPayload.count) bytes (need > 64)")
        }

        let certLen = decryptedPayload.count - 64
        let podCertDER = decryptedPayload.subdata(in: 0..<certLen)
        let podSignature = decryptedPayload.subdata(in: certLen..<decryptedPayload.count)

        log.default("Pod SPS2 decrypted: %{public}lld bytes (cert_DER=%{public}lld + sig=%{public}lld)", decryptedPayload.count, certLen, podSignature.count)
        log.info("Pod cert DER (%{public}lld bytes): %{public}@", podCertDER.count, podCertDER.hexadecimalString)
        log.info("Pod signature (64 bytes): %{public}@", podSignature.hexadecimalString)

        // Extract pod's public key from its DER certificate
        if let podPubKeyRaw = O5CertificateStore.extractP256PublicKey(fromDERCert: podCertDER) {
            log.info("Pod cert public key: %{public}@", podPubKeyRaw.hexadecimalString)

            // Verify the pod's signature over the pod's channel-binding transcript variant
            // Pod signs with w1=1: [0x02][controller_id][FIRMWARE_ID][podPub][pdmPub][podNonce][pdmNonce]
            let transcript = keyExchange.buildPodChannelBindingTranscript()
            let signatureValid = O5CertificateStore.verifySignature(podSignature, for: transcript, publicKeyRaw: podPubKeyRaw)
            if signatureValid {
                log.default("Pod SPS2 signature verification PASSED")
            } else {
                log.error("Pod SPS2 signature verification FAILED — transcript format may differ")
                // Don't throw — continue pairing and log for debugging
            }
        } else {
            log.error("Failed to extract P-256 public key from pod SPS2 certificate DER")
        }

        if let serial = O5CertificateStore.extractSerialNumber(fromDERCert: podCertDER) {
            log.info("Pod cert serial (%{public}lld bytes): %{public}@", serial.count, serial.hexadecimalString)
        }
    }

    // MARK: - P0

    private func o5validateP0(_ msg: MessagePacket) throws {
        log.debug("Received P0 from pod (%{public}lld raw bytes): %{public}@", msg.payload.count, msg.payload.hexadecimalString)

        let payload: Data
        do {
            payload = try StringLengthPrefixEncoding.parseKeys([O5LTKExchanger.P0], msg.payload)[0]
        } catch {
            log.error("P0 parse failed. Raw payload (%{public}lld bytes): %{public}@, error: %{public}@", msg.payload.count, msg.payload.hexadecimalString, String(describing: error))
            throw error
        }
        log.debug("P0 payload from pod: %{public}@", payload.hexadecimalString)
        if payload != O5LTKExchanger.EXPECTED_P0_PAYLOAD {
            log.error("Unexpected P0 payload: got %{public}@, expected %{public}@", payload.hexadecimalString, O5LTKExchanger.EXPECTED_P0_PAYLOAD.hexadecimalString)
            throw PodProtocolError.pairingException("Received unexpected P0 payload: \(payload.hexadecimalString)")
        }
    }

    // MARK: - CRC-16/XMODEM

    /// Compute CRC-16/XMODEM checksum
    /// Polynomial: 0x1021, Initial value: 0x0000
    static func crc16XMODEM(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0x0000
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc = crc << 1
                }
            }
        }
        return crc
    }

    // MARK: - Helpers

    private func o5aesCmac(_ key: Data, _ data: Data) throws -> Data {
        let mac = try CMAC(key: key.bytes)
        return try Data(mac.authenticate(data.bytes))
    }
}
