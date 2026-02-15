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
SPS2.1   → PKI authentication: INS02PG1 cert only (642 encrypted = 634 cert + 8 tag)
SPS2     → Certificate + signature exchange: TLS cert + ECDSA sig (variable size)
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

## SPS2.1 / SPS2 Payload Structure (confirmed by btsnoop of successful pairing)

The native `libb7fe0d.so` was reverse engineered (see `Omnipod5APK/NATIVE_LIBRARY_DECOMPILE.md`).
SPS2.1 and SPS2 are raw DER certificates, with SPS2 also carrying the ECDSA channel-binding signature.

**Verified from btsnoop capture of successful pairing (pdmid 2587928, 2026-02-15):**

### SPS2.1 (sent first) — Short path: cert only
```
plaintext = INS02PG1_cert_DER (634 bytes)
encrypted = AES_CCM_ENC(plaintext, key=conf, nonce=13B) || tag(8)
Total: 634 + 8 = 642
```
INS02PG1 DER is always 634 bytes (serial `315D61E9...`, same across registrations).

### SPS2 (sent second) — Extended path: cert + ECDSA signature
```
plaintext = TLS_cert_DER (variable, depends on SAN content) || ECDSA_signature (64 bytes raw r||s)
encrypted = AES_CCM_ENC(plaintext, key=conf, nonce=13B) || tag(8)
Total: TLS_cert_size + 64 + 8
```
For pdmid 2587928: TLS cert = 1017 bytes DER → 1017 + 64 + 8 = **1089** encrypted.
For pdmid 2584724 (old): TLS cert was smaller → ~951 + 8 = ~959 encrypted (old analysis incorrectly placed signature in SPS2.1).

### Size correction from btsnoop analysis
The original native RE analysis had the signature placement **reversed**. The btsnoop capture proves:
- **SPS2.1** = cert-only (no signature): INS02PG1 DER (634) + tag (8) = 642 ✓
- **SPS2** = cert + signature: TLS DER (1017) + ECDSA sig (64) + tag (8) = 1089 ✓

The native `getMyConfValSize` formulas still apply but the index→message mapping was misidentified:
- Short path (cert + 8): applies to **SPS2.1** (INS02PG1 intermediate cert)
- Extended path (cert + 72): applies to **SPS2** (TLS leaf cert + channel-binding signature)

### Channel-binding transcript (171 bytes, signed by secondary key)
From native `sub_36690` (fully resolved, controller `ctx[4]==0` path):
```
[0x01] [FIRMWARE_ID(6)] [controller_id(4)] [pdmPub(64)] [podPub(64)] [pdmNonce(16)] [podNonce(16)]
```
- Bytes 7-10 are `controller_id` (e.g. `00277d18`), NOT zeros.
- Keys grouped together, then nonces grouped together (NOT interleaved per side).
- Pod verification uses swapped variant: `[0x02] [controller_id(4)] [FIRMWARE_ID(6)] [podPub] [pdmPub] [podNonce] [pdmNonce]`.
- The 64-byte ECDSA signature of this transcript is appended to the TLS cert in **SPS2** (not SPS2.1).

### Native signature constraint
- `"wrong u16_signature_sz size! Need to be 64 bytes!"` — signature is exactly 64 bytes, no recovery byte.

**Important**: The registration payload (from `register/complete`) does NOT go in SPS2.1/SPS2. It's written to the pod during `setPodUid` activation.

## Active Registration: TEE Simulator pdmid 2587928 (SUCCESSFUL PAIRING)

Source: `/Users/james/Downloads/O5keys/KEYS/virtual_keys_v1/10260/` (TEE simulator, uid=10260)
Btsnoop capture: `/Users/james/Downloads/O5keys/KEYS/btsnoop_hci_20260215-2pm.log`
HAR capture: `/Users/james/Downloads/O5keys/KEYS/HTTPToolkit_2026-02-15_14-39.har`

