//
//  O5RegistrationData.swift
//  OmnipodKit
//
//  Extracted O5 registration data — keys, certificates, and PDM identity.
//  Swap the `active` instance to use a different registration set.
//
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//

import Foundation
import CryptoSwift

/// All material from a single O5 device registration.
/// Create additional instances for different registrations and assign to `O5RegistrationData.active`.
struct O5RegistrationData {

    // MARK: - PDM Identity (from TLS Certificate SAN)

    /// PDM ID from the TLS certificate SAN — becomes the 4-byte controller ID.
    let pdmid: UInt32

    /// PDM ID extension from the TLS certificate SAN.
    let pdmidExtension: UInt32

    /// Command capabilities from the TLS certificate SAN (base64-encoded).
    let commandsBase64: String

    // MARK: - Secondary Key (main signing key, SPS2.1 + pod commands)

    /// Secondary EC P-256 private key scalar (32 bytes hex).
    /// Source: KEYS/com.twi.enclave.device.secondary/priv.pk8
    let secondaryKeyScalarHex: String

    /// Secondary key public key (64 bytes hex, x || y, no 04 prefix).
    let secondaryPublicKeyHex: String

    // MARK: - Primary Key (certificate identity, sent to pod during SPS2.1)

    /// Primary EC P-256 private key scalar (32 bytes hex). May be nil if not extracted.
    let primaryKeyScalarHex: String?

    /// Primary key public key (64 bytes hex, x || y, no 04 prefix). May be nil.
    let primaryPublicKeyHex: String?

    /// Primary key self-signed X.509 certificate (DER, base64). Sent to pod during SPS2.1.
    let primaryCertificateDERBase64: String?

    // MARK: - Insulet Certificate Chain (downloaded via register/download)

    /// Root CA certificate (INS00PG1, self-signed, DER base64).
    let rootCACertDERBase64: String

    /// Intermediate CA certificate (INS02PG1, issued by INS00PG1, DER base64).
    let intermediateCACertDERBase64: String

    /// Pod Intermediate CA certificate (INS01PG1, issued by INS00PG1, DER base64).
    let podIntermediateCACertDERBase64: String

    /// TLS Certificate (issued by INS02PG1, DER base64).
    /// Its public key matches the secondary signing key.
    let tlsCertificateDERBase64: String

    // MARK: - Insulet Certificate Chain Public Keys (raw, 64 bytes hex, x || y)

    let rootCAPublicKeyHex: String
    let intermediateCAPublicKeyHex: String
    let podIntermediateCAPublicKeyHex: String

    // MARK: - Secondary Attestation Chain (Android Keystore, DER base64)

    /// cert[0] — Leaf (device key), cert[1] — TEE intermediate,
    /// cert[2] — HW intermediate (P-384), cert[3] — Google HW root (RSA-4096)
    let secondaryAttestationChainDERBase64: [String]

    // MARK: - Registration Payload (from register/complete)

    /// Binary payload written to pod during setPodUid. Contains secondary public key + commands.
    let registrationPayloadBase64: String?

    // MARK: - Convenience

    var secondaryKeyScalar: Data { Data(hex: secondaryKeyScalarHex) }
    var secondaryPublicKeyRaw: Data { Data(hex: secondaryPublicKeyHex) }
    var primaryKeyScalar: Data? { primaryKeyScalarHex.map { Data(hex: $0) } }
    var primaryPublicKeyRaw: Data? { primaryPublicKeyHex.map { Data(hex: $0) } }
    var primaryCertificateDER: Data? { primaryCertificateDERBase64.flatMap { Data(base64Encoded: $0) } }
    var rootCAPublicKeyRaw: Data { Data(hex: rootCAPublicKeyHex) }
    var intermediateCAPublicKeyRaw: Data { Data(hex: intermediateCAPublicKeyHex) }
    var podIntermediateCAPublicKeyRaw: Data { Data(hex: podIntermediateCAPublicKeyHex) }
    var tlsCertificateDER: Data? { Data(base64Encoded: tlsCertificateDERBase64) }
    var rootCACertDER: Data? { Data(base64Encoded: rootCACertDERBase64) }
    var intermediateCACertDER: Data? { Data(base64Encoded: intermediateCACertDERBase64) }

