# CLAUDE.md — OmnipodKit O5 Pairing Context

## Project Overview

OmnipodKit is a Swift framework for communicating with Omnipod insulin pumps over BLE. It supports both DASH and Omnipod 5 (O5) pods. The O5 pairing implementation is actively being developed.

**Build**: `xcodebuild -scheme OmnipodKit -destination 'generic/platform=iOS' build`
This is a framework target, not a standalone app. It's consumed by Loop (the iOS diabetes app).

## Architecture: O5 Pairing Flow

The pairing sequence is orchestrated by `O5LTKExchanger.o5negotiateLTK()`:

```
SP1+SP2  → Pod ID assignment (4+11 bytes)
SPS0     → Algorithm negotiation (5 bytes, CRC-16/XMODEM)
SPS1     → ECDH key exchange (80 bytes: 64-byte EC pubkey + 16-byte nonce)
SPS2.1   → Mutual PKI authentication (~642 encrypted = 634 plaintext + 8 AES-CCM tag)
SPS2     → CMAC confirmation (~960 phone→pod, ~902 pod→phone)
SP0/GP0  → Handshake complete
P0       → Pod ack (0xa5 = success)
```

Messages are wrapped in TWi framing (16-byte header) with `StringLengthPrefixEncoding`:
```
"SPS2.1=" (7 bytes) + length (2 bytes big-endian Int16) + encrypted_payload
```

So `651 bytes TWi payload = 7 + 2 + 642 encrypted`. The 651/650 byte sizes in btsnoop are the TWi payload (after the 16-byte header), not the full message.

## Key Files

### Pairing Implementation
- `OmnipodKit/Bluetooth/Pair/O5LTKExchanger.swift` — Main pairing flow (~700 lines). Contains `o5sps2_1()`, `o5sps2()`, `o5validatePodSps2_1()`, etc.
- `OmnipodKit/Bluetooth/Pair/O5KeyExchange.swift` — ECDH key exchange, KDF, channel-binding transcript (171 bytes), SPS nonce construction (13 bytes), nonce increment
- `OmnipodKit/Bluetooth/Pair/O5CertificateStore.swift` — PKI material management, ECDSA signing (secondary key), signature verification, DER certificate field extraction (public key, serial number, SAN)
- `OmnipodKit/Bluetooth/Pair/O5RegistrationData.swift` — All registration data for a PDM identity (keys, certs, public keys, attestation chain). `O5RegistrationData.active` selects the current registration.
- `OmnipodKit/Bluetooth/Pair/PairMessage.swift` — Wraps payloads into `MessagePacket` with `StringLengthPrefixEncoding`

### BLE Infrastructure
- `OmnipodKit/Bluetooth/BluetoothServices.swift` — BLE service/characteristic UUIDs for DASH and O5. Contains `PeripheralManager.Configuration.omnipod5` with service discovery, notification, and value update macros.
- `OmnipodKit/Bluetooth/PeripheralManager.swift` — BLE peripheral management, `applyConfiguration()` discovers services and subscribes to notifications
- `OmnipodKit/Bluetooth/BluetoothManager.swift` — Central manager, scanning, connection
- `OmnipodKit/Bluetooth/MessagePacket.swift` — TWi message framing (16-byte header: "TW" magic, flags, seq, ack, size, src/dst addresses)
- `OmnipodKit/Bluetooth/StringLengthPrefixEncoding.swift` — Key-value encoding for pairing messages: `[key_string][2-byte big-endian length][payload]`

### Identity
- `OmnipodKit/Bluetooth/Id.swift` — Controller/pod ID management. O5 uses pdmid from certificate (not random).

## SPS2.1 Compact Proof Structure (Phone → Pod)

Target: **634 bytes plaintext** → 642 encrypted (+ 8 AES-CCM tag) → 651 TWi payload

