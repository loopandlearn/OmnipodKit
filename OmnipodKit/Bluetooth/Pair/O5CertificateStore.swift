//
//  O5CertificateStore.swift
//  OmnipodKit
//
//  Created for Omnipod 5 PKI support.
//  Copyright © 2025 LoopKit Authors. All rights reserved.
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

    // MARK: - Static accessors (for Id.swift and other non-instance callers)

    static var pdmid: UInt32 { O5RegistrationData.active.pdmid }
    static var pdmidExtension: UInt32 { O5RegistrationData.active.pdmidExtension }
    static var secondaryPublicKeyRaw: Data { O5RegistrationData.active.secondaryPublicKeyRaw }
    static var primaryPublicKeyRaw: Data? { O5RegistrationData.active.primaryPublicKeyRaw }
    static var primaryCertificateDER: Data? { O5RegistrationData.active.primaryCertificateDER }
    static var rootCAPublicKeyRaw: Data { O5RegistrationData.active.rootCAPublicKeyRaw }
    static var intermediateCAPublicKeyRaw: Data { O5RegistrationData.active.intermediateCAPublicKeyRaw }
    static var podIntermediateCAPublicKeyRaw: Data { O5RegistrationData.active.podIntermediateCAPublicKeyRaw }

    // MARK: - Computed Properties

    var controllerID: Data { registration.controllerID }
    var controllerIDValue: UInt32 { registration.pdmid }

    var signingPublicKeyRaw: Data {
        return signingKey.publicKey.rawRepresentation
    }

    // MARK: - Initialization

    init() throws {
        self.registration = O5RegistrationData.active

        let scalar = registration.secondaryKeyScalar
        assert(scalar.count == 32, "Secondary key scalar must be exactly 32 bytes")
        self.signingKey = try P256.Signing.PrivateKey(rawRepresentation: scalar)

        // Verify the signing key's public key matches the expected value
        let derivedPubKey = signingKey.publicKey.rawRepresentation
        if derivedPubKey != registration.secondaryPublicKeyRaw {
            log.error("Signing key public key does NOT match expected secondary public key!")
        }

        log.debug("O5CertificateStore initialized, pdmid=%{public}u, controllerID=%{public}@",
                   registration.pdmid, controllerID.hexadecimalString)
    }

    // MARK: - Signing (Secondary Key)

    /// Sign data with the secondary private key using ECDSA SHA-256.
    /// Returns the DER-encoded ECDSA signature.
    func sign(_ data: Data) throws -> Data {
        let signature = try signingKey.signature(for: data)
        return Data(signature.derRepresentation)
    }

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

    // MARK: - Public Key Helpers

    /// Returns the uncompressed public key (65 bytes with 0x04 prefix) from raw representation.
    static func uncompressedPublicKey(_ rawKey: Data) -> Data {
        var result = Data([0x04])
        result.append(rawKey)
        return result
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
}