| Field | Value |
|-------|-------|
| pdmid | 2587928 |
| pdmidExtension | 4300804 |
| Controller ID | `00277d18` (big-endian) |
| Pod ID (assigned) | `00277d19` (2587929) |
| Secondary key scalar | `0bf11c04dab072a65f8faca060288188cb006845490bc618440d2af918099e24` (32 bytes) |
| Secondary public key | `5b04057ec3625db9a54ff3eba0518950f912d11af7cce09bf7149d3ef38acda4416cc723f3dd127e5a65b89356c5b4506303c287017fe8ed4dc8d347ef0f19c0` (64 bytes, x\|\|y) |
| Primary key scalar | `4d0e2b45250130b4ee4c449454bd29a91fec6bde5ad69a502e15b7218e6f440e` (32 bytes) |
| Primary public key | `33444df9308ff4a65d7752f25c86a4b2292ef8eb285a902ac63aad6b9e19d0ca0b093248d9ed8a160fb04f417a8a95f51b7642232759fb071632088166105814` (64 bytes, x\|\|y) |
| TLS cert serial | `7050660DE96C4A5CBA4A92A3E91398ABD55A2D96` (20 bytes) |
| TLS cert DER size | 1017 bytes |
| TLS cert issued | 2026-02-15 by INS02PG1 |
| TLS cert SAN | pdmid:2587928, primary key (base64 SPKI), commands:AAYTBhYGFwYcBh8=, devicetype:controllerAndroid |
| INS02PG1 serial | `315D61E9A5A9D2E14A1EE439BE1775CE4E7C1D69` |
| INS02PG1 DER size | 634 bytes |
| INS00PG1 serial | `0AFD56BE5A92140563173BFACC3BF240DE2899FE` |

The **primary key** is available in `com.twi.enclave.device.primary/priv.pk8`. Its public key is embedded in the TLS cert SAN as a base64-encoded SubjectPublicKeyInfo.

The **secondary key** matches the TLS certificate's public key. It signs the channel-binding transcript (appended to TLS cert in SPS2) and post-pairing pod commands.

The **registration payload** (163 bytes from `register/complete`) structure:
```
[0-3]   0000009f    Length prefix (159 = total - 4)
[4-7]   00000100    Version
[8-13]  139696000141  Flags/type
[14-17] 00277d18    Controller ID ✓
[18-81] 5b04057e... Secondary public key (64 bytes, no 0x04 prefix) ✓
[82-88] 6b73531e010000  Timestamp/flags
[89-97] 061306160617061c061f  Commands (matches SAN)
[98-162] 1ec56a79...0a0e  Signature (65 bytes)
```
This payload is written to the pod during `setPodUid`, NOT included in SPS2.1/SPS2.

### Previous Registration: pdmid 2584724 (FAILED — all tests disconnected at SPS2.1)

Source: `Omnipod5APK/KEYS/com.twi.enclave.device.secondary/` (TEE simulator, uid=10262)

| Field | Value |
|-------|-------|
| pdmid | 2584724 |
| Controller ID | `00277094` (big-endian) |
| Secondary public key | `e3c48e61...eebaa3bf` (64 bytes) |
| TLS cert serial | `7735BCC5BF295BAA151A6914890A5106C69FB47F` |

## Cryptographic Details

- **ECDH**: P-256, ephemeral keys per pairing session
- **KDF**: `SHA-256(len||FIRMWARE_ID || len||controllerID || len||pdmPub || len||podPub || len||sharedSecret)` → first 16 bytes = conf key, last 16 bytes = LTK
- **FIRMWARE_ID**: `9b0ab96a76f4` (fixed 6-byte constant)
- **AES-CCM**: 13-byte nonce (direction byte + 6 bytes from each nonce), 8-byte tag, conf key
- **ECDSA**: SHA-256, secondary key signs channel-binding transcript (appended to TLS cert in SPS2) and pod commands
- **Nonce increment**: First 8 bytes as little-endian UInt64 counter, preserving full 16-byte nonce length

