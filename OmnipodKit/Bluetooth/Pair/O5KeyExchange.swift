//
//  O5KeyExchange.swift
//  OmnipodKit
//
//  Created by Joe Moran on 3/25/25.
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//

import Foundation
import CryptoSwift
import os.log

enum Direction {
    case write
    case read
}

class O5KeyExchange {
    static let CMAC_SIZE = 16

    static let PUBLIC_KEY_SIZE = 64
    static let NONCE_SIZE = 16

    private let log = OSLog(category: "O5KeyExchange")

    private let INTERMEDIARY_KEY_MAGIC_STRING = "TWIt".data(using: .utf8)
    private let PDM_CONF_MAGIC_PREFIX = "KC_2_U".data(using: .utf8)
    private let POD_CONF_MAGIC_PREFIX = "KC_2_V".data(using: .utf8)

    var pdmNonce: Data
    let pdmPrivate: Data
    let pdmPublic: Data
    var podPublic: Data
    var podNonce: Data
    var conf: Data
    var ltk: Data

    /// The certificate-derived controller ID (4 bytes, big-endian)
    let controllerIdData: Data

    private let keyGenerator: PrivateKeyGenerator
    let randomByteGenerator: RandomByteGenerator

    init(_ keyGenerator: PrivateKeyGenerator, _ randomByteGenerator: RandomByteGenerator, controllerIdData: Data) throws {
        self.keyGenerator = keyGenerator
        self.randomByteGenerator = randomByteGenerator
        self.controllerIdData = controllerIdData

        pdmNonce = randomByteGenerator.nextBytes(length: O5KeyExchange.NONCE_SIZE)
        pdmPrivate = keyGenerator.generatePrivateKey()
        pdmPublic = try keyGenerator.publicFromPrivate(pdmPrivate)

        guard pdmNonce.count == O5KeyExchange.NONCE_SIZE else {
            throw PodProtocolError.pairingException("pdmNonce size \(pdmNonce.count) != expected \(O5KeyExchange.NONCE_SIZE)")
        }
        guard pdmPublic.count == O5KeyExchange.PUBLIC_KEY_SIZE else {
            throw PodProtocolError.pairingException("pdmPublic size \(pdmPublic.count) != expected \(O5KeyExchange.PUBLIC_KEY_SIZE)")
        }

        podPublic = Data(capacity: O5KeyExchange.PUBLIC_KEY_SIZE)
        podNonce = Data(capacity: O5KeyExchange.NONCE_SIZE)

        conf = Data(capacity: O5KeyExchange.CMAC_SIZE)

        ltk = Data(capacity: O5KeyExchange.CMAC_SIZE)

        log.default("O5KeyExchange init: controllerId=%{public}@", self.controllerIdData.hexadecimalString)
        log.bleDebug("  pdmNonce:  %{public}@", pdmNonce.hexadecimalString)
        log.bleDebug("  pdmPublic: %{public}@", pdmPublic.hexadecimalString)
    }

    func o5updatePodPublicData(_ payload: Data) throws {
        if (payload.count != O5KeyExchange.PUBLIC_KEY_SIZE + O5KeyExchange.NONCE_SIZE) {
            throw PodProtocolError.messageIOException("Invalid SPS1 payload size: \(payload.count), expected \(O5KeyExchange.PUBLIC_KEY_SIZE + O5KeyExchange.NONCE_SIZE)")
        }
        podPublic = payload.subdata(in: 0..<O5KeyExchange.PUBLIC_KEY_SIZE)
        podNonce = payload.subdata(in: O5KeyExchange.PUBLIC_KEY_SIZE..<O5KeyExchange.PUBLIC_KEY_SIZE + O5KeyExchange.NONCE_SIZE)
        log.bleDebug("  podPublic: %{public}@", podPublic.hexadecimalString)
        log.bleDebug("  podNonce:  %{public}@", podNonce.hexadecimalString)
        try o5generateKeys()
    }

