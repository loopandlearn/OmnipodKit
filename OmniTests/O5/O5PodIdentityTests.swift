//
//  O5PodIdentityTests.swift
//  OmniTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
@testable import OmnipodKit

class O5PodIdentityTests: XCTestCase {

    /// A certificate from a pod served by the LoopKit/pod simulator, signed by
    /// the CA that repository publishes.
    private let simulatedPodCertificate = Data(hexadecimalString: [
        "3082019030820137a0030201020209008b162d93578006cb300a06082a8648ce",
        "3d040302303331163014060355040a130d706f642073696d756c61746f723119",
        "301706035504031310706f642073696d756c61746f72204341301e170d323631",
        "3032383030303231305a170d3336313032353031303231305a30343116301406",
        "0355040a130d706f642073696d756c61746f72311a301806035504031311706f",
        "642073696d756c61746f7220706f643059301306072a8648ce3d020106082a86",
        "48ce3d03010703420004cfec6c026779c9b5728a748580e7af8709c3e408b7e0",
        "69963e38f276756005e92b791e23d4099075ee3dc02bceae85b8d1d1489f8c98",
        "71f39e3f1aee2ead7fd1a3333031300e0603551d0f0101ff040403020780301f",
        "0603551d2304183016801470d1e1f42826b71f50905e2a54bf54f78c984edd30",
        "0a06082a8648ce3d04030203470030440220442ec2c82f24763a413b2cb4d49e",
        "0dbbe18cf58b475f352c3f24151d9e52186f022043ecdc41033fa354a21cb557",
        "dd0f180513e9c63235a991988d10ac6809f0fae0"
    ].joined())!

    /// A pod the simulator served must be recognised as simulated, not merely
    /// left unplaced. That is the whole point of the simulator publishing a
    /// fixed CA.
    func testSimulatedPodIsRecognised() {
        XCTAssertEqual(O5PodIdentity.authenticity(leafCertificate: simulatedPodCertificate), .simulated)
    }

    /// Insulet's intermediate did not sign the simulator's pods, so a
    /// simulated pod must never read as genuine.
    func testSimulatedPodIsNotGenuine() {
        let signed = SignedCertificate(der: simulatedPodCertificate)
        XCTAssertNotNil(signed)
        XCTAssertFalse(signed!.isSigned(byPublicKey: O5PodIdentity.insuletPodAnchorKey))
    }

    /// Anything we cannot place is unverified, which the UI treats like a
    /// genuine pod. Rubbish must not crash or read as either anchor.
    func testUnplaceableCertificatesAreUnverified() {
        XCTAssertEqual(O5PodIdentity.authenticity(leafCertificate: Data()), .unverified)
        XCTAssertEqual(O5PodIdentity.authenticity(leafCertificate: Data([0x30, 0x82, 0xff, 0xff])), .unverified)
        XCTAssertEqual(O5PodIdentity.authenticity(leafCertificate: Data(repeating: 0x41, count: 400)), .unverified)
        // A truncated but otherwise well-formed certificate.
        XCTAssertEqual(O5PodIdentity.authenticity(leafCertificate: simulatedPodCertificate.prefix(120)), .unverified)
    }

    /// The signature must actually be checked: flipping a byte of the signed
    /// body has to stop it verifying.
    func testATamperedCertificateIsNotRecognised() {
        var tampered = simulatedPodCertificate
        // Somewhere inside the TBSCertificate, past its header.
        tampered[60] = tampered[60] ^ 0xff
        XCTAssertEqual(O5PodIdentity.authenticity(leafCertificate: tampered), .unverified)
    }

    /// The DER split has to find the signed body and the signature. A
    /// certificate is a SEQUENCE of TBSCertificate, the algorithm, and the
    /// signature as a BIT STRING.
    func testSignedCertificateSplitsTheDER() throws {
        let signed = try XCTUnwrap(SignedCertificate(der: simulatedPodCertificate))
        XCTAssertEqual(signed.tbs.first, 0x30, "the signed body is a SEQUENCE")
        XCTAssertGreaterThan(signed.tbs.count, 100)
        XCTAssertLessThan(signed.tbs.count, simulatedPodCertificate.count)
        XCTAssertEqual(signed.signature.first, 0x30, "an ECDSA signature is a DER SEQUENCE of r and s")
        XCTAssertGreaterThan(signed.signature.count, 60)
    }

    /// The pinned anchors must be the shapes they claim to be: a raw P-256
    /// public key, and a parseable certificate.
    func testAnchorsAreWellFormed() {
        XCTAssertEqual(O5PodIdentity.insuletPodAnchorKey.count, 64, "a raw P-256 key is x then y")
        XCTAssertNotNil(O5CertificateStore.extractP256PublicKey(fromDERCert: O5PodIdentity.simulatorAnchorCertificate))
    }
}
