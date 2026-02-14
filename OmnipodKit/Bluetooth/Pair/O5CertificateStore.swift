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
}