## Known Issues / Recent Fixes

### Fixed
- **HELLO controller ID mismatch (test #11)**: `OmniPumpManagerState` deserialized a stale `controllerId` from persistence, so `sendHello()` told the pod "I am `0x277094`" but pairing messages used `0x277D18`. Pod used HELLO ID in its KDF → different conf key → SPS2.1 decrypt failed → disconnect. Fix: `OmniPumpManagerState.init` now always derives O5 controller ID from `O5CertificateStore.pdmid` instead of using persisted value. Removed downstream correction band-aids from `BlePodComms.pairPod()`.
- **CryptoSwift Data.append overload**: Was corrupting channel-binding transcript (178 → 171 bytes). Fixed by using explicit `Data([0x01])` instead of `UInt8(0x01)`.
- **incrementNonce truncation**: Was truncating 16-byte nonces to 8 bytes. Fixed with `incrementNonceInPlace()` that modifies in place.
- **Wrong attestation chain**: cert_0-cert_3 were from pdmid 2538336 Pixel TEE (wrong public key `7d76fc46...`). Replaced with correct TEE simulator certs from KEYS/ that match our secondary key `e3c48e61...`.
- **Registration payload mismatch**: Old payload contained controller_id `0x0026bb60` (2538336). Set to nil.
- **Heartbeat service error**: `applyConfiguration()` threw `unknownCharacteristic` when heartbeat service wasn't exposed by unpaired pods. Fixed by changing the notifying characteristics loop to `continue` instead of `throw` for missing services.

### Resolved: SPS2.1/SPS2 Structure — SUCCESSFUL PAIRING ACHIEVED
Native library decompile revealed the payloads are raw DER certificates. Btsnoop capture of a successful
pairing (pdmid 2587928, 2026-02-15) confirmed the exact structure and **corrected the signature placement**:
- **SPS2.1** = INS02PG1 cert DER (634B) + AES-CCM tag (8B) = 642 — **no signature** (short path)
- **SPS2** = TLS cert DER (variable) + ECDSA signature (64B) + AES-CCM tag (8B) — **has signature** (extended path)

The previous pdmid 2584724 registration failed because the TEE simulator certs/keys were from a different
provisioning session. The new pdmid 2587928 registration used freshly provisioned keys with valid TEE
attestation, which the pod accepted.

### SPS2.1 Pairing Troubleshooting Log

| # | Change | Result | Notes |
|---|--------|--------|-------|
| 1 | Nonces-first transcript: `[pdmNonce][pdmPublic][podNonce][podPublic]` | Pod disconnect after SPS2.1 | pdmid 2584724. Original order, tested twice |
| 2 | Keys-first transcript: `[pdmPublic][pdmNonce][podPublic][podNonce]` | Pod disconnect after SPS2.1 | pdmid 2584724. Same pod as #1, corrupted by bad MTU attempt |
| 3 | Adjusted `BlePacket_MAX_PAYLOAD_SIZE` to match MTU (244→20) | Pod FAIL on SP1+SP2 | pdmid 2584724. **WRONG** — 244 is an app-level protocol constant. Reverted. |
| 4 | Keys-first transcript, correct packet framing (244) | Pod disconnect after SPS2.1 | pdmid 2584724. Same pod, recovered from #3. SP1/SPS0/SPS1 all OK. |
| 5 | Fixed transcript: `controller_id` in bytes 7-10 (was zeros) + keys grouped then nonces grouped | Pod disconnect after SPS2.1 | pdmid 2584724. Native RE confirmed exact layout. Transcript now matches native exactly. |
| 6-9 | Systematic test of all 4 {keysNonceFirst, bytesAsControllerId} combinations | Pod disconnect after SPS2.1 | pdmid 2584724. All 4 failed identically — transcript layout NOT the issue. |
| 10 | **New registration (pdmid 2587928) with fresh TEE keys** | **P0 = 0xa5 SUCCESS** | Root cause was invalid/stale TEE keys from pdmid 2584724. |
| 11 | pdmid 2587928, new pod, no code changes since #10 | Pod disconnect after SPS2.1 | HELLO sent with stale controller ID `0x277094` (pdmid 2584724) from persisted state, but pairing messages used corrected `0x277D18` (pdmid 2587928). Pod KDF used HELLO ID → different conf key → SPS2.1 decrypt failed. |
| 12 | **Fixed: derive O5 controller ID from certificate in `OmniPumpManagerState` init** | **Pending test** | `OmniPumpManagerState.init` now always uses `O5CertificateStore.pdmid` for O5 instead of persisted `controllerId`. Removed downstream "correction" band-aids from `BlePodComms.pairPod()`. HELLO and all pairing messages now use the same controller ID. |

**Root cause (tests 1-9)**: The pdmid 2584724 TEE simulator keys were from a different provisioning session
(uid=10262) and did not have valid attestation for the certificates being sent. The pod validates the TEE
attestation chain during SPS2.1/SPS2 and rejects mismatched keys. Using freshly provisioned keys
(pdmid 2587928, uid=10260) with a matching `register/complete` flow resolved the issue.

**Root cause (test 11)**: `OmniPumpManagerState` deserialized `controllerId = 2584724` from persisted state
(left over from the old registration). `sendHello()` used this stale ID, but `pairPod()` corrected
`self.myId` to the certificate pdmid `2587928` *after* HELLO was already sent. The pod used the HELLO
controller ID (`0x277094`) in its KDF, derived a different `conf` key, and couldn't decrypt SPS2.1.
Fix: O5 controller ID is now always derived from the TLS certificate at init time — never from persistence.

**Confirmed correct by native RE and btsnoop (no changes needed):**
- KDF: plain SHA-256 with 8-byte BE length prefixes ✓
- KDF input order: FIRMWARE_ID, controller_id, pdmPub, podPub, sharedSecret ✓
- KDF output split: conf=digest[0:16], LTK=digest[16:32] ✓
- Signing key: secondary (`com.twi.enclave.device.secondary`) ✓
- Signature: SHA256withECDSA → raw r||s (64 bytes), no double-hash ✓
- Signature placement: appended to TLS cert in SPS2 (not SPS2.1) ✓
- AES-CCM: nonce(13), tag(8), dir byte 0x01/0x02 ✓
- FIRMWARE_ID: `9b0ab96a76f4` hardcoded ✓

**Key learning (test #3):**
`BlePacket_MAX_PAYLOAD_SIZE=244` for O5 is an application-level protocol constant that defines logical packet
framing, NOT the physical BLE MTU. CoreBluetooth handles L2CAP fragmentation of writes > MTU transparently.
Changing it to 20 switches to DASH-style framing which the O5 pod rejects with FAIL (0x05).
Android explicitly calls `requestMtu(251)`, pod responds with 247. iOS auto-negotiates but stays at 23.
This is fine — CoreBluetooth fragments internally.

### Not Yet Implemented
- **Post-pairing command signing**: `EncryptedSignedMessage` (type 4) needs ECDSA with secondary key
- **Registration payload delivery**: Available (163 bytes). Needed for `setPodUid` post-pairing
- **Heartbeat keep-alive**: UUID defined, notification subscription works, but actual keep-alive logic not implemented

## External Reference Files

### Successful pairing capture (pdmid 2587928)
All in `/Users/james/Downloads/O5keys/KEYS/`:
- `btsnoop_hci_20260215-2pm.log` — Complete btsnoop HCI log of successful O5 pairing
- `HTTPToolkit_2026-02-15_14-39.har` — HTTP capture of full registration API flow
- `certificates/` — fullchain.pem (rootCA + INS02PG1 + TLS leaf), private.pem (secondary key), pod_fullchain.pem
- `virtual_keys_v1/10260/com.twi.enclave.device.secondary/` — priv.pk8, pub.der, cert_0-3.der (TEE attestation chain)
- `virtual_keys_v1/10260/com.twi.enclave.device.primary/` — priv.pk8, pub.der, cert_0-3.der
- `keybox.xml` — Android Keybox for virtual TEE

### Previous analysis (pdmid 2584724)
All in `/Users/james/repos/Omnipod5APK/`:
- `KEYS/com.twi.enclave.device.secondary/` — priv.pk8, pub.der, cert_0-3.der, meta.properties
- `BTSNOOP/BTSNOOP_ANALYSIS.md` — Protocol analysis from real btsnoop captures
- `SPS21_KEYS_PRIMARY.md` — Key extraction methodology, signature verification, registration payload structure
- `PAIRING_FLOW.md` — Full pairing flow documentation with pseudocode
- `TWISEC_REGISTRATION.md` — TwiSec registration API flow (register/start → register/complete → download)
- `POD_PKI.md` — PKI infrastructure analysis
- `NATIVE_LIBRARY_DECOMPILE.md` — Native library reverse engineering

### Insulet PKI certificates
- `/Users/james/Downloads/O5keys/KEYS/certificates/fullchain.pem` — Latest (pdmid 2587928)
- `/Users/james/repos/Omnipod5APK/KEYS/` — Previous copies

## Protocol Constants (confirmed across all btsnoop captures)

| Constant | Value | Notes |
|----------|-------|-------|
| SPS0 phone→pod | `000109a218` | Fixed |
| SPS0 pod→phone | `0000099129` | Fixed |
| AMF (Milenage) | `0xb9b9` (47545) | Fixed |
| SP2 protocol ID | `00030e01` | Fixed |
| P0 success | `0xa5` | Fixed |
| SPS2.1 phone→pod | 642 bytes encrypted | INS02PG1 DER (634) + tag (8). Always 642 (INS02PG1 is fixed). |
| SPS2.1 pod→phone | 641 bytes encrypted | Pod intermediate cert (633) + tag (8) |
| SPS2 phone→pod | variable | TLS cert DER + ECDSA sig (64) + tag (8). pdmid 2587928: 1089 bytes. |
| SPS2 pod→phone | variable | Pod TLS cert + sig + tag. pdmid 2587928: 895 bytes. |

### Successful pairing sizes (pdmid 2587928, btsnoop 2026-02-15)

| Message | Direction | Encrypted | Plaintext | Structure |
|---------|-----------|-----------|-----------|-----------|
| SPS2.1 | phone→pod | 642 | 634 | INS02PG1 DER (634) |
| SPS2.1 | pod→phone | 641 | 633 | Pod cert (633) |
| SPS2 | phone→pod | 1089 | 1081 | TLS DER (1017) + ECDSA sig (64) |
| SPS2 | pod→phone | 895 | 887 | Pod TLS cert + sig |

## BLE Service UUIDs

| Service | UUID | Notes |
|---------|------|-------|
| O5 Advertisement | `CE1F923D-C539-48EA-7300-0AFFFFFFFE00` | Includes podId |
| O5 Main Service | `1A7E4024-E3ED-4464-8B7E-751E03D0DC5F` | Same as DASH |
| O5 Command Char | `1A7E2441-E3ED-4464-8B7E-751E03D0DC5F` | Same as DASH |
| O5 Data Char | `1A7E2443-E3ED-4464-8B7E-751E03D0DC5F` | DASH uses 2442 |
| Heartbeat Service | `7DED7A6C-CA72-46A7-A3A2-6061F6FDCAEB` | O5 only, not on unpaired pods |
| Heartbeat Char | `7DED7A6D-CA72-46A7-A3A2-6061F6FDCAEB` | O5 keep-alive |
