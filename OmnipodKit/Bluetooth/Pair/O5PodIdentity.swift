//
//  O5PodIdentity.swift
//  OmnipodKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import CryptoKit
import Foundation

/// Whether the pod on the other end of a pairing is a genuine Insulet pod, the
/// LoopKit/pod development simulator, or could not be placed.
///
/// A real Omnipod 5 proves itself during pairing: it shows Insulet's pod
/// intermediate (CN=INS01PG1) in SPS2.1, its own certificate issued by that
/// intermediate in SPS2, and signs the channel-binding transcript with the key
/// in it. The simulator mirrors this with its own published CA, so the two are
/// distinguishable. This is a safety marker - it never blocks a pairing, and
/// an unverified pod is treated like a real one, so a pod whose chain we
/// cannot place is never falsely flagged. The simulator's key is public, so
/// "simulated" only ever errs toward "this is a simulated pod", never the
/// reverse for a real one.
public enum O5PodAuthenticity: String, Equatable {
    case genuine
    case simulated
    case unverified
}

enum O5PodIdentity {

    /// The public key of Insulet's pod intermediate (CN=INS01PG1, issued by
    /// CN=INS00PG1), captured from a real Omnipod 5 on 2026-10-27. A genuine
    /// pod's certificate is signed by this.
    ///
    /// The key is pinned rather than the certificate: a certificate can be
    /// reissued around the same key, and os_log truncates the DER anyway.
    static let insuletPodAnchorKey = Data(hexadecimalString: [
        "ad2f3b7cc5b5971bea582dff282e08421416d92e2380dbb45802944138cde023",
        "c5480d43ce04fda10b4980139a400903f581a3ef8a67186d719a79dc5492f441"
    ].joined())!

    /// The LoopKit/pod simulator's CA. Its signing key is published in that
    /// repository as a development marker, so this proves "simulated", not
    /// authenticity.
    static let simulatorAnchorCertificate = Data(hexadecimalString: [
        "308201973082013da003020102020101300a06082a8648ce3d04030230333116",
        "3014060355040a130d706f642073696d756c61746f7231193017060355040313",
        "10706f642073696d756c61746f72204341301e170d3236303130313030303030",
        "305a170d3436303130313030303030305a303331163014060355040a130d706f",
        "642073696d756c61746f723119301706035504031310706f642073696d756c61",
        "746f722043413059301306072a8648ce3d020106082a8648ce3d030107034200",
        "0401653bc04b88ffebdc05d9d8bea3844edda6aa64241bf468cf85b503ce8108",
        "5a1f0f974e0a47bff7a6c999bb31e9cf78a3d10fbd1078452fbe8d3072c97988",
        "7ba3423040300e0603551d0f0101ff040403020284300f0603551d130101ff04",
        "0530030101ff301d0603551d0e0416041470d1e1f42826b71f50905e2a54bf54",
        "f78c984edd300a06082a8648ce3d0403020348003045022018e1132e0f591da2",
        "90c4897ed63350d50b5c500efdb8b646b2bbded837100ce00221009152ff20d4",
        "0f7ceb276180aa38a2d1a74911157b3c5f901ac79618effd8def38"
    ].joined())!

    /// Classifies a pod from the certificate it showed in SPS2.
    ///
    /// Never throws; anything that cannot be placed is unverified.
    ///
    /// Validity dates are deliberately ignored. A real pod was found pairing
    /// with a certificate nineteen months past its notAfter, so honouring
    /// expiry here would flag pods in the field as suspect. This asks one
    /// question only: who signed this certificate.
    static func authenticity(leafCertificate: Data) -> O5PodAuthenticity {
        guard let signed = SignedCertificate(der: leafCertificate) else {
            return .unverified
        }
        if signed.isSigned(byPublicKey: insuletPodAnchorKey) {
            return .genuine
        }
        if let simulatorKey = O5CertificateStore.extractP256PublicKey(fromDERCert: simulatorAnchorCertificate),
           signed.isSigned(byPublicKey: simulatorKey) {
            return .simulated
        }
        return .unverified
    }
}

/// An X.509 certificate split into the part that was signed and the signature
/// over it, so a signature can be checked against an issuer's key without
/// going through SecTrust, which would also evaluate expiry.
struct SignedCertificate {
    /// The TBSCertificate, as encoded, which is what the issuer signed.
    let tbs: Data
    /// The signature, DER-encoded as an ECDSA-Sig-Value.
    let signature: Data

    init?(der: Data) {
        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue BIT STRING }
        guard let body = SignedCertificate.contents(of: der, at: der.startIndex, expecting: 0x30),
              let tbsRange = SignedCertificate.element(in: der, at: body.lowerBound, expecting: 0x30),
              let algRange = SignedCertificate.element(in: der, at: tbsRange.upperBound, expecting: 0x30),
              let sigContents = SignedCertificate.contents(of: der, at: algRange.upperBound, expecting: 0x03),
              sigContents.count > 1,
              der[sigContents.lowerBound] == 0x00 // no unused bits
        else {
            return nil
        }
        self.tbs = Data(der[tbsRange])
        self.signature = Data(der[(sigContents.lowerBound + 1)..<sigContents.upperBound])
    }

    /// Whether a P-256 public key, raw as x then y, signed this certificate.
    func isSigned(byPublicKey raw: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(rawRepresentation: raw),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature)
        else {
            return false
        }
        return key.isValidSignature(sig, for: tbs)
    }

    // MARK: - Minimal DER

    /// The range of one complete element, tag and length included.
    private static func element(in data: Data, at index: Data.Index, expecting tag: UInt8) -> Range<Data.Index>? {
        guard let contents = contents(of: data, at: index, expecting: tag) else { return nil }
        return index..<contents.upperBound
    }

    /// The range of an element's contents, tag and length excluded.
    private static func contents(of data: Data, at index: Data.Index, expecting tag: UInt8) -> Range<Data.Index>? {
        guard index < data.endIndex, data[index] == tag, index + 1 < data.endIndex else { return nil }
        let first = data[index + 1]
        var length = 0
        var start = index + 2
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7f)
            guard count > 0, count <= 4, index + 2 + count <= data.endIndex else { return nil }
            for i in 0..<count {
                length = length << 8 | Int(data[index + 2 + i])
            }
            start = index + 2 + count
        }
        guard length >= 0, start + length <= data.endIndex else { return nil }
        return start..<(start + length)
    }
}
