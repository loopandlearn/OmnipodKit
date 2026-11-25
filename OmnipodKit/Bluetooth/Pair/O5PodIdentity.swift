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
/// intermediate (CN=INS01PG1, issued by Insulet's root) in SPS2.1, its own
/// certificate issued by that intermediate in SPS2, naming its role as a pod,
/// and signs the channel-binding transcript with the key in it. Both
/// certificates are needed. The simulator mirrors this with its own published
/// CA, so the two are distinguishable. Pairing with anything but a genuine pod asks the user
/// first, since it may mean the pairing is being intercepted; after that it
/// is treated like a real pod. The simulator's key is public, so "simulated"
/// only ever errs toward "this is a simulated pod", never the reverse for a
/// real one.
public enum O5PodAuthenticity: String, Equatable {
    case genuine
    case simulated
    case unverified
}

enum O5PodIdentity {

    /// Public keys of Insulet's roots. A pod is genuine when the intermediate it
    /// shows in SPS2.1 is signed by one of these and signs the pod's own
    /// certificate, and that certificate names the pod role. The same root also
    /// issues certificates for other devices, so the role is what makes it a pod.
    ///
    /// Keys are pinned rather than certificates: a certificate can be reissued
    /// around the same key, and os_log truncates the DER anyway.
    static let insuletPodRootKeys: [Data] = [
        // CN=INS00PG1, the issuer of the pod intermediate CN=INS01PG1.
        Data(hexadecimalString: [
            "8a16b9ea0025860d06e3a8412ced307eae3da04ca73dbd6e85c8ea3e9070a607",
            "2f749ff6662c8b0702daf1974562c634a7e4da9324ceee75a22e27089d2e61df"
        ].joined())!
    ]

    /// The role a pod's certificate names in its subject alternative names.
    static let podRole = "devicetype:pod"

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

    /// Classifies a pod from the certificate it showed in SPS2, and the
    /// intermediate it showed in SPS2.1.
    ///
    /// Never throws; anything that cannot be placed is unverified.
    ///
    /// Validity dates are deliberately ignored. A real pod was found pairing
    /// with a certificate nineteen months past its notAfter, so honouring
    /// expiry here would flag pods in the field as suspect. This asks two
    /// questions only: who signed this certificate, and is it a pod's.
    static func authenticity(leafCertificate: Data, intermediateCertificate: Data?) -> O5PodAuthenticity {
        authenticity(leafCertificate: leafCertificate,
                     intermediateCertificate: intermediateCertificate,
                     rootKeys: insuletPodRootKeys)
    }

    /// As above, with the root keys given, so tests can use their own chain.
    static func authenticity(leafCertificate: Data, intermediateCertificate: Data?,
                             rootKeys: [Data]) -> O5PodAuthenticity {
        guard let signed = SignedCertificate(der: leafCertificate) else {
            return .unverified
        }
        if let issuerKey = intermediateKey(intermediateCertificate, signedByOneOf: rootKeys),
           signed.isSigned(byPublicKey: issuerKey),
           hasPodRole(signed) {
            return .genuine
        }
        if let simulatorKey = O5CertificateStore.extractP256PublicKey(fromDERCert: simulatorAnchorCertificate),
           signed.isSigned(byPublicKey: simulatorKey) {
            return .simulated
        }
        return .unverified
    }

    /// The public key of an intermediate certificate, if one of the root keys signed it.
    /// The key is read from the signed body only, never from bytes outside it.
    static func intermediateKey(_ certificate: Data?, signedByOneOf rootKeys: [Data]) -> Data? {
        guard let certificate = certificate,
              let signed = SignedCertificate(der: certificate),
              rootKeys.contains(where: signed.isSigned(byPublicKey:))
        else {
            return nil
        }
        return O5CertificateStore.extractP256PublicKey(fromDERCert: signed.tbs)
    }

    /// Whether the certificate's only device role is the pod role.
    static func hasPodRole(_ certificate: SignedCertificate) -> Bool {
        guard let uris = certificate.subjectAlternativeNameURIs else { return false }
        return uris.filter { $0.hasPrefix("devicetype:") } == [podRole]
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

    /// The URIs among the subject alternative names, read from the signed body
    /// only. Empty when there are none; nil when the extensions cannot be parsed.
    var subjectAlternativeNameURIs: [String]? {
        // TBSCertificate ::= SEQUENCE { ..., extensions [3] EXPLICIT SEQUENCE OF Extension OPTIONAL }
        guard let body = SignedCertificate.contents(of: tbs, at: tbs.startIndex, expecting: 0x30),
              let fields = SignedCertificate.children(of: tbs, in: body)
        else {
            return nil
        }
        guard let extensionsField = fields.first(where: { $0.tag == 0xa3 }) else { return [] }
        guard let wrapper = SignedCertificate.children(of: tbs, in: extensionsField.contents),
              wrapper.count == 1, wrapper[0].tag == 0x30,
              let extensions = SignedCertificate.children(of: tbs, in: wrapper[0].contents)
        else {
            return nil
        }
        var uris: [String]?
        for ext in extensions {
            // Extension ::= SEQUENCE { extnID OID, critical BOOLEAN DEFAULT FALSE, extnValue OCTET STRING }
            guard ext.tag == 0x30,
                  let parts = SignedCertificate.children(of: tbs, in: ext.contents),
                  parts.count == 2 || (parts.count == 3 && parts[1].tag == 0x01),
                  parts[0].tag == 0x06, parts[parts.count - 1].tag == 0x04
            else {
                return nil
            }
            guard tbs[parts[0].contents] == SignedCertificate.subjectAltNameOID else { continue }
            // GeneralNames ::= SEQUENCE OF GeneralName; uniformResourceIdentifier is [6] IMPLICIT IA5String.
            guard uris == nil,
                  let value = SignedCertificate.children(of: tbs, in: parts[parts.count - 1].contents),
                  value.count == 1, value[0].tag == 0x30,
                  let names = SignedCertificate.children(of: tbs, in: value[0].contents)
            else {
                return nil
            }
            var found: [String] = []
            for name in names where name.tag == 0x86 {
                guard let uri = String(data: tbs[name.contents], encoding: .ascii) else { return nil }
                found.append(uri)
            }
            uris = found
        }
        return uris ?? []
    }

    /// id-ce-subjectAltName, 2.5.29.17.
    private static let subjectAltNameOID = Data([0x55, 0x1d, 0x11])

    // MARK: - Minimal DER

    /// The elements directly inside a range, each as its tag and contents.
    /// Nil unless they fill the range exactly.
    private static func children(of data: Data, in range: Range<Data.Index>) -> [(tag: UInt8, contents: Range<Data.Index>)]? {
        var result: [(tag: UInt8, contents: Range<Data.Index>)] = []
        var index = range.lowerBound
        while index < range.upperBound {
            let tag = data[index]
            guard tag & 0x1f != 0x1f, // no multi-byte tags in a certificate
                  let contents = contents(of: data, at: index, expecting: tag),
                  contents.upperBound <= range.upperBound
            else {
                return nil
            }
            result.append((tag: tag, contents: contents))
            index = contents.upperBound
        }
        return result
    }

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
