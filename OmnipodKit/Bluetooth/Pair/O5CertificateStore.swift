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

/// Manages the PKI material needed for Omnipod 5 pairing.
///
/// ## Key Architecture
///
/// The O5 app uses TWO device identity keys:
///
/// - **Primary key** (`com.twi.enclave.device.primary`): Software-backed EC P-256 key.
///   Its certificate is sent to the pod during SPS2.1. The private key is extractable.
///
/// - **Secondary key** (`com.twi.enclave.device.secondary`): TEE hardware-backed EC P-256 key.
///   Used for the SPS2.1 channel-binding signature, pod command signing, CSR signing, and
///   TLS client auth. The private key is **non-extractable** — only the public key and
///   attestation chain are available.
///
/// ## Signing Limitation
///
/// The SPS2.1 channel-binding signature and pod command signatures require the secondary
/// private key, which lives in the Android TEE and cannot be extracted. The primary key
/// stored here can sign data, but those signatures will NOT match what the real app produces
/// for SPS2.1 channel binding. The primary key may be used for signing in the SPS2 phase
/// (~1089 bytes), but this has not yet been confirmed.
///
class O5CertificateStore {

    private let log = OSLog(category: "O5CertificateStore")

    // MARK: - Primary Key (Extractable Software EC P-256)

    /// The primary EC P-256 private key scalar (32 bytes).
    /// Extracted from `com.twi.enclave.device.primary` via Frida hook.
    /// Alias: `com.twi.enclave.device.primary`
    /// Subject: CN=com.twi.enclave.device.primary, O=Twi, C=US
    static let primaryKeyScalar = Data(hex: "7045a86517f2127bfe84bd366c068107ed46198487f46380fd68c5f8fac57560")

    /// The primary P256 signing private key, loaded from the extracted scalar.
    /// This key's certificate is sent to the pod during SPS2.1.
    /// NOTE: This key does NOT produce the SPS2.1 channel-binding signature (that uses secondary).
    let primarySigningKey: P256.Signing.PrivateKey

    /// The primary key's public key in raw representation (64 bytes, x || y)
    /// Matches: 04 3c121cb7074a6047651b39be78fd29498bd5eee4271d5d73a5001783e60a1855
    ///             9014f9dfa2faf8fda788fa9242934f8138e43e1d651dd77d789ef13fe6f5a962
    static let primaryPublicKeyRaw = Data(hex: "3c121cb7074a6047651b39be78fd29498bd5eee4271d5d73a5001783e60a18559014f9dfa2faf8fda788fa9242934f8138e43e1d651dd77d789ef13fe6f5a962")

    /// The primary key's self-signed X.509 certificate (DER, base64-encoded).
    /// Subject: CN=com.twi.enclave.device.primary, O=Twi, C=US
    /// This certificate is sent to the pod during SPS2.1 as part of the compact proof.
    static let primaryCertificateDERBase64 = "MIIBczCCARkCBBcDWo0wCgYIKoZIzj0EAwIwRDELMAkGA1UEBhMCVVMxDDAKBgNVBAoTA1R3aTEnMCUGA1UEAxMeY29tLnR3aS5lbmNsYXZlLmRldmljZS5wcmltYXJ5MB4XDTI1MDEwMTAwMDAwMFoXDTM1MDEwMTAwMDAwMFowRDELMAkGA1UEBhMCVVMxDDAKBgNVBAoTA1R3aTEnMCUGA1UEAxMeY29tLnR3aS5lbmNsYXZlLmRldmljZS5wcmltYXJ5MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEPBIctwdKYEdlGzm+eP0pSYvV7uQnHV1zpQAXg+YKGFWQFPnfovr4/aeI+pJCk0+BOOQ+HWUd1314nvE/5vWpYjAKBggqhkjOPQQDAgNIADBFAiBtQdHvHFTax6ktGGxJoeuPaowPmN0BLyZKOUjyuByo1QIhAKSoLdPXJinw4PhGbnAR9g582KNgyfMTdJG2rhnnlRZm"

    /// The primary certificate as DER Data (decoded from base64)
    static var primaryCertificateDER: Data {
        return Data(base64Encoded: primaryCertificateDERBase64)!
    }

    // MARK: - Secondary Key (TEE Hardware — Non-Extractable)

