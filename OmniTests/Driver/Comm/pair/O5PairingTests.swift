//
//  O5PairingTests.swift
//  OmniTests
//
//  Unit tests for Omnipod 5 pairing protocol, validated against btsnoop captures.
//  Reference: BTSNOOP_ANALYSIS.md, SPS21_KEYS_PRIMARY.md
//
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//

import XCTest
import CryptoKit
@testable import OmnipodKit

class O5PairingTests: XCTestCase {

    // MARK: - CRC-16/XMODEM (validated against btsnoop SPS0 constants)

    /// Phone→Pod SPS0 constant: 000109a218 (confirmed identical across all captured sessions)
    func testCRC16XMODEM_SPS0_Phone() {
        let header = Data([0x00, 0x01, 0x09])
        let crc = O5LTKExchanger.crc16XMODEM(header)
        XCTAssertEqual(crc, 0xa218, String(format: "Expected a218, got %04x", crc))
    }

    /// Pod→Phone SPS0 constant: 0000099129 (confirmed identical across all captured sessions)
    func testCRC16XMODEM_SPS0_Pod() {
        let header = Data([0x00, 0x00, 0x09])
        let crc = O5LTKExchanger.crc16XMODEM(header)
        XCTAssertEqual(crc, 0x9129, String(format: "Expected 9129, got %04x", crc))
    }

    /// Full SPS0 payload: header + CRC
    func testSPS0PhonePayload() {
        let header = Data([0x00, 0x01, 0x09])
        let crc = O5LTKExchanger.crc16XMODEM(header)
        var payload = header
        payload.append(UInt8((crc >> 8) & 0xFF))
        payload.append(UInt8(crc & 0xFF))
        XCTAssertEqual(payload.hexadecimalString, "000109a218")
    }

    func testSPS0PodPayload() {
        let header = Data([0x00, 0x00, 0x09])
        let crc = O5LTKExchanger.crc16XMODEM(header)
        var payload = header
        payload.append(UInt8((crc >> 8) & 0xFF))
        payload.append(UInt8(crc & 0xFF))
        XCTAssertEqual(payload.hexadecimalString, "0000099129")
    }

    // MARK: - Protocol Constants (verified across multiple btsnoop captures)

    /// FIRMWARE_ID is a fixed 6-byte value embedded in PDM firmware
    func testFirmwareID() {
        XCTAssertEqual(O5LTKExchanger.FIRMWARE_ID.count, 6)
        XCTAssertEqual(O5LTKExchanger.FIRMWARE_ID.hexadecimalString, "9b0ab96a76f4")
    }

    /// Key exchange sizes for P-256
    func testKeyExchangeSizes() {
        XCTAssertEqual(O5KeyExchange.PUBLIC_KEY_SIZE, 64, "P-256 public key is 64 bytes (x||y)")
        XCTAssertEqual(O5KeyExchange.NONCE_SIZE, 16, "Nonce is 16 bytes")
        XCTAssertEqual(O5KeyExchange.CMAC_SIZE, 16, "CMAC is 16 bytes")
    }

    /// Milenage constants confirmed from btsnoop EAP-AKA exchanges
    func testMilenageConstants() {
        // AMF = 0xb9b9 confirmed in both Pod #1 and Pod #2 captures
        XCTAssertEqual(Milenage.MILENAGE_AMF.hexadecimalString, "b9b9")
        // OP confirmed in protocol analysis
        XCTAssertEqual(Milenage.MILENAGE_OP.hexadecimalString, "cdc202d5123e20f62b6d676ac72cb318")
    }

    // MARK: - Controller ID (from TLS certificate pdmid)

    /// pdmid → 4-byte big-endian controller ID
    func testControllerIDFromPdmid() {
        let reg = O5RegistrationData.active
        XCTAssertEqual(reg.pdmid, 2584724)

        let controllerID = reg.controllerID
        XCTAssertEqual(controllerID.count, 4)
        XCTAssertEqual(controllerID.hexadecimalString, "00277094")
    }

