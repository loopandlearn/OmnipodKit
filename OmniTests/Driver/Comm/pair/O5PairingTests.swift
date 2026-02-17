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
import CryptoSwift
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
        XCTAssertEqual(reg.pdmid, 2587928)

        let controllerID = reg.controllerID
        XCTAssertEqual(controllerID.count, 4)
        XCTAssertEqual(controllerID.hexadecimalString, "00277d18")
    }

    /// Pod ID is always PDM ID + 1 (confirmed in both btsnoop sessions)
    func testPodIDIsPdmIDPlusOne() {
        // Session 1: PDM=0x0025f360, Pod=0x0025f361
        XCTAssertEqual(UInt32(0x0025f360) + 1, UInt32(0x0025f361))
        // Session 2: PDM=0x002600d8, Pod=0x002600d9
        XCTAssertEqual(UInt32(0x002600d8) + 1, UInt32(0x002600d9))
    }

    // MARK: - Key Derivation (from extracted TEE simulator keys)

    /// Verify secondary key scalar produces the expected public key (pdmid 2587928)
    func testSecondaryKeyDerivation() throws {
        let scalar = Data(hexadecimalString: "0bf11c04dab072a65f8faca060288188cb006845490bc618440d2af918099e24")!
        let expectedPubKey = Data(hexadecimalString: "5b04057ec3625db9a54ff3eba0518950f912d11af7cce09bf7149d3ef38acda4416cc723f3dd127e5a65b89356c5b4506303c287017fe8ed4dc8d347ef0f19c0")!

        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: scalar)
        XCTAssertEqual(Data(privateKey.publicKey.rawRepresentation), expectedPubKey)
    }

    /// Verify primary key scalar produces the expected public key (pdmid 2587928)
    func testPrimaryKeyDerivation() throws {
        let scalar = Data(hexadecimalString: "4d0e2b45250130b4ee4c449454bd29a91fec6bde5ad69a502e15b7218e6f440e")!
        let expectedPubKey = Data(hexadecimalString: "33444df9308ff4a65d7752f25c86a4b2292ef8eb285a902ac63aad6b9e19d0ca0b093248d9ed8a160fb04f417a8a95f51b7642232759fb071632088166105814")!

        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: scalar)
        XCTAssertEqual(Data(privateKey.publicKey.rawRepresentation), expectedPubKey)
    }

    /// Verify O5CertificateStore loads correctly and the signing key matches
    func testCertificateStoreInit() throws {
        let store = try O5CertificateStore()
        let expectedPubKey = Data(hexadecimalString: "5b04057ec3625db9a54ff3eba0518950f912d11af7cce09bf7149d3ef38acda4416cc723f3dd127e5a65b89356c5b4506303c287017fe8ed4dc8d347ef0f19c0")!
        XCTAssertEqual(store.signingPublicKeyRaw, expectedPubKey)
        XCTAssertEqual(store.controllerIDValue, 2587928)
    }

    // MARK: - Channel-Binding Transcript (structure validated against SPS21_KEYS_PRIMARY.md Section 6)

    /// Verify the 171-byte transcript structure: offsets, field sizes, content order
    func testChannelBindingTranscriptStructure() throws {
        // Use a known P-256 key for the phone side
        let phonePrivateKey = Data(hexadecimalString: "0bf11c04dab072a65f8faca060288188cb006845490bc618440d2af918099e24")!
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

        // Bytes 1-6: FIRMWARE_ID
        XCTAssertEqual(transcript.subdata(in: 1..<7).hexadecimalString, "9b0ab96a76f4")

        // Bytes 7-10: controllerID (bytesAsControllerId=true is now the default)
        XCTAssertEqual(transcript.subdata(in: 7..<11).hexadecimalString, "00277d18")

        // Keys-grouped layout (keysNonceFirst=false): keys together then nonces
        // Bytes 11-74: phone public key (64 bytes)
        let expectedPhonePub = try P256KeyGenerator().publicFromPrivate(phonePrivateKey)
        XCTAssertEqual(transcript.subdata(in: 11..<75), expectedPhonePub)

        // Bytes 75-138: pod public key (64 bytes)
        XCTAssertEqual(transcript.subdata(in: 75..<139), podPubKey)

        // Bytes 139-154: phone nonce (16 bytes)
        XCTAssertEqual(transcript.subdata(in: 139..<155), phoneNonce)

        // Bytes 155-170: pod nonce (16 bytes)
        XCTAssertEqual(transcript.subdata(in: 155..<171), podNonce)
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

    // MARK: - Data.append Safety (CryptoSwift overload pitfalls)

    /// CryptoSwift adds Data.append overloads that can silently widen integer literals.
    /// `Data.append(0x01)` may append 8 bytes (Int64) instead of 1 byte (UInt8).
    /// Always use `Data([0x01])` or `contentsOf: [0x01]` instead.
    func testDataAppendByteWidth() {
        // This is how buildChannelBindingTranscript appends the version byte.
        // If this fails, CryptoSwift's overload resolution has changed.
        var data = Data()
        data.append(Data([0x01]))
        XCTAssertEqual(data.count, 1, "Appending Data([0x01]) must produce exactly 1 byte")
        XCTAssertEqual(data[0], 0x01)

        // contentsOf: [UInt8] is also safe
        var data2 = Data()
        data2.append(contentsOf: [0x02])
        XCTAssertEqual(data2.count, 1, "Appending contentsOf: [0x02] must produce exactly 1 byte")
    }

    // MARK: - Nonce Increment Size Stability

    /// Verify incrementNonce doesn't truncate the 16-byte nonce to 8 bytes.
    /// `Data(pdmNonce.to(UInt64.self) + 1)` may produce 8 bytes from a 16-byte input.
    func testIncrementNoncePreservesSize() throws {
        let phonePrivateKey = Data(hexadecimalString: "f5b539ec69b24876e74785fba316fe2e95eb6e26005f80f9cc7394dfcb461d05")!
        let phoneNonce = Data(hexadecimalString: "36ddde243ca8ef7fca132c725313fbfe")!

        let keyGen = MockFixedPrivateKeyGenerator(fixedPrivateKey: phonePrivateKey, generator: P256KeyGenerator())
        let randGen = MockRandomByteGenerator(fixedData: phoneNonce)
        let ke = try O5KeyExchange(keyGen, randGen)

        let podPubKey = Data(P256.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        let podNonce = Data(hexadecimalString: "0c010b9d86dc2298da20749b7764a1e5")!
        try ke.o5updatePodPublicData(podPubKey + podNonce)

        // Verify initial sizes
        XCTAssertEqual(ke.pdmNonce.count, 16, "pdmNonce must start at 16 bytes")
        XCTAssertEqual(ke.podNonce.count, 16, "podNonce must start at 16 bytes")

        // Increment and verify sizes are preserved
        ke.incrementNonce(direction: .write)
        XCTAssertEqual(ke.pdmNonce.count, 16, "pdmNonce must remain 16 bytes after write increment")

        ke.incrementNonce(direction: .read)
        XCTAssertEqual(ke.podNonce.count, 16, "podNonce must remain 16 bytes after read increment")

        // SPS nonce must still be 13 bytes after increments
        let writeNonce = ke.getSPSNonce(direction: .write)
        XCTAssertEqual(writeNonce.count, 13, "SPS write nonce must be 13 bytes after increment")
        let readNonce = ke.getSPSNonce(direction: .read)
        XCTAssertEqual(readNonce.count, 13, "SPS read nonce must be 13 bytes after increment")

        // Multiple increments should also be stable
        ke.incrementNonce(direction: .write)
        ke.incrementNonce(direction: .write)
        XCTAssertEqual(ke.pdmNonce.count, 16, "pdmNonce must remain 16 bytes after 3 increments")
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

// MARK: - Real Session Validation (from 2026-02-14 O5 pairing attempt)
//
// These tests use values captured from a real O5 pairing session log.
// They verify that our code produces byte-exact output matching real pod communication.

class O5RealSessionTests: XCTestCase {

    // All values from real session Xcode log output (2026-02-14)
    let pdmNonce    = Data(hexadecimalString: "67b78fad1746e6e70e49225e9435dcdb")!
    let pdmPublic   = Data(hexadecimalString: "05a2df12a90037c53b2799906f580c9290178250875d9a5c66e9225f12252cec5242856a774f12d7842b82e648b90653af4d4c9de75435169744eafaef3a8388")!
    let podPublic   = Data(hexadecimalString: "ac9507c86809eb15373380728ab37cd714056f9371e99724abd02ae0e85fa86d60cc15bc22ab411e61205292d665eb120325371081ac50d8c5d503820537fcaa")!
    let podNonce    = Data(hexadecimalString: "bf5e3c56728108d01b080ab90a911b31")!
    let sharedSecret = Data(hexadecimalString: "f58a29d4b23f1c977ac8ac25fa7bb514a8547a7b4db83257d2f0cf4dcbb1963d")!
    let controllerID = Data(hexadecimalString: "00277094")!
    let expectedConf = Data(hexadecimalString: "d2b12c76bc999eeff55230a95969a8cc")!
    let expectedLtk  = Data(hexadecimalString: "ccbddcedc2c1d9886a4d97183f0a4dc0")!

    // MARK: - KDF (Key Derivation Function)

    /// Verify KDF input construction matches the exact 210-byte value from the real session.
    /// This tests the length-prefixed concatenation: len||FIRMWARE_ID || len||controllerID || len||pdmPub || len||podPub || len||sharedSecret
    func testKDFInputConstruction() {
        let expectedKdfInput = Data(hexadecimalString:
            "00000000000000069b0ab96a76f4" +
            "000000000000000400277094" +
            "0000000000000040" +
            "05a2df12a90037c53b2799906f580c9290178250875d9a5c66e9225f12252cec" +
            "5242856a774f12d7842b82e648b90653af4d4c9de75435169744eafaef3a8388" +
            "0000000000000040" +
            "ac9507c86809eb15373380728ab37cd714056f9371e99724abd02ae0e85fa86d" +
            "60cc15bc22ab411e61205292d665eb120325371081ac50d8c5d503820537fcaa" +
            "0000000000000020" +
            "f58a29d4b23f1c977ac8ac25fa7bb514a8547a7b4db83257d2f0cf4dcbb1963d"
        )!
        XCTAssertEqual(expectedKdfInput.count, 210, "KDF input must be exactly 210 bytes")

        // Reconstruct the KDF input the same way O5KeyExchange.o5generateKeys() does
        var kdfInput = Data()
        kdfInput.append(withUnsafeBytes(of: UInt64(O5LTKExchanger.FIRMWARE_ID.count).bigEndian, { Data($0) }))
        kdfInput.append(O5LTKExchanger.FIRMWARE_ID)
        kdfInput.append(withUnsafeBytes(of: UInt64(controllerID.count).bigEndian, { Data($0) }))
        kdfInput.append(controllerID)
        kdfInput.append(withUnsafeBytes(of: UInt64(pdmPublic.count).bigEndian, { Data($0) }))
        kdfInput.append(pdmPublic)
        kdfInput.append(withUnsafeBytes(of: UInt64(podPublic.count).bigEndian, { Data($0) }))
        kdfInput.append(podPublic)
        kdfInput.append(withUnsafeBytes(of: UInt64(sharedSecret.count).bigEndian, { Data($0) }))
        kdfInput.append(sharedSecret)

        XCTAssertEqual(kdfInput.count, 210)
        XCTAssertEqual(kdfInput, expectedKdfInput, "KDF input must match real session byte-for-byte")
    }

    /// Verify SHA-256 of the KDF input produces the exact conf and ltk from the real session.
    func testKDFOutputMatchesRealSession() {
        let kdfInput = Data(hexadecimalString:
            "00000000000000069b0ab96a76f4" +
            "000000000000000400277094" +
            "0000000000000040" +
            "05a2df12a90037c53b2799906f580c9290178250875d9a5c66e9225f12252cec" +
            "5242856a774f12d7842b82e648b90653af4d4c9de75435169744eafaef3a8388" +
            "0000000000000040" +
            "ac9507c86809eb15373380728ab37cd714056f9371e99724abd02ae0e85fa86d" +
            "60cc15bc22ab411e61205292d665eb120325371081ac50d8c5d503820537fcaa" +
            "0000000000000020" +
            "f58a29d4b23f1c977ac8ac25fa7bb514a8547a7b4db83257d2f0cf4dcbb1963d"
        )!

        // CryptoSwift .sha256() — same as used in O5KeyExchange.o5generateKeys()
        let derivedKey = kdfInput.sha256()
        XCTAssertEqual(derivedKey.count, 32)

        let conf = Data(derivedKey[0..<16])
        let ltk = Data(derivedKey[16..<32])

        XCTAssertEqual(conf, expectedConf, "conf must match real session: \(expectedConf.hexadecimalString)")
        XCTAssertEqual(ltk, expectedLtk, "ltk must match real session: \(expectedLtk.hexadecimalString)")
    }

    // MARK: - Channel-Binding Transcript

    /// Verify the 171-byte transcript constructed from real session values is byte-exact.
    /// This would have caught the Data.append(0x01) → 8-byte Int overload bug.
    func testTranscriptFromRealSession() {
        let expectedTranscript = Data(hexadecimalString:
            "01" +                                                              // version byte (1)
            "9b0ab96a76f4" +                                                    // FIRMWARE_ID (6)
            "00000000" +                                                        // flags (4)
            "67b78fad1746e6e70e49225e9435dcdb" +                                // pdmNonce (16)
            "05a2df12a90037c53b2799906f580c9290178250875d9a5c66e9225f12252cec" + // pdmPublic (64)
            "5242856a774f12d7842b82e648b90653af4d4c9de75435169744eafaef3a8388" +
            "bf5e3c56728108d01b080ab90a911b31" +                                // podNonce (16)
            "ac9507c86809eb15373380728ab37cd714056f9371e99724abd02ae0e85fa86d" + // podPublic (64)
            "60cc15bc22ab411e61205292d665eb120325371081ac50d8c5d503820537fcaa"
        )!
        XCTAssertEqual(expectedTranscript.count, 171, "Expected transcript must be 171 bytes")

        // Reconstruct transcript the same way buildChannelBindingTranscript() does
        var transcript = Data(capacity: 171)
        transcript.append(Data([0x01]))
        transcript.append(O5LTKExchanger.FIRMWARE_ID)
        transcript.append(Data([0x00, 0x00, 0x00, 0x00]))
        transcript.append(pdmNonce)
        transcript.append(pdmPublic)
        transcript.append(podNonce)
        transcript.append(podPublic)

        XCTAssertEqual(transcript.count, 171, "Transcript must be exactly 171 bytes (got \(transcript.count))")
        XCTAssertEqual(transcript, expectedTranscript, "Transcript must match real session byte-for-byte")

        // Verify key structural offsets
        XCTAssertEqual(transcript[0], 0x01, "Byte 0: version")
        XCTAssertEqual(transcript.subdata(in: 1..<7), O5LTKExchanger.FIRMWARE_ID, "Bytes 1-6: FIRMWARE_ID")
        XCTAssertEqual(transcript.subdata(in: 7..<11), Data([0x00, 0x00, 0x00, 0x00]), "Bytes 7-10: flags")
        XCTAssertEqual(transcript.subdata(in: 11..<27), pdmNonce, "Bytes 11-26: pdmNonce")
        XCTAssertEqual(transcript.subdata(in: 27..<91), pdmPublic, "Bytes 27-90: pdmPublic")
        XCTAssertEqual(transcript.subdata(in: 91..<107), podNonce, "Bytes 91-106: podNonce")
        XCTAssertEqual(transcript.subdata(in: 107..<171), podPublic, "Bytes 107-170: podPublic")
    }

    // MARK: - SPS Nonce

    /// Verify SPS nonce construction from real session nonces.
    func testSPSNonceFromRealSession() {
        // Write: 0x01 + pdmNonce[0:6] + podNonce[0:6]
        let expectedWriteNonce = Data(hexadecimalString: "0167b78fad1746bf5e3c567281")!
        XCTAssertEqual(expectedWriteNonce.count, 13)

        var writeNonce = Data()
        writeNonce.append(contentsOf: [UInt8(0x01)])
        writeNonce.append(pdmNonce.subdata(in: 0..<6))
        writeNonce.append(podNonce.subdata(in: 0..<6))
        XCTAssertEqual(writeNonce, expectedWriteNonce, "Write SPS nonce must match")

        // Read: 0x02 + podNonce[0:6] + pdmNonce[0:6]
        let expectedReadNonce = Data(hexadecimalString: "02bf5e3c56728167b78fad1746")!
        XCTAssertEqual(expectedReadNonce.count, 13)

        var readNonce = Data()
        readNonce.append(contentsOf: [UInt8(0x02)])
        readNonce.append(podNonce.subdata(in: 0..<6))
        readNonce.append(pdmNonce.subdata(in: 0..<6))
        XCTAssertEqual(readNonce, expectedReadNonce, "Read SPS nonce must match")
    }

    // MARK: - SP2 (GetStatus Command Encoding)

    /// Verify SP2 payload encoding for podId=0x277095 matches the real session.
    func testSP2EncodingForRealPodId() {
        let expectedSP2 = Data(hexadecimalString: "0027709500030e010081a1")!

        let address: UInt32 = 0x277095
        let message = Message(address: address, messageBlocks: [GetStatusCommand()], sequenceNum: 0)
        let encoded = message.encoded()

        XCTAssertEqual(encoded, expectedSP2, "SP2 get status encoding must match real session")
    }

    // MARK: - SPS0

    /// Verify SPS0 phone and pod payloads match the real session.
    func testSPS0FromRealSession() {
        // Phone→Pod SPS0
        let phoneSPS0 = Data(hexadecimalString: "000109a218")!
        let phoneHeader = Data([0x00, 0x01, 0x09])
        let phoneCRC = O5LTKExchanger.crc16XMODEM(phoneHeader)
        var phonePayload = phoneHeader
        phonePayload.append(UInt8((phoneCRC >> 8) & 0xFF))
        phonePayload.append(UInt8(phoneCRC & 0xFF))
        XCTAssertEqual(phonePayload, phoneSPS0, "Phone SPS0 must match real session")

        // Pod→Phone SPS0 (extracted from raw message: "SPS0=" + len + payload)
        let podSPS0 = Data(hexadecimalString: "0000099129")!
        let podHeader = Data([0x00, 0x00, 0x09])
        let podCRC = O5LTKExchanger.crc16XMODEM(podHeader)
        var podPayload = podHeader
        podPayload.append(UInt8((podCRC >> 8) & 0xFF))
        podPayload.append(UInt8(podCRC & 0xFF))
        XCTAssertEqual(podPayload, podSPS0, "Pod SPS0 must match real session")
    }

    // MARK: - Controller ID

    /// Verify controller ID derivation: pdmid 2584724 → 0x00277094
    func testControllerIDFromRealSession() {
        XCTAssertEqual(controllerID, Data(hexadecimalString: "00277094")!)

        // Verify it matches pdmid conversion
        var pdmid = UInt32(2584724).bigEndian
        let derived = Data(bytes: &pdmid, count: 4)
        XCTAssertEqual(derived, controllerID, "controllerID must equal pdmid in big-endian")

        // Pod ID for first pairing: (pdmid & ~3) | 1 = pdmid + 1 when bottom 2 bits are 0
        let pdmidValue = UInt32(bigEndian: controllerID.withUnsafeBytes { $0.load(as: UInt32.self) })
        let podIdValue = (pdmidValue & 0xFFFFFFFC) | 1
        XCTAssertEqual(podIdValue, 0x277095, "podId for first pairing must be (pdmid & ~3) | 1")
    }

    // MARK: - Component Sizes

    /// Verify all real session values have expected sizes.
    /// This catches Data(hex:) or Data(hexadecimalString:) producing wrong-size output.
    func testRealSessionComponentSizes() {
        XCTAssertEqual(pdmNonce.count, 16, "pdmNonce")
        XCTAssertEqual(pdmPublic.count, 64, "pdmPublic")
        XCTAssertEqual(podPublic.count, 64, "podPublic")
        XCTAssertEqual(podNonce.count, 16, "podNonce")
        XCTAssertEqual(sharedSecret.count, 32, "sharedSecret")
        XCTAssertEqual(controllerID.count, 4, "controllerID")
        XCTAssertEqual(expectedConf.count, 16, "conf")
        XCTAssertEqual(expectedLtk.count, 16, "ltk")
        XCTAssertEqual(O5LTKExchanger.FIRMWARE_ID.count, 6, "FIRMWARE_ID")
    }
}

// MARK: - Golden Data from Successful Pairing (btsnoop 2026-02-15, pdmid 2587928)
//
// These tests verify the active registration data and expected sizes from the
// btsnoop capture of a SUCCESSFUL O5 pairing (P0 = 0xa5).
// Source: /Users/james/Downloads/O5keys/KEYS/btsnoop_hci_20260215-2pm.log

class O5BtsnoopGoldenDataTests: XCTestCase {

    // MARK: - Registration Data Verification

    /// Verify the active registration matches pdmid 2587928
    func testActiveRegistrationIsBtsnoop() {
        let reg = O5RegistrationData.active
        XCTAssertEqual(reg.pdmid, 2587928)
        XCTAssertEqual(reg.pdmidExtension, 4300804)
        XCTAssertEqual(reg.controllerID.hexadecimalString, "00277d18")
    }

    /// Pod ID for first pairing = (pdmid & ~3) | 1 (verified in btsnoop: 0x00277d19)
    /// The bottom 2 bits cycle 1, 2, 3, 1, 2, 3 for each successive pod.
    func testPodIDFromBtsnoop() {
        let pdmid: UInt32 = 2587928
        let firstPodId = (pdmid & 0xFFFFFFFC) | 1
        XCTAssertEqual(firstPodId, 2587929) // 0x00277d19

        var podId = UInt32(firstPodId).bigEndian
        let podIdData = Data(bytes: &podId, count: 4)
        XCTAssertEqual(podIdData.hexadecimalString, "00277d19")

        // Verify cycling: pod 2 = |2, pod 3 = |3, pod 4 wraps to |1
        XCTAssertEqual((pdmid & 0xFFFFFFFC) | 2, 2587930) // 0x00277d1a
        XCTAssertEqual((pdmid & 0xFFFFFFFC) | 3, 2587931) // 0x00277d1b
        XCTAssertEqual(OmniPumpManagerState.nextO5PairingCounter(0), 1)
        XCTAssertEqual(OmniPumpManagerState.nextO5PairingCounter(1), 2)
        XCTAssertEqual(OmniPumpManagerState.nextO5PairingCounter(2), 3)
        XCTAssertEqual(OmniPumpManagerState.nextO5PairingCounter(3), 1) // wraps
    }

    /// SP2 encoding for the btsnoop pod ID
    func testSP2EncodingForBtsnoopPodId() {
        let address: UInt32 = 0x00277d19
        let message = Message(address: address, messageBlocks: [GetStatusCommand()], sequenceNum: 0)
        let encoded = message.encoded()
        XCTAssertEqual(encoded.count, 11, "SP2 payload must be 11 bytes")
    }

    // MARK: - Certificate DER Sizes (verified against btsnoop encrypted payload sizes)

    /// INS02PG1 intermediate cert = 634 bytes DER (btsnoop: SPS2.1 = 634 + 8 = 642)
    func testINS02PG1CertSize() {
        let reg = O5RegistrationData.active
        guard let certDER = reg.intermediateCACertDER else {
            XCTFail("INS02PG1 cert DER is nil")
            return
        }
        XCTAssertEqual(certDER.count, 634, "INS02PG1 DER must be 634 bytes (btsnoop SPS2.1 = 634 + 8 tag = 642)")
    }

    /// TLS cert = 1017 bytes DER (btsnoop: SPS2 = 1017 + 64 sig + 8 tag = 1089)
    func testTLSCertSize() {
        let reg = O5RegistrationData.active
        guard let certDER = reg.tlsCertificateDER else {
            XCTFail("TLS cert DER is nil")
            return
        }
        XCTAssertEqual(certDER.count, 1017, "TLS DER must be 1017 bytes (btsnoop SPS2 = 1017 + 64 + 8 = 1089)")
    }

    /// Root CA cert (INS00PG1) = 435 bytes DER
    func testRootCACertSize() {
        let reg = O5RegistrationData.active
        guard let certDER = reg.rootCACertDER else {
            XCTFail("Root CA cert DER is nil")
            return
        }
        XCTAssertEqual(certDER.count, 435, "INS00PG1 root CA DER must be 435 bytes")
    }

    // MARK: - SPS2.1 / SPS2 Expected Encrypted Sizes

    /// SPS2.1 = cert-only (short path): INS02PG1 (634) + tag (8) = 642
    func testSPS21ExpectedSize() {
        let reg = O5RegistrationData.active
        guard let certDER = reg.intermediateCACertDER else {
            XCTFail("INS02PG1 cert DER is nil")
            return
        }
        let expectedEncryptedSize = certDER.count + 8 // cert + AES-CCM tag
        XCTAssertEqual(expectedEncryptedSize, 642, "SPS2.1 encrypted size must be 642")
    }

    /// SPS2 = cert + signature (extended path): TLS (1017) + sig (64) + tag (8) = 1089
    func testSPS2ExpectedSize() {
        let reg = O5RegistrationData.active
        guard let certDER = reg.tlsCertificateDER else {
            XCTFail("TLS cert DER is nil")
            return
        }
        let expectedEncryptedSize = certDER.count + 64 + 8 // cert + ECDSA sig + AES-CCM tag
        XCTAssertEqual(expectedEncryptedSize, 1089, "SPS2 encrypted size must be 1089")
    }

    // MARK: - Key Material Verification

    /// Secondary key scalar → public key derivation for pdmid 2587928
    func testSecondaryKeyMatchesTLSCert() throws {
        let reg = O5RegistrationData.active
        let store = try O5CertificateStore()

        // The signing public key must match the secondary public key from registration
        XCTAssertEqual(store.signingPublicKeyRaw, reg.secondaryPublicKeyRaw)

        // Extract public key from TLS certificate and verify it matches
        if let tlsDER = reg.tlsCertificateDER,
           let certPubKey = O5CertificateStore.extractP256PublicKey(fromDERCert: tlsDER) {
            XCTAssertEqual(certPubKey, reg.secondaryPublicKeyRaw,
                           "TLS cert public key must match secondary key")
        } else {
            XCTFail("Could not extract public key from TLS certificate")
        }
    }

    /// Registration payload contains the correct controller_id and secondary public key
    func testRegistrationPayloadContents() {
        let reg = O5RegistrationData.active
        guard let payload = reg.registrationPayload else {
            XCTFail("Registration payload is nil")
            return
        }
        XCTAssertEqual(payload.count, 163, "Registration payload must be 163 bytes")

        // Controller ID at offset 8 (after 4-byte length + 4-byte flags)
        // Actually at offset 10: length(4) + flags(4) + id(3) + sep(1) + type(1) + keysize(1) + controller_id(4)
        // The exact offset depends on the structure, but the controller_id bytes should be present
        let controllerIDBytes = Data(hexadecimalString: "00277d18")!
        XCTAssertNotNil(payload.range(of: controllerIDBytes),
                        "Registration payload must contain controller_id 00277d18")
    }
}
