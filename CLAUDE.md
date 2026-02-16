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
- Bytes 7-10 are ZEROS (`00000000`), NOT the real controllerID. Confirmed by Config#10 (2026-02-16).
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
- **KDF**: `SHA-256(len||FIRMWARE_ID || len||ZEROS(4) || len||pdmPub || len||podPub || len||sharedSecret)` → first 16 bytes = conf key, last 16 bytes = LTK. Pod uses ZEROS for controllerID in KDF input (confirmed Config#10, 2026-02-16).
- **FIRMWARE_ID**: `9b0ab96a76f4` (fixed 6-byte constant)
- **AES-CCM**: 13-byte nonce (direction byte + 6 bytes from each nonce), 8-byte tag, conf key
- **ECDSA**: SHA-256, secondary key signs channel-binding transcript (appended to TLS cert in SPS2) and pod commands
- **Nonce increment**: First 8 bytes as little-endian UInt64 counter, preserving full 16-byte nonce length

## Known Issues / Recent Fixes

### Fixed
- **O5 command char write type (test #12→#13)**: `sendHello()` and `sendCommandType()` used `.withResponse` (ATT Write Request) on the command characteristic, inherited from DASH. Btsnoop shows Android uses `.withoutResponse` (ATT Write Command). Fixed both to use `.withoutResponse` for O5, matching `sendData()` which already had the O5/DASH switch.
- **HELLO controller ID mismatch (test #11)**: `OmniPumpManagerState` deserialized a stale `controllerId` from persistence, so `sendHello()` told the pod "I am `0x277094`" but pairing messages used `0x277D18`. Pod used HELLO ID in its KDF → different conf key → SPS2.1 decrypt failed → disconnect. Fix: `OmniPumpManagerState.init` now always derives O5 controller ID from `O5CertificateStore.pdmid` instead of using persisted value. Removed downstream correction band-aids from `BlePodComms.pairPod()`.
- **CryptoSwift Data.append overload**: Was corrupting channel-binding transcript (178 → 171 bytes). Fixed by using explicit `Data([0x01])` instead of `UInt8(0x01)`.
- **incrementNonce truncation**: Was truncating 16-byte nonces to 8 bytes. Fixed with `incrementNonceInPlace()` that modifies in place.
- **Wrong attestation chain**: cert_0-cert_3 were from pdmid 2538336 Pixel TEE (wrong public key `7d76fc46...`). Replaced with correct TEE simulator certs from KEYS/ that match our secondary key `e3c48e61...`.
- **Registration payload mismatch**: Old payload contained controller_id `0x0026bb60` (2538336). Set to nil.
- **Heartbeat service error**: `applyConfiguration()` threw `unknownCharacteristic` when heartbeat service wasn't exposed by unpaired pods. Fixed by changing the notifying characteristics loop to `continue` instead of `throw` for missing services.
- **O5 EAP-AKA session establishment (2026-02-16)**: `SessionEstablisher` and `BleMessageTransport` now use `doRTS=false` for O5 pods. O5 pods never use RTS/CTS flow control; sending RTS (0x00) caused immediate disconnect (CBError code=7). Files: `SessionEstablisher.swift`, `BleMessageTransport.swift`, `BlePodComms.swift`.
- **O5 KDF controllerID (Config#10, 2026-02-16)**: Pod uses ZEROS (`00000000`) for controllerID in both the KDF input and the channel-binding transcript (bytes 7-10), not the real controllerID. Config#10 (bitmask `00001010`: `kdfZeroControllerID=true`, `bytesAsControllerId=false`) produced P0=0xa5 on a fresh pod (UUID `74CF60D7-6A27-EED6-9C1D-BDA1ACA5546F`). Defaults locked in `O5KeyExchange.swift`; bitmask cycling disabled in `O5PairingConfiguration.swift`.

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
| 12 | Fixed: derive O5 controller ID from certificate in `OmniPumpManagerState` init | Pod disconnect after SPS2.1 | HELLO ID now correct (`0x277D18`). Same pod as #11 — manufacturer data changed `0x00→0x80`, pod may be in tainted state from previous failed attempt. All message structure verified byte-for-byte against btsnoop. |
| 13 | **Fixed: O5 command characteristic write type `.withResponse` → `.withoutResponse`** | **Pending test** | Btsnoop shows Android uses ATT Write Command (`.withoutResponse`) for all command char writes. OmnipodKit was using ATT Write Request (`.withResponse`), inherited from DASH. Fixed `sendHello()` and `sendCommandType()` to use `.withoutResponse` for O5. **Both the original btsnoop analysis AND the independent GATT-level comparison confirmed this as the primary remaining discrepancy.** **Test with a fresh pod** (not the tainted one from #11/#12). |
| 14 | **Config#10 (bitmask 00001010): `kdfZeroControllerID=true`, `bytesAsControllerId=false`** | **P0 = 0xa5 SUCCESS** | Fresh pod UUID `74CF60D7-6A27-EED6-9C1D-BDA1ACA5546F`. Key finding: pod uses ZEROS for controllerID in both KDF input and channel-binding transcript bytes 7-10. Signature verification failed locally (cosmetic, doesn't affect pairing). Post-pairing: pod disconnects during EAP-AKA session establishment (CBError code=7) when RTS is sent. **Remaining work**: fix EAP session establishment (try `doRTS=false`, add delay, or handle disconnect/reconnect). |
| 15 | **Fixed: `doRTS=false` for O5 EAP-AKA session and encrypted messages** | **Pending test** | After Config#10 pairing succeeded (P0=0xa5), pod disconnected (CBError code=7) when EAP-AKA session tried to send RTS (0x00). Root cause: `SessionEstablisher` and `BleMessageTransport` defaulted to `doRTS: true` (DASH behavior), but O5 pods NEVER use RTS/CTS. Btsnoop evidence: zero occurrences of RTS (0x00) or CTS (0x01) in entire O5 capture — only CMD writes are HELLO (0x06, once) and SUCCESS (0x04, after each message). Fix: Added `podType` parameter to `SessionEstablisher`, pass `doRTS: false` for O5 in all three EAP message operations. Also updated `BleMessageTransport` to derive `useRTS` from `manager.podType` for encrypted command/response messages. |

**Root cause (tests 1-9)**: The pdmid 2584724 TEE simulator keys were from a different provisioning session
(uid=10262) and did not have valid attestation for the certificates being sent. The pod validates the TEE
attestation chain during SPS2.1/SPS2 and rejects mismatched keys. Using freshly provisioned keys
(pdmid 2587928, uid=10260) with a matching `register/complete` flow resolved the issue.

**Root cause (test 11)**: `OmniPumpManagerState` deserialized `controllerId = 2584724` from persisted state
(left over from the old registration). `sendHello()` used this stale ID, but `pairPod()` corrected
`self.myId` to the certificate pdmid `2587928` *after* HELLO was already sent. The pod used the HELLO
controller ID (`0x277094`) in its KDF, derived a different `conf` key, and couldn't decrypt SPS2.1.
Fix: O5 controller ID is now always derived from the TLS certificate at init time — never from persistence.

**Root cause (test 12)**: HELLO ID fix confirmed working, but same pod was reused from test #11. Pod
manufacturer data byte changed `0x00→0x80` between attempts, indicating internal state change. Full
byte-by-byte comparison of SPS2.1 message structure against btsnoop showed all content matches. Only
remaining discrepancy: command characteristic write type (`.withResponse` vs btsnoop's `.withoutResponse`).
Fix: `sendHello()` and `sendCommandType()` now use `.withoutResponse` for O5, matching the real Android app.

**Confirmed correct by native RE, btsnoop, AND independent GATT-level comparison (no changes needed):**
- KDF: plain SHA-256 with 8-byte BE length prefixes ✓
- KDF input order: FIRMWARE_ID, ZEROS(4), pdmPub, podPub, sharedSecret ✓ (controllerID field is zeros, confirmed Config#10 2026-02-16)
- KDF output split: conf=digest[0:16], LTK=digest[16:32] ✓
- Signing key: secondary (`com.twi.enclave.device.secondary`) ✓
- Signature: SHA256withECDSA → raw r||s (64 bytes), no double-hash ✓
- Signature placement: appended to TLS cert in SPS2 (not SPS2.1) ✓
- AES-CCM: nonce(13), tag(8), dir byte 0x01/0x02 ✓
- FIRMWARE_ID: `9b0ab96a76f4` hardcoded ✓
- Certificates: INS02PG1 (634B) and TLS cert (1017B) verified byte-identical between code and PEM files ✓
- Secondary key scalar verified identical between code and private.pem ✓
- BLE service/characteristic UUIDs: identical between btsnoop and OmnipodKit ✓
- CCCD subscription pattern: indications on 2441, notifications on 2443, matches CoreBluetooth behavior ✓

**Key learning (test #3):**
`BlePacket_MAX_PAYLOAD_SIZE=244` for O5 is an application-level protocol constant that defines logical packet
framing, NOT the physical BLE MTU. CoreBluetooth handles L2CAP fragmentation of writes > MTU transparently.
Changing it to 20 switches to DASH-style framing which the O5 pod rejects with FAIL (0x05).
Android explicitly calls `requestMtu(251)`, pod responds with 247 (btsnoop frames 1758-1759). iOS auto-negotiates
but `maximumWriteValueLength` reports 20 (MTU 23). CoreBluetooth fragments internally for `.withoutResponse` writes.
**Validation needed**: Log `maximumWriteValueLength` at SPS2.1 send time to confirm fragmentation is actually
happening correctly. If iOS negotiates a larger MTU after initial connection, the value at connection time (20)
may differ from the value at SPS2.1 time.

### Btsnoop vs OmnipodKit GATT-Level Comparison (2026-02-15)

Detailed comparison of the successful Android btsnoop capture against the failing OmnipodKit iOS pairing log.
Both used the same pdmid 2587928 registration with identical certificates and keys.

**Protocol match through SPS0:**
- SP1+SP2: Byte-for-byte identical (controller ID `00277d18`, pod ID `00277d19`, protocol `00030e01`)
- SPS0 phone→pod: `000109a218` ✓
- SPS0 pod→phone: `0000099129` ✓
- SPS1: Both exchange 80-byte ECDH public keys (64-byte P-256 point + 16-byte nonce)

**Certificate verification (independent confirmation):**
- INS02PG1 DER (634 bytes): Verified byte-for-byte identical between `O5RegistrationData.swift` and `KEYS/certificates/fullchain.pem` cert[1]
- TLS cert DER (1017 bytes): Verified byte-for-byte identical between `O5RegistrationData.swift` and `KEYS/certificates/fullchain.pem` cert[2]
- Secondary key scalar: `0bf11c04...` matches between `O5RegistrationData.swift` and `KEYS/certificates/private.pem`

**GATT-level differences identified:**

| Aspect | Android (btsnoop) | iOS (OmnipodKit) | Impact |
|--------|-------------------|-------------------|--------|
| MTU | 247 (negotiated at frames 1758-1759) | 23 (maximumWriteValueLength=20) | CoreBluetooth fragments `.withoutResponse` writes internally. Should be transparent. |
| Command char writes | ATT Write Command (`.withoutResponse`) | Was ATT Write Request (`.withResponse`) — **fixed in test #13** | **Primary discrepancy. Both investigations confirm.** |
| Data char writes | ATT Write Command (`.withoutResponse`) | `.withoutResponse` ✓ | Match |
| CCCD subscriptions | Indications on 2441 (0x0002), Notifications on 2443 (0x0001) | `setNotifyValue(true)` for both | Match — CoreBluetooth sends appropriate CCCD value per characteristic properties |
| BLE services | 3: GAP, GATT, Omnipod (1a7e4024) | Same 3 services | Match |
| SPS2.1 phone→pod size | 642 bytes (3 BLE packets at MTU 247) | 642 bytes (fragmented at MTU 23) | Same payload, different fragmentation |

**Failure mode analysis:**
The pod ACKs the SPS2.1 message at the transport level (sends SUCCESS command) but then actively disconnects
instead of responding with its own SPS2.1 certificate. This indicates the pod received and parsed the message
but rejected it at the application layer. Possible causes ranked by likelihood:

1. **Command write type mismatch (HIGH)** — The `.withResponse` vs `.withoutResponse` difference on the command
   characteristic is the only remaining protocol-level discrepancy. The pod may treat ATT Write Requests
   differently from ATT Write Commands, or the ATT response handling may interfere with timing. Fixed in test #13.
2. **Tainted pod state (MEDIUM)** — Test #12 reused the pod from test #11 (which sent wrong controller ID).
   Pod manufacturer data changed `0x00→0x80`, suggesting internal state change. Always use a factory-fresh pod.
3. **MTU/fragmentation edge case (LOW)** — While CoreBluetooth should handle fragmentation transparently, if
   the pod's BLE stack has a bug with reassembling many small fragments (642 bytes / 20 bytes ≈ 33 fragments vs
   3 fragments at MTU 247), it could cause issues. Log `maximumWriteValueLength` at write time to verify.

### Pending Validation Steps

| # | Step | Status | Notes |
|---|------|--------|-------|
| V1 | Test #13 fix (`.withoutResponse` commands) with **factory-fresh pod** | **DONE (test #14)** | Config#10 with `.withoutResponse` commands achieved P0=0xa5 on fresh pod. |
| V2 | Log `maximumWriteValueLength` at SPS2.1 send time | **TODO** | Add log line in `sendData()` or `o5sps2_1()` to confirm actual write length at the moment of SPS2.1 transmission. |
| V3 | Verify MTU negotiation timing | **TODO** | Check if iOS negotiates a larger MTU after initial connection. `maximumWriteValueLength` at connection time (20) may differ from the value when SPS2.1 is actually sent. |
| V4 | Compare OmnipodKit SPS2.1 encrypted payload against btsnoop | **TODO** | After V1 succeeds or fails, capture the actual encrypted bytes OmnipodKit sends and compare structure against `sps21_phone_transport.hex`. The encrypted content will differ (different ECDH ephemeral keys) but the framing/sizes should match exactly. |
| V5 | Fix EAP-AKA session establishment (post-pairing disconnect) | **DONE (test #15)** | Root cause: `SessionEstablisher` and `BleMessageTransport` defaulted to `doRTS: true` (DASH behavior). O5 pods never use RTS/CTS. Fixed: `doRTS=false` for O5 in `SessionEstablisher` and `useRTS` derived from `podType` in `BleMessageTransport`. |

### Not Yet Implemented
- **Post-pairing command signing**: Design now understood (see "Post-Pairing Command Protocol" below). ECDSA signature covers the complete encrypted message (AAD + ciphertext + CCM tag). Signing key is `com.twi.enclave.device.secondary` (P-256). **Implementation needed.**
- **Registration payload delivery**: Available (163 bytes). Needed for `setPodUid` post-pairing
- **Command sequence counter**: Counter tracked in `TwiCaching` value (bytes 40-42), increments per command exchange. Must be persisted across reconnections. **Implementation needed.**
- **Session persistence**: `.twi_session` (4140 bytes, AES/GCM encrypted with `com.twi.enclave.session` key) stores session state. Must save/restore on reconnect. **Implementation needed.**
- ~~**Heartbeat keep-alive**~~: **NOT NEEDED.** Frida session (2026-02-15) confirmed the heartbeat service UUID `7DED7A6C` is NOT discovered on connected pods. Only three BLE services exist: GAP (0x1800), GATT (0x1801), and Omnipod custom (1a7e4024). The app polls via normal encrypted commands every ~20-30 seconds instead.

## Post-Pairing Command Protocol (from Frida 2026-02-15)

Captured from a running, pod-connected Omnipod 5 app (pod serial 2587929, pod ID `00277d19`, BLE address `B4:3D:6B:FF:15:6E`) using comprehensive Frida instrumentation.

### Type 4 Message Signing Flow (EncryptedSignedMessage)

Post-pairing commands use TWi message type 4 (encrypted + signed). The ECDSA signature covers the **complete encrypted message**, NOT the plaintext:

```
signing_input (80 bytes) = AAD (16 bytes) + AES-CCM ciphertext (56 bytes) + CCM tag (8 bytes)
```

Captured examples:
```
Sign #1 (21:57:58.242Z):
  AAD:        545711041e00070000277d1800277d19
  ciphertext: ca320ff201b572925d4941477c992ed4e10c514ab3aeefddbdd89d40aec533461b1142f0b7e327b4914abb006572ed0b3a3b97a58791713
  tag:        3933dc9cf09fde89
  total:      80 bytes signed

Sign #2 (21:58:32.320Z):
  AAD:        545711042100070000277d1800277d19
  ciphertext: 13ece9397e11bec613ccdc78287f9b1a747d0b7a64021daea96f44dc9cadc557d47e87bddbb40ca41f4d4a753a1eb167c7a6d9c10501e8b1
  tag:        64c2e8edcdf4b543
  total:      80 bytes signed
```

Signing key: `com.twi.enclave.device.secondary` (ECDSA P-256, SHA256withECDSA).

### AAD Format (AES-CCM Additional Authenticated Data)

The 16-byte AAD is the TWi packet header:
```
5457 XXYY ZZZZ WWWW SSSSSSSS DDDDDDDD
 TW   ^^   ^^   ^^   src_id   dst_id
      ||   ||   ||
      ||   ||   payload_size (big-endian)
      ||   seq_number + flags
      msg_type (11=type4, 10=type3?)
```

Observed AAD patterns:
- `545711041e00070000277d1800277d19` — type 4 outgoing command (56B payload)
- `545711042100070000277d1800277d19` — type 4 outgoing command (56B payload)
- `54571101210003a000277d1800277d19` — type 1 outgoing (ACK, no payload)
- `545710812014000000277d1800277d19` — type 0/1 outgoing (ACK)
- `545710811f13000000277d1800277d19` — type 0/1 outgoing (ACK)

Source ID = `00277d18` (controller), Destination ID = `00277d19` (pod) for outgoing.

### BLE Communication Pattern (Post-Pairing)

Only two characteristics used on the Omnipod custom service (`1a7e4024`):
- **Data** (`1a7e2443`): NOTIFY + WRITE_NO_RESP — primary data channel
- **Control** (`1a7e2441`): INDICATE + WRITE — acknowledgment/control channel

Full command cycle:
1. **WRITE** on `2443` (data) — send encrypted+signed command
2. **NOTIFY** responses on `2443` — receive encrypted response data
3. **INDICATE** on `2441` (control) — pod signals completion
4. **WRITE** ack on `2441` — controller acknowledges

BLE writes include a **7-byte fragmentation header** before the TWi packet data.

No separate heartbeat mechanism exists. The app polls the pod every ~20-30 seconds via normal encrypted commands on the data characteristic.

### ACK Messages

ACK messages have **empty plaintext**, producing only the 8-byte AES-CCM auth tag:
```
AES-CCM encrypt: key=handle, aad=TWi_header(16B), plaintext=empty → output=8B_tag_only
```
Observed ACK tags: `8883628bb65a1ea0`, `55fe2128ff150a82`, `8520c59b27c24e0e`.

### Session State Management

**TwiCaching value structure** (93 bytes, key=pod_id `00277d19`):
```
[0-15]   f3157d4eeae83bd963fd4faf7bbb442e   — session CK or LTK derivative (constant across session)
[16-31]  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx   — rolling state (changes per command, likely nonce/IV)
[32-39]  0000000000 0d6c82                  — fixed prefix + unknown
[40-42]  fe6b1fa5                           — partial counter area
[43-45]  9f492c → 9f4935                    — command sequence counter (increments: 2b→2c→2d→2e→2f→30→31→32→33→34→35)
[46-53]  00000000000000                     — padding/reserved
[54-57]  00277d19                           — pod ID
[58-65]  0000012cab4c2c3c                   — timestamp or session ID
[66-77]  ceaa3dd8b3692ed59ef98b             — unknown (constant)
[78-92]  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx   — rolling state (likely derived MAC/checksum)
```

The counter at bytes 43-45 (`9f492c` → `9f4935`) increments with each command exchange, confirming it tracks the command sequence.

**Session persistence files:**
- `.twi_session` (4140 bytes) — encrypted with AES/GCM using `com.twi.enclave.session` AndroidKeyStore key
- `.twi_session_iv` (12 bytes) — GCM IV: `099a297d99e778e333c8a6de`

### AES-CCM Key Handle

The Frida-visible "key" field in `TwiCcmAes` shows `00277d19` (pod ID). This is a **handle/identifier**, not the raw 128-bit AES key. The actual key resides inside the native TWI security engine, accessed via native handle `-5476376651964425072` (`TwiSecurityContext.a` field). The raw key never passes through Java.

AES-CCM parameters: tag length parameter = 1 (meaning 8-byte tags), consistent with pairing.

### Pod Connection State (Frida dump)

| Field | Value |
|-------|-------|
| Pod BLE address | B4:3D:6B:FF:15:6E (bonded, type=0) |
| Pod AP identifier | `AP FFFFFFFE 0E59784100258BD1` |
| Pod serial | 2587929 |
| Pod ID | `00277d19` |
| Controller ID | `00277d18` |
| TWI version | a=71, e=24 |
| Connection RSSI | -79 |
| Discovery timestamp | 02/15/2026 14:44:01 |
| `setup_complete` | true |
| `pod_cmd_sequence_number` | 0 |
| `pod_ip_cmd_sequence_number` | 1 |
| BLE services discovered | 3: GAP (0x1800), GATT (0x1801), Omnipod (1a7e4024) |
| Heartbeat service (7DED7A6C) | **NOT present** |

### AndroidKeyStore Keys (from running app)

| Alias | Type | Purpose |
|-------|------|---------|
| `com.twi.enclave.device.secondary` | EC (P-256) | Signs commands (Type 4), signs channel-binding transcript |
| `com.twi.enclave.device.primary` | EC (P-256) | Embedded in TLS cert SAN |
| `com.twi.enclave.session` | AES | Encrypts `.twi_session` persistence file |
| `hardware-backed-key` | EC | TEE attestation key |
| `TwiSecretKeyStore` | Secret | TWI internal |
| `realm-secret` | Secret | Realm DB encryption |
| `hmac-secret` | Secret | HMAC operations |
| `secured-sharedpreferences-secret` | Secret | SharedPreferences encryption |

## Next Steps / Implementation Checklist

Ordered steps to implement post-pairing pod communication in OmnipodKit:

### Phase 1: Command Construction
1. **Implement Type 4 signed message construction**
   - After AES-CCM encryption, construct 80-byte signing input: `AAD(16) + ciphertext + tag(8)`
   - Sign with secondary key (`com.twi.enclave.device.secondary`, SHA256withECDSA)
   - Append 64-byte raw r||s signature to the encrypted message
   - Test: verify signature matches Frida-captured examples using known key material

2. **Implement command sequence counter management**
   - Track counter per session (observed: `9f492c` → `9f4935`, incrementing per command exchange)
   - Persist counter in session state for reconnection
   - Counter appears in TWi header and TwiCaching value (bytes 43-45)

3. **Implement ACK message construction**
   - ACK = AES-CCM encrypt with empty plaintext, producing 8-byte tag only
   - ACK is written to control characteristic (`2441`) after receiving pod response on data characteristic (`2443`)

### Phase 2: BLE Communication
4. **Implement BLE polling loop (every ~20-30 seconds)**
   - Send encrypted status query commands on data characteristic
   - No separate heartbeat/keep-alive mechanism needed
   - Handle NOTIFY responses on data characteristic
   - Handle INDICATE on control characteristic with WRITE ack

5. **Implement BLE fragmentation header**
   - 7-byte fragmentation header prepended to TWi packet on BLE writes
   - Parse incoming fragments and reassemble TWi packets

### Phase 3: Session Management
6. **Implement session persistence (save/restore)**
   - Save: LTK derivative, nonce state, command counter, pod ID, session metadata
   - Restore: reload on app restart for reconnection without re-pairing
   - Model after TwiCaching 93-byte value structure

7. **Implement reconnection using stored session**
   - Skip pairing flow when LTK exists
   - Resume AES-CCM encryption with persisted nonce/counter state
   - Re-establish BLE subscriptions (NOTIFY on 2443, INDICATE on 2441)

### Phase 4: Pod Activation
8. **Implement setPodUid with registration payload**
   - Send 163-byte registration payload to pod
   - Determine if this uses Type 3 or Type 4 message format
   - Must happen after pairing, before first basal program

### Phase 5: Validation
9. **End-to-end test: send a status query and parse response**
   - Verify encryption, signing, sequence counter, ACK cycle
   - Compare BLE traffic against Frida captures

## External Reference Files

### Successful pairing capture (pdmid 2587928)
All in `/Users/james/Downloads/O5keys/KEYS/`:
- `btsnoop_hci_20260215-2pm.log` — Complete btsnoop HCI log of successful O5 pairing (148KB, 270 ATT frames)
- `sps_pairing_data.json` — Extracted structured pairing data: frame numbers, sizes, hex for each step
- `HTTPToolkit_2026-02-15_14-39.har` — HTTP capture of full registration API flow
- `certificates/` — fullchain.pem (rootCA + INS02PG1 + TLS leaf), private.pem (secondary key), pod_fullchain.pem
- `virtual_keys_v1/10260/com.twi.enclave.device.secondary/` — priv.pk8, pub.der, cert_0-3.der (TEE attestation chain)
- `virtual_keys_v1/10260/com.twi.enclave.device.primary/` — priv.pk8, pub.der, cert_0-3.der
- `keybox.xml` — Android Keybox for virtual TEE

#### Extracted btsnoop pairing data (hex files)
All in `/Users/james/Downloads/O5keys/KEYS/`:
- `ecdh_phone_pubkey.hex` — Phone ECDH P-256 public key (80 bytes: 64-byte point + 16-byte nonce)
- `ecdh_pod_pubkey.hex` — Pod ECDH P-256 public key (80 bytes)
- `sps21_phone_cert.hex` — SPS2.1 phone→pod encrypted cert (642 bytes: INS02PG1 DER + tag)
- `sps21_phone_transport.hex` — SPS2.1 phone→pod full TWi transport frame (includes 16-byte header)
- `sps21_pod_cert.hex` — SPS2.1 pod→phone encrypted cert (641 bytes)
- `sps21_pod_transport.hex` — SPS2.1 pod→phone full TWi transport frame
- `sps2_phone_cert.hex` — SPS2 phone→pod encrypted cert+sig (1089 bytes: TLS DER + ECDSA sig + tag)
- `sps2_pod_cert.hex` — SPS2 pod→phone encrypted cert+sig (895 bytes)

### Frida session capture (2026-02-15, pod-connected app)
All in `/Users/james/Downloads/O5keys/KEYS/`:
- `frida_output_20260215_215748.log` — Complete Frida instrumentation log: BLE state dump, AES-CCM encrypt/decrypt, ECDSA signing, TwiCaching updates, session files, AndroidKeyStore enumeration
- `FRIDA_QUESTIONS.md` — Prioritized extraction plan documenting what to hook and why

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

## O5 vs DASH: RTS/CTS Flow Control

- **DASH**: Uses RTS/CTS flow control for all message exchanges (pairing, EAP, encrypted commands). RTS (0x00) is written to CMD characteristic before sending data; pod responds with CTS (0x01).
- **O5**: NEVER uses RTS/CTS. All messages are sent directly on the DATA characteristic. The only CMD characteristic writes are HELLO (0x06, once at connection) and SUCCESS (0x04, sent after each message as acknowledgment).
- O5 btsnoop post-pairing flow: P0 → SUCCESS ack → EAP Challenge (direct on DATA) → EAP Response → SUCCESS ack → EAP Success → encrypted commands.

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
| Heartbeat Service | `7DED7A6C-CA72-46A7-A3A2-6061F6FDCAEB` | **NOT discovered on connected pods** (Frida 2026-02-15). Not used. |
| Heartbeat Char | `7DED7A6D-CA72-46A7-A3A2-6061F6FDCAEB` | Not present. App polls via normal commands instead. |