```
Section 1: ECDSA signature (64 bytes, raw r || s)
  - Signs 171-byte channel-binding transcript with secondary key
  - Transcript: [0x01] [FIRMWARE_ID(6)] [0x00000000(4)] [pdmNonce(16)] [pdmPublic(64)] [podNonce(16)] [podPublic(64)]

Section 2: Five uncompressed public keys (5 × 65 = 325 bytes, each with 0x04 prefix)
  Key 1: Secondary/TLS cert key (identity key, used for signing)
  Key 2: INS02PG1 intermediate CA
  Key 3: INS00PG1 root CA
  Key 4: Attestation leaf (cert_0 from secondary attestation chain)
  Key 5: TEE intermediate (cert_1 from secondary attestation chain)

Section 3: Certificate metadata (~245 bytes, exact layout still being determined)
  - TLS cert serial number (20 bytes)
  - TLS cert SHA-256 fingerprint[:20] (20 bytes)
  - TLS cert SAN DER value (~98 bytes, contains pdmid/devicetype/commands URIs)
  - INS02PG1 serial number (20 bytes)
  - INS02PG1 fingerprint[:20] (20 bytes)
  - INS00PG1 serial number (20 bytes)
  - INS00PG1 fingerprint[:20] (20 bytes)
  Current total: 64 + 325 + 218 = 607 bytes (27 bytes short of 634 target)
  The missing ~27 bytes may be: length prefixes, version bytes, padding, or additional fields
```

**Important**: The registration payload (from `register/complete`) does NOT go in SPS2.1. It's written to the pod during `setPodUid` activation.

## Active Registration: TEE Simulator pdmid 2584724

Source: `Omnipod5APK/KEYS/com.twi.enclave.device.secondary/` (TEE simulator, uid=10262)

| Field | Value |
|-------|-------|
| pdmid | 2584724 |
| pdmidExtension | 4300804 |
| Controller ID | `00277094` (big-endian) |
| Secondary key scalar | `f5b539ec...461d05` (32 bytes) |
| Secondary public key | `e3c48e61...eebaa3bf` (64 bytes, x\|\|y) |
| TLS cert serial | `7735BCC5BF295BAA151A6914890A5106C69FB47F` (20 bytes) |
| TLS cert fingerprint[:20] | `0b681f0462ab592bb8f109ac5cf20c579d179ed7` |
| SAN DER | 98 bytes (contains pdmid:2584724, devicetype:controllerAndroid, commands) |
| INS02PG1 serial | `315D61E9A5A9D2E14A1EE439BE1775CE4E7C1D69` |
| INS00PG1 serial | `0AFD56BE5A92140563173BFACC3BF240DE2899FE` |

The **primary key** (software, extractable) was captured from a Frida hook session. Its self-signed certificate is sent to the pod during SPS2.1 (role TBD — may also be used in SPS2).

The **registration payload** is nil — we never captured the `register/complete` response for pdmid 2584724. This payload is needed for `setPodUid`, NOT for SPS2.1.

## Cryptographic Details

- **ECDH**: P-256, ephemeral keys per pairing session
- **KDF**: `SHA-256(len||FIRMWARE_ID || len||controllerID || len||pdmPub || len||podPub || len||sharedSecret)` → first 16 bytes = conf key, last 16 bytes = LTK
- **FIRMWARE_ID**: `9b0ab96a76f4` (fixed 6-byte constant)
- **AES-CCM**: 13-byte nonce (direction byte + 6 bytes from each nonce), 8-byte tag, conf key
- **ECDSA**: SHA-256, secondary key signs channel-binding transcript (SPS2.1) and pod commands
- **CMAC**: AES-CMAC with conf key for SPS2 confirmation
- **Nonce increment**: First 8 bytes as little-endian UInt64 counter, preserving full 16-byte nonce length

## Known Issues / Recent Fixes