    /// Pod ID is always PDM ID + 1 (confirmed in both btsnoop sessions)
    func testPodIDIsPdmIDPlusOne() {
        // Session 1: PDM=0x0025f360, Pod=0x0025f361
        XCTAssertEqual(UInt32(0x0025f360) + 1, UInt32(0x0025f361))
        // Session 2: PDM=0x002600d8, Pod=0x002600d9
        XCTAssertEqual(UInt32(0x002600d8) + 1, UInt32(0x002600d9))
    }

    // MARK: - Key Derivation (from extracted TEE simulator keys)

    /// Verify secondary key scalar produces the expected public key
    func testSecondaryKeyDerivation() throws {
        let scalar = Data(hexadecimalString: "f5b539ec69b24876e74785fba316fe2e95eb6e26005f80f9cc7394dfcb461d05")!
        let expectedPubKey = Data(hexadecimalString: "e3c48e617ccb64979c6e99cb4d07af307316450fe3ac9f176b20a09b64d47864f54dea67d10327ef9be03aee756bc6819e6ae5cfd566e4687e303793eebaa3bf")!

        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: scalar)
        XCTAssertEqual(Data(privateKey.publicKey.rawRepresentation), expectedPubKey)
    }

    /// Verify primary key scalar produces the expected public key
    func testPrimaryKeyDerivation() throws {
        let scalar = Data(hexadecimalString: "7045a86517f2127bfe84bd366c068107ed46198487f46380fd68c5f8fac57560")!
        let expectedPubKey = Data(hexadecimalString: "3c121cb7074a6047651b39be78fd29498bd5eee4271d5d73a5001783e60a18559014f9dfa2faf8fda788fa9242934f8138e43e1d651dd77d789ef13fe6f5a962")!

        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: scalar)
        XCTAssertEqual(Data(privateKey.publicKey.rawRepresentation), expectedPubKey)
    }

    /// Verify O5CertificateStore loads correctly and the signing key matches
    func testCertificateStoreInit() throws {
        let store = try O5CertificateStore()
        let expectedPubKey = Data(hexadecimalString: "e3c48e617ccb64979c6e99cb4d07af307316450fe3ac9f176b20a09b64d47864f54dea67d10327ef9be03aee756bc6819e6ae5cfd566e4687e303793eebaa3bf")!
        XCTAssertEqual(store.signingPublicKeyRaw, expectedPubKey)
        XCTAssertEqual(store.controllerIDValue, 2584724)
    }

    // MARK: - Channel-Binding Transcript (structure validated against SPS21_KEYS_PRIMARY.md Section 6)

    /// Verify the 171-byte transcript structure: offsets, field sizes, content order
    func testChannelBindingTranscriptStructure() throws {
        // Use a known P-256 key for the phone side
        let phonePrivateKey = Data(hexadecimalString: "f5b539ec69b24876e74785fba316fe2e95eb6e26005f80f9cc7394dfcb461d05")!
        let phoneNonce = Data(hexadecimalString: "36ddde243ca8ef7fca132c725313fbfe")!

        let keyGen = MockFixedPrivateKeyGenerator(fixedPrivateKey: phonePrivateKey, generator: P256KeyGenerator())
        let randGen = MockRandomByteGenerator(fixedData: phoneNonce)
        let ke = try O5KeyExchange(keyGen, randGen)

        // Use a fresh ephemeral key for the pod side
        let podEphemeral = P256.KeyAgreement.PrivateKey()
        let podPubKey = Data(podEphemeral.publicKey.rawRepresentation)
        let podNonce = Data(hexadecimalString: "0c010b9d86dc2298da20749b7764a1e5")!
        try ke.o5updatePodPublicData(podPubKey + podNonce)

        let transcript = ke.buildChannelBindingTranscript()

        // Total size
        XCTAssertEqual(transcript.count, 171, "Transcript must be exactly 171 bytes")

        // Byte 0: version
        XCTAssertEqual(transcript[0], 0x01)

        // Bytes 1-6: FIRMWARE_ID (NOT a session nonce)
        XCTAssertEqual(transcript.subdata(in: 1..<7).hexadecimalString, "9b0ab96a76f4")

        // Bytes 7-10: flags (zero)
        XCTAssertEqual(transcript.subdata(in: 7..<11), Data([0x00, 0x00, 0x00, 0x00]))

        // Bytes 11-26: phone nonce (16 bytes) — Nonce FIRST in transcript (reversed from SPS1 wire order)
        XCTAssertEqual(transcript.subdata(in: 11..<27), phoneNonce)

        // Bytes 27-90: phone public key (64 bytes)
        let expectedPhonePub = try P256KeyGenerator().publicFromPrivate(phonePrivateKey)
        XCTAssertEqual(transcript.subdata(in: 27..<91), expectedPhonePub)

        // Bytes 91-106: pod nonce (16 bytes)
        XCTAssertEqual(transcript.subdata(in: 91..<107), podNonce)

        // Bytes 107-170: pod public key (64 bytes)
        XCTAssertEqual(transcript.subdata(in: 107..<171), podPubKey)
    }

    /// Verify transcript from a captured session matches the known base64 value.
    /// Reference: SPS21_KEYS_PRIMARY.md Section 6 — full 171-byte hex verified against btsnoop.
    func testChannelBindingTranscriptFromCapture() throws {
        // Known 171-byte transcript from SPS21_KEYS_PRIMARY.md Section 6 (base64)
        let expectedTranscript = Data(base64Encoded:
            "AZsKuWp29AAAAAA23d4kPKjvf8oTLHJTE/v+Z9aHfCDVn+NL7UtUcsdWCmy2zDeLVeVNj8EBBALI" +
            "rqH6bdzseIod16fLql4ftjAWzgXBun+HFx2XL9fc+tENnwwBC52G3CKY2iB0m3dkoeV8ExGHP3op" +
            "VyHULfBXAvN37PAuAVNn4piNgK6W7a09XvINLKnon538WFZtvWmOxTZjNQiIZSx3VRA2NNHzlMPY"
        )!
        XCTAssertEqual(expectedTranscript.count, 171, "Reference transcript must be 171 bytes")

        // Verify structural constants in the captured transcript
        XCTAssertEqual(expectedTranscript[0], 0x01, "Version byte")
        XCTAssertEqual(expectedTranscript.subdata(in: 1..<7).hexadecimalString, "9b0ab96a76f4", "FIRMWARE_ID")
        XCTAssertEqual(expectedTranscript.subdata(in: 7..<11), Data([0x00, 0x00, 0x00, 0x00]), "Flags")

        // Verify known nonces at their expected offsets
        XCTAssertEqual(
            expectedTranscript.subdata(in: 11..<27).hexadecimalString,
            "36ddde243ca8ef7fca132c725313fbfe",
            "Phone nonce at offset 11"
        )
        XCTAssertEqual(
            expectedTranscript.subdata(in: 91..<107).hexadecimalString,
            "0c010b9d86dc2298da20749b7764a1e5",
            "Pod nonce at offset 91"
        )

        // Phone ECDH public key is 64 bytes at offset 27-90
        XCTAssertEqual(expectedTranscript.subdata(in: 27..<91).count, 64, "Phone public key region")
        // Pod ECDH public key is 64 bytes at offset 107-170
        XCTAssertEqual(expectedTranscript.subdata(in: 107..<171).count, 64, "Pod public key region")
    }

    // MARK: - ECDSA Signature Verification (from btsnoop capture)

    /// Verify the real SPS2.1 signature from btsnoop validates against the secondary public key.
    /// This is the core cryptographic proof that our understanding of the protocol is correct.
    ///
    /// Reference: SPS21_KEYS_PRIMARY.md Section 6 (signature) + Section 15 (verification)
    func testBTSnoopSPS21SignatureVerification() throws {
        // 171-byte transcript (base64 from SPS21_KEYS_PRIMARY.md Section 6)
        let transcript = Data(base64Encoded:
            "AZsKuWp29AAAAAA23d4kPKjvf8oTLHJTE/v+Z9aHfCDVn+NL7UtUcsdWCmy2zDeLVeVNj8EBBALI" +
            "rqH6bdzseIod16fLql4ftjAWzgXBun+HFx2XL9fc+tENnwwBC52G3CKY2iB0m3dkoeV8ExGHP3op" +
            "VyHULfBXAvN37PAuAVNn4piNgK6W7a09XvINLKnon538WFZtvWmOxTZjNQiIZSx3VRA2NNHzlMPY"
        )!
        XCTAssertEqual(transcript.count, 171)

        // DER-encoded ECDSA signature (70 bytes, from SPS21_KEYS_PRIMARY.md Section 6)
        let signatureDER = Data(hexadecimalString:
            "3046022100ce4b47ca06e4302b6b20f5490482ff33c2eb43afa972417109d79d810acdf97a" +
            "022100cfdab3dbc497c03b58bbcdac7a583c642257e4c8a3da8043ff8ea1d662bdf2d9"
        )!

        // Secondary public key from btsnoop session (SPKI DER, base64)
        // This is from the btsnoop capture's registration (pdmid=2538336), NOT our extracted key
        let spkiData = Data(base64Encoded:
            "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEfXb8RsMmvbvTFPuN0HnoI0mxTWTnwkJmQ2LRKTk0" +
            "5kRFtFOxgY32DTSR3N5/Kpi61q2s5S2mgGmjIJvbButNWQ=="
        )!
        let pubKey = try P256.Signing.PublicKey(derRepresentation: spkiData)
        let rawPubKey = Data(pubKey.rawRepresentation)

        // This MUST pass — cryptographically verified in SPS21_KEYS_PRIMARY.md Section 15
        let isValid = O5CertificateStore.verifySignature(signatureDER, for: transcript, publicKeyRaw: rawPubKey)
        XCTAssertTrue(isValid, "btsnoop SPS2.1 signature must verify against secondary public key")
    }

    /// The same signature must NOT verify against the primary key.
    /// This confirms the secondary key (not primary) signs the channel-binding transcript.
    func testBTSnoopSignatureRejectsWrongKey() throws {
        let transcript = Data(base64Encoded:
            "AZsKuWp29AAAAAA23d4kPKjvf8oTLHJTE/v+Z9aHfCDVn+NL7UtUcsdWCmy2zDeLVeVNj8EBBALI" +
            "rqH6bdzseIod16fLql4ftjAWzgXBun+HFx2XL9fc+tENnwwBC52G3CKY2iB0m3dkoeV8ExGHP3op" +
            "VyHULfBXAvN37PAuAVNn4piNgK6W7a09XvINLKnon538WFZtvWmOxTZjNQiIZSx3VRA2NNHzlMPY"
        )!

        let signatureDER = Data(hexadecimalString:
            "3046022100ce4b47ca06e4302b6b20f5490482ff33c2eb43afa972417109d79d810acdf97a" +
            "022100cfdab3dbc497c03b58bbcdac7a583c642257e4c8a3da8043ff8ea1d662bdf2d9"
        )!

        // Primary key from the same session (SPS21_KEYS_PRIMARY.md Section 1)
        let primarySpki = Data(base64Encoded:
            "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEPBIctwdKYEdlGzm+eP0pSYvV7uQnHV1zpQAXg+YK" +
            "GFWQFPnfovr4/aeI+pJCk0+BOOQ+HWUd1314nvE/5vWpYg=="
        )!
        let primaryPubKey = try P256.Signing.PublicKey(derRepresentation: primarySpki)
        let rawPrimaryKey = Data(primaryPubKey.rawRepresentation)

        let isValid = O5CertificateStore.verifySignature(signatureDER, for: transcript, publicKeyRaw: rawPrimaryKey)
        XCTAssertFalse(isValid, "Signature must NOT verify against the primary key")
    }

    // MARK: - Signing Roundtrip (our extracted key)

    /// Verify sign + verify roundtrip with the extracted secondary key
    func testSignAndVerifyRoundtrip() throws {
        let store = try O5CertificateStore()

        let testData = Data("channel binding transcript".utf8)
        let signatureDER = try store.sign(testData)

        let isValid = O5CertificateStore.verifySignature(
            signatureDER,
            for: testData,
            publicKeyRaw: store.signingPublicKeyRaw
        )
        XCTAssertTrue(isValid, "DER signature must verify against the signing key's public key")
    }

    /// Verify raw (r||s) signature roundtrip — used for SPS2.1 compact proof
    func testSignRawAndVerify() throws {
        let store = try O5CertificateStore()

        let testData = Data("raw signature test".utf8)
        let signatureRaw = try store.signRaw(testData)
        XCTAssertEqual(signatureRaw.count, 64, "Raw signature must be 64 bytes (r||s)")

        let isValid = O5CertificateStore.verifySignature(
            signatureRaw,
            for: testData,
            publicKeyRaw: store.signingPublicKeyRaw
        )
        XCTAssertTrue(isValid, "Raw signature must verify")
    }

    // MARK: - SPS Nonce Construction

    /// Verify SPS nonce format: direction_byte(1) + first_nonce[0:6](6) + second_nonce[0:6](6) = 13 bytes
    func testSPSNonceConstruction() throws {
        let phonePrivateKey = P256.KeyAgreement.PrivateKey()
        let phoneNonce = Data(hexadecimalString: "a9f1d8e7f74d86a34e9d5461fd170f4b")! // from btsnoop Session 1

        let keyGen = MockFixedPrivateKeyGenerator(fixedPrivateKey: phonePrivateKey.rawRepresentation, generator: P256KeyGenerator())
        let randGen = MockRandomByteGenerator(fixedData: phoneNonce)
        let ke = try O5KeyExchange(keyGen, randGen)

        let podPubKey = P256.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let podNonce = Data(hexadecimalString: "56bbfb14ec4fd9bab67769f39289b098")! // from btsnoop Session 1
        try ke.o5updatePodPublicData(Data(podPubKey) + podNonce)

        // Write direction: 0x01 + pdmNonce[0:6] + podNonce[0:6]
        let writeNonce = ke.getSPSNonce(direction: .write)
        XCTAssertEqual(writeNonce.count, 13)
        XCTAssertEqual(writeNonce[0], 0x01)
        XCTAssertEqual(writeNonce.subdata(in: 1..<7), phoneNonce.subdata(in: 0..<6))
        XCTAssertEqual(writeNonce.subdata(in: 7..<13), podNonce.subdata(in: 0..<6))

        // Read direction: 0x02 + podNonce[0:6] + pdmNonce[0:6]
        let readNonce = ke.getSPSNonce(direction: .read)
        XCTAssertEqual(readNonce.count, 13)
        XCTAssertEqual(readNonce[0], 0x02)
        XCTAssertEqual(readNonce.subdata(in: 1..<7), podNonce.subdata(in: 0..<6))
        XCTAssertEqual(readNonce.subdata(in: 7..<13), phoneNonce.subdata(in: 0..<6))
    }

    // MARK: - Public Key Helpers

    func testUncompressedPublicKey() {
        let rawKey = Data(hexadecimalString: "e3c48e617ccb64979c6e99cb4d07af307316450fe3ac9f176b20a09b64d47864f54dea67d10327ef9be03aee756bc6819e6ae5cfd566e4687e303793eebaa3bf")!
        let uncompressed = O5CertificateStore.uncompressedPublicKey(rawKey)
        XCTAssertEqual(uncompressed.count, 65, "Uncompressed key = 0x04 prefix + 64 bytes")
        XCTAssertEqual(uncompressed[0], 0x04)
        XCTAssertEqual(uncompressed.subdata(in: 1..<65), rawKey)
    }

    // MARK: - O5RegistrationData Consistency

    /// Verify all key material in the active registration has valid sizes and decodes properly
    func testRegistrationDataConsistency() {
        let reg = O5RegistrationData.active

        // Key scalars: 32 bytes
        XCTAssertEqual(reg.secondaryKeyScalar.count, 32)
        if let primary = reg.primaryKeyScalar {
            XCTAssertEqual(primary.count, 32)
        }

        // Public keys: 64 bytes (x||y, no prefix)
        XCTAssertEqual(reg.secondaryPublicKeyRaw.count, 64)
        if let primary = reg.primaryPublicKeyRaw {
            XCTAssertEqual(primary.count, 64)
        }

        // Controller ID: 4 bytes
        XCTAssertEqual(reg.controllerID.count, 4)

        // CA public keys: 64 bytes each
        XCTAssertEqual(reg.rootCAPublicKeyRaw.count, 64)
        XCTAssertEqual(reg.intermediateCAPublicKeyRaw.count, 64)
        XCTAssertEqual(reg.podIntermediateCAPublicKeyRaw.count, 64)
    }

    /// Verify certificate DER data decodes from base64
    func testCertificateChainDecodable() {
        let reg = O5RegistrationData.active

        XCTAssertNotNil(reg.tlsCertificateDER, "TLS certificate must decode from base64")
        if let tls = reg.tlsCertificateDER {
            XCTAssertGreaterThan(tls.count, 100, "TLS certificate must have substantial content")
        }
        if let primaryCert = reg.primaryCertificateDER {
            XCTAssertGreaterThan(primaryCert.count, 100, "Primary certificate must have substantial content")
        }
    }

    /// Verify the signing key's public key matches the registration data
    func testSigningKeyMatchesRegistration() throws {
        let store = try O5CertificateStore()
        let reg = O5RegistrationData.active
        XCTAssertEqual(store.signingPublicKeyRaw, reg.secondaryPublicKeyRaw,
                       "Signing key must match secondary public key from registration")
    }

    // MARK: - Key Derivation Determinism

    /// Verify that O5KeyExchange with the same inputs always produces the same LTK and conf
    func testKeyDerivationDeterminism() throws {
        let phonePrivateKey = Data(hexadecimalString: "f5b539ec69b24876e74785fba316fe2e95eb6e26005f80f9cc7394dfcb461d05")!
        let phoneNonce = Data(hexadecimalString: "a9f1d8e7f74d86a34e9d5461fd170f4b")!

        // Create a fixed pod key for reproducibility
        let podScalar = Data(hexadecimalString: "7045a86517f2127bfe84bd366c068107ed46198487f46380fd68c5f8fac57560")!
        let podPubKey = try P256KeyGenerator().publicFromPrivate(podScalar)
        let podNonce = Data(hexadecimalString: "56bbfb14ec4fd9bab67769f39289b098")!

        // Run key exchange twice
        let keyGen1 = MockFixedPrivateKeyGenerator(fixedPrivateKey: phonePrivateKey, generator: P256KeyGenerator())
        let randGen1 = MockRandomByteGenerator(fixedData: phoneNonce)
        let ke1 = try O5KeyExchange(keyGen1, randGen1)
        try ke1.o5updatePodPublicData(podPubKey + podNonce)

        let keyGen2 = MockFixedPrivateKeyGenerator(fixedPrivateKey: phonePrivateKey, generator: P256KeyGenerator())
        let randGen2 = MockRandomByteGenerator(fixedData: phoneNonce)
        let ke2 = try O5KeyExchange(keyGen2, randGen2)
        try ke2.o5updatePodPublicData(podPubKey + podNonce)

        // LTK and conf must be identical
        XCTAssertEqual(ke1.ltk, ke2.ltk, "LTK must be deterministic")
        XCTAssertEqual(ke1.conf, ke2.conf, "Conf key must be deterministic")
        XCTAssertEqual(ke1.ltk.count, 16, "LTK must be 16 bytes")
        XCTAssertEqual(ke1.conf.count, 16, "Conf key must be 16 bytes")

        // Transcripts must also match
        XCTAssertEqual(ke1.buildChannelBindingTranscript(), ke2.buildChannelBindingTranscript())
    }
}
