//
//  O5CertificateStore.swift
//  OmnipodKit
//
//  Created for Omnipod 5 PKI support.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import CryptoKit
import CryptoSwift
import os.log

/// Manages the PKI material needed for Omnipod 5 pairing and pod communication.
/// Key/certificate data comes from `O5RegistrationData.active` — swap it to use a different registration.
class O5CertificateStore {

    private let log = OSLog(category: "O5CertificateStore")

    /// The registration data backing this store.
    let registration: O5RegistrationData

    /// The secondary P256 signing private key (SPS2.1 channel binding + pod commands).
    let signingKey: P256.Signing.PrivateKey

    // MARK: - Computed Properties

    var controllerId: UInt32 { registration.controllerId }
    var controllerIdData: Data { registration.controllerIdData }

    var signingPublicKeyRaw: Data {
        return signingKey.publicKey.rawRepresentation
    }

    // MARK: - Access aids

    /// Randomly picks an available O5 controllerId with or 0 if none available
    static var pickControllerId: UInt32 {
        loadOptionalO5Data()
        if let data = O5RegistrationData.allValues.randomElement() {
            return data.controllerId
        }
        return 0
    }

    // Returns true if no O5RegistrationData is available
    static var isEmpty: Bool {
        loadOptionalO5Data()
        return O5RegistrationData.isEmpty
    }

    // Returns true if O5RegistrationData exists for the specific controllerId
    static func contains(_ controllerId: UInt32) -> Bool {
        loadOptionalO5Data()
        return O5RegistrationData.get(controllerId) != nil
    }


    // MARK: - Initialization

    // init for the specified controllerId
    init(controllerId: UInt32) throws {

        loadOptionalO5Data()
        guard let data = O5RegistrationData.get(controllerId) else {
            log.debug("@@@ O5CertificateStore has no data for 0x%08llX", controllerId)
            throw PodCommsError.noCertificateFound
        }

        self.registration = data
        let scalar = registration.privateKey
        assert(scalar.count == 32, "Secondary key scalar must be exactly 32 bytes")
        self.signingKey = try P256.Signing.PrivateKey(rawRepresentation: scalar)

        // Verify the signing key's public key matches the expected value
        let derivedPubKey = signingKey.publicKey.rawRepresentation
        if derivedPubKey != registration.publicKey {
            log.error("Signing public key does NOT match expected secondary public key!")
            throw PodCommsError.noCertificateFound
        }

        log.bleDebug("O5CertificateStore initialized for 0x%08llX", registration.controllerId)
    }

    // MARK: - Signing (Secondary Key)

    /// Sign data with the secondary key and return the raw signature (r || s, 64 bytes).
    func signRaw(_ data: Data) throws -> Data {
        let signature = try signingKey.signature(for: data)
        return Data(signature.rawRepresentation)
    }

    // MARK: - Verification