    private func o5generateKeys() throws {
        let sharedSecret = try keyGenerator.computeSharedSecret(pdmPrivate, podPublic)
        log.bleDebug("  sharedSecret: %{public}@", sharedSecret.hexadecimalString)
        log.bleDebug("  KDF flags: controllerID source=fixed zeros")

        var data = Data()
        data.append(withUnsafeBytes(of: UInt64(O5LTKExchanger.FIRMWARE_ID.count).bigEndian, { Data($0) }))
        data.append(O5LTKExchanger.FIRMWARE_ID)
        data.append(withUnsafeBytes(of: UInt64(4).bigEndian, { Data($0) }))
        data.append(Data([0x00, 0x00, 0x00, 0x00]))
        data.append(withUnsafeBytes(of: UInt64(self.pdmPublic.count).bigEndian, { Data($0) }))
        data.append(self.pdmPublic)
        data.append(withUnsafeBytes(of: UInt64(self.podPublic.count).bigEndian, { Data($0) }))
        data.append(self.podPublic)
        data.append(withUnsafeBytes(of: UInt64(sharedSecret.count).bigEndian, { Data($0) }))
        data.append(sharedSecret)
        log.info("  KDF input (%{public}lld bytes): %{public}@", data.count, data.hexadecimalString)

        let derivedKey = data.sha256()
        guard derivedKey.count == 32 else {
            throw PodProtocolError.pairingException("SHA-256 output size \(derivedKey.count) != expected 32")
        }
        self.conf = derivedKey.subdata(in: 0..<16)
        self.ltk = derivedKey.subdata(in: 16..<32)
        log.default("Key derivation complete: conf=%{public}@, ltk=%{public}@", conf.hexadecimalString, ltk.hexadecimalString)
    }
    
    private static let SPS_NONCE_SIZE = 13

    public func getSPSNonce(direction: Direction) -> Data {
        guard pdmNonce.count >= 6, podNonce.count >= 6 else {
            log.error("Nonce too short for SPS nonce: pdmNonce=%{public}lld bytes, podNonce=%{public}lld bytes", pdmNonce.count, podNonce.count)
            return Data() // will cause AES-CCM to fail with a clear error
        }

        let pdmSlice = pdmNonce.subdata(in: 0..<6)
        let podSlice = podNonce.subdata(in: 0..<6)

        var nonce = Data()
        switch direction {
        case .write:
            nonce.append(contentsOf: [0x01])
            nonce.append(pdmSlice)
            nonce.append(podSlice)
        case .read:
            nonce.append(contentsOf: [0x02])
            nonce.append(podSlice)
            nonce.append(pdmSlice)
        }
        if nonce.count != O5KeyExchange.SPS_NONCE_SIZE {
            log.error("SPS nonce size %{public}lld != expected %{public}lld", nonce.count, O5KeyExchange.SPS_NONCE_SIZE)
        }
        return nonce
    }
    
    public func incrementNonce(direction: Direction) {
        switch direction {
        case .write:
            incrementNonceInPlace(&pdmNonce)
            break
        case .read:
            incrementNonceInPlace(&podNonce)
            break
        }
    }

    /// Increment the first 8 bytes of a nonce as a native-endian counter,
    /// preserving the full nonce length. The previous implementation used
    /// `Data(nonce.to(UInt64.self) + 1)` which truncated 16-byte nonces to 8 bytes.
    private func incrementNonceInPlace(_ nonce: inout Data) {
        let prevCount = nonce.count
        var counter = nonce.withUnsafeBytes { $0.load(as: UInt64.self) }
        counter &+= 1
        Swift.withUnsafeBytes(of: counter) { src in
            nonce.replaceSubrange(0..<8, with: src)
        }
        if nonce.count != prevCount {
            log.error("incrementNonce changed nonce size from %{public}lld to %{public}lld bytes!", prevCount, nonce.count)
        }
    }

