//
//  O5KeyExchange.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/Pair/KeyExchange.swift
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
    let controllerID: Data

    private let keyGenerator: PrivateKeyGenerator
    let randomByteGenerator: RandomByteGenerator

    init(_ keyGenerator: PrivateKeyGenerator, _ randomByteGenerator: RandomByteGenerator, controllerID: Data? = nil) throws {
        self.keyGenerator = keyGenerator
        self.randomByteGenerator = randomByteGenerator

        // Use certificate-derived controller ID if provided, otherwise use pdmid from cert store
        if let controllerID = controllerID {
            self.controllerID = controllerID
        } else {
            var pdmid = O5CertificateStore.pdmid.bigEndian
            self.controllerID = Data(bytes: &pdmid, count: 4)
        }

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

        log.default("O5KeyExchange init: controllerID=%{public}@", self.controllerID.hexadecimalString)
        log.info("  pdmNonce:  %{public}@", pdmNonce.hexadecimalString)
        log.info("  pdmPublic: %{public}@", pdmPublic.hexadecimalString)
    }

    func o5updatePodPublicData(_ payload: Data) throws {
        if (payload.count != O5KeyExchange.PUBLIC_KEY_SIZE + O5KeyExchange.NONCE_SIZE) {
            throw PodProtocolError.messageIOException("Invalid SPS1 payload size: \(payload.count), expected \(O5KeyExchange.PUBLIC_KEY_SIZE + O5KeyExchange.NONCE_SIZE)")
        }
        podPublic = payload.subdata(in: 0..<O5KeyExchange.PUBLIC_KEY_SIZE)
        podNonce = payload.subdata(in: O5KeyExchange.PUBLIC_KEY_SIZE..<O5KeyExchange.PUBLIC_KEY_SIZE + O5KeyExchange.NONCE_SIZE)
        log.info("  podPublic: %{public}@", podPublic.hexadecimalString)
        log.info("  podNonce:  %{public}@", podNonce.hexadecimalString)
        try o5generateKeys()
    }

    private func o5generateKeys() throws {
        let sharedSecret = try keyGenerator.computeSharedSecret(pdmPrivate, podPublic)
        log.info("  sharedSecret: %{public}@", sharedSecret.hexadecimalString)

        var data = Data()
        data.append(withUnsafeBytes(of: UInt64(O5LTKExchanger.FIRMWARE_ID.count).bigEndian, {Data($0)}))
        data.append(O5LTKExchanger.FIRMWARE_ID)
        data.append(withUnsafeBytes(of: UInt64(self.controllerID.count).bigEndian, {Data($0)}))
        data.append(self.controllerID)
        data.append(withUnsafeBytes(of: UInt64(self.pdmPublic.count).bigEndian, {Data($0)}))
        data.append(self.pdmPublic)
        data.append(withUnsafeBytes(of: UInt64(self.podPublic.count).bigEndian, {Data($0)}))
        data.append(self.podPublic)
        data.append(withUnsafeBytes(of: UInt64(sharedSecret.count).bigEndian, {Data($0)}))
        data.append(sharedSecret)
        log.info("  KDF input (%{public}d bytes): %{public}@", data.count, data.hexadecimalString)

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
            log.error("Nonce too short for SPS nonce: pdmNonce=%{public}d bytes, podNonce=%{public}d bytes", pdmNonce.count, podNonce.count)
            return Data() // will cause AES-CCM to fail with a clear error
        }
        var nonce = Data()
        switch direction {
        case .write:
            nonce.append(contentsOf: [0x01])
            nonce.append(pdmNonce.subdata(in: 0..<6))
            nonce.append(podNonce.subdata(in: 0..<6))
            break
        case .read:
            nonce.append(contentsOf: [0x02])
            nonce.append(podNonce.subdata(in: 0..<6))
            nonce.append(pdmNonce.subdata(in: 0..<6))
            break
        }
        if nonce.count != O5KeyExchange.SPS_NONCE_SIZE {
            log.error("SPS nonce size %{public}d != expected %{public}d", nonce.count, O5KeyExchange.SPS_NONCE_SIZE)
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
            log.error("incrementNonce changed nonce size from %{public}d to %{public}d bytes!", prevCount, nonce.count)
        }
    }

    /// Build the 171-byte channel-binding transcript for SPS2.1 signing.
    ///
    /// From native library `sub_36690` (fully resolved, `ctx[4]==0` controller path):
    /// ```
    /// Byte  0:       0x01            — type (w1==0 → 0x01)
    /// Bytes 1-6:     FIRMWARE_ID     — 9b0ab96a76f4 (6 bytes, from ctx+0xff)
    /// Bytes 7-10:    controller_id   — e.g. 00277094 (4 bytes, from ctx+0xfb)
    /// Bytes 11-74:   pdmPublic       — phone ECDH public key (64 bytes)
    /// Bytes 75-138:  podPublic       — pod ECDH public key (64 bytes)
    /// Bytes 139-154: pdmNonce        — phone nonce (16 bytes)
    /// Bytes 155-170: podNonce        — pod nonce (16 bytes)
    /// ```
    ///
    /// Note: Keys are grouped together, then nonces grouped together (NOT interleaved).
    func buildChannelBindingTranscript() -> Data {
        var transcript = Data(capacity: 171)

        // Type byte (controller context: ctx[4]==0, w1==ctx[4]==0 → type 0x01)
        transcript.append(Data([0x01]))

        // Field A: FIRMWARE_ID (6 bytes, from ctx+0xff)
        transcript.append(O5LTKExchanger.FIRMWARE_ID)

        // Field B: controller_id (4 bytes, from ctx+0xfb) — NOT zeros
        transcript.append(controllerID)

        // Both public keys grouped together (64 + 64 = 128 bytes)
        transcript.append(pdmPublic)
        transcript.append(podPublic)

        // Both nonces grouped together (16 + 16 = 32 bytes)
        transcript.append(pdmNonce)
        transcript.append(podNonce)

        if transcript.count != 171 {
            log.error("Channel-binding transcript size mismatch: got %{public}d, expected 171", transcript.count)
            log.error("  FIRMWARE_ID: %{public}d, pdmNonce: %{public}d, pdmPublic: %{public}d, podNonce: %{public}d, podPublic: %{public}d",
                       O5LTKExchanger.FIRMWARE_ID.count, pdmNonce.count, pdmPublic.count, podNonce.count, podPublic.count)
        }
        return transcript
    }

    /// Build the pod's (peer) variant of the channel-binding transcript for verifying pod SPS2.1.
    ///
    /// The pod signs with `w1=1` (its own context has `ctx[4]==1`), which produces:
    /// ```
    /// [0x02] [controller_id(4)] [FIRMWARE_ID(6)] [podPub(64)] [pdmPub(64)] [podNonce(16)] [pdmNonce(16)]
    /// ```
    func buildPodChannelBindingTranscript() -> Data {
        var transcript = Data(capacity: 171)

        // Type byte (pod context: w1==1 → type 0x02)
        transcript.append(Data([0x02]))

        // Field A: controller_id (4 bytes) — swapped from controller transcript
        transcript.append(controllerID)

        // Field B: FIRMWARE_ID (6 bytes) — swapped from controller transcript
        transcript.append(O5LTKExchanger.FIRMWARE_ID)

        // Pod keys first (swapped from controller transcript)
        transcript.append(podPublic)
        transcript.append(pdmPublic)

        // Pod nonces first (swapped from controller transcript)
        transcript.append(podNonce)
        transcript.append(pdmNonce)

        return transcript
    }

    private func o5aesCmac(_ key: Data, _ data: Data) throws -> Data {
        let mac = try CMAC(key: key.bytes)
        return try Data(mac.authenticate(data.bytes))
    }
}