    /// Verify an ECDSA signature against a public key (raw, 64 bytes x || y).
    static func verifySignature(_ signature: Data, for data: Data, publicKeyRaw: Data) -> Bool {
        guard let pubKey = try? P256.Signing.PublicKey(rawRepresentation: publicKeyRaw) else {
            return false
        }
        if let derSig = try? P256.Signing.ECDSASignature(derRepresentation: signature) {
            return pubKey.isValidSignature(derSig, for: data)
        }
        if let rawSig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) {
            return pubKey.isValidSignature(rawSig, for: data)
        }
        return false
    }

    // MARK: - DER Certificate Key Extraction

    /// The fixed DER header bytes for a P-256 SubjectPublicKeyInfo + uncompressed point indicator.
    /// SEQUENCE(89) > SEQUENCE(19) > OID(ecPublicKey) + OID(secp256r1) > BIT STRING(66) > 0x00 > 0x04
    private static let p256SPKIHeader = Data([
        0x30, 0x59,                                     // SEQUENCE (89 bytes)
        0x30, 0x13,                                     // SEQUENCE (19 bytes) - AlgorithmIdentifier
        0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,  // OID 1.2.840.10045.2.1 (ecPublicKey)
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,  // OID 1.2.840.10045.3.1.7 (secp256r1)
        0x03, 0x42,                                     // BIT STRING (66 bytes)
        0x00,                                           // no unused bits
        0x04                                            // uncompressed EC point
    ])

    /// Extract the raw P-256 public key (64 bytes, x || y) from a DER-encoded X.509 certificate.
    ///
    /// Searches for the known SubjectPublicKeyInfo DER header pattern for P-256 keys,
    /// then extracts the 64-byte raw EC point (without the 0x04 prefix).
    ///
    /// - Parameter certDERBase64: Base64-encoded DER certificate
    /// - Returns: 64-byte raw public key (x || y), or nil if not found / not P-256
    static func extractP256PublicKey(fromDERCertBase64 certDERBase64: String) -> Data? {
        guard let certDER = Data(base64Encoded: certDERBase64) else {
            return nil
        }
        return extractP256PublicKey(fromDERCert: certDER)
    }

    /// Extract the raw P-256 public key (64 bytes, x || y) from DER certificate data.
    static func extractP256PublicKey(fromDERCert certDER: Data) -> Data? {
        let header = p256SPKIHeader
        let headerLen = header.count
        let keyLen = 64  // raw x || y

        guard certDER.count >= headerLen + keyLen else {
            return nil
        }

        // Search for the SPKI header pattern
        for i in 0...(certDER.count - headerLen - keyLen) {
            if certDER.subdata(in: i..<(i + headerLen)) == header {
                // Found it — the next 64 bytes are the raw public key
                let keyStart = i + headerLen
                return certDER.subdata(in: keyStart..<(keyStart + keyLen))
            }
        }
        return nil
    }

    // MARK: - DER Certificate Field Extraction

    /// Extract the serial number from a DER-encoded X.509 certificate.
    ///
    /// Handles both v3 certificates (with explicit version tag `a0 03 02 01 02`)
    /// and v1 certificates (no version tag — serial immediately after TBSCertificate SEQUENCE).
    static func extractSerialNumber(fromDERCert certDER: Data) -> Data? {
        // Try v3 first: [0] EXPLICIT { INTEGER 2 } = a0 03 02 01 02
        // Followed by serial: 02 [length] [serial bytes]
        let v3Pattern = Data([0xa0, 0x03, 0x02, 0x01, 0x02, 0x02])
        if let range = certDER.range(of: v3Pattern) {
            let serialLenOffset = range.upperBound
            guard serialLenOffset < certDER.count else { return nil }
            let serialLen = Int(certDER[serialLenOffset])
            let serialStart = serialLenOffset + 1
            guard serialLen > 0, serialStart + serialLen <= certDER.count else { return nil }
            return certDER.subdata(in: serialStart..<(serialStart + serialLen))
        }

        // V1 fallback: no version tag. Structure is:
        //   SEQUENCE (outer cert) { SEQUENCE (TBSCertificate) { INTEGER (serial) ... } ... }
        // Parse outer SEQUENCE, then inner TBSCertificate SEQUENCE, then read serial INTEGER directly.
        guard certDER.count > 4, certDER[0] == 0x30 else { return nil }
        let (_, outerContentStart) = parseDERLength(certDER, offset: 1)
        guard let tbsStart = outerContentStart, tbsStart < certDER.count, certDER[tbsStart] == 0x30 else { return nil }
        let (_, tbsContentStart) = parseDERLength(certDER, offset: tbsStart + 1)
        guard let serialOffset = tbsContentStart, serialOffset < certDER.count else { return nil }

        // First element should be INTEGER (0x02) = serial number (v1 has no version tag)
        guard certDER[serialOffset] == 0x02 else { return nil }
        let lenOffset = serialOffset + 1
        guard lenOffset < certDER.count else { return nil }
        let serialLen = Int(certDER[lenOffset])
        let serialStart = lenOffset + 1
        guard serialLen > 0, serialStart + serialLen <= certDER.count else { return nil }
        return certDER.subdata(in: serialStart..<(serialStart + serialLen))
    }

    /// Parse a DER length field starting at `offset`. Returns (length, contentStartOffset).
    /// Handles both short-form (single byte) and long-form (0x8n + n bytes) lengths.
    private static func parseDERLength(_ data: Data, offset: Int) -> (Int?, Int?) {
        guard offset < data.count else { return (nil, nil) }
        let firstByte = data[offset]
        if firstByte & 0x80 == 0 {
            // Short form
            return (Int(firstByte), offset + 1)
        } else {
            // Long form
            let numLenBytes = Int(firstByte & 0x7f)
            guard numLenBytes > 0, offset + 1 + numLenBytes <= data.count else { return (nil, nil) }
            var len = 0
            for i in 0..<numLenBytes {
                len = (len << 8) | Int(data[offset + 1 + i])
            }
            return (len, offset + 1 + numLenBytes)
        }
    }
}

// MARK: - Runtime Installer

/// Load the data from the optional O5Data file if present by invoking its install() function using a unsafeBitCast
fileprivate func loadOptionalO5Data() {
    // Use RTLD_DEFAULT (-2) to find the symbol if it was compiled into the binary
    if let installSym = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2),
        "O5RegistrationDataInstall"
    ) {
        typealias InstallFunc = @convention(c) () -> Void
        let install = unsafeBitCast(installSym, to: InstallFunc.self)
        install()
    }
}
