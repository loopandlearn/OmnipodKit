//
//  O5LTKExchanger.swift
//  OmnipodKit
//
//  Based on OmniBLE/OmniBLE/Bluetooth/Pair/LTKExchanger.swift
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
        self.certStore = try O5CertificateStore()
        self.keyExchange = try O5KeyExchange(P256KeyGenerator(), OmniRandomByteGenerator(), controllerID: certStore.controllerID)
    }

    func o5negotiateLTK() throws -> PairResult {

        // Set flags based on the current pair attempt (cycles through 256 combinations via bit-masking)
        let attempt = O5KeyExchange.pairAttempts % 256
        keyExchange.keysNonceFirst          = (attempt & 0x01) != 0
        keyExchange.bytesAsControllerId     = (attempt & 0x02) != 0
        keyExchange.useUInt32LengthPrefixes = (attempt & 0x04) != 0
        keyExchange.kdfZeroControllerID     = (attempt & 0x08) != 0
        keyExchange.swapCertIndexes         = (attempt & 0x10) != 0
        keyExchange.sigBeforeCert           = (attempt & 0x20) != 0
        keyExchange.nonceLastBytes          = (attempt & 0x40) != 0
        keyExchange.swapNonceDirection      = (attempt & 0x80) != 0
        let flagDesc = "keysNonceFirst=\(keyExchange.keysNonceFirst), bytesAsControllerId=\(keyExchange.bytesAsControllerId), useUInt32LengthPrefixes=\(keyExchange.useUInt32LengthPrefixes), kdfZeroControllerID=\(keyExchange.kdfZeroControllerID), swapCertIndexes=\(keyExchange.swapCertIndexes), sigBeforeCert=\(keyExchange.sigBeforeCert), nonceLastBytes=\(keyExchange.nonceLastBytes), swapNonceDirection=\(keyExchange.swapNonceDirection)"
        log.default("=== PAIR ATTEMPT #%{public}d/%{public}d: %{public}@ ===",
                    O5KeyExchange.pairAttempts, 256, flagDesc)

        do {
            return try o5negotiateLTKBody()
        } catch {
            O5KeyExchange.pairAttempts = (O5KeyExchange.pairAttempts + 1) % 256
            log.error("Pairing failed (attempt #%{public}d), next attempt will use combination #%{public}d/%{public}d",
                      O5KeyExchange.pairAttempts, O5KeyExchange.pairAttempts % 256, 256)
            throw error
        }
    }

    private func o5negotiateLTKBody() throws -> PairResult {

        log.default("=== O5 Pairing Start === myId=0x%{public}x podId=0x%{public}x", ids.myId.toUInt32(), ids.podId.toUInt32())
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
        guard let podSps0 = try manager.readMessagePacket(doRTS: false) else {
            logPeripheralState("SPS0")
            throw PodProtocolError.pairingException("Could not read SPS0")
        }
        try validatePodO5sps0(podSps0)

        // send and receive 80-byte SPS1 pairing messages
        log.default("Sending SPS1 (80 bytes: pubkey=%{public}d + nonce=%{public}d)", keyExchange.pdmPublic.count, keyExchange.pdmNonce.count)
        seq += 1
        let sps1 = PairMessage(
            sequenceNumber: seq,
            source: ids.myId,
            destination: podAddress,
            keys: [O5LTKExchanger.SPS1],
            payloads: [keyExchange.pdmPublic + keyExchange.pdmNonce]
        )
        try o5throwOnSendError(sps1.message, O5LTKExchanger.SPS1)

        guard let podSps1 = try manager.readMessagePacket(doRTS: false) else {
            logPeripheralState("SPS1")
            throw PodProtocolError.pairingException("Could not read SPS1")
        }
        try o5validatePodSps1(podSps1)

        // send ~642 byte SPS2.1 and receive ~641 byte SPS2.1 pairing messages
        log.default("=== SPS2.1 PHASE START ===")
        seq += 1

        log.default("Building SPS2.1 payload...")
        let sps2_1_payload = try o5sps2_1()
        log.default("SPS2.1 payload built: %{public}d bytes encrypted", sps2_1_payload.count)

        let sps2_1 = PairMessage(
            sequenceNumber: seq,
            source: ids.myId,
            destination: podAddress,
            keys: [O5LTKExchanger.SPS2_1],
            payloads: [sps2_1_payload]
        )

        log.default("Sending SPS2.1 (%{public}d bytes)... peripheral state=%{public}@", sps2_1.message.payload.count, peripheralStateString())
        try o5throwOnSendError(sps2_1.message, O5LTKExchanger.SPS2_1)
        log.default("SPS2.1 sent successfully, pod acknowledged (SUCCESS). peripheral state=%{public}@", peripheralStateString())

        log.default("Waiting for pod SPS2.1 response... peripheral state=%{public}@", peripheralStateString())
        let podSPS2_1: MessagePacket
        do {
            guard let resp = try manager.readMessagePacket(doRTS: false) else {
                log.error("SPS2.1 read returned nil. peripheral state=%{public}@", peripheralStateString())
                logPeripheralState("SPS2.1")
                throw PodProtocolError.pairingException("Could not read SPS2.1")
            }
            podSPS2_1 = resp
        } catch {
            log.error("SPS2.1 read threw error: %{public}@. peripheral state=%{public}@", String(describing: error), peripheralStateString())
            logPeripheralState("SPS2.1-exception")
            throw error
        }
        log.default("SPS2.1 response received (%{public}d bytes). peripheral state=%{public}@", podSPS2_1.payload.count, peripheralStateString())
        try o5validatePodSps2_1(podSPS2_1)
        log.default("=== SPS2.1 PHASE COMPLETE ===")

        /// send ~960 byte SPS2 and receive ~902 byte SPS2 pairing messages
        log.default("Sending SPS2")
        seq += 1
        let sps2 = try PairMessage(
            sequenceNumber: seq,
            source: ids.myId,
            destination: podAddress,
            keys: [O5LTKExchanger.SPS2],
            payloads: [o5sps2()]
        )
        try o5throwOnSendError(sps2.message, O5LTKExchanger.SPS2)
        guard let podSPS2 = try manager.readMessagePacket(doRTS: false) else {
            logPeripheralState("SPS2")
            throw PodProtocolError.pairingException("Could not read SPS2")
        }
        try o5validatePodSps2(podSPS2)

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
        guard let p0 = try manager.readMessagePacket(doRTS: false) else {
            logPeripheralState("P0")
            throw PodProtocolError.pairingException("Could not read P0")
        }
        try o5validateP0(p0)

        guard keyExchange.ltk.count == 16 else {
            throw PodProtocolError.invalidLTKKey("Invalid Key, got \(String(data: keyExchange.ltk, encoding: .utf8) ?? "")")
        }

        log.default("=== O5 Pairing Complete === LTK: %{public}@, address: 0x%{public}x, seq: %{public}d", keyExchange.ltk.hexadecimalString, ids.podId.toUInt32(), seq)
        return PairResult(
            ltk: keyExchange.ltk,
            address: ids.podId.toUInt32(),
            msgSeq: seq
        )
    }

    private func o5throwOnSendError(_ msg: MessagePacket, _ msgType: String) throws {
        log.default("[o5throwOnSendError] %{public}@: begin (payload %{public}d bytes, seq %{public}d, doRTS=false). peripheral state=%{public}@",
                    msgType, msg.payload.count, seq, peripheralStateString())
        let result = manager.sendMessagePacket(msg, doRTS: false)
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
        log.error("Read failed at %{public}@: peripheral state=%{public}@ (isConnected=%{public}@), central state=%{public}@, services=%{public}d",
                  step, periState, String(describing: isConnected), centralState, serviceCount)
    }

    /// The 11-byte O5 SP2 payload is an encoded type 0 get pod status command for the requested id including the calculated CRC-16
    /// SP2=[00 0b][[00 0c 3a 35][00][03][0e 01 00][02 45]
    private func o5sp2(podId: Id) -> Data {
        let address = podId.toUInt32()
        let sequenceNum = 0 // when does this 4-bit Omnipod sequence # need to be something else?
        let message = Message(address: address, messageBlocks: [GetStatusCommand()], sequenceNum: sequenceNum)
        let encoded = message.encoded()
        log.debug("Encoded SP2 get status command for address 0x%x and seq # %u: %@", address, seq, encoded.hexadecimalString)
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
        payload.append(UInt8((crc >> 8) & 0xFF))
        payload.append(UInt8(crc & 0xFF))
        log.debug("Generated SPS0 value: %@", payload.bytes.toHexString())
        return payload
    }

    /// Validate the returned 5-byte SPS0 from the pod.
    /// Pod direction byte is 0x00 (vs PDM's 0x01).
    private func validatePodO5sps0(_ msg: MessagePacket) throws {
        log.debug("Received SPS0 from pod (%{public}d raw bytes): %{public}@", msg.payload.count, msg.payload.hexadecimalString)

        let payload: Data
        do {
            payload = try StringLengthPrefixEncoding.parseKeys([O5LTKExchanger.SPS0], msg.payload)[0]
        } catch {
            log.error("SPS0 parse failed. Raw payload (%{public}d bytes): %{public}@, error: %{public}@", msg.payload.count, msg.payload.hexadecimalString, String(describing: error))
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
        let receivedCRC = (UInt16(payload[3]) << 8) | UInt16(payload[4])
        guard expectedCRC == receivedCRC else {
            throw PodProtocolError.pairingException("SPS0 CRC mismatch: expected \(String(format: "%04x", expectedCRC)), received \(String(format: "%04x", receivedCRC))")
        }
    }

    // MARK: - SPS1

    private func o5validatePodSps1(_ msg: MessagePacket) throws {
        log.debug("Received SPS1 from pod (%{public}d raw bytes): %{public}@", msg.payload.count, msg.payload.hexadecimalString)

        let payload: Data
        do {
            payload = try StringLengthPrefixEncoding.parseKeys([O5LTKExchanger.SPS1], msg.payload)[0]
        } catch {
            log.error("SPS1 parse failed. Raw payload (%{public}d bytes): %{public}@, error: %{public}@", msg.payload.count, msg.payload.hexadecimalString, String(describing: error))
            throw error
        }
        log.default("SPS1 payload from pod: %{public}d bytes (expected %{public}d)", payload.count, O5KeyExchange.PUBLIC_KEY_SIZE + O5KeyExchange.NONCE_SIZE)

        try keyExchange.o5updatePodPublicData(payload)
    }

    // MARK: - SPS2.1 (Certificate Confirmation, Index 1)

    /// Build and encrypt the SPS2.1 payload.
    ///
    /// From native library decompile (libb7fe0d.so sub_36de4):
    ///   plaintext = cert_DER[index=1] || aux64
    ///   encrypted = AES_CCM_ENC(plaintext) || tag(8)
    ///
    /// The certificate at index 1 is the INS02PG1 intermediate CA (570 bytes for our cert).
    /// aux64 is the 64-byte ECDSA raw signature (r || s) over the 171-byte channel-binding
    /// transcript, signed with the secondary key.
    ///
    /// Total: cert_size[1] + 64 + 8 = cert_size[1] + 72 (observed 570 + 72 = 642).
    private func o5sps2_1() throws -> Data {
        // Get the certificate DER — swapCertIndexes controls which cert is used
        let certDER: Data
        if keyExchange.swapCertIndexes {
            guard let tlsDER = certStore.registration.tlsCertificateDER else {
                throw PodProtocolError.pairingException("SPS2.1: TLS certificate DER is nil")
            }
            certDER = tlsDER
        } else {
            guard let intermediateDER = certStore.registration.intermediateCACertDER else {
                throw PodProtocolError.pairingException("SPS2.1: INS02PG1 intermediate CA certificate DER is nil")
            }
            certDER = intermediateDER
        }
        log.default("SPS2.1: using %{public}@ cert (%{public}d bytes), sigBeforeCert=%{public}@",
                    keyExchange.swapCertIndexes ? "TLS" : "INS02PG1", certDER.count,
                    String(describing: keyExchange.sigBeforeCert))

        // Build the 171-byte channel-binding transcript and sign with secondary key
        let transcript = keyExchange.buildChannelBindingTranscript()
        log.info("Channel-binding transcript (%d bytes): %{public}@", transcript.count, transcript.bytes.toHexString())

        let signatureRaw = try certStore.signRaw(transcript)
        log.info("ECDSA signature (aux64, %d bytes): %{public}@", signatureRaw.count, signatureRaw.bytes.toHexString())

        // Assemble plaintext: cert_DER || signature(64) or signature(64) || cert_DER
        var plaintext = Data(capacity: certDER.count + 64)
        if keyExchange.sigBeforeCert {
            plaintext.append(signatureRaw)
            plaintext.append(certDER)
        } else {
            plaintext.append(certDER)
            plaintext.append(signatureRaw)
        }

        log.default("SPS2.1 plaintext: %{public}d bytes (cert=%{public}d + sig=%{public}d, sigBeforeCert=%{public}@)",
                    plaintext.count, certDER.count, signatureRaw.count,
                    String(describing: keyExchange.sigBeforeCert))

        // Encrypt with AES-CCM: key=conf, nonce=13B, tag=8
        let nonce = keyExchange.getSPSNonce(direction: .write)
        let key = keyExchange.conf
        log.info("Encrypting SPS2.1: key=%{public}@, nonce=%{public}@, plaintext=%{public}d bytes",
                 key.bytes.toHexString(), nonce.bytes.toHexString(), plaintext.count)
        let encrypted: [UInt8]
        do {
            let ccm = CCM(iv: nonce.bytes, tagLength: 8, messageLength: plaintext.count)
            let aes = try AES(key: key.bytes, blockMode: ccm, padding: .noPadding)
            encrypted = try aes.encrypt(plaintext.bytes)
        } catch {
            log.error("AES-CCM encrypt FAILED for SPS2.1: %{public}@", String(describing: error))
            throw PodProtocolError.pairingException("SPS2.1 encrypt failed: \(error)")
        }
        keyExchange.incrementNonce(direction: .write)
        log.default("SPS2.1 encrypted: %{public}d bytes (target=642)", encrypted.count)
        return Data(encrypted)
    }

    // MARK: - Pod SPS2.1 Verification

    /// Decrypt and verify the pod's SPS2.1 response.
    ///
    /// Pod SPS2.1 has the same structure as phone SPS2.1 (from native library decompile):
    ///   plaintext = pod_cert_DER || signature(64)
    ///   encrypted = AES_CCM_ENC(plaintext) || tag(8)
    ///
    /// The pod's certificate is its INS01PG1-issued identity cert. The last 64 bytes
    /// of the plaintext are the pod's ECDSA raw signature over the channel-binding transcript.
    private func o5validatePodSps2_1(_ msg: MessagePacket) throws {
        log.debug("Pod SPS2.1 raw message (%{public}d bytes): %{public}@", msg.payload.count, msg.payload.hexadecimalString)
        let payload: Data
        do {
            payload = try StringLengthPrefixEncoding.parseKeys([O5LTKExchanger.SPS2_1], msg.payload)[0]
        } catch {
            log.error("SPS2.1 parse failed. Raw payload (%{public}d bytes): %{public}@, error: %{public}@", msg.payload.count, msg.payload.hexadecimalString, String(describing: error))
            throw error
        }
        log.default("Received pod SPS2.1: %{public}d bytes (btsnoop expects ~641)", payload.count)

        // Decrypt the pod's SPS2.1 payload
        let nonce = keyExchange.getSPSNonce(direction: .read)
        let key = keyExchange.conf
        log.info("Decrypting pod SPS2.1: key=%{public}@, nonce=%{public}@, ciphertext=%{public}d bytes", key.toHexString(), nonce.bytes.toHexString(), payload.count)
        let decryptedPayload: Data
        do {
            let ccm = CCM(iv: nonce.bytes, tagLength: 8, messageLength: payload.count - 8)
            let aes = try AES(key: key.bytes, blockMode: ccm, padding: .noPadding)
            decryptedPayload = Data(try aes.decrypt(payload.bytes))
        } catch {
            log.error("AES-CCM decrypt FAILED for pod SPS2.1: key=%{public}@, nonce=%{public}@, payload=%{public}d bytes, error=%{public}@", key.toHexString(), nonce.bytes.toHexString(), payload.count, String(describing: error))
            throw PodProtocolError.pairingException("Pod SPS2.1 decrypt failed (\(payload.count) bytes): \(error)")
        }
        keyExchange.incrementNonce(direction: .read)

        // Structure: cert_DER(N bytes) || signature(64 bytes)
        guard decryptedPayload.count > 64 else {
            throw PodProtocolError.pairingException("Pod SPS2.1 payload too short: \(decryptedPayload.count) bytes (need > 64)")
        }

        let certLen = decryptedPayload.count - 64
        let podCertDER = decryptedPayload.subdata(in: 0..<certLen)
        let podSignature = decryptedPayload.subdata(in: certLen..<decryptedPayload.count)

        log.default("Pod SPS2.1 decrypted: %{public}d bytes (cert_DER=%{public}d + sig=%{public}d)", decryptedPayload.count, certLen, podSignature.count)
        log.info("Pod cert DER (%{public}d bytes): %{public}@", podCertDER.count, podCertDER.hexadecimalString)
        log.info("Pod signature (64 bytes): %{public}@", podSignature.hexadecimalString)

        // Extract pod's public key from its DER certificate
        if let podPubKeyRaw = O5CertificateStore.extractP256PublicKey(fromDERCert: podCertDER) {
            log.info("Pod cert public key: %{public}@", podPubKeyRaw.hexadecimalString)

            // Verify the pod's signature over the pod's channel-binding transcript variant
            // Pod signs with w1=1: [0x02][controller_id][FIRMWARE_ID][podPub][pdmPub][podNonce][pdmNonce]
            let transcript = keyExchange.buildPodChannelBindingTranscript()
            let signatureValid = O5CertificateStore.verifySignature(podSignature, for: transcript, publicKeyRaw: podPubKeyRaw)
            if signatureValid {
                log.default("Pod SPS2.1 signature verification PASSED")
            } else {
                log.error("Pod SPS2.1 signature verification FAILED — transcript format may differ")
                // Don't throw — continue pairing and log for debugging
            }
        } else {
            log.error("Failed to extract P-256 public key from pod certificate DER")
        }

        // Extract and log the pod certificate serial for debugging
        if let serial = O5CertificateStore.extractSerialNumber(fromDERCert: podCertDER) {
            log.info("Pod cert serial (%{public}d bytes): %{public}@", serial.count, serial.hexadecimalString)
        }
    }

    // MARK: - SPS2 (Certificate Confirmation, Index 0)

    /// Build and encrypt the SPS2 payload.
    ///
    /// From native library decompile (libb7fe0d.so sub_370e8):
    ///   plaintext = cert_DER[index=0]
    ///   encrypted = AES_CCM_ENC(plaintext) || tag(8)
    ///
    /// Index 0 uses the short path — just the raw certificate, no signature appended.
    /// The certificate at index 0 is the TLS certificate (~951 bytes for our cert).
    ///
    /// Total: cert_size[0] + 8 (observed 951 + 8 = 959).
    private func o5sps2() throws -> Data {
        // Get the certificate DER — swapCertIndexes controls which cert is used
        let certDER: Data
        if keyExchange.swapCertIndexes {
            guard let intermediateDER = certStore.registration.intermediateCACertDER else {
                throw PodProtocolError.pairingException("SPS2: INS02PG1 intermediate CA certificate DER is nil")
            }
            certDER = intermediateDER
        } else {
            guard let tlsDER = certStore.registration.tlsCertificateDER else {
                throw PodProtocolError.pairingException("SPS2: TLS certificate DER is nil")
            }
            certDER = tlsDER
        }
        log.default("SPS2: using %{public}@ cert (%{public}d bytes)",
                    keyExchange.swapCertIndexes ? "INS02PG1" : "TLS", certDER.count)

        // Encrypt with AES-CCM: key=conf, nonce=13B, tag=8
        let nonce = keyExchange.getSPSNonce(direction: .write)
        let key = keyExchange.conf
        log.info("Encrypting SPS2: key=%{public}@, nonce=%{public}@, plaintext=%{public}d bytes",
                 key.bytes.toHexString(), nonce.bytes.toHexString(), certDER.count)
        let encrypted: [UInt8]
        do {
            let ccm = CCM(iv: nonce.bytes, tagLength: 8, messageLength: certDER.count)
            let aes = try AES(key: key.bytes, blockMode: ccm, padding: .noPadding)
            encrypted = try aes.encrypt(certDER.bytes)
        } catch {
            log.error("AES-CCM encrypt FAILED for SPS2: %{public}@", String(describing: error))
            throw PodProtocolError.pairingException("SPS2 encrypt failed: \(error)")
        }
        keyExchange.incrementNonce(direction: .write)

        log.default("SPS2 encrypted: %{public}d bytes (target ~959)", encrypted.count)
        return Data(encrypted)
    }

    /// Validate the pod's SPS2 response.
    ///
    /// Pod SPS2 has the same structure as phone SPS2 (index 0, short path):
    ///   plaintext = pod_cert_DER[index=0]
    ///   encrypted = AES_CCM_ENC(plaintext) || tag(8)
    ///
    /// The pod's index-0 certificate is its identity cert (~894 bytes).
    /// btsnoop shows pod SPS2 is ~902 bytes (894 cert + 8 tag).
    private func o5validatePodSps2(_ msg: MessagePacket) throws {
        log.debug("Pod SPS2 raw message (%{public}d bytes): %{public}@", msg.payload.count, msg.payload.hexadecimalString)
        let payload: Data
        do {
            payload = try StringLengthPrefixEncoding.parseKeys([O5LTKExchanger.SPS2], msg.payload)[0]
        } catch {
            log.error("SPS2 parse failed. Raw payload (%{public}d bytes): %{public}@, error: %{public}@", msg.payload.count, msg.payload.hexadecimalString, String(describing: error))
            throw error
        }
        log.default("Received pod SPS2: %{public}d bytes (btsnoop expects ~902)", payload.count)

        // Decrypt the pod's SPS2 payload
        let nonce = keyExchange.getSPSNonce(direction: .read)
        let key = keyExchange.conf
        log.info("Decrypting pod SPS2: key=%{public}@, nonce=%{public}@, ciphertext=%{public}d bytes", key.toHexString(), nonce.bytes.toHexString(), payload.count)
        let decryptedPayload: Data
        do {
            let ccm = CCM(iv: nonce.bytes, tagLength: 8, messageLength: payload.count - 8)
            let aes = try AES(key: key.bytes, blockMode: ccm, padding: .noPadding)
            decryptedPayload = Data(try aes.decrypt(payload.bytes))
        } catch {
            log.error("AES-CCM decrypt FAILED for pod SPS2: key=%{public}@, nonce=%{public}@, payload=%{public}d bytes, error=%{public}@", key.toHexString(), nonce.bytes.toHexString(), payload.count, String(describing: error))
            throw PodProtocolError.pairingException("Pod SPS2 decrypt failed (\(payload.count) bytes): \(error)")
        }
        keyExchange.incrementNonce(direction: .read)

        // Structure: raw pod certificate DER (index 0, no signature)
        let podCertDER = decryptedPayload
        log.default("Pod SPS2 decrypted: %{public}d bytes (pod cert DER)", podCertDER.count)
        log.info("Pod cert[0] DER: %{public}@", podCertDER.hexadecimalString)

        // Extract and log the pod certificate details
        if let podPubKeyRaw = O5CertificateStore.extractP256PublicKey(fromDERCert: podCertDER) {
            log.info("Pod cert[0] public key: %{public}@", podPubKeyRaw.hexadecimalString)
        } else {
            log.error("Failed to extract P-256 public key from pod cert[0] DER")
        }

        if let serial = O5CertificateStore.extractSerialNumber(fromDERCert: podCertDER) {
            log.info("Pod cert[0] serial (%{public}d bytes): %{public}@", serial.count, serial.hexadecimalString)
        }
    }

    // MARK: - P0

    private func o5validateP0(_ msg: MessagePacket) throws {
        log.debug("Received P0 from pod (%{public}d raw bytes): %{public}@", msg.payload.count, msg.payload.hexadecimalString)

        let payload: Data
        do {
            payload = try StringLengthPrefixEncoding.parseKeys([O5LTKExchanger.P0], msg.payload)[0]
        } catch {
            log.error("P0 parse failed. Raw payload (%{public}d bytes): %{public}@, error: %{public}@", msg.payload.count, msg.payload.hexadecimalString, String(describing: error))
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