    /// The secondary EC P-256 public key in raw representation (64 bytes, x || y).
    /// Extracted from the SubjectPublicKeyInfo of the secondary attestation leaf cert.
    /// Alias: `com.twi.enclave.device.secondary`
    /// Subject: CN=com.twi.enclave.device.secondary, O=Twi, C=US
    ///
    /// The PRIVATE key is non-extractable (TEE hardware-backed).
    /// This public key is included in the registration payload written to the pod during setPodUid.
    static let secondaryPublicKeyRaw = Data(hex: "7d76fc46c326bdbbd314fb8dd079e82349b14d64e7c24266436ad12939e4e64445b453b1818df60d3491dcde7f2a98bad6adace52da68069a3209bdb06eb4d59")

    /// Secondary attestation leaf certificate (DER, base64-encoded).
    /// Issued by TEE intermediate, contains the secondary public key.
    static let secondaryLeafCertDERBase64 = "MIIC3TCCAoKgAwIBAgIEALxhTjAKBggqhkjOPQQDAjA5MQwwCgYDVQQMDANURUUxKTAnBgNVBAUTIDhjMGU2MGNkZjA0ZTJiNDUxYzI5NjY0NWViYWUwYWQ4MB4XDTcwMDEwMTAwMDAwMFoXDTQ4MDEwMTAwMDAwMFowRjEMMAoGA1UEChMDVHdpMQswCQYDVQQGEwJVUzEpMCcGA1UEAxMgY29tLnR3aS5lbmNsYXZlLmRldmljZS5zZWNvbmRhcnkwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAR9dvxGwya9u9MU+43QeegjSbFNZOfCQmZDYtEpOTTmREW0U7GBjfYNNJHc3n8qmLrWrazlLaaAaaMgm9sG601Zo4IBaTCCAWUwDgYDVR0PAQH/BAQDAgeAMIIBUQYKKwYBBAHWeQIBEQSCAUEwggE9AgIAyAoBAQICAMgKAQEEIDMzMTM1MzY1N2ZmZGMxMDliYzIwOGNmNTNhZTg2OWI5BAAwWL+FPQgCBgGcFwNXob+FRUgERjBEMR4wHAQWY29tLmluc3VsZXQubXlibHVlLnBkbQICE6YxIgQgTkgHdQiznlfdb06NK1Pbid/gSj3oiZi02patX9XFJDQwga6hCDEGAgECAgEDogMCAQOjBAICAQClCDEGAgEAAgEEpgUxAwIBBaoDAgEBv4N3AgUAv4U+AwIBAL+FQEwwSgQgiyxM1Tn1B16OfPISrbPbBBP7130yEZnHPVpHPFHy4Q0BAf8KAQAEIPJIqrgRh9zJpZtCeAzrqElhQSy+Zb8Yg7/qYKqvresNv4VBBQIDAfvQv4VCBQIDAxdpv4VOBgIEATUlCb+FTwYCBAE1JQkwCgYIKoZIzj0EAwIDSQAwRgIhAPgo02exMqF7okXk3xC+51d5SvADQvoohfBNfnR2wpG2AiEAnA1O0V+GDqT+wIOraBhpXJuzSD6i5ePr2seRAOe7Gog="

    /// Secondary TEE intermediate certificate (DER, base64-encoded).
    static let secondaryTEEIntermediateCertDERBase64 = "MIIB9DCCAXmgAwIBAgIQKCxmIIUNPuj0j6bL98QLNjAKBggqhkjOPQQDAjA5MQwwCgYDVQQMDANURUUxKTAnBgNVBAUTIGQ4YmZlOTUxYzg0MGEwNGQ1MTcwYjVhZGUwNmQzYTU0MB4XDTIyMDEyNTIzMzUyMVoXDTMyMDEyMzIzMzUyMVowOTEMMAoGA1UEDAwDVEVFMSkwJwYDVQQFEyA4YzBlNjBjZGYwNGUyYjQ1MWMyOTY2NDVlYmFlMGFkODBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABKFIMTCFQmHYYDbipfC1GgwFRuIAy1uRyNaqm9KD7HIGnZlyYa2gXl/khe+B4yqa1y2hI6wgv9cgkhbD1qaqIs+jYzBhMB0GA1UdDgQWBBT9htbJlzc01RuKa5VPFDuWC+/9rzAfBgNVHSMEGDAWgBRI9I6OtrDGv8Vaz6nPAL/WqA7rUzAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwICBDAKBggqhkjOPQQDAgNpADBmAjEApCZ12C5NTULVQz3fXc5fKcQTMOhTthgcDWRub/WnKLl2ja2J1H/zehzXtgFwQDx1AjEA1D2jtYHZ+V2iewDM9GmCp266Alcpbx1NKdun1CSUBLeM4UFp3SI+9XBMaAoQTj+t"

