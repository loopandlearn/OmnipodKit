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

enum Direction {
    case write
    case read
}

class O5KeyExchange {
    static let CMAC_SIZE = 16

    static let PUBLIC_KEY_SIZE = 64
    static let NONCE_SIZE = 16

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

        podPublic = Data(capacity: O5KeyExchange.PUBLIC_KEY_SIZE)
        podNonce = Data(capacity: O5KeyExchange.NONCE_SIZE)

        conf = Data(capacity: O5KeyExchange.CMAC_SIZE)

        ltk = Data(capacity: O5KeyExchange.CMAC_SIZE)
    }

    func o5updatePodPublicData(_ payload: Data) throws {
        if (payload.count != O5KeyExchange.PUBLIC_KEY_SIZE + O5KeyExchange.NONCE_SIZE) {
            throw PodProtocolError.messageIOException("Invalid payload size")
        }
        podPublic = payload.subdata(in: 0..<O5KeyExchange.PUBLIC_KEY_SIZE)
        podNonce = payload.subdata(in: O5KeyExchange.PUBLIC_KEY_SIZE..<O5KeyExchange.PUBLIC_KEY_SIZE + O5KeyExchange.NONCE_SIZE)
        try o5generateKeys()
    }

    private func o5generateKeys() throws {
        let sharedSecret = try keyGenerator.computeSharedSecret(pdmPrivate, podPublic)
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
        let derivedKey = data.sha256()
        self.conf = derivedKey.subdata(in: 0..<16)
        self.ltk = derivedKey.subdata(in: 16..<derivedKey.count)
    }
    
    public func getSPSNonce(direction: Direction) -> Data {
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
        return nonce
    }
    
    public func incrementNonce(direction: Direction) {
        switch direction {
        case .write:
            self.pdmNonce = Data(pdmNonce.to(UInt64.self) + 1)
            break
        case .read:
            self.podNonce = Data(podNonce.to(UInt64.self) + 1)
            break
        }
    }

    /// Build the 171-byte channel-binding transcript for SPS2.1 signing.
    ///
    /// Verified against real btsnoop capture (SPS21_KEYS_PRIMARY.md Section 6):
    /// ```
    /// Byte  0:       0x01          — version/type
    /// Bytes 1-6:     9b0ab96a76f4  — FIRMWARE_ID (fixed, NOT session nonce)
    /// Bytes 7-10:    00000000      — flags/counter
    /// Bytes 11-26:   phone nonce   — pdmNonce (16 bytes)
    /// Bytes 27-90:   phone EC X,Y  — pdmPublic (64 bytes, ephemeral ECDH)
    /// Bytes 91-106:  pod nonce     — podNonce (16 bytes)
    /// Bytes 107-170: pod EC X,Y    — podPublic (64 bytes, ephemeral ECDH)
    /// ```
    ///
    /// Note: SPS1 payloads are sent over BLE as PubKey(64) + Nonce(16),
    /// but in the transcript they appear as Nonce(16) + PubKey(64) (reversed order).
    func buildChannelBindingTranscript() -> Data {
        var transcript = Data(capacity: 171)

        // Version byte
        transcript.append(0x01)

        // FIRMWARE_ID (fixed 6-byte value from PDM firmware, NOT a session nonce)
        transcript.append(O5LTKExchanger.FIRMWARE_ID)

        // Flags (4 zero bytes)
        transcript.append(Data([0x00, 0x00, 0x00, 0x00]))

        // Phone SPS1 payload: pdmNonce (16 bytes) + pdmPublic (64 bytes) = 80 bytes
        // Note: order is Nonce first, then EC public key (reversed from BLE wire order)
        transcript.append(pdmNonce)
        transcript.append(pdmPublic)

        // Pod SPS1 payload: podNonce (16 bytes) + podPublic (64 bytes) = 80 bytes
        transcript.append(podNonce)
        transcript.append(podPublic)

        assert(transcript.count == 171, "Channel-binding transcript must be exactly 171 bytes")
        return transcript
    }

    private func o5aesCmac(_ key: Data, _ data: Data) throws -> Data {
        let mac = try CMAC(key: key.bytes)
        return try Data(mac.authenticate(data.bytes))
    }
}