    /// Build the 171-byte channel-binding transcript for SPS2.1 signing.
    ///
    /// Layout (keys-grouped, native RE layout):
    /// ```
    /// [0x01][FIRMWARE_ID(6)][bytes7_10(4)][pdmPublic(64)][podPublic(64)][pdmNonce(16)][podNonce(16)]
    /// ```
    ///
    /// `bytes7_10` is always 4 zero bytes.
    /// Total is always 1 + 6 + 4 + 64 + 64 + 16 + 16 = 171 bytes.
    func buildChannelBindingTranscript() -> Data {
        var transcript = Data(capacity: 171)

        // Type byte (controller context: ctx[4]==0, w1==ctx[4]==0 -> type 0x01)
        transcript.append(Data([0x01]))

        // Field A: FIRMWARE_ID (6 bytes)
        transcript.append(O5LTKExchanger.FIRMWARE_ID)

        // Field B: bytes 7-10 — always zeros
        transcript.append(Data([0x00, 0x00, 0x00, 0x00]))

        // Keys-grouped layout: keys together then nonces together (native RE)
        transcript.append(pdmPublic)
        transcript.append(podPublic)
        transcript.append(pdmNonce)
        transcript.append(podNonce)

        if transcript.count != 171 {
            log.error("Channel-binding transcript size mismatch: got %{public}lld, expected 171", transcript.count)
            let sizes = "FIRMWARE_ID: \(O5LTKExchanger.FIRMWARE_ID.count), pdmNonce: \(pdmNonce.count), pdmPublic: \(pdmPublic.count), podNonce: \(podNonce.count), podPublic: \(podPublic.count)"
            log.error("  %{public}@", sizes)
        }
        return transcript
    }

    /// Build the pod's (peer) variant of the channel-binding transcript for verifying pod SPS2.
    ///
    /// **IMPORTANT — Nonce adjustment:**
    /// This method is called from `o5validatePodSps2()`, AFTER:
    ///   1. Controller sent SPS2.1    → pdmNonce incremented (+1)
    ///   2. Controller recv pod SPS2.1 → podNonce incremented (+1)
    ///   3. Controller sent SPS2      → pdmNonce incremented (+2 total)
    ///   4. Controller recv pod SPS2   → podNonce incremented (+2 total)
    ///
    /// The pod built its transcript AFTER receiving controller SPS2 (step 6 from pod's view)
    /// but BEFORE encrypting its own SPS2 response. At that point the pod's nonce state was:
    ///   - pdmNonce: incremented twice (pod decrypted SPS2.1 + SPS2) = same as controller's current
    ///   - podNonce: incremented once (pod encrypted SPS2.1 only) = controller's current − 1
    ///
    /// So we use `pdmNonce` as-is and decrement `podNonce` by 1 (little-endian first 8 bytes).
    ///
    /// Verified by ECDSA signature match against successful pairing data (2026-02-16).
    ///
    /// Layout (keys-grouped, confirmed):
    /// ```
    /// [0x02][bytes7_10(4)][FIRMWARE_ID(6)][podPublic(64)][pdmPublic(64)][podNonce_adj(16)][pdmNonce(16)]
    /// ```
    ///
    /// `bytes7_10` is always 4 zero bytes.
    /// Total is always 1 + 4 + 6 + 64 + 64 + 16 + 16 = 171 bytes.
    func buildPodChannelBindingTranscript() -> Data {
        var transcript = Data(capacity: 171)

        // Type byte (pod context: w1==1 -> type 0x02)
        transcript.append(Data([0x02]))

        // Field A: bytes7_10 (4 bytes) — swapped position from controller transcript, always zeros
        transcript.append(Data([0x00, 0x00, 0x00, 0x00]))

        // Field B: FIRMWARE_ID (6 bytes) — swapped position from controller transcript
        transcript.append(O5LTKExchanger.FIRMWARE_ID)

        // Adjust podNonce: decrement by 1 to match the pod's nonce state at signing time.
        // At verification time, podNonce has been incremented twice (SPS2.1 recv + SPS2 recv),
        // but the pod signed with podNonce incremented only once (SPS2.1 send only).
        var podNonceAdjusted = podNonce
        var counter = podNonceAdjusted.withUnsafeBytes { $0.load(as: UInt64.self) }
        counter &-= 1
        Swift.withUnsafeBytes(of: counter) { src in
            podNonceAdjusted.replaceSubrange(0..<8, with: src)
        }

        // Keys-grouped layout: keys together then nonces together (native RE)
        transcript.append(podPublic)
        transcript.append(pdmPublic)
        transcript.append(podNonceAdjusted)
        transcript.append(pdmNonce)

        return transcript
    }

    private func o5aesCmac(_ key: Data, _ data: Data) throws -> Data {
        let mac = try CMAC(key: key.bytes)
        return try Data(mac.authenticate(data.bytes))
    }
}