### Fixed
- **CryptoSwift Data.append overload**: Was corrupting channel-binding transcript (178 → 171 bytes). Fixed by using explicit `Data([0x01])` instead of `UInt8(0x01)`.
- **incrementNonce truncation**: Was truncating 16-byte nonces to 8 bytes. Fixed with `incrementNonceInPlace()` that modifies in place.
- **Wrong attestation chain**: cert_0-cert_3 were from pdmid 2538336 Pixel TEE (wrong public key `7d76fc46...`). Replaced with correct TEE simulator certs from KEYS/ that match our secondary key `e3c48e61...`.
- **Registration payload mismatch**: Old payload contained controller_id `0x0026bb60` (2538336). Set to nil.
- **Heartbeat service error**: `applyConfiguration()` threw `unknownCharacteristic` when heartbeat service wasn't exposed by unpaired pods. Fixed by changing the notifying characteristics loop to `continue` instead of `throw` for missing services.

### Current Issue: SPS2.1 Size Mismatch
Our compact proof produces ~607 bytes plaintext vs the 634-byte target from btsnoop. The missing ~27 bytes need to be identified. This may require:
- Decoding actual btsnoop SPS2.1 payloads byte-by-byte
- Frida instrumentation of TwiSecPair SDK calls
- Iterative testing against real pods

### Not Yet Implemented
- **SPS2 exact structure**: The ~952-byte plaintext structure is speculative. Needs native library (`libb7fe0d.so`) analysis or Frida captures.
- **Post-pairing command signing**: `EncryptedSignedMessage` (type 4) needs ECDSA with secondary key
- **Registration payload capture**: Need to re-run TEE simulator registration and capture the `register/complete` response for pdmid 2584724
- **Heartbeat keep-alive**: UUID defined, notification subscription works, but actual keep-alive logic not implemented

## External Reference Files

All in `/Users/james/repos/Omnipod5APK/`:
- `KEYS/com.twi.enclave.device.secondary/` — priv.pk8, pub.der, cert_0-3.der, meta.properties
- `BTSNOOP/BTSNOOP_ANALYSIS.md` — Protocol analysis from real btsnoop captures
- `SPS21_KEYS_PRIMARY.md` — Key extraction methodology, signature verification, registration payload structure
- `PAIRING_FLOW.md` — Full pairing flow documentation with pseudocode
- `TWISEC_REGISTRATION.md` — TwiSec registration API flow (register/start → register/complete → download)
- `POD_PKI.md` — PKI infrastructure analysis

Certificate PEM files (same content in both locations):
- `/Users/james/Downloads/Archive/` — rootCA.pem, intermediateCA.pem, podIntermediateCA.pem, tlsCertificate.pem
- `/Users/james/repos/Omnipod5APK/KEYS/` — same files

## Protocol Constants (confirmed across all btsnoop captures)

| Constant | Value | Notes |
|----------|-------|-------|
| SPS0 phone→pod | `000109a218` | Fixed |
| SPS0 pod→phone | `0000099129` | Fixed |
| AMF (Milenage) | `0xb9b9` (47545) | Fixed |
| SP2 protocol ID | `00030e01` | Fixed |
| P0 success | `0xa5` | Fixed |
| SPS2.1 phone→pod | 651 bytes | TWi payload (642 encrypted) |
| SPS2.1 pod→phone | 650 bytes | TWi payload |
| SPS2 phone→pod | ~960 bytes | TWi payload |
| SPS2 pod→phone | ~902 bytes | TWi payload |

## BLE Service UUIDs

| Service | UUID | Notes |
|---------|------|-------|
| O5 Advertisement | `CE1F923D-C539-48EA-7300-0AFFFFFFFE00` | Includes podId |
| O5 Main Service | `1A7E4024-E3ED-4464-8B7E-751E03D0DC5F` | Same as DASH |
| O5 Command Char | `1A7E2441-E3ED-4464-8B7E-751E03D0DC5F` | Same as DASH |
| O5 Data Char | `1A7E2443-E3ED-4464-8B7E-751E03D0DC5F` | DASH uses 2442 |
| Heartbeat Service | `7DED7A6C-CA72-46A7-A3A2-6061F6FDCAEB` | O5 only, not on unpaired pods |
| Heartbeat Char | `7DED7A6D-CA72-46A7-A3A2-6061F6FDCAEB` | O5 keep-alive |