    /// Registration payload from register/complete (written to pod during setPodUid).
    var registrationPayload: Data? { registrationPayloadBase64.flatMap { Data(base64Encoded: $0) } }

    /// Attestation leaf public key (cert_0, P-256, 64 bytes raw x || y).
    /// This is the secondary key's attestation leaf certificate's subject key.
    var attestationLeafPublicKeyRaw: Data? {
        guard secondaryAttestationChainDERBase64.count > 0 else { return nil }
        return O5CertificateStore.extractP256PublicKey(fromDERCertBase64: secondaryAttestationChainDERBase64[0])
    }

    /// TEE intermediate public key (cert_1, P-256, 64 bytes raw x || y).
    var teeIntermediatePublicKeyRaw: Data? {
        guard secondaryAttestationChainDERBase64.count > 1 else { return nil }
        return O5CertificateStore.extractP256PublicKey(fromDERCertBase64: secondaryAttestationChainDERBase64[1])
    }

    var controllerID: Data {
        var value = pdmid.bigEndian
        return Data(bytes: &value, count: 4)
    }
}

// MARK: - Active Registration

extension O5RegistrationData {

    /// The currently active registration data set.
    /// Change this to use a different registration.
    static var active: O5RegistrationData = .teeSimulator_2584724
}

// MARK: - TEE Simulator Registration (pdmid 2584724, Feb 2026)
//
// Source: Omnipod5APK/KEYS/
// Secondary key extracted from TEE simulator VirtualKeyStore.
// TLS certificate issued 2026-02-14 by INS02PG1.
// Primary key from an earlier Frida-hook session (pdmid 2538336).
//

extension O5RegistrationData {

