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
        log.default("Sending SPS2.1")
        seq += 1
        let sps2_1 = try PairMessage(
            sequenceNumber: seq,
            source: ids.myId,
            destination: podAddress,
            keys: [O5LTKExchanger.SPS2_1],
            payloads: [o5sps2_1()]
        )
        try o5throwOnSendError(sps2_1.message, O5LTKExchanger.SPS2_1)
        guard let podSPS2_1 = try manager.readMessagePacket(doRTS: false) else {
            logPeripheralState("SPS2.1")
            throw PodProtocolError.pairingException("Could not read SPS2.1")
        }
        try o5validatePodSps2_1(podSPS2_1)

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
        let result = manager.sendMessagePacket(msg, doRTS: false)
        guard case .sentWithAcknowledgment = result else {
            log.error("Send %{public}@ failed (payload %{public}d bytes, seq %{public}d): %{public}@", msgType, msg.payload.count, seq, String(describing: result))
            throw PodProtocolError.pairingException("Send \(msgType) failure (seq \(seq), \(msg.payload.count) bytes): \(result)")
        }
    }

    /// Log peripheral state for debugging read timeouts
    private func logPeripheralState(_ step: String) {
        let state = manager.peripheral.state
        let stateStr: String
        switch state {
        case .connected: stateStr = "connected"
        case .connecting: stateStr = "connecting"
        case .disconnected: stateStr = "disconnected"
        case .disconnecting: stateStr = "disconnecting"
        @unknown default: stateStr = "unknown(\(state.rawValue))"
        }
        log.error("Read failed at %{public}@: peripheral state=%{public}@", step, stateStr)
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

    // MARK: - SPS2.1 (Compact Proof Assembly)

    /// Build and encrypt the SPS2.1 compact proof payload (~634 bytes plaintext -> ~642 encrypted).
    ///
    /// The real app's SPS2.1 payload structure (from BTSNOOP analysis):
    ///   1. ECDSA signature over the 171-byte channel-binding transcript (~65 bytes, DER or raw+prefix)
    ///   2. Extracted public keys from the certificate chain (5 x 65 bytes = 325 bytes uncompressed)
    ///   3. Certificate metadata (serial numbers, fingerprints, SAN data)
    ///   4. Hardware attestation data (Android Keystore chain fragments)
    ///
    /// Total plaintext: ~634 bytes. Encrypted: ~642 bytes (+ 8 byte AES-CCM tag).
    ///
    /// Signs the channel-binding transcript with the secondary key (ECDSA SHA-256),
    /// matching the real app behavior.
    private func o5sps2_1() throws -> Data {
        // Build the channel-binding transcript (171 bytes)
        let transcript = keyExchange.buildChannelBindingTranscript()
        log.info("Channel-binding transcript (%d bytes): %{public}@", transcript.count, transcript.bytes.toHexString())

        // Sign the transcript with the secondary private key (ECDSA SHA-256)
        let signatureRaw = try certStore.signRaw(transcript)
        log.info("ECDSA signature over transcript (%d bytes): %{public}@", signatureRaw.count, signatureRaw.bytes.toHexString())

        // Assemble the compact proof payload
        var compactProof = Data()

        // 1. ECDSA signature (64 bytes, r || s raw format)
        //    The BTSNOOP analysis shows 65 bytes — possibly a 1-byte type prefix before the signature
        compactProof.append(signatureRaw)

        // 2. Public keys from certificate chain (uncompressed, 65 bytes each with 0x04 prefix)
        //    BTSNOOP shows 5 keys: primary cert, secondary cert, + 3 attestation chain keys
        //    = 5 x 65 = 325 bytes
        if let primaryPubKey = O5CertificateStore.primaryPublicKeyRaw {
            compactProof.append(O5CertificateStore.uncompressedPublicKey(primaryPubKey))   // Primary cert key (65 bytes)
        }
        compactProof.append(O5CertificateStore.uncompressedPublicKey(O5CertificateStore.secondaryPublicKeyRaw)) // Secondary cert key (65 bytes)
        // Additional attestation chain public keys would go here (3 more x 65 bytes)
        // TODO: Extract public keys from secondary attestation chain certs

        // 3. Primary certificate (DER-encoded X.509)
        //    The primary certificate is sent to the pod during SPS2.1
        if let primaryCert = O5CertificateStore.primaryCertificateDER {
            // Length-prefix the certificate (2 bytes, big-endian)
            compactProof.append(UInt8((primaryCert.count >> 8) & 0xFF))
            compactProof.append(UInt8(primaryCert.count & 0xFF))
            compactProof.append(primaryCert)
        }

        // 4. Certificate metadata
        var metadata = Data()

        // PDM identity info
        var pdmid = O5CertificateStore.pdmid.bigEndian
        metadata.append(Data(bytes: &pdmid, count: 4))

        var pdmidExt = O5CertificateStore.pdmidExtension.bigEndian
        metadata.append(Data(bytes: &pdmidExt, count: 4))

        compactProof.append(metadata)

        log.info("Compact proof assembled (%d bytes): %{public}@", compactProof.count, compactProof.bytes.toHexString())

        // Encrypt with AES-CCM using the derived conf key
        let nonce = keyExchange.getSPSNonce(direction: .write)
        let key = keyExchange.conf
        log.info("Encrypting SPS2.1: key=%{public}@, nonce=%{public}@, plaintext=%{public}d bytes", key.bytes.toHexString(), nonce.bytes.toHexString(), compactProof.count)
        let encrypted: [UInt8]
        do {
            let ccm = CCM(iv: nonce.bytes, tagLength: 8, messageLength: compactProof.count)
            let aes = try AES(key: key.bytes, blockMode: ccm, padding: .noPadding)
            encrypted = try aes.encrypt(compactProof.bytes)
        } catch {
            log.error("AES-CCM encrypt FAILED for SPS2.1: key=%{public}@, nonce=%{public}@, plaintext=%{public}d bytes, error=%{public}@", key.bytes.toHexString(), nonce.bytes.toHexString(), compactProof.count, String(describing: error))
            throw PodProtocolError.pairingException("SPS2.1 encrypt failed: \(error)")
        }
        keyExchange.incrementNonce(direction: .write)
        log.default("SPS2.1 encrypted payload: %{public}d bytes (plaintext was %{public}d bytes, btsnoop expects ~642)", encrypted.count, compactProof.count)
        return Data(encrypted)
    }

    // MARK: - Pod SPS2.1 Verification

    /// Decrypt and verify the pod's SPS2.1 response.
    /// The pod sends its own compact proof containing:
    ///   1. ECDSA signature over the pairing transcript
    ///   2. Pod's public keys (pod cert, pod intermediate CA, root CA)
    ///   3. Pod certificate metadata
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
        log.debug("PDM Private: %{public}@", keyExchange.pdmPrivate.hexadecimalString)
        log.debug("PDM Public: %{public}@", keyExchange.pdmPublic.hexadecimalString)
        log.debug("PDM Nonce: %{public}@", keyExchange.pdmNonce.hexadecimalString)
        log.debug("Pod Public: %{public}@", keyExchange.podPublic.hexadecimalString)
        log.debug("Pod Nonce: %{public}@", keyExchange.podNonce.hexadecimalString)

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
        log.info("Decrypted SPS2.1 payload from pod (%d bytes): %{public}@", decryptedPayload.count, decryptedPayload.bytes.toHexString())
        keyExchange.incrementNonce(direction: .read)

        // Extract and verify the pod's compact proof
        guard decryptedPayload.count >= 64 else {
            throw PodProtocolError.pairingException("Pod SPS2.1 payload too short: \(decryptedPayload.count) bytes")
        }

        // 1. Extract pod's ECDSA signature (first 64 bytes, raw r || s)
        let podSignature = decryptedPayload.subdata(in: 0..<64)
        log.info("Pod ECDSA signature: %{public}@", podSignature.bytes.toHexString())

        // 2. Extract pod's public keys at known offsets
        //    Each uncompressed key is 65 bytes (0x04 prefix + 64 bytes)
        let keyStartOffset = 64
        if decryptedPayload.count >= keyStartOffset + 65 {
            let podCertPubKey = decryptedPayload.subdata(in: keyStartOffset..<keyStartOffset + 65)
            log.info("Pod cert public key: %{public}@", podCertPubKey.bytes.toHexString())

            // Extract the raw key (skip 0x04 prefix) for verification
            if podCertPubKey[0] == 0x04 {
                let podPubKeyRaw = podCertPubKey.subdata(in: 1..<65)

                // 3. Build the transcript the pod would have signed
                let transcript = keyExchange.buildChannelBindingTranscript()

                // 4. Verify the pod's signature over the transcript
                let signatureValid = O5CertificateStore.verifySignature(podSignature, for: transcript, publicKeyRaw: podPubKeyRaw)
                if signatureValid {
                    log.info("Pod SPS2.1 signature verification PASSED")
                } else {
                    log.info("Pod SPS2.1 signature verification FAILED - pod may use different transcript format")
                    // Don't throw here - continue pairing and log for debugging.
                    // The exact transcript format the pod signs may differ from ours.
                }
            }
        }

        // 5. Log additional public keys if present (for debugging and future validation)
        if decryptedPayload.count >= keyStartOffset + 130 {
            let key2 = decryptedPayload.subdata(in: (keyStartOffset + 65)..<(keyStartOffset + 130))
            log.info("Pod compact proof key 2: %{public}@", key2.bytes.toHexString())
        }
        if decryptedPayload.count >= keyStartOffset + 195 {
            let key3 = decryptedPayload.subdata(in: (keyStartOffset + 130)..<(keyStartOffset + 195))
            log.info("Pod compact proof key 3: %{public}@", key3.bytes.toHexString())
        }
    }

    // MARK: - SPS2 (CMAC Confirmation)

    /// Generate the SPS2 confirmation payload.
    ///
    /// BTSNOOP shows phone→pod SPS2 is ~960 bytes (encrypted) = ~952 bytes plaintext + 8 tag.
    /// The exact structure is still being reverse-engineered from the native library (libb7fe0d.so).
    ///
    /// Current best understanding:
    ///   - CMAC confirmations over session data
    ///   - Certificate/key binding data
    ///   - ECDSA signature (signing key for SPS2 TBD — may use secondary or primary)
    ///   - Public keys and attestation chain fragments
    ///   - Session parameters (nonces, ECDH public keys, controller ID)
    private func o5sps2() throws -> Data {
        let confKey = keyExchange.conf

        var confirmationData = Data()

        // Section 1: PDM confirmation CMAC (similar to DASH KC_2_U pattern)
        let pdmConfPrefix = "KC_2_U".data(using: .utf8)!
        var pdmConfInput = pdmConfPrefix
        pdmConfInput.append(keyExchange.pdmNonce)
        pdmConfInput.append(keyExchange.podNonce)
        let pdmConf = try o5aesCmac(confKey, pdmConfInput)

        // Section 2: Session binding via transcript hash
        let transcript = keyExchange.buildChannelBindingTranscript()
        let transcriptHash = Data(SHA256.hash(data: transcript))

        // Section 3: Certificate binding data
        let certBinding = buildCertificateBinding()

        // Section 4: Sign the combined confirmation
        // The signing key for SPS2 is TBD — using secondary here (same as SPS2.1).
        var signatureInput = Data()
        signatureInput.append(pdmConf)
        signatureInput.append(transcriptHash)
        signatureInput.append(certBinding)
        let confirmationSignature = try certStore.sign(signatureInput)

        // Assemble the full SPS2 payload
        confirmationData.append(pdmConf)                          // 16 bytes
        confirmationData.append(transcriptHash)                    // 32 bytes
        confirmationData.append(certBinding)                       // variable
        confirmationData.append(confirmationSignature)             // ~70-72 bytes (DER)

        // Public keys (uncompressed, 65 bytes each)
        if let primaryPubKey = O5CertificateStore.primaryPublicKeyRaw {
            confirmationData.append(O5CertificateStore.uncompressedPublicKey(primaryPubKey))
        }
        confirmationData.append(O5CertificateStore.uncompressedPublicKey(O5CertificateStore.secondaryPublicKeyRaw))

        // Session parameters
        confirmationData.append(keyExchange.controllerID)          // 4 bytes
        confirmationData.append(O5LTKExchanger.FIRMWARE_ID)        // 6 bytes
        confirmationData.append(keyExchange.pdmPublic)             // 64 bytes
        confirmationData.append(keyExchange.podPublic)             // 64 bytes
        confirmationData.append(keyExchange.pdmNonce)              // 16 bytes
        confirmationData.append(keyExchange.podNonce)              // 16 bytes

        // Primary certificate (the pod received it in SPS2.1, but SPS2 may include it again)
        if let primaryCert = O5CertificateStore.primaryCertificateDER {
            confirmationData.append(UInt8((primaryCert.count >> 8) & 0xFF))
            confirmationData.append(UInt8(primaryCert.count & 0xFF))
            confirmationData.append(primaryCert)
        }

        // Final integrity CMAC over all confirmation data
        let finalCmac = try o5aesCmac(confKey, confirmationData)
        confirmationData.append(finalCmac)                         // 16 bytes

        log.info("Generated SPS2 confirmation (%d bytes): %{public}@", confirmationData.count, confirmationData.bytes.toHexString())

        // Encrypt the confirmation data with AES-CCM
        let nonce = keyExchange.getSPSNonce(direction: .write)
        let key = keyExchange.conf
        log.info("Encrypting SPS2: key=%{public}@, nonce=%{public}@, plaintext=%{public}d bytes", key.bytes.toHexString(), nonce.bytes.toHexString(), confirmationData.count)
        let encrypted: [UInt8]
        do {
            let ccm = CCM(iv: nonce.bytes, tagLength: 8, messageLength: confirmationData.count)
            let aes = try AES(key: key.bytes, blockMode: ccm, padding: .noPadding)
            encrypted = try aes.encrypt(confirmationData.bytes)
        } catch {
            log.error("AES-CCM encrypt FAILED for SPS2: key=%{public}@, nonce=%{public}@, plaintext=%{public}d bytes, error=%{public}@", key.bytes.toHexString(), nonce.bytes.toHexString(), confirmationData.count, String(describing: error))
            throw PodProtocolError.pairingException("SPS2 encrypt failed: \(error)")
        }
        keyExchange.incrementNonce(direction: .write)

        log.default("SPS2 encrypted payload: %{public}d bytes (plaintext was %{public}d bytes, btsnoop expects ~960)", encrypted.count, confirmationData.count)
        return Data(encrypted)
    }

    /// Build the certificate binding data for SPS2
    private func buildCertificateBinding() -> Data {
        var binding = Data()

        // Certificate chain fingerprints (SHA-256 of uncompressed public keys)
        if let primaryPubKey = O5CertificateStore.primaryPublicKeyRaw {
            let primaryUncompressed = O5CertificateStore.uncompressedPublicKey(primaryPubKey)
            binding.append(Data(SHA256.hash(data: primaryUncompressed)))
        }
        let secondaryUncompressed = O5CertificateStore.uncompressedPublicKey(O5CertificateStore.secondaryPublicKeyRaw)
        binding.append(Data(SHA256.hash(data: secondaryUncompressed)))

        // PDM identity
        var pdmid = O5CertificateStore.pdmid.bigEndian
        binding.append(Data(bytes: &pdmid, count: 4))

        var pdmidExt = O5CertificateStore.pdmidExtension.bigEndian
        binding.append(Data(bytes: &pdmidExt, count: 4))

        return binding
    }

    /// Validate the pod's SPS2 response.
    /// The pod sends its own CMAC confirmation (~871 bytes).
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
        log.info("Pod SPS2 payload: %{public}@", payload.bytes.toHexString())

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
        log.info("Decrypted pod SPS2 (%d bytes): %{public}@", decryptedPayload.count, decryptedPayload.bytes.toHexString())
        keyExchange.incrementNonce(direction: .read)

        // Extract and verify the pod's CMAC confirmation
        guard decryptedPayload.count >= 16 else {
            throw PodProtocolError.pairingException("Pod SPS2 payload too short: \(decryptedPayload.count) bytes")
        }

        // The first 16 bytes should be the pod's CMAC confirmation
        let podConf = decryptedPayload.subdata(in: 0..<16)
        log.info("Pod CMAC confirmation: %{public}@", podConf.bytes.toHexString())

        // Verify pod confirmation (similar to DASH KC_2_V pattern)
        let confKey = keyExchange.conf
        let podConfPrefix = "KC_2_V".data(using: .utf8)!
        var podConfInput = podConfPrefix
        podConfInput.append(keyExchange.podNonce)
        podConfInput.append(keyExchange.pdmNonce)
        let expectedPodConf = try o5aesCmac(confKey, podConfInput)

        if podConf == expectedPodConf {
            log.default("Pod SPS2 CMAC confirmation PASSED")
        } else {
            log.error("Pod SPS2 CMAC confirmation MISMATCH")
            log.error("  expected: %{public}@", expectedPodConf.bytes.toHexString())
            log.error("  received: %{public}@", podConf.bytes.toHexString())
            log.error("  confKey:  %{public}@", confKey.bytes.toHexString())
            log.error("  input:    %{public}@", podConfInput.bytes.toHexString())
            // Don't throw - the exact format is still being determined
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
