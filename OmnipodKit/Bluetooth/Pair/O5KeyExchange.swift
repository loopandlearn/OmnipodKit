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

    /// Counts pairing attempts so we can cycle through all 256 flag combinations (mod 256).
    /// Attempt #60 (0b00111100) produced a structured error response from pod instead of disconnect.
    static var pairAttempts: Int = 60

    /// When true, uses nonces-first layout (nonce-key interleaved per side, matching Frida capture).
    /// When false, uses keys-grouped layout (keys together then nonces together, matching native RE).
    var keysNonceFirst: Bool = false

    /// When true, puts controllerID in bytes 7-10. When false, puts 4 zero bytes.
    var bytesAsControllerId: Bool = false

    /// When true, uses 4-byte UInt32 BE length prefixes in KDF (instead of 8-byte UInt64).
    var useUInt32LengthPrefixes: Bool = false

    /// When true, uses zeros instead of real controllerID in the KDF input.
    var kdfZeroControllerID: Bool = false

    /// When true, swaps cert indexes: TLS cert in SPS2.1 (with sig), INS02PG1 in SPS2 (without sig).
    var swapCertIndexes: Bool = false

    /// When true, puts signature before cert in SPS2.1 plaintext (sig||cert instead of cert||sig).
    var sigBeforeCert: Bool = false

    /// When true, uses the last 6 bytes of each nonce for SPS nonce construction (instead of first 6).
    var nonceLastBytes: Bool = false

    /// When true, uses direction bytes 0x00/0x01 for write/read (instead of 0x01/0x02).
    var swapNonceDirection: Bool = false

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
        log.info("  KDF flags: useUInt32LengthPrefixes=%{public}@, kdfZeroControllerID=%{public}@",
                 String(describing: useUInt32LengthPrefixes), String(describing: kdfZeroControllerID))

        let appendLength: (inout Data, Int) -> Void = { [useUInt32LengthPrefixes] buf, len in
            if useUInt32LengthPrefixes {
                buf.append(withUnsafeBytes(of: UInt32(len).bigEndian, { Data($0) }))
            } else {
                buf.append(withUnsafeBytes(of: UInt64(len).bigEndian, { Data($0) }))
            }
        }

        let kdfControllerID = kdfZeroControllerID ? Data([0x00, 0x00, 0x00, 0x00]) : self.controllerID

        var data = Data()
        appendLength(&data, O5LTKExchanger.FIRMWARE_ID.count)
        data.append(O5LTKExchanger.FIRMWARE_ID)
        appendLength(&data, kdfControllerID.count)
        data.append(kdfControllerID)
        appendLength(&data, self.pdmPublic.count)
        data.append(self.pdmPublic)
        appendLength(&data, self.podPublic.count)
        data.append(self.podPublic)
        appendLength(&data, sharedSecret.count)
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

        let pdmSlice: Data
        let podSlice: Data
        if nonceLastBytes {
            pdmSlice = pdmNonce.subdata(in: (pdmNonce.count - 6)..<pdmNonce.count)
            podSlice = podNonce.subdata(in: (podNonce.count - 6)..<podNonce.count)
        } else {
            pdmSlice = pdmNonce.subdata(in: 0..<6)
            podSlice = podNonce.subdata(in: 0..<6)
        }

        var nonce = Data()
        switch direction {
        case .write:
            nonce.append(contentsOf: [swapNonceDirection ? 0x00 : 0x01])
            nonce.append(pdmSlice)
            nonce.append(podSlice)
        case .read:
            nonce.append(contentsOf: [swapNonceDirection ? 0x01 : 0x02])
            nonce.append(podSlice)
            nonce.append(pdmSlice)
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
    /// Layout is controlled by two boolean flags:
    ///
    /// **keysNonceFirst == false** (keys-grouped, native RE layout):
    /// ```
    /// [0x01][FIRMWARE_ID(6)][bytes7_10(4)][pdmPublic(64)][podPublic(64)][pdmNonce(16)][podNonce(16)]
    /// ```
    ///
    /// **keysNonceFirst == true** (nonces-first, Frida capture layout):
    /// ```
    /// [0x01][FIRMWARE_ID(6)][bytes7_10(4)][pdmNonce(16)][pdmPublic(64)][podNonce(16)][podPublic(64)]
    /// ```
    ///
    /// `bytes7_10` is `controllerID` when `bytesAsControllerId == true`, or 4 zero bytes when false.
    /// Total is always 1 + 6 + 4 + 64 + 64 + 16 + 16 = 171 bytes.
    func buildChannelBindingTranscript() -> Data {
        var transcript = Data(capacity: 171)

        // Type byte (controller context: ctx[4]==0, w1==ctx[4]==0 -> type 0x01)
        transcript.append(Data([0x01]))

        // Field A: FIRMWARE_ID (6 bytes)
        transcript.append(O5LTKExchanger.FIRMWARE_ID)

        // Field B: bytes 7-10 — controllerID or zeros depending on flag
        let bytes7_10 = bytesAsControllerId ? controllerID : Data([0x00, 0x00, 0x00, 0x00])
        transcript.append(bytes7_10)

        if keysNonceFirst {
            // Nonces-first layout: nonce-key interleaved per side (Frida capture)
            transcript.append(pdmNonce)
            transcript.append(pdmPublic)
            transcript.append(podNonce)
            transcript.append(podPublic)
        } else {
            // Keys-grouped layout: keys together then nonces together (native RE)
            transcript.append(pdmPublic)
            transcript.append(podPublic)
            transcript.append(pdmNonce)
            transcript.append(podNonce)
        }

        if transcript.count != 171 {
            log.error("Channel-binding transcript size mismatch: got %{public}d, expected 171", transcript.count)
            let sizes = "FIRMWARE_ID: \(O5LTKExchanger.FIRMWARE_ID.count), pdmNonce: \(pdmNonce.count), pdmPublic: \(pdmPublic.count), podNonce: \(podNonce.count), podPublic: \(podPublic.count)"
            log.error("  %{public}@", sizes)
        }
        return transcript
    }

    /// Build the pod's (peer) variant of the channel-binding transcript for verifying pod SPS2.1.
    ///
    /// Layout is controlled by two boolean flags (same as controller transcript, but type=0x02
    /// and the fixed fields are swapped: bytes7_10 first, then FIRMWARE_ID).
    ///
    /// **keysNonceFirst == false** (keys-grouped, native RE layout):
    /// ```
    /// [0x02][bytes7_10(4)][FIRMWARE_ID(6)][podPublic(64)][pdmPublic(64)][podNonce(16)][pdmNonce(16)]
    /// ```
    ///
    /// **keysNonceFirst == true** (nonces-first, Frida capture layout):
    /// ```
    /// [0x02][bytes7_10(4)][FIRMWARE_ID(6)][podNonce(16)][podPublic(64)][pdmNonce(16)][pdmPublic(64)]
    /// ```
    ///
    /// `bytes7_10` is `controllerID` when `bytesAsControllerId == true`, or 4 zero bytes when false.
    /// Total is always 1 + 4 + 6 + 64 + 64 + 16 + 16 = 171 bytes.
    func buildPodChannelBindingTranscript() -> Data {
        var transcript = Data(capacity: 171)

        // Type byte (pod context: w1==1 -> type 0x02)
        transcript.append(Data([0x02]))

        // Field A: bytes7_10 (4 bytes) — swapped position from controller transcript
        let bytes7_10 = bytesAsControllerId ? controllerID : Data([0x00, 0x00, 0x00, 0x00])
        transcript.append(bytes7_10)

        // Field B: FIRMWARE_ID (6 bytes) — swapped position from controller transcript
        transcript.append(O5LTKExchanger.FIRMWARE_ID)

        if keysNonceFirst {
            // Nonces-first layout: nonce-key interleaved per side (Frida capture)
            transcript.append(podNonce)
            transcript.append(podPublic)
            transcript.append(pdmNonce)
            transcript.append(pdmPublic)
        } else {
            // Keys-grouped layout: keys together then nonces together (native RE)
            transcript.append(podPublic)
            transcript.append(pdmPublic)
            transcript.append(podNonce)
            transcript.append(pdmNonce)
        }

        return transcript
    }

    private func o5aesCmac(_ key: Data, _ data: Data) throws -> Data {
        let mac = try CMAC(key: key.bytes)
        return try Data(mac.authenticate(data.bytes))
    }
}