    /// Hardware intermediate certificate (EC P-384, DER, base64-encoded).
    static let secondaryHWIntermediateCertDERBase64 = "MIIDlDCCAXygAwIBAgIRAJVCTT29Kco6Jb3Kxe5RGHwwDQYJKoZIhvcNAQELBQAwGzEZMBcGA1UEBRMQZjkyMDA5ZTg1M2I2YjA0NTAeFw0yMjAxMjUyMzMyNDhaFw0zMjAxMjMyMzMyNDhaMDkxDDAKBgNVBAwMA1RFRTEpMCcGA1UEBRMgZDhiZmU5NTFjODQwYTA0ZDUxNzBiNWFkZTA2ZDNhNTQwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAAQWwIfytXG3HCiP5A86lhNH6YxLM5nIgnssT8AejEwAtF/Qh8rI9++5kyl4CoSTW8dh7c7ssRPp8AekngN/BzHB3A7Muw6Z2V69zwQVye2HaVMmrsy0AAHv15Unmg3/1NyjYzBhMB0GA1UdDgQWBBRI9I6OtrDGv8Vaz6nPAL/WqA7rUzAfBgNVHSMEGDAWgBQ2YeEAfIgFCVGLRGxH/xpMyepPEjAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwICBDANBgkqhkiG9w0BAQsFAAOCAgEAM9sIKoPdl8OeIf2bfiNxopvg0u/Saxu/qfMTBywzXrspkBmCgXk0NVHRnS+K+BYsIMxd7GTcPU98+69MOLSBH5qEY1G/1uu+wIlU3B6/v3k+oyAGzCwZiNBMkIF8ASYj/t3s79h69y54CVAFqKwWBXZWeXZawGY6JdQ39dLlkLpxBq2Jb0fJC/9mdvU3lw7j6qVQPpXDKKuk1l5mTsv7yrSHyxUByHp8IvF+RxIbGe3qPpMlRB8kSRJKugtMPPu2g0sAYxI9Hw8Dm1UQvgQAWj2KJ9tHdiZnjb3byHkm3d0+wEzSczjfqQ5k5DRSOjWdQk8vSv3SHOeUG25w/3lKvg1AVihgironLdSDYjCm6c9HJl8Aa6j9ofIwZQIZn7rnl8e2AGa/BNgmviNnc2Zgnkw1nhUsbNmdfoNbyf5sLK0PrScgZ+INmx7ZqflnXq325todpsW2LYkPR+S6cOG8hF/9M87gCK6RHC0GBoDnMhA6MtGn/3MTivEBSiB3XVD8a9ywFhueOkyvMAN+61VLFSDQi3HAFxlQE3Lo/vVZGtQuZf0pxf/+2TA+H+oeJR7fnnf5LwllUIBN70XfgVjA1oxPnSYf2EUEFxwGxDGhDPHJy+ufJ1SQiuzpaIbpuBjq7XHNnXkrDbVNTT8/8T8rFPF+pp2iaRKE0tVhbx89LBM="

