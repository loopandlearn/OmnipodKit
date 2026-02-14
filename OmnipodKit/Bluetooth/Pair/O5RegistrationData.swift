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
        secondaryAttestationChainDERBase64: [
            // cert_0 — leaf (device secondary key)
            "MIIC3TCCAoKgAwIBAgIEALxhTjAKBggqhkjOPQQDAjA5MQwwCgYDVQQMDANURUUx" +
            "KTAnBgNVBAUTIDhjMGU2MGNkZjA0ZTJiNDUxYzI5NjY0NWViYWUwYWQ4MB4XDTcw" +
            "MDEwMTAwMDAwMFoXDTQ4MDEwMTAwMDAwMFowRjEMMAoGA1UEChMDVHdpMQswCQYD" +
            "VQQGEwJVUzEpMCcGA1UEAxMgY29tLnR3aS5lbmNsYXZlLmRldmljZS5zZWNvbmRh" +
            "cnkwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAR9dvxGwya9u9MU+43QeegjSbFN" +
            "ZOfCQmZDYtEpOTTmREW0U7GBjfYNNJHc3n8qmLrWrazlLaaAaaMgm9sG601Zo4IB" +
            "aTCCAWUwDgYDVR0PAQH/BAQDAgeAMIIBUQYKKwYBBAHWeQIBEQSCAUEwggE9AgIA" +
            "yAoBAQICAMgKAQEEIDMzMTM1MzY1N2ZmZGMxMDliYzIwOGNmNTNhZTg2OWI5BAA" +
            "wWL+FPQgCBgGcFwNXob+FRUgERjBEMR4wHAQWY29tLmluc3VsZXQubXlibHVlLnBk" +
            "bQICE6YxIgQgTkgHdQiznlfdb06NK1Pbid/gSj3oiZi02patX9XFJDQwga6hCDEG" +
            "AgECAgEDogMCAQOjBAICAQClCDEGAgEAAgEEpgUxAwIBBaoDAgEBv4N3AgUAv4U+" +
            "AwIBAL+FQEwwSgQgiyxM1Tn1B16OfPISrbPbBBP7130yEZnHPVpHPFHy4Q0BAf8K" +
            "AQAEIPJIqrgRh9zJpZtCeAzrqElhQSy+Zb8Yg7/qYKqvresNv4VBBQIDAfvQv4VC" +
            "BQIDAxdpv4VOBgIEATUlCb+FTwYCBAE1JQkwCgYIKoZIzj0EAwIDSQAwRgIhAPgo" +
            "02exMqF7okXk3xC+51d5SvADQvoohfBNfnR2wpG2AiEAnA1O0V+GDqT+wIOraBhp" +
            "XJuzSD6i5ePr2seRAOe7Gog=",
            // cert_1 — TEE intermediate
            "MIIB9DCCAXmgAwIBAgIQKCxmIIUNPuj0j6bL98QLNjAKBggqhkjOPQQDAjA5MQww" +
            "CgYDVQQMDANURUUxKTAnBgNVBAUTIGQ4YmZlOTUxYzg0MGEwNGQ1MTcwYjVhZGUw" +
            "NmQzYTU0MB4XDTIyMDEyNTIzMzUyMVoXDTMyMDEyMzIzMzUyMVowOTEMMAoGA1UE" +
            "DAwDVEVFMSkwJwYDVQQFEyA4YzBlNjBjZGYwNGUyYjQ1MWMyOTY2NDVlYmFlMGFk" +
            "ODBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABKFIMTCFQmHYYDbipfC1GgwFRuIA" +
            "y1uRyNaqm9KD7HIGnZlyYa2gXl/khe+B4yqa1y2hI6wgv9cgkhbD1qaqIs+jYzBh" +
            "MB0GA1UdDgQWBBT9htbJlzc01RuKa5VPFDuWC+/9rzAfBgNVHSMEGDAWgBRI9I6O" +
            "trDGv8Vaz6nPAL/WqA7rUzAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIC" +
            "BDAKBggqhkjOPQQDAgNpADBmAjEApCZ12C5NTULVQz3fXc5fKcQTMOhTthgcDWRu" +
            "b/WnKLl2ja2J1H/zehzXtgFwQDx1AjEA1D2jtYHZ+V2iewDM9GmCp266Alcpbx1N" +
            "Kdun1CSUBLeM4UFp3SI+9XBMaAoQTj+t",
            // cert_2 — HW intermediate (EC P-384)
            "MIIDlDCCAXygAwIBAgIRAJVCTT29Kco6Jb3Kxe5RGHwwDQYJKoZIhvcNAQELBQAw" +
            "GzEZMBcGA1UEBRMQZjkyMDA5ZTg1M2I2YjA0NTAeFw0yMjAxMjUyMzMyNDhaFw0z" +
            "MjAxMjMyMzMyNDhaMDkxDDAKBgNVBAwMA1RFRTEpMCcGA1UEBRMgZDhiZmU5NTFj" +
            "ODQwYTA0ZDUxNzBiNWFkZTA2ZDNhNTQwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAAQW" +
            "wIfytXG3HCiP5A86lhNH6YxLM5nIgnssT8AejEwAtF/Qh8rI9++5kyl4CoSTW8dh" +
            "7c7ssRPp8AekngN/BzHB3A7Muw6Z2V69zwQVye2HaVMmrsy0AAHv15Unmg3/1Nyj" +
            "YzBhMB0GA1UdDgQWBBRI9I6OtrDGv8Vaz6nPAL/WqA7rUzAfBgNVHSMEGDAWgBQ2" +
            "YeEAfIgFCVGLRGxH/xpMyepPEjAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQE" +
            "AwICBDANBgkqhkiG9w0BAQsFAAOCAgEAM9sIKoPdl8OeIf2bfiNxopvg0u/Saxu/" +
            "qfMTBywzXrspkBmCgXk0NVHRnS+K+BYsIMxd7GTcPU98+69MOLSBH5qEY1G/1uu+" +
            "wIlU3B6/v3k+oyAGzCwZiNBMkIF8ASYj/t3s79h69y54CVAFqKwWBXZWeXZawGY6" +
            "JdQ39dLlkLpxBq2Jb0fJC/9mdvU3lw7j6qVQPpXDKKuk1l5mTsv7yrSHyxUByHp" +
            "8IvF+RxIbGe3qPpMlRB8kSRJKugtMPPu2g0sAYxI9Hw8Dm1UQvgQAWj2KJ9tHdi" +
            "Znjb3byHkm3d0+wEzSczjfqQ5k5DRSOjWdQk8vSv3SHOeUG25w/3lKvg1AVihgir" +
            "onLdSDYjCm6c9HJl8Aa6j9ofIwZQIZn7rnl8e2AGa/BNgmviNnc2Zgnkw1nhUsb" +
            "NmdfoNbyf5sLK0PrScgZ+INmx7ZqflnXq325todpsW2LYkPR+S6cOG8hF/9M87gC" +
            "K6RHC0GBoDnMhA6MtGn/3MTivEBSiB3XVD8a9ywFhueOkyvMAN+61VLFSDQi3HAF" +
            "xlQE3Lo/vVZGtQuZf0pxf/+2TA+H+oeJR7fnnf5LwllUIBN70XfgVjA1oxPnSYf2" +
            "EUEFxwGxDGhDPHJy+ufJ1SQiuzpaIbpuBjq7XHNnXkrDbVNTT8/8T8rFPF+pp2ia" +
            "RKE0tVhbx89LBM=",
            // cert_3 — Google HW Attestation Root (RSA-4096)
            "MIIFHDCCAwSgAwIBAgIJAMNrfES5rhgxMA0GCSqGSIb3DQEBCwUAMBsxGTAXBgNV" +
            "BAUTEGY5MjAwOWU4NTNiNmIwNDUwHhcNMjExMTE3MjMxMDQyWhcNMzYxMTEzMjMx" +
            "MDQyWjAbMRkwFwYDVQQFExBmOTIwMDllODUzYjZiMDQ1MIICIjANBgkqhkiG9w0B" +
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
            "VR0PAQH/BAQDAgIEMA0GCSqGSIb3DQEBCwUAA4ICAQBTNNZe5cuf8oiq+jV0itTG" +
            "zWVhSTjOBEk2FQvh11J3o3lna0o7rd8RFHnN00q4hi6TapFhh4qaw/iG6Xg+xOan" +
            "63niLWIC5GOPFgPeYXM9+nBb3zZzC8ABypYuCusWCmt6Tn3+Pjbz3MTVhRGXuT/T" +
            "QH4KGFY4PhvzAyXwdjTOCXID+aHud4RLcSySr0Fq/L+R8TWalvM1wJJPhyRjqRC" +
            "JerGtfBagiALzvhnmY7U1qFcS0NCnKjoO7oFedKdWlZz0YAfu3aGCJd4KHT0MsGi" +
            "LZez9WP81xYSrKMNEsDK+zK5fVzw6jA7cxmpXcARTnmAuGUeI7VVDhDzKeVOctf3" +
            "a0qQLwC+d0+xrETZ4r2fRGNw2YEs2W8Qj6oDcfPvq9JySe7pJ6wcHnl5EZ0lwc4" +
            "xH7Y4Dx9RA1JlfooLMw3tOdJZH0enxPXaydfAD3YifeZpFaUzicHeLzVJLt9dvGB" +
            "0bHQLE4+EqKFgOZv2EoP686DQqbVS1u+9k0p2xbMA105TBIk7npraa8VM0fnrRKi" +
            "7wlZKwdH+aNAyhbXRW9xsnODJ+g8eF452zvbiKKngEKirK5LGieoXBX7tZ9D1GNB" +
            "H2Ob3bKOwwIWdEFle/YF/h6zWgdeoaNGDqVBrLr2+0DtWoiB1aDEjLWl9FmyIUyU" +
            "m7mD/vFDkzF+wm7cyWpQpCVQ==",
        ],

        // Registration Payload (from register/complete for pdmid 2538336 session)
        registrationPayloadBase64:
            "AAAAnwAAAQATUuYAAUEAJrtgfXb8RsMmvbvTFPuN0HnoI0mxTWTnwkJmQ2LRKTk0" +
            "5kRFtFOxgY32DTSR3N5/Kpi61q2s5S2mgGmjIJvbButNWWtf7KwA9gAGEwYWBhcG" +
            "HAYfhCR70zZZUkTC5LROE+NurBHspOH4k3UmWrWbwpfuxjEVqNBQj5p9LrCBTiTC" +
            "clQbA1+uyjMzF/PB/gDql/PS9w=="
    )
}
