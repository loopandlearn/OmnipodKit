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

## SPS2.1 / SPS2 Payload Structure (from native library decompile)

The native `libb7fe0d.so` was reverse engineered (see `Omnipod5APK/NATIVE_LIBRARY_DECOMPILE.md`).
SPS2.1 and SPS2 are **not** custom "compact proofs" — they are raw DER certificates, optionally with a signature appended.

The app loads certificates `[TLS_cert, INS02PG1]` (root excluded via `size - 1`), then iterates **backwards**:

### SPS2.1 (Index 1, sent first) — `sub_36de4` extended path
```
plaintext = INS02PG1_cert_DER (570 bytes) || ECDSA_signature (64 bytes raw r||s)
encrypted = AES_CCM_ENC(plaintext, key=conf, nonce=13B) || tag(8)
Total: cert_size[1] + 72 = 570 + 72 = 642
```

### SPS2 (Index 0, sent second) — `sub_370e8` short path
```
plaintext = TLS_cert_DER (~951 bytes)
encrypted = AES_CCM_ENC(plaintext, key=conf, nonce=13B) || tag(8)
Total: cert_size[0] + 8 = 951 + 8 = 959
```

### Channel-binding transcript (171 bytes, signed by secondary key for aux64)
From native `sub_36690` — exact field order uncertain, currently testing keys-first:
```
[0x01] [FIRMWARE_ID(6)] [FLAGS(4)] [pdmPublic(64)] [pdmNonce(16)] [podPublic(64)] [podNonce(16)]
```
Note: keys-first groups each side as `[pubkey(64)][nonce(16)]`, matching SPS1 wire format.

### Size equations (from `getMyConfValSize`)
- `index == 0`: `size = cert_size[0] + 8` (short path, cert only)
- `index != 0`: `size = cert_size[index] + 72` (extended path, cert + 0x40 aux + 0x08 tag)

### Native signature constraint
- `"wrong u16_signature_sz size! Need to be 64 bytes!"` — signature is exactly 64 bytes, no recovery byte.

**Important**: The registration payload (from `register/complete`) does NOT go in SPS2.1/SPS2. It's written to the pod during `setPodUid` activation.

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

The **registration payload** (163 bytes from `register/complete`) is now available. Verified: controller_id=`00277094` (2584724), secondary key=`e3c48e61...`. This payload is written to the pod during `setPodUid`, NOT included in SPS2.1.

## Cryptographic Details

- **ECDH**: P-256, ephemeral keys per pairing session
- **KDF**: `SHA-256(len||FIRMWARE_ID || len||controllerID || len||pdmPub || len||podPub || len||sharedSecret)` → first 16 bytes = conf key, last 16 bytes = LTK
- **FIRMWARE_ID**: `9b0ab96a76f4` (fixed 6-byte constant)
- **AES-CCM**: 13-byte nonce (direction byte + 6 bytes from each nonce), 8-byte tag, conf key
- **ECDSA**: SHA-256, secondary key signs channel-binding transcript (SPS2.1 aux64) and pod commands
- **Nonce increment**: First 8 bytes as little-endian UInt64 counter, preserving full 16-byte nonce length

## Known Issues / Recent Fixes

### Fixed
- **CryptoSwift Data.append overload**: Was corrupting channel-binding transcript (178 → 171 bytes). Fixed by using explicit `Data([0x01])` instead of `UInt8(0x01)`.
- **incrementNonce truncation**: Was truncating 16-byte nonces to 8 bytes. Fixed with `incrementNonceInPlace()` that modifies in place.
- **Wrong attestation chain**: cert_0-cert_3 were from pdmid 2538336 Pixel TEE (wrong public key `7d76fc46...`). Replaced with correct TEE simulator certs from KEYS/ that match our secondary key `e3c48e61...`.
- **Registration payload mismatch**: Old payload contained controller_id `0x0026bb60` (2538336). Set to nil.
- **Heartbeat service error**: `applyConfiguration()` threw `unknownCharacteristic` when heartbeat service wasn't exposed by unpaired pods. Fixed by changing the notifying characteristics loop to `continue` instead of `throw` for missing services.

### Resolved: SPS2.1/SPS2 Structure
Native library decompile revealed the payload is simply `cert_DER || signature(64)` for SPS2.1
and `cert_DER` for SPS2. The old "compact proof" approach (extracted keys, serials, fingerprints, SAN)
was completely wrong. Rewritten to match native structure. Size now matches btsnoop exactly.

### SPS2.1 Pairing Troubleshooting Log

Pod disconnects immediately after receiving SPS2.1. The send succeeds (acknowledged) but the pod rejects the payload and drops the BLE connection.

| # | Change | Result | Notes |
|---|--------|--------|-------|
| 1 | Nonces-first transcript: `[pdmNonce][pdmPublic][podNonce][podPublic]` | Pod disconnect after SPS2.1 | Original order, tested twice |
| 2 | Keys-first transcript: `[pdmPublic][pdmNonce][podPublic][podNonce]` | Pod disconnect after SPS2.1 | Same pod as #1, corrupted by bad MTU attempt |
| 3 | Adjusted `BlePacket_MAX_PAYLOAD_SIZE` to match MTU (244→20) | Pod FAIL on SP1+SP2 | **WRONG** — 244 is an app-level protocol constant. Reverted. |
| 4 | Keys-first transcript, correct packet framing (244) | Pod disconnect after SPS2.1 | Same pod, recovered from #3. SP1/SPS0/SPS1 all OK. Confirms keys-first also fails. |

Both transcript orders tested with correct framing → both fail. The issue is NOT transcript order.

**Key learning (test #3):**
`BlePacket_MAX_PAYLOAD_SIZE=244` for O5 is an application-level protocol constant that defines logical packet
framing, NOT the physical BLE MTU. CoreBluetooth handles L2CAP fragmentation of writes > MTU transparently.
Changing it to 20 switches to DASH-style framing which the O5 pod rejects with FAIL (0x05).
Android explicitly calls `requestMtu(251)`, pod responds with 247. iOS auto-negotiates but stays at 23.
This is fine — CoreBluetooth fragments internally.

**Possible remaining causes (tests 1-2 are valid — disconnect after SPS2.1):**
- **KDF is wrong** → wrong conf key → pod can't decrypt SPS2.1 at all
- **Transcript field order** — still uncertain (keys-first vs nonces-first)
- **Flags field** should be controllerID (`00277094`) instead of zeros
- **Double-hashing** — CryptoKit `signature(for:)` hashes internally; if native lib also hashes, signature would differ
- **Primary key** should be used instead of secondary key for SPS2.1 signing

### Not Yet Implemented
- **Post-pairing command signing**: `EncryptedSignedMessage` (type 4) needs ECDSA with secondary key
- **Registration payload delivery**: Available (163 bytes). Needed for `setPodUid` post-pairing
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