    static let teeSimulator_2584724 = O5RegistrationData(

        // PDM Identity
        pdmid: 2584724,
        pdmidExtension: 4300804,
        commandsBase64: "AAYTBhYGFwYcBh8=",

        // Secondary Key (com.twi.enclave.device.secondary)
        // Source: KEYS/com.twi.enclave.device.secondary/priv.pk8
        secondaryKeyScalarHex:
            "f5b539ec69b24876e74785fba316fe2e95eb6e26005f80f9cc7394dfcb461d05",
        secondaryPublicKeyHex:
            "e3c48e617ccb64979c6e99cb4d07af307316450fe3ac9f176b20a09b64d47864" +
            "f54dea67d10327ef9be03aee756bc6819e6ae5cfd566e4687e303793eebaa3bf",

        // Primary Key (com.twi.enclave.device.primary)
        // Source: SPS21_KEYS_PRIMARY.md — Frida hook extraction (earlier session)
        primaryKeyScalarHex:
            "7045a86517f2127bfe84bd366c068107ed46198487f46380fd68c5f8fac57560",
        primaryPublicKeyHex:
            "3c121cb7074a6047651b39be78fd29498bd5eee4271d5d73a5001783e60a1855" +
            "9014f9dfa2faf8fda788fa9242934f8138e43e1d651dd77d789ef13fe6f5a962",
        primaryCertificateDERBase64:
            "MIIBczCCARkCBBcDWo0wCgYIKoZIzj0EAwIwRDELMAkGA1UEBhMCVVMxDDAKBgNV" +
            "BAoTA1R3aTEnMCUGA1UEAxMeY29tLnR3aS5lbmNsYXZlLmRldmljZS5wcmltYXJ5" +
            "MB4XDTI1MDEwMTAwMDAwMFoXDTM1MDEwMTAwMDAwMFowRDELMAkGA1UEBhMCVVMx" +
            "DDAKBgNVBAoTA1R3aTEnMCUGA1UEAxMeY29tLnR3aS5lbmNsYXZlLmRldmljZS5w" +
            "cmltYXJ5MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEPBIctwdKYEdlGzm+eP0p" +
            "SYvV7uQnHV1zpQAXg+YKGFWQFPnfovr4/aeI+pJCk0+BOOQ+HWUd1314nvE/5vWp" +
            "YjAKBggqhkjOPQQDAgNIADBFAiBtQdHvHFTax6ktGGxJoeuPaowPmN0BLyZKOUjy" +
            "uByo1QIhAKSoLdPXJinw4PhGbnAR9g582KNgyfMTdJG2rhnnlRZm",

        // Insulet Certificate Chain (KEYS/*.pem)
        rootCACertDERBase64:
            "MIIBrzCCAVWgAwIBAgIUCv1WvlqSFAVjFzv6zDvyQN4omf4wCgYIKoZIzj0EAwIw" +
            "JTEQMA4GA1UECgwHSW5zdWxldDERMA8GA1UEAwwISU5TMDBQRzEwHhcNMjEwMzAx" +
            "MTc0MzU0WhcNNDYwMjIzMTc0MzUzWjAlMRAwDgYDVQQKDAdJbnN1bGV0MREwDwYD" +
            "VQQDDAhJTlMwMFBHMTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABIoWueoAJYYN" +
            "BuOoQSztMH6uPaBMpz29boXI6j6QcKYHL3Sf9mYsiwcC2vGXRWLGNKfk2pMkzu51" +
            "oi4nCJ0uYd+jYzBhMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU4QRpZdMc" +
            "QHMKyAL8weYArFFIXikwHQYDVR0OBBYEFOEEaWXTHEBzCsgC/MHmAKxRSF4pMA4G" +
            "A1UdDwEB/wQEAwIBhjAKBggqhkjOPQQDAgNIADBFAiEA2JR6+lrmR7RqrOWtKMPX" +
            "vL3GrcArllVcpZDEb4PNQSYCICJWIQdkk3ScuJjGcLoBrTE0sLiGidoWnssFQBBn" +
            "51zt",
        intermediateCACertDERBase64:
            "MIICdjCCAhygAwIBAgIUMV1h6aWp0uFKHuQ5vhd1zk58HWkwCgYIKoZIzj0EAwIw" +
            "JTEQMA4GA1UECgwHSW5zdWxldDERMA8GA1UEAwwISU5TMDBQRzEwHhcNMjEwMzAy" +
            "MjA0NzM2WhcNMzYwMjI3MjA0NzM1WjAlMRAwDgYDVQQKDAdJbnN1bGV0MREwDwYD" +
            "VQQDDAhJTlMwMlBHMTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABMg2GKWPvc4e" +
            "/WnsxkeEtbPA2aQMhZDjyE/EGkhQX8Rh5d9LGaJO7yAQHFvulGyxVg0RkN0wrDQV" +
            "YA0DQpIocVCjggEoMIIBJDAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFOEE" +
            "aWXTHEBzCsgC/MHmAKxRSF4pMIHABgNVHR8EgbgwgbUwgbKggYSggYGGf2h0dHA6" +
            "Ly9pc3N1aW5nLnByb2Qtb21uaXBvZGNsb3VkLnVzLnByb2Quc2Fhcy5wcmltZWtl" +
            "eS5jb20vZWpiY2EvcHVibGljd2ViL2NybHMvc2VhcmNoLmNnaT9zS0lESGFzaD00" +
            "UVJwWmRNY1FITUt5QUw4d2VZQXJGRklYaWuiKaQnMCUxETAPBgNVBAMMCElOUzAw" +
            "UEcxMRAwDgYDVQQKDAdJbnN1bGV0MB0GA1UdDgQWBBSwitBSFMAmwDsKs5XqpiAD" +
            "ocdNDDAOBgNVHQ8BAf8EBAMCAYYwCgYIKoZIzj0EAwIDSAAwRQIgYZEhtAwlrqUM" +
            "IJpK17wrdMsX4mY6vNKpbOIcKFFsqDACIQC7ghXZHgc0NTvyay0ssEqguu4ymeMq" +
            "c3vVWj9SFszc/A==",
        podIntermediateCACertDERBase64:
            "MIICdTCCAhygAwIBAgIUe9cUX7BxE53OCQGKp2jPCLchENMwCgYIKoZIzj0EAwIw" +
            "JTEQMA4GA1UECgwHSW5zdWxldDERMA8GA1UEAwwISU5TMDBQRzEwHhcNMjEwMzAy" +
            "MjA0NDA3WhcNMzYwMjI3MjA0NDA2WjAlMRAwDgYDVQQKDAdJbnN1bGV0MREwDwYD" +
            "VQQDDAhJTlMwMVBHMTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABK0vO3zFtZcb" +
            "6lgt/yguCEIUFtkuI4DbtFgClEE4zeAjxUgNQ84E/aELSYATmkAJA/WBo++KZxht" +
            "cZp53FSS9EGjggEoMIIBJDAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFOEE" +
            "aWXTHEBzCsgC/MHmAKxRSF4pMIHABgNVHR8EgbgwgbUwgbKggYSggYGGf2h0dHA6" +
            "Ly9pc3N1aW5nLnByb2Qtb21uaXBvZGNsb3VkLnVzLnByb2Quc2Fhcy5wcmltZWtl" +
            "eS5jb20vZWpiY2EvcHVibGljd2ViL2NybHMvc2VhcmNoLmNnaT9zS0lESGFzaD00" +
            "UVJwWmRNY1FITUt5QUw4d2VZQXJGRklYaWuiKaQnMCUxETAPBgNVBAMMCElOUzAw" +
            "UEcxMRAwDgYDVQQKDAdJbnN1bGV0MB0GA1UdDgQWBBQfuPi31sWsIDH//Kw+YcuT" +
            "VVhHkzAOBgNVHQ8BAf8EBAMCAYYwCgYIKoZIzj0EAwIDRwAwRAIgAxr4YGj7N3Fy" +
            "XzZMJyrIPU/XkC/xiasOZHtq/9B5U20CIHP863vh8rIBNPk/dL9CfSQ6nkPyXR+W" +
            "Nz7bgo7Q8aTA",
        tlsCertificateDERBase64:
            "MIIDbDCCAxKgAwIBAgIUdzW8xb8pW6oVGmkUiQpRBsaftH8wCgYIKoZIzj0EAwIw" +
            "JTEQMA4GA1UECgwHSW5zdWxldDERMA8GA1UEAwwISU5TMDJQRzEwHhcNMjYwMjE0" +
            "MTcxNTMzWhcNMzAwMjEzMTcxNTMyWjBLMRYwFAYDVQQDDA1UaGlyZHdheXYgSW5j" +
            "MRAwDgYDVQQKDAdJbnN1bGV0MRIwEAYDVQQLDAlBdXRoVXNlcnMxCzAJBgNVBAYT" +
            "AlVTMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE48SOYXzLZJecbpnLTQevMHMW" +
            "RQ/jrJ8XayCgm2TUeGT1Tepn0QMn75vgOu51a8aBnmrlz9Vm5Gh+MDeT7rqjv6OC" +
            "AfgwggH0MAwGA1UdEwEB/wQCMAAwHwYDVR0jBBgwFoAUsIrQUhTAJsA7CrOV6qYg" +
            "A6HHTQwwcgYIKwYBBQUHAQEEZjBkMGIGCCsGAQUFBzABhlZodHRwOi8vaXNzdWlu" +
            "Zy5wcm9kLW9tbmlwb2RjbG91ZC51cy5wcm9kLnNhYXMucHJpbWVrZXkuY29tL2Vq" +
            "YmNhL3B1YmxpY3dlYi9zdGF0dXMvb2NzcDBpBgNVHREEYjBghhljb21tYW5kczpB" +
            "QVlUQmhZR0Z3WWNCaDg9hhxkZXZpY2V0eXBlOmNvbnRyb2xsZXJBbmRyb2lkhg1w" +
            "ZG1pZDoyNTg0NzI0hhZwZG1pZGV4dGVuc2lvbjo0MzAwODA0MB0GA1UdJQQWMBQG" +
            "CCsGAQUFBwMCBggrBgEFBQcDATCBlQYDVR0fBIGNMIGKMIGHoIGEoIGBhn9odHRw" +
            "Oi8vaXNzdWluZy5wcm9kLW9tbmlwb2RjbG91ZC51cy5wcm9kLnNhYXMucHJpbWVr" +
            "ZXkuY29tL2VqYmNhL3B1YmxpY3dlYi9jcmxzL3NlYXJjaC5jZ2k/c0tJREhhc2g9" +
            "c0lyUVVoVEFKc0E3Q3JPVjZxWWdBNkhIVFF3MB0GA1UdDgQWBBTM9FpI9qHgfnhm" +
            "WL/n5hBzTE9ZvzAOBgNVHQ8BAf8EBAMCBaAwCgYIKoZIzj0EAwIDSAAwRQIhAJmu" +
            "bOd3Qr3oEl/dIoeT689QHATBPdg4/2i7ikbF/3+6AiBRGgQr1sMH2OSzLMocFh76" +
            "IiDlLY/cBWb9dKj6zDibuw==",

        // Insulet Chain Public Keys (raw, hex, x || y, no 04 prefix)
        rootCAPublicKeyHex:
            "8a16b9ea0025860d06e3a8412ced307eae3da04ca73dbd6e85c8ea3e9070a607" +
            "2f749ff6662c8b0702daf1974562c634a7e4da9324ceee75a22e27089d2e61df",
        intermediateCAPublicKeyHex:
            "c83618a58fbdce1efd69ecc64784b5b3c0d9a40c8590e3c84fc41a48505fc461" +
            "e5df4b19a24eef20101c5bee946cb1560d1190dd30ac3415600d034292287150",
        podIntermediateCAPublicKeyHex:
            "ad2f3b7cc5b5971bea582dff282e08421416d92e2380dbb45802944138cde023" +
            "c5480d43ce04fda10b4980139a400903f581a3ef8a67186d719a79dc5492f441",

        // Secondary Attestation Chain (KEYS/com.twi.enclave.device.secondary/cert_*.der)
        // TEE Simulator chain (uid=10262), cert_0 public key matches secondary key.
        secondaryAttestationChainDERBase64: [
            // cert_0 — leaf (TEE simulator, contains our secondary public key e3c48e61...)
            "MIIC1TCCAnugAwIBAgIEALxhTjAKBggqhkjOPQQDAjA5MQwwCgYDVQQMDANURUUx" +
            "KTAnBgNVBAUTIDczMjI4ODQ3Mzk3ZmMzYjZhZDA4NmQ3MTUyNTU1ZDdhMB4XDTcw" +
            "MDEwMTAwMDAwMFoXDTQ4MDEwMTAwMDAwMFowRjEpMCcGA1UEAwwgY29tLnR3aS5l" +
            "bmNsYXZlLmRldmljZS5zZWNvbmRhcnkxCzAJBgNVBAYTAlVTMQwwCgYDVQQKDANU" +
            "d2kwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATjxI5hfMtkl5xumctNB68wcxZF" +
            "D+OsnxdrIKCbZNR4ZPVN6mfRAyfvm+A67nVrxoGeauXP1WbkaH4wN5PuuqO/o4IB" +
            "YjCCAV4wDgYDVR0PAQH/BAQDAgeAMIIBSgYKKwYBBAHWeQIBEQSCATowggE2AgIB" +
            "LAoBAQICASwKAQEEIGE4ZTNmM2VkMWM2OTYyZjZiZmUxMjZjYjZjODk5MzEyBAAw" +
            "WL+FPQgCBgGcXS+zLL+FRUgERjBEMR4wHAQWY29tLmluc3VsZXQubXlibHVlLnBk" +
            "bQICFGQxIgQgTkgHdQiznlfdb06NK1Pbid/gSj3oiZi02patX9XFJDQwgaehCDEG" +
            "AgECAgEDogMCAQOjBAICAQClCDEGAgEAAgEEqgMCAQG/g3cCBQC/hT4DAgEAv4VA" +
            "TDBKBCARJIJpoNX1zKLjYZpVlwyNsk7r0bknefE91SdWRAWymgEB/woBAAQgaCv5" +
            "r9i8J4lbu+msb202wIA5edhVBIyCDRNs6uOlreS/hUEFAgMCSfC/hUIFAgMDF2m/" +
            "hU4GAgQBNSUJv4VPBgIEATUlCTAKBggqhkjOPQQDAgNIADBFAiBks8X8cPq/kCEG" +
            "KG2X7qPLQ6QsP+c4VIhs1ZCaONu/LwIhAIhTMsTBiaQous8hU3S3YspdigvgBKGB" +
            "f7gBNRZQb/kp",
            // cert_1 — TEE intermediate (TEE simulator)
            "MIIB8jCCAXmgAwIBAgIQH7v+o2W6bJu0JVFT0Z8LjTAKBggqhkjOPQQDAjA5MQww" +
            "CgYDVQQMDANURUUxKTAnBgNVBAUTIGI1ZmEyMTVkMjY5ZWQ1ZDk2ZTRmYTUzMDU2" +
            "NTFjODAzMB4XDTIwMDEwNzIwNTEzN1oXDTMwMDEwNDIwNTEzN1owOTEMMAoGA1UE" +
            "DAwDVEVFMSkwJwYDVQQFEyA3MzIyODg0NzM5N2ZjM2I2YWQwODZkNzE1MjU1NWQ3" +
            "YTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABNDKinW13NyJcYlpbKzI76ZedNEQ" +
            "Bt37AhT96xpa7jM1yP2iqr73nnQa3pgZYpT6pAnAhn4Ssw7dozaxYQfIlHujYzBh" +
            "MB0GA1UdDgQWBBQGt3dexBepBAJNItT5VkWhUY4NzzAfBgNVHSMEGDAWgBQN5NB3" +
            "d2lA7UG8vE9WMJZ8OTbKwTAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIC" +
            "BDAKBggqhkjOPQQDAgNnADBkAjB/X1qd4v6xXFX7vl7wsW56/b3LoCp+eOQBraiuC" +
            "rnbk7D7zygmTdW7ZquEwePSGEYCMGjS8jcrJUiRSQR8d/MweRrfiMIC8c2X/M/MPz" +
            "a1k7aPRbVY66e60wcwKw0VoaqmNA==",
            // cert_2 — HW intermediate (EC P-384, TEE simulator)
            "MIIDkzCCAXugAwIBAgIQS2Lw1jXh2CqWmcac2htOGTANBgkqhkiG9w0BAQsFADAb" +
            "MRkwFwYDVQQFExBmOTIwMDllODUzYjZiMDQ1MB4XDTIwMDEwNzIwNTA1MFoXDTMw" +
            "MDEwNDIwNTA1MFowOTEMMAoGA1UEDAwDVEVFMSkwJwYDVQQFEyBiNWZhMjE1ZDI2" +
            "OWVkNWQ5NmU0ZmE1MzA1NjUxYzgwMzB2MBAGByqGSM49AgEGBSuBBAAiA2IABEN3" +
            "xgZcDXwQ3HOojzHbQwgOnuv4t9/uCE7euyjfPcId/WJIAkhQttfaiXHbQAHZqnvZ" +
            "hsgrEo31c+QPEVKhEwiEQb7WclTax7JwsVIhXBOGQs1vpYGSV9/gcE1HxqxFCaNj" +
            "MGEwHQYDVR0OBBYEFA3k0Hd3aUDtQby8T1Ywlnw5NsrBMB8GA1UdIwQYMBaAFDZh" +
            "4QB8iAUJUYtEbEf/GkzJ6k8SMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQD" +
            "AgIEMA0GCSqGSIb3DQEBCwUAA4ICAQATR4gQZqXNRnFT97prNB9JwB5ecpe4H5wv" +
            "k+RinuV+hyTnyWKzga0YI4Riaw+gQLISNAih4P1evAgchChnJSk4HhR3SGPLO+wm" +
            "hMRBhgTzG0UTyX1y8yrxZC1aDPjQTBm9JMSZ868DgcEJryJO+3ynVYeGwRddDMu5" +
            "7hyNKibvbrKU/zZUlR3JcdaWz7ZGLkcKZMwg1qiL91R9lD337EZOKyCNJOcj1r0G" +
            "yZ809eMcWZyK68oPfwFa+dhErGu8GUVW3tn9jdp4JLQjkh37/cSXHhZCOe0Ar2/p" +
            "YRBfv4lRkUhA7fdSbMMbVjD/aVYsN4jzmzDw/uftXjIQBy3cu9v68ipJND8C5Vv4" +
            "ugIvsuUb0bSIBBSBBp/Pt1fQbMRJFUbDXZ+L74nwRvgM2NniHZX7emHzk3KRf/oQ" +
            "EH8vUQutkP/KNBoiI5PuUyu0kNw64XcNbH93LtXDL5UOaRDvhG1pJ9RN4tkPh7CC" +
            "D4u0HsT/rRV+pzfZpRDt4j3TGD6VnYMscJRL0RpwfxEYQaa45LQSXzECVKxCL+im" +
            "ZQcPTnINWpTY3cOKcRRtT2EyzxmD8/pwto4ChTq6hfsb0U2DNn5QZq9KKej5cK+G" +
            "Vj3//K3lO0XpXkSXeJEe4HC1c+KDZMqkgHv78c9wVdfPC++ERNBMhMxO0a0gCgLr" +
            "HUOdeTeYfw==",
            // cert_3 — Google HW Attestation Root (RSA-4096, TEE simulator)
            "MIIFHDCCAwSgAwIBAgIJANUP8luj8tazMA0GCSqGSIb3DQEBCwUAMBsxGTAXBgNV" +
            "BAUTEGY5MjAwOWU4NTNiNmIwNDUwHhcNMTkxMTIyMjAzNzU4WhcNMzQxMTE4MjAz" +
            "NzU4WjAbMRkwFwYDVQQFExBmOTIwMDllODUzYjZiMDQ1MIICIjANBgkqhkiG9w0B" +
            "AQEFAAOCAg8AMIICCgKCAgEAr7bHgiuxpwHsK7Qui8xUFmOr75gvMsd/dTEDDJdS" +
            "Sxtf6An7xyqpRR90PL2abxM1dEqlXnf2tqw1Ne4Xwl5jlRfdnJLmN0pTy/4lj4/7" +
            "tv0Sk3iiKkypnEUtR6WfMgH0QZfKHM1+di+y9TFRtv6y//0rb+T+W8a9nsNL/ggj" +
            "nar86461qO0rOs2cXjp3kOG1FEJ5MVmFmBGtnrKpa73XpXyTqRxB/M0n1n/W9nGqC" +
            "4FSYa04T6N5RIZGBN2z2MT5IKGbFlbC8UrW0DxW7AYImQQcHtGl/m00QLVWutHQo" +
            "VJYnFPlXTcHYvASLu+RhhsbDmxMgJJ0mcDpvsC4PjvB+TxywElgS70vE0XmLD+OJ" +
            "tvsBslHZvPBKCOdT0MS+tgSOIfga+z1Z1g7+DVagf7quvmag8jfPioyKvxnK/Egs" +
            "TUVi2ghzq8wm27ud/mIM7AY2qEORR8Go3TVB4HzWQgpZrt3i5MIlCaY504LzSRii" +
            "gHCzAPlHws+W0rB5N+er5/2pJKnfBSDiCiFAVtCLOZ7gLiMm0jhO2B6tUXHI/+MR" +
            "Pjy02i59lINMRRev56GKtcd9qO/0kUJWdZTdA2XoS82ixPvZtXQpUpuL12ab+9Ea" +
            "DK8Z4RHJYYfCT3Q5vNAXaiWQ+8PTWm2QgBR/bkwSWc+NpUFgNPN9PvQi8WEg5Um" +
            "AGMCAwEAAaNjMGEwHQYDVR0OBBYEFDZh4QB8iAUJUYtEbEf/GkzJ6k8SMB8GA1Ud" +
            "IwQYMBaAFDZh4QB8iAUJUYtEbEf/GkzJ6k8SMA8GA1UdEwEB/wQFMAMBAf8wDgYD" +
            "VR0PAQH/BAQDAgIEMA0GCSqGSIb3DQEBCwUAA4ICAQBOMaBc8oumXb2voc7XCWnu" +
            "XKhBBK3e2KMGz39t7lA3XXRe2ZLLAkLM5y3J7tURkf5a1SutfdOyXAmeE6SRo83U" +
            "h6WszodmMkxK5GM4JGrnt4pBisu5igXEydaW7qq2CdC6DOGjG+mEkN8/TA6p3cno" +
            "L/sPyz6evdjLlSeJ8rFBH6xWyIZCbrcpYEJzXaUOEaxxXxgYz5/cTiVKN2M1G2ok" +
            "QBUIYSY6bjEL4aUN5cfo7ogP3UvliEo3Eo0YgwuzR2v0KR6C1cZqZJSTnghIC/v" +
            "AD32KdNQ+c3N+vl2OTsUVMC1GiWkngNx1OO1+kXW+YTnnTUOtOIswUP/Vqd5SYg" +
            "AImMAfY8U9/iIgkQj6T2W6FsScy94IN9fFhE1UtzmLoBIuUFsVXJMTz+Jucth+Iq" +
            "oWFua9v1R93/k98p41pjtFX+H8DslVgfP097vju4KDlqN64xV1grw3ZLl4CiOe/A" +
            "91oeLm2UHOq6wn3esB4r2EIQKb6jTVGu5sYCcdWpXr0AUVqcABPdgL+H7qJguBw" +
            "09ojm6xNIrw2OocrDKsudk/okr/AwqEyPKw9WnMlQgLIKw1rODG2NvU9oR3GVGdM" +
            "kUBZutL8VuFkERQGt6vQ2OCw0sV47VMkuYbacK/xyZFiRcrPJPb41zgbQj9XAEyL" +
            "KCHex0SdDrx+tWUDqG8At2JHA==",
        ],

        // Registration Payload from register/complete for pdmid 2584724.
        // Structure (163 bytes): length(4) + flags(4) + id(3) + sep(1) + type(1) + keysize=65(1)
        //   + controller_id(4) + secondary_pubkey(64) + commands(11) + encrypted_data(65)
        // Verified: controller_id = 00277094 (2584724), secondary key = e3c48e61...
        registrationPayloadBase64:
            "AAAAnwAAAQATk3wAAUEAJ3CU48SOYXzLZJecbpnLTQevMHMWRQ/jrJ8XayCgm2TUeGT1Tepn0QMn" +
            "75vgOu51a8aBnmrlz9Vm5Gh+MDeT7rqjv2tx441UaQAGEwYWBhcGHAYfcbN9kT/bY5A4StHPEZzu" +
            "SfGdFAfyzrrI964yENeQae3Cn6HCY+R5XjeQhP5vfwq+EgRXe7VxG5wxjqHU4Cqcag=="
    )
}