    /// Google Hardware Attestation Root certificate (RSA-4096, DER, base64-encoded).
    static let googleHWAttestationRootCertDERBase64 = "MIIFHDCCAwSgAwIBAgIJAMNrfES5rhgxMA0GCSqGSIb3DQEBCwUAMBsxGTAXBgNVBAUTEGY5MjAwOWU4NTNiNmIwNDUwHhcNMjExMTE3MjMxMDQyWhcNMzYxMTEzMjMxMDQyWjAbMRkwFwYDVQQFExBmOTIwMDllODUzYjZiMDQ1MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAr7bHgiuxpwHsK7Qui8xUFmOr75gvMsd/dTEDDJdSSxtf6An7xyqpRR90PL2abxM1dEqlXnf2tqw1Ne4Xwl5jlRfdnJLmN0pTy/4lj4/7tv0Sk3iiKkypnEUtR6WfMgH0QZfKHM1+di+y9TFRtv6y//0rb+T+W8a9nsNL/ggjnar86461qO0rOs2cXjp3kOG1FEJ5MVmFmBGtnrKpa73XpXyTqRxB/M0n1n/W9nGqC4FSYa04T6N5RIZGBN2z2MT5IKGbFlbC8UrW0DxW7AYImQQcHtGl/m00QLVWutHQoVJYnFPlXTcHYvASLu+RhhsbDmxMgJJ0mcDpvsC4PjvB+TxywElgS70vE0XmLD+OJtvsBslHZvPBKCOdT0MS+tgSOIfga+z1Z1g7+DVagf7quvmag8jfPioyKvxnK/EgsTUVi2ghzq8wm27ud/mIM7AY2qEORR8Go3TVB4HzWQgpZrt3i5MIlCaY504LzSRiigHCzAPlHws+W0rB5N+er5/2pJKnfBSDiCiFAVtCLOZ7gLiMm0jhO2B6tUXHI/+MRPjy02i59lINMRRev56GKtcd9qO/0kUJWdZTdA2XoS82ixPvZtXQpUpuL12ab+9EaDK8Z4RHJYYfCT3Q5vNAXaiWQ+8PTWm2QgBR/bkwSWc+NpUFgNPN9PvQi8WEg5UmAGMCAwEAAaNjMGEwHQYDVR0OBBYEFDZh4QB8iAUJUYtEbEf/GkzJ6k8SMB8GA1UdIwQYMBaAFDZh4QB8iAUJUYtEbEf/GkzJ6k8SMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgIEMA0GCSqGSIb3DQEBCwUAA4ICAQBTNNZe5cuf8oiq+jV0itTGzWVhSTjOBEk2FQvh11J3o3lna0o7rd8RFHnN00q4hi6TapFhh4qaw/iG6Xg+xOan63niLWIC5GOPFgPeYXM9+nBb3zZzC8ABypYuCusWCmt6Tn3+Pjbz3MTVhRGXuT/TQH4KGFY4PhvzAyXwdjTOCXID+aHud4RLcSySr0Fq/L+R8TWalvM1wJJPhyRjqRCJerGtfBagiALzvhnmY7U1qFcS0NCnKjoO7oFedKdWlZz0YAfu3aGCJd4KHT0MsGiLZez9WP81xYSrKMNEsDK+zK5fVzw6jA7cxmpXcARTnmAuGUeI7VVDhDzKeVOctf3a0qQLwC+d0+xrETZ4r2fRGNw2YEs2W8Qj6oDcfPvq9JySe7pJ6wcHnl5EZ0lwc4xH7Y4Dx9RA1JlfooLMw3tOdJZH0enxPXaydfAD3YifeZpFaUzicHeLzVJLt9dvGB0bHQLE4+EqKFgOZv2EoP686DQqbVS1u+9k0p2xbMA105TBIk7npraa8VM0fnrRKi7wlZKwdH+aNAyhbXRW9xsnODJ+g8eF452zvbiKKngEKirK5LGieoXBX7tZ9D1GNBH2Ob3bKOwwIWdEFle/YF/h6zWgdeoaNGDqVBrLr2+0DtWoiB1aDEjLWl9FmyIUyUm7mD/vFDkzF+wm7cyWpQpCVQ=="

    // MARK: - PDM Identity (from CSR Subject Alternative Name)

    /// The PDM ID extracted from the TLS certificate's Subject Alternative Name.
    /// This is the decimal value that gets converted to a 4-byte controller ID.
    /// Value from captured session: 2538336 (0x0026BB60)
    static let pdmid: UInt32 = 2538336

    /// The pdmid extension value from the TLS certificate SAN
    static let pdmidExtension: UInt32 = 4300804

    /// Command capabilities from the TLS certificate SAN (base64: AAYTBhYGFwYcBh8=)
    static let commandsBase64 = "AAYTBhYGFwYcBh8="

    // MARK: - Registration Payload

    /// The registration payload from `register/complete` response (base64-encoded).
    /// This blob is written to the pod during `setPodUid` activation.
    /// Contains: secondary public key + command capabilities + encrypted provisioning data.
    static let registrationPayloadBase64 = "AAAAnwAAAQATUuYAAUEAJrtgfXb8RsMmvbvTFPuN0HnoI0mxTWTnwkJmQ2LRKTk05kRFtFOxgY32DTSR3N5/Kpi61q2s5S2mgGmjIJvbButNWWtf7KwA9gAGEwYWBhcGHAYfhCR70zZZUkTC5LROE+NurBHspOH4k3UmWrWbwpfuxjEVqNBQj5p9LrCBTiTCclQbA1+uyjMzF/PB/gDql/PS9w=="

    // MARK: - Computed Properties

    /// The 4-byte controller ID derived from pdmid (big-endian).
    /// e.g. pdmid 2538336 -> [0x00, 0x26, 0xBB, 0x60]
    var controllerID: Data {
        var value = O5CertificateStore.pdmid.bigEndian
        return Data(bytes: &value, count: 4)
    }

    /// The controller ID as a UInt32 value
    var controllerIDValue: UInt32 {
        return O5CertificateStore.pdmid
    }

    /// The primary signing key's public key in raw representation (64 bytes, x || y)
    var primaryPublicKeyRawFromKey: Data {
        return primarySigningKey.publicKey.rawRepresentation
    }

    // MARK: - Initialization

    init() throws {
        // Load the primary private key from the extracted scalar (always 32 bytes for P-256)
        let scalar = O5CertificateStore.primaryKeyScalar
        assert(scalar.count == 32, "Primary key scalar must be exactly 32 bytes")
        self.primarySigningKey = try P256.Signing.PrivateKey(rawRepresentation: scalar)

        // Verify that the signing key's public key matches the expected primary public key
        let derivedPubKey = primarySigningKey.publicKey.rawRepresentation
        if derivedPubKey != O5CertificateStore.primaryPublicKeyRaw {
            log.error("Primary signing key public key does NOT match expected value!")
        }

        log.debug("O5CertificateStore initialized with controllerID: %{public}@", controllerID.hexadecimalString)
    }

    // MARK: - Signing (Primary Key)

    /// Sign data with the primary private key using ECDSA SHA-256.
    /// Returns the DER-encoded ECDSA signature.
    ///
    /// NOTE: The SPS2.1 channel-binding signature in the real app uses the SECONDARY key
    /// (non-extractable). Signatures produced here with the primary key will NOT match
    /// the real app's SPS2.1 signatures. The primary key's role may be limited to
    /// certificate identity and potentially SPS2 signing.
    func signWithPrimary(_ data: Data) throws -> Data {
        let signature = try primarySigningKey.signature(for: data)
        return Data(signature.derRepresentation)
    }

    /// Sign data with the primary key and return the raw signature (r || s, 64 bytes)
    func signWithPrimaryRaw(_ data: Data) throws -> Data {
        let signature = try primarySigningKey.signature(for: data)
        return Data(signature.rawRepresentation)
    }

    // MARK: - Verification

    /// Verify an ECDSA signature against a public key (raw, 64 bytes x || y).
    /// The signature can be DER-encoded or raw (r || s).
    static func verifySignature(_ signature: Data, for data: Data, publicKeyRaw: Data) -> Bool {
        guard let pubKey = try? P256.Signing.PublicKey(rawRepresentation: publicKeyRaw) else {
            return false
        }
        // Try DER first, then raw
        if let derSig = try? P256.Signing.ECDSASignature(derRepresentation: signature) {
            return pubKey.isValidSignature(derSig, for: data)
        }
        if let rawSig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) {
            return pubKey.isValidSignature(rawSig, for: data)
        }
        return false
    }

    /// Verify a signature was produced by the secondary key (using its public key).
    static func verifySecondarySignature(_ signature: Data, for data: Data) -> Bool {
        return verifySignature(signature, for: data, publicKeyRaw: secondaryPublicKeyRaw)
    }

    // MARK: - Public Key Helpers

    /// Returns the uncompressed public key (65 bytes with 0x04 prefix) from raw representation
    static func uncompressedPublicKey(_ rawKey: Data) -> Data {
        var result = Data([0x04])
        result.append(rawKey)
        return result
    }
}
