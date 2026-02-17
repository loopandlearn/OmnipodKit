# CLAUDE.md — OmnipodKit O5 Pairing Context

## Project Overview

OmnipodKit is a Swift framework for communicating with Omnipod insulin pumps over BLE. It supports both DASH and Omnipod 5 (O5) pods. The O5 pairing implementation is actively being developed.

**Build**: `xcodebuild -scheme OmnipodKit -destination 'generic/platform=iOS' build`
This is a framework target, not a standalone app. It's consumed by Loop (the iOS diabetes app).

## Architecture: O5 Pairing Flow

The pairing sequence is orchestrated by `O5LTKExchanger.o5negotiateLTK()`:

```
SP1+SP2  → Pod ID assignment (4+11 bytes)
SPS0     → Algorithm negotiation (5 bytes: 00 01 09 a2 18, algo=0x09, CRC-16/XMODEM)
SPS1     → ECDH key exchange (80 bytes: 64-byte EC pubkey + 16-byte nonce)
SPS2.1   → PKI authentication (642 encrypted, native index=1, extended path with sig)
SPS2     → Certificate exchange (1089 encrypted, native index=0, short path)
SP0/GP0  → Handshake complete
P0       → Pod ack (0xa5 = success)
```
Algorithm byte `0x09` = `CURVE256R1_NO_PASSWORD_CERTIFICATE`. SPS3 exists in the code but is
only triggered for PASSWORD algorithm variants (0x05, 0x0D) — O5 pods use 0x09 which bypasses
SPS3 entirely. Confirmed by 3 btsnoop captures: zero SPS3 occurrences.

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

### Post-Pairing / Activation
- `OmnipodKit/Bluetooth/O5AidCommands.swift` — O5 AID command constructors for pre-SetupPod sequence (UtcCommand, TdiCommand, TargetBgProfile, DiaCommand, EgvCommand, AlgorithmInsulinHistory, UnifiedAidPodStatus). Uses ASCII key-value SLPE format. **Binary AID data fix (2026-02-17)**: TdiCommand, TargetBgProfileCommand, and AlgorithmInsulinHistoryCommand now send raw binary bytes in their data portions (via `useBinaryAidData` flag) instead of ASCII hex text. See "Known Issues / Recent Fixes" for details.

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

### Size correction from btsnoop analysis (DEFINITIVELY RESOLVED 2026-02-17)
The native RE analysis had the ternary condition **inverted** during decompilation. Btsnoop byte counts prove (verified across 4 payloads and 3 independent pairings):
- **SPS2.1** = cert-only (no signature): INS02PG1 DER (634) + tag (8) = 642 ✓ (pod side: INS01PG1 (633) + 8 = 641 ✓)
- **SPS2** = cert + signature: TLS DER (1017) + ECDSA sig (64) + tag (8) = 1089 ✓ (pod side: pod_cert (823) + 64 + 8 = 895 ✓)

Native index mapping (corrected): index=0 → `"SPS2="` → EXTENDED path (cert+sig+tag), index=1 → `"SPS2.1="` → SHORT path (cert+tag). The `getMyConfValSize` ternary `(index != 0 ? 0x40 : 0)` was inverted during native decompilation; the true behavior is index=0 adds 0x40 (64-byte sig). **OmnipodKit already implements this correctly.**

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

**Important**: The registration payload (from `register/complete`) does NOT go in SPS2.1/SPS2. It is NOT sent during activation — the btsnoop messages originally identified as registration payloads (frames 1925, 1939, 1952) were actually AlgorithmInsulinHistory (`SE2.1=`) AID commands. The size coincidence (184 bytes encrypted ~ 163 bytes payload + overhead) led to the misidentification.

## Active Registration: TEE Simulator pdmid 2587928 (SUCCESSFUL PAIRING)

Source: `/Users/james/Downloads/O5keys/KEYS/virtual_keys_v1/10260/` (TEE simulator, uid=10260)
Btsnoop capture: `/Users/james/Downloads/O5keys/KEYS/btsnoop_hci_20260215-2pm.log`
HAR capture: `/Users/james/Downloads/O5keys/KEYS/HTTPToolkit_2026-02-15_14-39.har`

| Field | Value |
|-------|-------|
| pdmid | 2587928 |
| pdmidExtension | 4300804 |
| Controller ID | `00277d18` (big-endian) |
| Pod1 ID (assigned, 2026-02-15) | `00277d19` (2587929) |
| Pod2 ID (assigned, 2026-02-16) | `00277d1a` (2587930) |
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
This payload is NOT included in SPS2.1/SPS2. It is NOT sent during activation — the btsnoop messages originally identified as registration payloads were actually AlgorithmInsulinHistory (`SE2.1=`) AID commands. Sending the 163-byte binary blob wrapped in `S0.0=...G0.0` SLPE format caused CBError 7 pod disconnect.

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
- **O5 AID setup commands implemented (2026-02-16)**: 8 AID commands now sent between getPodVersion and setPodUid during activation. Implemented in `O5AidCommands.swift` and called from `BlePodComms.swift`. Uses ASCII key-value SLPE format (SET+GET, GET-only, Extended SET).
- **Activation order corrected (Pod2 Frida, 2026-02-16)**: Removed basal schedule programming from Phase 1 (before priming). Pod2 Frida capture confirms NO basal is sent before prime 1 -- basal is deferred to Phase 2. Previously assumed from historical btsnoop that 3x ProgramBasal preceded prime.
- **Alert parameters corrected (Pod2 Frida, 2026-02-16)**: Low reservoir threshold is 10U (100 ticks, corrected from initial 5U misinterpretation), beepRepeat=1 (not 2). Prime bolus beep parameter is 0x7C (completion beep ON + 60min reminder), not no beeps. User expiry triggers at 3968 min (~66h8m, ~5h52m before 72h), not 68h.
- ~~**Registration payload re-added to activation (error 33 fix, 2026-02-16)**~~: **REVERTED** — the btsnoop messages identified as registration payloads were actually AlgorithmInsulinHistory (`SE2.1=`) AID commands. Error 33 was caused by 24-hour hour format, not missing registration payload. See "Registration payload removed" entry below.
- **Message type signing rules clarified (Pod2 Frida, 2026-02-16)**: Only `programBolus` (prime/delivery) uses TWi Type 4 (encrypted + ECDSA signed). All other commands -- including setPodUid, programAlert, AID commands -- use TWi Type 1 (encrypted only, no signature). Previously assumed all post-pairing commands used Type 4.
- **SLPE suffix fix — `,G3.12` → `,G0.0` for standard commands (Pod3, 2026-02-16)**: `getCmdMessage()` was sending `,G3.12` as the SLPE GET suffix for ALL O5 commands. This tells the pod "respond with AID status format" — the pod complied, returning `3.12=` prefixed AID data instead of the expected `0.0=` VersionResponse. Caused `unknownBlockType(rawVal: 0)` on the first post-pairing getPodVersion command. The real O5 app uses `S0.0=...,G0.0` for ALL standard Omnipod commands; only AID-specific commands use AID suffixes. Fixed all 4 locations in `BleMessageTransport.swift` to use `COMMAND_SUFFIX` (`,G0.0`). AID commands already use their own suffixes via `sendO5AidCommand()` / `O5AidCommands.swift`.
- **GetStatus removed from `o5PreSetupSteps()` (Pod3 reconnect, 2026-02-16)**: `o5PreSetupSteps()` sent two GetStatus commands (after AssignAddress, and before SetupPod) that the real O5 app never sends. Pod at progress state 2 (FILLED) rejects GetStatus with `ERR_ILLEGAL_CMD_STATE` (error code 19). The rejected exchange desynchronized nonce state, causing subsequent AID commands to fail. Fix: removed both GetStatus calls and the `o5SendGetStatus()` function from `BlePodComms.swift`. The method now goes directly to AID setup commands, matching the Pod2 Frida-validated activation flow.
- **O5 resume path: `resumingPodSetup()` GetStatus guard + route through `blePairAndSetupPod()` (test #18, 2026-02-16)**: Two fixes: (1) `resumingPodSetup()` in `OmniPumpManager.swift` unconditionally called `getStatus()` — O5 pods at FILLED state reject with error 19. Added early return guard when `podType == omnipod5Type && setupProgress.isPaired == false`. (2) "Already paired" resume path in `pairAndPrime()` went straight to prime, skipping getPodVersion + AID + setPodUid. Now routes O5 pre-setup pods through `blePairAndSetupPod()` which handles the full activation sequence.
- **O5 double EAP-AKA session prevention (test #19, 2026-02-16)**: `blePairAndSetupPod()` sent HELLO + established a new EAP-AKA session even when `completeConfiguration()` had already done so. Pod disconnected (CBError 7) on receiving second HELLO. Fix: (1) Set `needsSessionEstablishment = false` after successful establishment in `completeConfiguration()`. (2) In `blePairAndSetupPod()`, skip HELLO + EAP-AKA when `!needsSessionEstablishment` and `podState.bleMessageTransportState.ck` is valid.
- **O5 resume path: missing getPodVersion before AID commands (test #20, 2026-02-16)**: After the double-EAP fix, UtcCommand was sent as the first encrypted command but pod gave no response (`emptyValue`). Root cause: `getPodVersion` (AssignAddress with 0xffffffff) must be the first encrypted command after each new EAP-AKA session. In normal pairing, `pairPod()` sends it; on resume, it was skipped. Fix: added `getPodVersion` send in `blePairAndSetupPod()` resume path, after session verification but before `o5PreSetupSteps()`.
- **AID command SLPE length prefix (test #21, 2026-02-16)**: `O5AidCommands` used `StringLengthPrefixEncoding.formatKeys()` to construct AID command payloads. This function inserts 2-byte big-endian length prefixes between the key and data (e.g., `"SE255.2=" + 0x000A + "1771276453"`). But AID commands use plain ASCII key-value format with NO length prefix (Frida confirms: `"SE255.2=1771222561"`). The pod received the encrypted command (ACKed transport with SUCCESS) but couldn't parse the inner payload due to the extra bytes, so it silently dropped it — no data response, timeout after 5s. Fix: replaced all three `O5AidCommands` payload methods (`setGetPayload`, `getPayload`, `extendedSetPayload`) with simple string concatenation. Also fixed `sendO5AidCommand()` response parsing to strip ASCII prefix instead of using `StringLengthPrefixEncoding.parseKeys()` (which also expects length-prefixed format). Changed hex format to uppercase (`%08X`) to match real O5 app.
- **Double getPodVersion on initial pairing path (test #21, 2026-02-16)**: `pairPod()` sends `getPodVersion` (AssignAddress with 0xffffffff) as part of normal pairing. Then `blePairAndSetupPod()` at line 586 sends it AGAIN because `setupProgress.isPaired == false`. The second `getPodVersion` exchange shifts nonce state by 3 (encrypt, decrypt, ACK), so subsequent AID commands would use wrong nonce and fail AES-CCM integrity check. Fix: added `pairPodRanGetPodVersion` boolean flag set when `pairPod()` runs; the later `getPodVersion` is only sent when `pairPod()` was skipped (resume path). Note: this was initially suspected as the root cause but the AID SLPE format was the actual blocker — the double-getPodVersion would have been a secondary issue.
- **SetupPodCommand 24-hour vs 12-hour hour format RE-CONFIRMED (test #22, fresh pod 2026-02-16)**: Originally hypothesized that O5 pods expect 12-hour format (0-11) matching Java `Calendar.HOUR` (field 10), and added `% 12` conversion in `BlePodComms.setupPod()`. This was reverted as "hypothesis was incorrect", but fresh pod test (feb16-840pm-1.txt) proved it was correct after all. O5 pods DO expect 12-hour format: sending hour=20 (24-hour format) at 8:40 PM caused error 33. The `% 12` conversion is required and has been re-implemented in `BlePodComms.setupPod()` for all O5 pods.
- **Phase 1 alert ordering: user expiry moved after prime (O5 Java validation, 2026-02-16)**: User expiry alert (slot #3) was programmed before prime bolus. O5 Java state machine shows ACTIVATION_PRIMED_PUMP (state 7) must occur before ACTIVATION_PROGRAMMED_USER_SET_EXPIRATION_ALERT (state 8). Moved user expiry programming to after prime completion and status polling, matching the Java activation state sequence.
- **Low reservoir threshold corrected from 5U to 10U (Frida re-analysis, 2026-02-16)**: Previous analysis decoded Frida threshold `0x0064` (100 decimal) as 100 uL = 5U. Correct decoding: OmnipodKit encodes volume as `ticks = volume / 0.05 / 2`, so 100 ticks = 100 * 0.05 * 2 = 10U. Low reservoir alert threshold is 10U (200 uL), not 5U.
- **User expiry absolute time corrected to ~66h8m (Frida re-analysis, 2026-02-16)**: Frida shows 3968 minutes = 66 hours 8 minutes (~5h52m before 72h nominal life), not 4080 minutes (68h) as previously documented. The `~66h` shorthand in earlier entries was correct; the `66.13h` was a rounding artifact.
- **Phase 2: ProgramBasal is first command (O5 Java validation, 2026-02-16)**: O5 Java activation state ACTIVATION_PROGRAMMED_BASAL (state 9) is the first Phase 2 command, immediately after Phase 1 completes (ACTIVATION_COMPLETED_PHASE_1, state 8). Basal schedule programming precedes all Phase 2 alerts and prime 2.
- **Phase 2: shutdown imminent beepRepeat corrected to every5Minutes (O5 Java validation, 2026-02-16)**: Shutdown imminent alert (slot #0) beepRepeat was every15Minutes (6). O5 Java source confirms it should be every5Minutes (8). Fixed to match decompiled O5 alert configuration.
- **Phase 2: slot #0 auto-off alert added (O5 Java validation, 2026-02-16)**: New auto-off alert on slot #0 with duration=15min, autoOff=true, beepRepeat=2. This alert was missing from the Phase 2 implementation. Added to match O5 Java activation state machine.
- **Registration payload removed (misidentified btsnoop frames, 2026-02-16)**: The three 184-byte btsnoop messages (frames 1925, 1939, 1952) previously identified as "registration payload delivery" were actually AlgorithmInsulinHistory (`SE2.1=`) AID commands. Size coincidence (184 bytes encrypted ~ 163 payload + overhead) led to the incorrect identification in O5_ACTIVATION_SEQUENCE.md. Both btsnoop and Pod2 Frida confirm no registration payload is sent during activation. Removed `o5SendRegistrationPayload()` and `sendRawO5DataExpectingAck()` from the codebase — sending the 163-byte binary blob wrapped in `S0.0=...G0.0` SLPE format caused CBError 7 pod disconnect.
- **O5 messageNumber reset after EAP-AKA (reconnect fix, 2026-02-16)**: `establishSession()` carried forward the old `messageNumber` from podState on reconnect, causing setPodUid to use stale Omnipod Message sequence numbers. Frida shows: getPodVersion(seq=0) → setPodUid(seq=2) — sequence restarts from 0 after each new EAP-AKA session. Fix: in `establishSession()`, O5 pods always reset `omnipodMessageNumber = 0` instead of preserving the old value. On the fresh pairing path this happened naturally (podState was nil → default 0), but on reconnect the stale value caused wrong seq numbers. DASH behavior unchanged.
- **certPdmId cycling fix (2026-02-16)**: OmnipodKit now cycles the bottom 2 bits of certPdmId through 1->2->3->1... matching the Android app's `peripheral_node_counter` behavior. Formula: `(certPdmId & 0xFFFFFFFC) | ((counter % 3) + 1)`. Files: `OmniPumpManagerState.swift` (added `o5PairingCounter`, `nextO5PairingCounter()`, `o5PodId()`), `OmniPumpManager.swift` (`prepForNewPod()` uses cycling counter instead of hardcoded +1). While correct for protocol compliance, this was already eliminated as the cause of Error 33 — pairing and commands succeed regardless of address offset.
- **SessionKeyMode enum added (2026-02-16)**: `SessionEstablisher.swift` now supports PRIMARY (controller initiates EAP-AKA challenge, DASH default) and SECONDARY (pod initiates, hypothesized for O5 post-pairing) modes. Test #24 used SECONDARY during pairing — pod disconnected immediately. Test #25 used SECONDARY for 44 consecutive post-pairing reconnections — pod NEVER sent a challenge, complete deadlock. **SECONDARY mode fully eliminated; code reverted to `.PRIMARY` for all sessions.**
- **BUG FOUND: pdmidExtension value wrong in O5RegistrationData.swift (2026-02-16)**: `pdmidExtension: 43008040` (line 351 of active registration `teeSimulator_2587928`) should be `4300804`. TLS certificate SAN and HAR capture both show `4300804`. This is a factor-of-10 error (hex `0x02904028` wrong vs `0x0041A004` correct). **Fix pending.**
- **ERROR 33 RESOLVED: Binary AID data encoding fix (2026-02-17)**: Root cause of Error 33 (0x21) at SetUniqueId found and fixed. Three AID commands (TdiCommand, TargetBgProfileCommand, AlgorithmInsulinHistoryCommand) were sending ASCII hex text in their data portions where the Android app sends raw binary bytes. For example, TdiCommand sent the ASCII string `"0003000E00"` (10 bytes) instead of raw bytes `\x00\x03\x00\x0E\x00` (5 bytes). The pod's AID command parser accepted the malformed data without returning errors, but the incorrectly-encoded data left the pod's algorithm state invalid, causing it to reject SetUniqueId with Error 33. Fix: added `useBinaryAidData` flag (default `true`) and binary data variants (`setGetPayload(feature:attribute:binaryData:)`, `extendedSetPayload(feature:attribute:binaryData:)`) for the three affected commands. Correct sizes: TdiCommand=15B (was 20B), TargetBgProfileCommand=204B (was 398B), AlgorithmInsulinHistoryCommand=176B (was 346B). Test #26 (feb17-01am-1.txt) confirmed: all 9 AID commands succeed with correct binary sizes, SetUniqueId succeeds with `progressStatus=Pairing completed`.
- **Type 4 AAD size field corruption RESOLVED (2026-02-17)**: `getO5SignedCmdMessage()` in `BleMessageTransport.swift` appended the 64-byte ECDSA signature to `signedPacket.payload`. When `asData()` serialized the message, the header size field included the signature bytes (size=120 instead of 56), corrupting the AAD. Pod couldn't decrypt because AAD at encryption time (size=56) didn't match AAD at decryption time (size=120). Result: pod silently dropped the message, controller saw `emptyValue` timeout. Fix: added `var signatureData: Data?` to `MessagePacket` in `MessagePacket.swift`. Signature is appended after payload in `asData()` but excluded from the size field calculation. Files: `MessagePacket.swift`, `BleMessageTransport.swift`.
- **Type 4 ACK type corrected (2026-02-17)**: ACK after receiving a Type 4 response was sent as `ENCRYPTED_SIGNED` (Type 4) with a 64-byte ECDSA signature. Frida/btsnoop analysis shows the official app sends ACK as `ENCRYPTED` (Type 1, AAD byte[3]=`0x81`) with NO signature. Fix: renamed `getO5SignedAck()` → `getO5Ack()`, changed to `MessageType.ENCRYPTED`, removed signature computation. File: `BleMessageTransport.swift`.
- **BolusExtraCommand O5 format: 0x0d → 0x12 WITH_PDM_VALUE (2026-02-17)**: O5 pods require `BolusExtraCommand` type byte `0x12` (WITH_PDM_VALUE, 20 bytes) instead of DASH's `0x0d` (NO_VALUE, 15 bytes). The 5 extra bytes are: `bolusSource(0x01) + mealPulses(0x0000) + correctionPulses(0x0000)`. Pod rejected type `0x0d` with error code 42 (0x2A). Fix: added `withPdmValue: Bool` to `BolusExtraCommand.swift`, used `true` for both Phase 1 prime and Phase 2 cannula insertion in `PodCommsSession+O5Activation.swift`. Byte-level comparison against Frida confirmed all other fields match.
- **FIRST SUCCESSFUL O5 PRIME (2026-02-17)**: Test #28 (feb17-0145am-2withprime.txt). Pod delivered 2.25U prime, podProgressStatus advanced to "Priming completed". User expiry alert (slot #3) configured successfully post-prime. This is the first time an O5 pod has been successfully primed by OmnipodKit.

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
| 16 | **Pairing + EAP success, first encrypted command fails with `unknownBlockType(rawVal: 0)`** | **Pod3 failed** | Fresh pod (seq `0022F3BC`). Pairing P0=0xa5, EAP-AKA session established. First getPodVersion command sent successfully, pod responds, but decrypted response has `3.12=` prefix (AID status data, 22 bytes) instead of `0.0=` prefix (VersionResponse). Root cause: `getCmdMessage()` used `,G3.12` suffix for ALL O5 commands — this tells the pod to respond in AID format. Real O5 app uses `,G0.0` for standard commands. Fix: changed all SLPE suffix references from `O5_COMMAND_SUFFIX` to `COMMAND_SUFFIX`. Retry attempts failed at SPS0 because pod was already in paired state from first attempt. |
| 17 | **Pod3 reconnect: GetStatus rejected with error code 19 (`ERR_ILLEGAL_CMD_STATE`)** | **Pod3 failed (reconnect)** | Same pod as #16 (seq `0022F3BC`), auto-reconnected after SLPE suffix fix. Pairing skipped (pod already paired), EAP-AKA session established (eapSeq=2→3). `o5PreSetupSteps()` sent GetStatus after getPodVersion — pod returned error code 19 (`ERR_ILLEGAL_CMD_STATE`) because pod at progress state 2 (FILLED) rejects GetStatus. This desynchronized nonce state. Subsequent UtcCommand (AID) got no response (`emptyValue`) — pod ACK'd transport but couldn't decrypt. Auto-reconnect (eapSeq=3→4) also failed: `resumingPodSetup()` called `getStatus()` with `podState.address` (0x277d19) instead of `0xffffffff`. Root cause: `o5PreSetupSteps()` had two GetStatus calls not present in real O5 app. Fix: removed both GetStatus calls and the `o5SendGetStatus()` function. Real O5 app goes directly: getPodVersion → UtcCommand → ... → SetupPod with NO GetStatus in between. |
| 18 | **Pod3 reconnect: `resumingPodSetup()` still sends GetStatus, resume path skips setPodUid** | **Pod3 failed (reconnect)** | Same pod, eapSeq=8→10. Two issues: (1) `resumingPodSetup()` in `OmniPumpManager.swift` (separate from `o5PreSetupSteps()`) still calls `getStatus()` — pod rejects with error 19. (2) "Already paired" resume path goes directly to `o5Prime()` → `ConfigureAlerts` without ever running getPodVersion + AID commands + setPodUid. Pod still at FILLED state, rejects all commands with error 19. Also wrong inner address (`podState.address` = 0x277d19 instead of 0xffffffff before setPodUid). Fix: (1) Guard `resumingPodSetup()` with early return for O5 pre-setup pods. (2) Route O5 pre-setup pods through `blePairAndSetupPod()` which already handles AID + setPodUid. |
| 19 | **Pod3 reconnect: double EAP-AKA session — `blePairAndSetupPod()` re-establishes session** | **Pod3 failed (reconnect)** | Same pod, eapSeq=10→14. Fix #18 correctly routes to `blePairAndSetupPod()`, but it sends HELLO + establishes a NEW EAP-AKA session even though `completeConfiguration()` already established one. Pod disconnects (CBError 7) because it already has an active session. Infinite loop: `completeConfiguration` establishes session → `blePairAndSetupPod` sends HELLO → pod disconnects → reconnect → repeat. Fix: (1) Set `needsSessionEstablishment = false` after successful establishment in `completeConfiguration()`. (2) In `blePairAndSetupPod()`, skip HELLO + EAP-AKA when `!needsSessionEstablishment` and `ck` is valid. |
| 20 | **Pod3 reconnect: UtcCommand sent but pod gives no response (`emptyValue`)** | **Pod3 failed (reconnect)** | Same pod, eapSeq=18→22. Double-EAP fix works ("Session already established by completeConfiguration, skipping HELLO + EAP-AKA"). AID command UtcCommand is sent, pod ACKs at transport level (SUCCESS) but never responds on DATA char. Root cause: `getPodVersion` (AssignAddress with 0xffffffff) is missing from the resume path — `pairPod()` normally sends it but is skipped on resume. Pod needs this as the first encrypted command after each new EAP-AKA session before it will accept AID commands. Fix: added `getPodVersion` send in `blePairAndSetupPod()` resume path, before `o5PreSetupSteps()`. |
| 21 | **Fixed: AID commands used SLPE length prefix, should be plain ASCII** | **AID commands succeed, setPodUid fails** | New pod (5A751FA5). Pairing P0=0xa5, EAP-AKA success, getPodVersion success (FW 9.0.4). Double-getPodVersion fix confirmed working (`pairPodRanGetPodVersion` flag). UtcCommand fails with `emptyValue` — pod ACKs transport but never responds. Root cause: `O5AidCommands` used `StringLengthPrefixEncoding.formatKeys()` which adds 2-byte big-endian length prefixes, but AID commands use plain ASCII key-value format with NO length prefix. Frida: `"SE255.2=1771222561"` (18 bytes). OmnipodKit sent: `"SE255.2=" + 0x000A + "1771276453"` (20 bytes). Fix: replaced `formatKeys()` with simple string concatenation, fixed response parsing in `sendO5AidCommand()` to strip prefix instead of using `parseKeys()`. Also fixed double-getPodVersion with `pairPodRanGetPodVersion` flag. |
| 22 | **AID SLPE fix confirmed: all 9 AID commands succeed. setPodUid fails error 33** | **Pod4 failed at setPodUid** | Same pod as #21 (5A751FA5), retry with SLPE fix. ALL 9 AID COMMANDS SUCCEED for first time ever: UtcCommand, TdiCommand, TargetBgProfile, DiaCommand, EgvCommand, 3x AlgorithmInsulinHistory, UnifiedAidPodStatus. setPodUid then fails with error code 33 (0x21). Hypothesized as 12-hour vs 24-hour hour format mismatch (`Calendar.HOUR` field 10) and added `% 12` conversion. Initially reverted as "incorrect", but a fresh pod test (feb16-840pm-1.txt) **RE-CONFIRMED that 12-hour format IS correct**: sending hour=20 (24-hour) at 8:40 PM caused error 33. The `% 12` conversion is required and has been re-implemented. Error 33 on THIS pod was caused by 24-hour hour format. |
| 23 | **Removed registration payload, reset O5 messageNumber after EAP-AKA** | **Pending test** | Registration payload (163B x 3) was misidentified btsnoop frames — actually AlgorithmInsulinHistory (`SE2.1=`). Sending it caused CBError 7. Also: `establishSession()` preserved stale `messageNumber` from old podState on reconnect. O5 Frida shows message seq restarts from 0 after each EAP-AKA. Fix: removed registration payload sending (`o5SendRegistrationPayload()` and `sendRawO5DataExpectingAck()`), O5 pods now reset `messageNumber=0` in `establishSession()`. **Test with fresh pod.** |
| 24 | **SECONDARY EAP-AKA mode: pod initiates challenge instead of controller** | **Pairing P0=0xa5 SUCCESS, pod disconnected on SECONDARY EAP-AKA** | Fresh pod (BLE `3FE369C7-22A0-2344-5393-EB967FB49AE3`), pdmid 2584724, myId=`0x277094`, podId=`0x277095`. Pairing succeeded (P0=0xa5, LTK=`4f1da4ab399c275afdb8be816adb2089`, seq=6). SessionEstablisher entered SECONDARY mode (waits for pod's EAP-AKA challenge). Pod immediately disconnected (CBError code=7) — never sent any EAP-AKA challenge data. Log: "Skipping notifications for undiscovered service: 7DED7A6C". Second attempt on same pod failed during SPS0 read (pod in tainted state from first attempt, disconnected at SPS0). **Key finding**: Pod does NOT initiate EAP-AKA challenge after pairing — SECONDARY mode may not be the correct post-pairing approach for the initial session, OR a disconnect/reconnect cycle may be needed between pairing and session establishment. PRIMARY (controller initiates) may actually be correct for the first post-pairing session. |
| 25 | **SECONDARY EAP-AKA mode for post-pairing reconnections (same pod as #24)** | **Complete failure: 44 consecutive reconnections, zero successful sessions** | Same pod from test #24 (already paired). Code changed so post-pairing reconnections (`isPairing==false`, `podType==omnipod5Type`) use SECONDARY mode. Log confirmed: `negotiateSessionKeys: podType=O5, useRTS=false, mode=SECONDARY` on every attempt. Pod NEVER sent an EAP-AKA challenge — both sides deadlocked (phone waited for pod to speak first, pod expected phone to speak first). Pod disconnected the phone (CBError code=7) after timing out on every attempt. Pod sent `0800010100` on command channel a few times (not EAP-AKA data). MTU degraded to 23 on reconnections (irrelevant — EAP-AKA never started). **Conclusion**: SECONDARY EAP-AKA is fully eliminated. Pod expects PRIMARY mode at ALL lifecycle stages — during pairing (test #24) and during post-pairing reconnection (test #25). The Android app's `TwiEapAkaSlave` class naming does not reflect wire-level behavior; the TWI SDK may handle the protocol differently internally. Code reverted back to `.PRIMARY` for all sessions. |
| 26 | **ERROR 33 RESOLVED: Binary AID data encoding fix** | **SetUniqueId SUCCESS (progressStatus=Pairing completed). Prime bolus FAILED (new issue).** | Fresh pod (feb17-01am-1.txt). Root cause of Error 33 found: TdiCommand, TargetBgProfileCommand, and AlgorithmInsulinHistoryCommand sent ASCII hex text in data portions instead of raw binary bytes. Example: TdiCommand sent `"0003000E00"` (10B ASCII) instead of `\x00\x03\x00\x0E\x00` (5B binary). Pod accepted malformed AID data silently but left algorithm state invalid, causing SetUniqueId rejection. Fix: `useBinaryAidData` flag + binary payload variants. Correct sizes confirmed in logs: TdiCommand=15B (was 20B), TargetBgProfile=204B (was 398B), AlgorithmInsulinHistory=176B (was 346B). Full sequence: Pairing P0=0xa5, EAP-AKA PRIMARY success, all 9 AID commands succeed, **SetUniqueId SUCCESS**, ProgramAlert x2 succeed. **NEW ISSUE**: Prime bolus (2.6U, Type 4 signed) fails — pod ACKs BLE write but never sends response (`emptyValue` timeout, 4 retries all failed). ProgramAlert (unsigned Type 1) works fine. Failure is specific to ECDSA-signed message path. |
| 27 | **Type 4 signing fixes: AAD size corruption + ACK type + BolusExtraCommand format** | **Pod responds (Type 4 fixed!) but rejects programBolus with error 42 (0x2A).** | Same pod as #26, reconnected (feb17-0145am-1.txt). TWO Type 4 bugs fixed: (1) ECDSA signature was appended to `signedPacket.payload`, causing `asData()` to include it in size field (120 instead of 56) — corrupted AAD, pod couldn't decrypt. Fix: `signatureData: Data?` field on `MessagePacket`, excluded from size. (2) ACK after Type 4 response was sent as `ENCRYPTED_SIGNED` with signature — official app uses Type 1 (`ENCRYPTED`), no signature. Fix: `getO5Ack()` uses `MessageType.ENCRYPTED`. **Pod now responds** (no more `emptyValue`!) but returns error 42. Root cause of error 42: `BolusExtraCommand` used type byte `0x0d` (NO_VALUE, 15 bytes) — O5 requires `0x12` (WITH_PDM_VALUE, 20 bytes) with 5 extra bytes: `bolusSource(0x01) + mealPulses(0x0000) + correctionPulses(0x0000)`. Byte-level comparison against Frida confirmed everything else matched. |
| 28 | **BolusExtraCommand WITH_PDM_VALUE fix (0x0d → 0x12)** | **FIRST SUCCESSFUL O5 PRIME! Phase 2 fails with BLE disconnections.** | Same pod, continued (feb17-0145am-2withprime.txt). Added `withPdmValue: Bool` to `BolusExtraCommand`. When true: type byte `0x12`, appends 5 bytes (`01 0000 0000`). **Pod delivered 2.25U prime, progressed to "Priming completed".** User expiry alert (slot #3) configured successfully post-prime. Phase 2 starts: `programBasal` sent but **pod disconnects (CBError 7)** before sending SUCCESS ack. Investigation showed: official app maintains continuous BLE connection throughout Phase 1→Phase 2 (no disconnect/reconnect). OmnipodKit breaks connection between phases. After reconnection, MTU drops from 247→23, `maximumWriteValueLength: 20`. Large writes (244 bytes) silently truncated → pod gets garbled data → disconnects. |
| 29 | **MTU polling + Phase 2 retry** | **ProgramBasal causes pod disconnect (CBError 7). MTU is NOT the issue.** | feb17-0145am-3trycannula.txt. MTU polling works correctly — settles to 244 immediately (0 polls needed). Session establishment succeeds. GetStatus works (pod reports `progressStatus: Priming completed`). But every ProgramBasal (87 bytes, Type 1) write causes **immediate pod disconnect** (CBError 7). 4 consecutive attempts, same result. **ROOT CAUSE FOUND**: ProgramBasal (0x13) must be sent as **Type 4 (ECDSA signed)**, not Type 1. The O5 firmware enforces a `specific_commands` whitelist from TWI device registration: commands `0x13, 0x16, 0x17, 0x1c, 0x1f` ALL require Type 4 signing. Previously we thought only ProgramBolus (0x17) needed Type 4. Byte-level comparison of Frida capture confirms: real app sends ProgramBasal as Type 4 (151 bytes = 87 + 64-byte signature). Also found: MCTF flag should be 1 (true) in LSF, and beep param should be 0x40 not 0x00. |

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

**Key learning (test #3, CORRECTED test #28):**
`BlePacket_MAX_PAYLOAD_SIZE=244` for O5 is an application-level protocol constant that defines logical packet
framing, NOT the physical BLE MTU. Changing it to 20 switches to DASH-style framing which the O5 pod rejects
with FAIL (0x05). Android explicitly calls `requestMtu(251)`, pod responds with 247 (btsnoop frames 1758-1759).
iOS auto-negotiates MTU asynchronously after connect — initially reports `maximumWriteValueLength: 20` (MTU 23),
but settles to 244 (MTU 247) within ~100-500ms. **CORRECTION**: CoreBluetooth does NOT fragment `.withoutResponse`
writes. Writes exceeding `maximumWriteValueLength` are **silently truncated**. This caused the Phase 2 BLE
disconnections in test #28 — after reconnection, MTU hadn't settled and 244-byte writes were truncated to 20 bytes.
Fix: `completeConfiguration()` now polls MTU until it settles before sending protocol messages.

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
| MTU | 247 (negotiated at frames 1758-1759) | 23→247 (auto-negotiated async, ~100-500ms) | **NOT transparent**: `.withoutResponse` writes > MTU are silently truncated. `completeConfiguration()` now polls until MTU settles. |
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
- ~~**Resolve Error 33 at SetUniqueId**~~: **RESOLVED (Test #26, 2026-02-17).** Root cause: three AID commands (TdiCommand, TargetBgProfileCommand, AlgorithmInsulinHistoryCommand) sent ASCII hex text in data portions instead of raw binary bytes. The pod's AID parser accepted the malformed data silently but left algorithm state invalid, causing SetUniqueId to reject with Error 33 (0x21). Fix: `useBinaryAidData` flag + binary payload variants in `O5AidCommands.swift`. Correct sizes: TdiCommand=15B (was 20B ASCII), TargetBgProfile=204B (was 398B), AlgorithmInsulinHistory=176B (was 346B). All investigated hypotheses and their final status:
  1. ~~**SPS2.1 ECDSA signature placement — RESOLVED, ALREADY CORRECT (2026-02-17)**~~: OmnipodKit already implements this correctly — signature is in SPS2, matching btsnoop.
  2. ~~**12-hour hour format for SetUniqueId — CONFIRMED CORRECT (test #22)**~~: O5 pods require 12-hour format (0-11). The `% 12` conversion is in place. This was a secondary cause of Error 33 (fixed before the binary data fix).
  3. ~~**Binary AID data encoding — THIS WAS THE ROOT CAUSE (test #26)**~~: `setGetPayload()` and `extendedSetPayload()` treated binary data as hex-encoded ASCII strings. TdiCommand sent `"0003000E00"` (10B) instead of `\x00\x03\x00\x0E\x00` (5B). Pod accepted malformed data but algorithm state was invalid.
  4. ~~**`setPreparePassword()` / SPS3 — ELIMINATED (2026-02-17)**~~: O5 pods use algorithm byte `0x09` which bypasses SPS3 entirely.
  5. ~~**TwiSecurityIdentifier `0xCCCCCCCC`**~~: **ELIMINATED**. Internal dispatch/lookup value, not transmitted OTA.
  6. ~~**EAP-AKA role reversal (SECONDARY mode)**~~: **ELIMINATED**. Pod expects PRIMARY mode at all lifecycle stages.
- ~~**Resolve Type 4 signed message failure (prime bolus fails silently)**~~: **RESOLVED (Tests #27-#28, 2026-02-17).** Three bugs found and fixed:
  1. **AAD size field corruption (CRITICAL, test #27)**: `getO5SignedCmdMessage()` appended the 64-byte ECDSA signature to `signedPacket.payload`. When `asData()` serialized this, the size field included the signature (120 instead of 56), corrupting the AAD header. Pod couldn't decrypt (AAD mismatch) → silent drop → `emptyValue` timeout. Fix: added `signatureData: Data?` field to `MessagePacket` — signature is appended after payload in `asData()` but NOT counted in the size field.
  2. **ACK sent as Type 4 signed (test #27)**: ACK after Type 4 response was `ENCRYPTED_SIGNED` with 64-byte signature. Official app sends ACK as Type 1 (`ENCRYPTED`, byte[3]=`0x81`) with no signature. Fix: renamed `getO5SignedAck()` → `getO5Ack()`, changed to `MessageType.ENCRYPTED`, removed signature.
  3. **BolusExtraCommand message type `0x0d` instead of `0x12` (test #27→#28)**: O5 pods require `0x12` (WITH_PDM_VALUE) with 5 extra bytes: `bolusSource(0x01) + mealPulses(0x0000) + correctionPulses(0x0000)`. DASH uses `0x0d` (NO_VALUE). Pod rejected with error code 42 (0x2A). Fix: added `withPdmValue: Bool` to `BolusExtraCommand.swift`, set `true` for O5 prime and cannula insertion in `PodCommsSession+O5Activation.swift`.
- **BLE MTU check added to completeConfiguration() (2026-02-17)**: After BLE reconnection, iOS auto-negotiates MTU asynchronously. For O5, `.withoutResponse` writes exceeding `maximumWriteValueLength` are silently truncated (NOT fragmented by CoreBluetooth). `completeConfiguration()` now polls MTU up to 10 times (200ms intervals, 2s max) until `maximumWriteValueLength >= BlePacket_MAX_PAYLOAD_SIZE (244)` before sending HELLO. Also corrected misleading comment in `PeripheralManager.swift` that claimed CoreBluetooth handles fragmentation transparently for `.withoutResponse` writes — it does not.

#### Native Pairing Call Sequence for O5 (algo=0x09, from JNI + state machine investigation 2026-02-17)
State machine: C3426e (AppPairing) → C3427f (SPS0) → C3423b (SPS1) → C3422a (SPS2.x) → C3425d (SP0).
Note: C3424c (SPS3/setPreparePassword) is SKIPPED for algo 0x09 — only used for PASSWORD algorithms.
```
 1. TwiSecPair(context, identifier)        — Constructor (identifier = 4 bytes from pdmId)
 2. hasLtk(ctx, identifier)                — Check for existing LTK
 3. init(ctx, false, certCount)            — Initialize with certificate count
 4. setPhoneCertificates(ctx, certs, sizes) — Load ALL certificates into native engine
--- SPS0 (C3427f SettingAlgorithmCMD) ---
 5. Send SPS0 (algo byte 0x09), receive pod's SPS0
--- SPS1 (C3423b InitialStateControllerNode) ---
 6. startPairing(ctx)                      — Reset state machine
 7. prepareLocalData(ctx)                  — Generate ECDH keypair + nonce
 8. getKeyPairSize(ctx) → 64, getPairNonceSize(ctx) → 16
 9. getPairingData(ctx, key, nonce)        — Get pubkey + nonce for SPS1
10. Send SPS1, receive pod's SPS1
11. setPeerData(ctx, peerKey, peerNonce)   — Compute shared secret + LTK via KDF
--- SPS2.1 (C3422a ConfirmationValueControllerNode, index=1) ---
12. getMyConfValSize(ctx, 1)               — Returns cert[1]+8 (SHORT path: cert+tag only)
13. calcConfValue(ctx, buf, 1)             — Generate SPS2.1 payload (INS02PG1 cert + CCM tag)
14. verConfValue(ctx, peerBuf, 1)          — Verify pod's SPS2.1 (INS01PG1 cert + tag)
--- SPS2 (C3422a, index=0) ---
15. getMyConfValSize(ctx, 0)               — Returns cert[0]+72 (EXTENDED path: cert+sig+tag)
16. calcConfValue(ctx, buf, 0)             — Generate SPS2 payload (TLS cert + ECDSA sig + CCM tag)
17. verConfValue(ctx, peerBuf, 0)          — Verify pod's SPS2 (pod cert + sig + tag)
--- SP0/GP0 (C3425d PairingFinalizingState) ---
18. Send "SP0,GP0", receive P0 (0xa5 = success)
19. saveLtk(ctx, identifier)               — Persist LTK
20. saveAsCurrentActiveNode(identifier)    — Register active node in TwiCaching
21. deinit(ctx)                            — Clean up native context
```
Index=1 → SLPE "SPS2.1=" (SHORT path, cert-only), index=0 → SLPE "SPS2=" (EXTENDED path, cert+sig). The native decompile's ternary was inverted during reconstruction; btsnoop byte counts are the ground truth. OmnipodKit already implements this correctly.

#### `saveLtk()` — LOW RISK
Persists LTK + pairing state to encrypted SharedPreferences (TwiCaching). Called AFTER pairing succeeds. OmnipodKit stores LTK in Swift — the native storage is irrelevant for the current session.

#### `verifyCloudPublicKey()` — LOW RISK
Verification-only: validates Insulet's cloud certificate signature. Does not set pod-side state. Pod performs its own independent verification.
- **Phase 2 cannula insertion — ProgramBasal requires Type 4 signing (CURRENT BLOCKER, test #29)**: Phase 1 priming succeeds (test #28). Phase 2 `programBasal` causes immediate pod disconnect (CBError 7). MTU is NOT the issue (settles to 244 immediately). **Root cause**: ProgramBasal (0x13) is sent as Type 1 (encrypted only) but the O5 firmware requires it as **Type 4 (encrypted + ECDSA signed)**. The `specific_commands` whitelist from TWI device registration specifies which commands must be signed: `0x13 (ProgramBasal), 0x16 (ProgramTempBasal), 0x17 (ProgramBolus), 0x1c (DeactivatePod), 0x1f (ProgramBeep)`. Currently only ProgramBolus uses `o5Send()` (Type 4); ProgramBasal goes through `sendCommand()` (Type 1). **Fix needed**: route all `specific_commands` through the Type 4 signed path (`o5Send()`). Additional Frida comparison findings: (1) MCTF flag in inner message LSF should be 1 (true), OmnipodKit sends 0. (2) Beep parameter for ProgramBasal should be 0x40 (completion beep ON), OmnipodKit sends 0x00.
- **Command sequence counter**: Counter tracked in `TwiCaching` value (bytes 40-42), increments per command exchange. Must be persisted across reconnections. **Implementation needed.**
- **Session persistence**: `.twi_session` (4140 bytes, AES/GCM encrypted with `com.twi.enclave.session` key) stores session state. Must save/restore on reconnect. **Implementation needed.**
- ~~**Heartbeat keep-alive**~~: **NOT NEEDED.** Frida session (2026-02-15) confirmed the heartbeat service UUID `7DED7A6C` is NOT discovered on connected pods. Only three BLE services exist: GAP (0x1800), GATT (0x1801), and Omnipod custom (1a7e4024). The app polls via normal encrypted commands every ~20-30 seconds instead.
- ~~**Post-pairing command signing**~~: **PARTIALLY IMPLEMENTED**. Type 4 signing works for programBolus (0x17) via `o5Send()`. **Still needs implementation** for the other `specific_commands`: programBasal (0x13), programTempBasal (0x16), deactivatePod (0x1c), programBeep (0x1f). These currently go through the unsigned Type 1 path and cause immediate pod disconnect. See "TWi Message Type Signing Rules" section.
- ~~**Registration payload delivery**~~: **NOT NEEDED.** The btsnoop messages originally identified as registration payloads (frames 1925, 1939, 1952) were actually AlgorithmInsulinHistory (`SE2.1=`) AID commands. Sending the 163-byte binary blob caused CBError 7. Removed `o5SendRegistrationPayload()` and `sendRawO5DataExpectingAck()`.

## Post-Pairing Command Protocol (from Frida 2026-02-15 and Pod2 2026-02-16)

Captured from a running, pod-connected Omnipod 5 app using comprehensive Frida instrumentation. Pod1 session (2026-02-15, pod 2587929) provided steady-state command signing. Pod2 activation (2026-02-16, pod 2587930) provided the complete Phase 1 activation sequence with plaintext captures.

### TWi Message Type Signing Rules (Pod2 Frida + specific_commands whitelist, UPDATED 2026-02-17)

The O5 firmware enforces a `specific_commands` whitelist from the TWI device registration payload. Commands on the whitelist MUST be sent as Type 4 (encrypted + ECDSA signed); all others use Type 1 (encrypted only). Sending a whitelisted command as Type 1 causes immediate pod disconnect (CBError 7).

| TWi Type | AAD Byte | Signing | Used By |
|----------|----------|---------|---------|
| **Type 1** | `01` | Encrypted only, **no signature** | getPodVersion, all AID commands, setPodUid, programAlert, getPodStatus, configureAlerts |
| **Type 4** | `04` | Encrypted + **ECDSA signed** | **All `specific_commands`**: programBasal (0x13), programTempBasal (0x16), programBolus (0x17), deactivatePod (0x1c), programBeep (0x1f) |

The `specific_commands` whitelist is encoded in the TWI device registration as: `00 06 13 06 16 06 17 06 1c 06 1f` (each command byte preceded by `06`). This was confirmed by:
- Frida capture: ProgramBasal during Phase 2 sent as Type 4 (151 bytes = 87 encrypted + 64 signature)
- Test #29: ProgramBasal sent as Type 1 (87 bytes, no signature) → pod disconnected immediately
- `POD2_O5APP_BTSNOOP_HCI.md` line 1010-1018: decoded `specific_commands` field

### Inner Omnipod Message Address Rules (Pod2 Frida, 2026-02-16)

There are two levels of addressing in the O5 protocol:
1. **TWi header (outer)**: source/destination IDs in the 16-byte header. Always controller/pod IDs from pairing.
2. **Inner Message address**: 4-byte address at bytes 0-3 of the Omnipod Message struct inside the encrypted payload.

The inner address transitions from `0xFFFFFFFF` to the assigned pod address **immediately after setPodUid completes**:

| # | Command | Inner Address | Has Message Wrapper? | Frida Evidence |
|---|---------|--------------|---------------------|----------------|
| 0 | getPodVersion | `0xFFFFFFFF` | Yes (`S0.0=` + Message) | Line 844: `ffffffff0006...` |
| 1-9 | All AID commands | **N/A** | **No** (raw SLPE, no Message struct) | Lines 957-2134: raw ASCII payloads |
| 10 | setPodUid | `0xFFFFFFFF` | Yes (`S0.0=` + Message) | Line 2256: `ffffffff0815...` |
| 11+ | programAlert, programBolus, getPodStatus | **assigned podId** (e.g., `0x00277d1a`) | Yes (`S0.0=` + Message) | Lines 2371+: `00277d1a...` |

**Key insight**: O5 AID commands (`SE255.2=`, `S3.2=`, `G3.12`, etc.) bypass the inner Message struct entirely. They are raw SLPE-formatted ASCII payloads with no address, sequence, or CRC fields. Only legacy/ER commands (`S0.0=...,G0.0`) have the inner Message wrapper.

OmnipodKit implementation is correct: `sendO5AidCommand()` sends raw SLPE payloads; `getPodVersion` and `setPodUid` use `0xffffffff`; post-SetupPod commands use `podState.address`.

### Type 4 Message Signing Flow (EncryptedSignedMessage)

For Type 4 messages, the ECDSA signature covers the **complete encrypted message**, NOT the plaintext:

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

Full command cycle (validated by Pod2 Frida, 2026-02-16):
1. **WRITE** on `2443` (data) — send encrypted command (+ 64B ECDSA signature for Type 4 only)
2. **NOTIFY** on `2441` (control) — pod sends `04 00 01 00 00` (SUCCESS acknowledgment)
3. **NOTIFY** on `2443` (data) — pod sends encrypted response
4. **WRITE** on `2441` (control) — controller sends `04` (acknowledgment byte)
5. **ACK** on `2443` (data) — AES-CCM with empty plaintext, 31 bytes: `[7B frag] + [16B AAD] + [8B tag]`

BLE writes include a **7-byte fragmentation header** before the TWi packet data.
Pattern: `0000XXXXXXXXXXXX` (first 2 bytes `0000`, remaining 5 vary per message).

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

## EAP-AKA Role Reversal (Confirmed by Omnipod5APK Reverse Engineering, 2026-02-17)

The Omnipod 5 app implements an **EAP-AKA role reversal** between initial pairing and post-pairing sessions. The TWI SDK exposes two distinct classes — `TwiEapAka` (master/authenticator) and `TwiEapAkaSlave` (slave/supplicant) — and the phone app uses **both**, switching role based on the connection phase.

### During Initial Pairing: Phone = Master, Pod = Slave

The phone drives the EAP-AKA exchange as the authenticator:

| Component | Class (obfuscated) | Class (renamed) | SDK class |
|-----------|-------------------|-----------------|-----------|
| EncryptionContext | `aNW` | `PairingContext` | — |
| EAP handler | `aNU` | `EapAkaHandler` | `TwiEapAka` (master) |

- `PairingContext` creates `EapAkaHandler` at `PairingContext.java:1816`
- `EapAkaHandler` creates `new TwiEapAka(context, identifier)` at `EapAkaHandler.java:169`
- The phone **initiates** the session by calling `startSession()` at `EapAkaHandler.java:180`
- Identifier: dynamic, from `PairingContext.f24548a` (pairing-specific identity bytes)
- The pod responds to the phone's EAP-AKA challenge as the supplicant

### During Reconnection (post-pairing): Phone = Slave, Pod = Master

The pod drives the EAP-AKA exchange as the authenticator:

| Component | Class (obfuscated) | Class (renamed) | SDK class |
|-----------|-------------------|-----------------|-----------|
| EncryptionContext | `aNX` | `EapAkaAuthenticator` | — |
| EAP handler | `aOb` / `C7139aOb` | `EapAkaSlaveManager` | `TwiEapAkaSlave` (slave) |

- `EapAkaAuthenticator` creates `EapAkaSlaveManager` at `EapAkaAuthenticator.java:670`
- `EapAkaSlaveManager` creates `new TwiEapAkaSlave(context, identifier)` at `EapAkaSlaveManager.java:197`
- The phone does **NOT** call `startSession()` — it calls `init(0)` and waits passively
- Identifier: **hardcoded** `{-52, -52, -52, -52}` (`0xCCCCCCCC`) at `EapAkaAuthenticator.java:1024`
- The pod initiates the EAP-AKA challenge; the phone responds as supplicant
- Log tags: `"EapAkaSlaveModule"`, `"SecuritySlaveManager"`

### Role Selection Logic

The role is determined by the `EnumC3403a` enum in `C7095aMj.java`:

| Enum value | String | Ordinal | Phone role |
|-----------|--------|---------|------------|
| `f24314b` | `"Master"` | 0 | EAP-AKA Master (pairing) |
| `f24316d` | `"Slave"` | 1 | EAP-AKA Slave (reconnection) |
| `f24313a` | `"None"` | 2 | No role |

The branch in `RunnableC7090aMe.java` (the connection manager):
- Line 2362: `if (mode == "Slave")` → creates `EapAkaAuthenticator` (slave path, `TwiEapAkaSlave`)
- Line 2262: else → creates `PairingContext` (master path, `TwiEapAka`)

### Key Behavioral Differences

| Aspect | Pairing (Phone=Master) | Reconnection (Phone=Slave) |
|--------|----------------------|---------------------------|
| SDK class | `TwiEapAka` | `TwiEapAkaSlave` |
| Session initiation | Phone calls `startSession()` | Phone waits; pod initiates |
| Identifier | Dynamic (from pairing context) | Hardcoded `0xCCCCCCCC` |
| On success | Creates `MessageEncryptor`, signals pairing complete | Creates `MessageEncryptor`, signals session ready |
| 5-second timeout | Yes (handler-based) | Yes (handler-based) |
| State enum values | `START`, `SESSION_FAILED`, `RESYNC` | `START`, `SESSION_FAILED`, `RESYNC_COUNT_REACH_MAX`, `INVALID` |

### Implications for OmnipodKit

**SECONDARY mode is ELIMINATED** (tests #24 and #25). OmnipodKit uses PRIMARY mode for all sessions, which is correct.

1. **Initial pairing**: PRIMARY mode (phone = master, phone initiates). Correct and working.
2. **Post-pairing sessions**: PRIMARY mode. Test #25 proved SECONDARY fails on reconnection (44 consecutive attempts, pod never sent a challenge). The Android `TwiEapAkaSlave` class naming does not reflect wire-level behavior — the TWI SDK may handle the EAP-AKA protocol differently internally (e.g., the native library may still use PRIMARY-style initiation under the hood despite the Java wrapper being called "slave").
3. ~~**TwiSecurityIdentifier `0xCCCCCCCC`**~~: Moot — SECONDARY mode eliminated, slave identifier not needed.
4. **Test results**: Test #24 — pod disconnected immediately in SECONDARY during post-pairing session. Test #25 — 44 consecutive reconnection attempts in SECONDARY, all failed with deadlock (pod expects phone to speak first).

## O5 Phase 1 Activation Flow (Pod2 Frida-Validated, 2026-02-16)

The complete Phase 1 activation sequence, validated against a live Pod2 activation (pdmid 2587928, podId 0x277d1a). See `POST_PAIR_COMMANDS.md` for full byte-level encoding details.

### Activation Command Sequence

```
EAP-AKA Success
    |
    v
Phase 0: getPodVersion (0x07)                    [Type 1, 26B plaintext]
    |     AssignAddress with 0xFFFFFFFF
    |     Response: FW 4.23.1.21, productId=5, state=FILLED
    v
O5 AID Setup (8 commands, all Type 1):
    1. UtcCommand          SE255.2=[unix_timestamp]              (ASCII)
    2. TdiCommand          S3.2=[binary 5B],G3.2                 (TDI=14U, 15B total)
    3. TargetBgProfile     S3.1=[binary 196B],G3.1               (110 mg/dL, 204B total)
    4. DiaCommand          S3.9=8,G3.9                           (DIA=8 hours, ASCII)
    5. EgvCommand          S3.7=3670015,G3.7                     (Low=55, ASCII)
    6-8. AlgorithmInsulinHistory x3  SE2.1=[binary 168B]         (176B total each)
    9. UnifiedAidPodStatus G3.12
    --- "activation (QN setup) 0/2 finished" ---
    |
    v
Phase 1: Pod Setup ("activation 1/2"):
    10. setPodUid (0x03)                          [Type 1, 41B] state->UID_SET
    11. programAlert slot #4: low reservoir       [Type 1, 32B] 10U threshold
    12. programAlert slot #7: LOC/setup reminder  [Type 1, 32B] 5min/55min
    13. programBolus: prime 1 (2.6U, 52 pulses)  [Type 4 SIGNED, 56B + 64B sig]
        ... poll getPodStatus page 7 until done (~52 sec) ...
    14. programAlert slot #3: user expiry         [Type 1, 32B] 3968 min (~66h8m)
    --- ACTIVATION_COMPLETED_PHASE_1 ---
```

### O5 AID Command SLPE Formats

Three wrapping formats for AID commands (distinct from legacy `S0.0=`/`,G0.0` wrapping):
- **SET+GET**: `S[feature].[attr]=[data],G[feature].[attr]` -- sets value and reads back confirmation
- **GET only**: `G[feature].[attr]` -- reads current value
- **Extended SET**: `SE[feature].[attr]=[data]` -- extended feature set, response prefix `ES[feature].[attr]=`

**Important**: Despite the name "SLPE", AID commands do NOT use `StringLengthPrefixEncoding` length prefixes. The key portion (`S3.2=`, `SE2.1=`, etc.) is always plain ASCII. The data portion after the `=` sign is either plain ASCII (for simple numeric values like UtcCommand, DiaCommand, EgvCommand) or **raw binary bytes** (for TdiCommand, TargetBgProfileCommand, AlgorithmInsulinHistoryCommand). The binary data commands use `setGetPayload(feature:attribute:binaryData:)` and `extendedSetPayload(feature:attribute:binaryData:)` variants. Only standard Omnipod commands (`S0.0=...,G0.0`) use the 2-byte big-endian length prefix from `StringLengthPrefixEncoding.formatKeys()`.

### Alert Parameters (Pod2 Frida-validated)

| Alert | Slot | BeepReps | BeepType | Duration | AlertType | Threshold |
|-------|------|----------|----------|----------|-----------|-----------|
| Low Reservoir | 4 | 1 | 2 | 0 | volume | 100 ticks (10U) |
| LOC/Setup Reminder | 7 | 8 | 2 | 55 min | time | 5 min |
| User Expiry | 3 | 3 | 2 | 0 | time | 3968 min (~66h8m) |

### Prime Bolus Parameters (Pod2 Frida-validated)

| Parameter | Value |
|-----------|-------|
| Pulses | 520 partial (52 pulses = 2.6U) |
| Delay | 100000 us (1 sec/pulse) |
| Beep | 0x7C (completion beep ON, 60min reminder) |
| Message type | 0x12 (WITH_PDM_VALUE) |
| TWi type | Type 4 (ECDSA signed) |

### Pod State Transitions During Activation

```
FILLED (2) -> [after setPodUid] -> UID_SET (3) -> [after programBolus prime] ->
ENGAGING_CLUTCH_DRIVE (4) -> [after prime completes] -> CLUTCH_DRIVE_ENGAGED (5)
```

### Key Corrections from Pod2 Frida

- **NO basal schedule before priming.** Basal is deferred to Phase 2. Historical btsnoop showed 3x ProgramBasal before prime -- that was a different app/firmware version.
- **Registration payload is NOT sent during activation.** The btsnoop messages originally identified as registration payloads were actually AlgorithmInsulinHistory (`SE2.1=`) AID commands (size coincidence: 184 bytes encrypted ~ 163 payload + overhead). Confirmed by both btsnoop re-analysis and Pod2 Frida captures.
- **Only programBolus uses Type 4 (signed).** All other Phase 1 commands use Type 1 (encrypted only). See "TWi Message Type Signing Rules" above.
- **Status polling uses page 7** (`0x0e 01 07`), not page 0.
- **Low reservoir threshold is 10U** (100 ticks, where ticks = volume / 0.05 / 2). Previously miscalculated as 5U.
- **User expiry at 3968 min (~66h8m)**, approximately 5h52m before 72h pod life.
- **Prime beep parameter is 0x7C**, not 0 (no beeps). Completion beep ON + 60min reminder.

## Next Steps / Implementation Checklist

Ordered steps to implement post-pairing pod communication in OmnipodKit.

### DONE (Phase 1 activation sequence implemented through SetUniqueId + alerts)
1. ~~**Type 4 signed message construction**~~ -- **DONE (construction implemented, but runtime failure — see item 6b).** Implemented in `PodCommsSession.o5Send()`. Only used for `programBolus` (prime/delivery). AAD(16) + ciphertext + tag(8) signed with secondary key, 64-byte raw r||s appended.
2. ~~**O5 AID setup commands**~~ -- **DONE.** 8 AID commands implemented in `O5AidCommands.swift`, called from `BlePodComms.swift` between getPodVersion and setPodUid. **Binary data fix (2026-02-17)**: TdiCommand, TargetBgProfileCommand, AlgorithmInsulinHistoryCommand now send raw binary bytes instead of ASCII hex text.
3. ~~**Phase 1 activation order**~~ -- **DONE.** Corrected to match Pod2 Frida: getPodVersion, AID setup, setPodUid, alerts, prime 1, poll, expiry alert. No basal before priming.
4. ~~**Alert parameters**~~ -- **DONE.** Low reservoir=10U (slot #4), LOC=5min/55min (slot #7), user expiry=3968min (slot #3, after prime). Prime beep=0x7C.
5. ~~**Registration payload delivery**~~ -- **REMOVED (misidentified).** The btsnoop messages originally identified as registration payloads were actually AlgorithmInsulinHistory (`SE2.1=`) AID commands. Sending the 163-byte binary blob in `S0.0=...G0.0` SLPE format caused CBError 7 pod disconnect. Removed `o5SendRegistrationPayload()` and `sendRawO5DataExpectingAck()`. Registration payload is NOT needed for activation.
5b. ~~**Error 33 at SetUniqueId**~~ -- **RESOLVED (Test #26, 2026-02-17).** Root cause: binary AID data encoding. Three AID commands sent ASCII hex text instead of raw binary bytes, corrupting pod algorithm state. Fix: `useBinaryAidData` flag + binary payload variants. SetUniqueId now succeeds (`progressStatus=Pairing completed`).

### TODO: Remaining Implementation
6. ~~**Resolve Error 33 at setPodUid — DONE (Test #26, 2026-02-17)**~~
   - Root cause: binary AID data encoding. Three AID commands sent ASCII hex text instead of raw binary bytes, leaving pod algorithm state invalid.
   - Fix: `useBinaryAidData` flag + binary payload variants in `O5AidCommands.swift`.
   - 12-hour hour format also confirmed correct (test #22, secondary cause).
   - pdmidExtension bug (`43008040` -> `4300804`) still pending fix in `O5RegistrationData.swift`.

6b. **Resolve Type 4 signed message failure (BLOCKING — prime bolus fails silently, NEW)**
   - Test #26: ProgramBolus (2.6U prime, Type 4 ECDSA-signed) fails — pod ACKs BLE write but never responds (`emptyValue` timeout, 4 retries).
   - ProgramAlert (Type 1, unsigned) works fine after SetUniqueId. Failure is specific to the signed message path.
   - ECDSA signature covers AAD(16) + ciphertext + tag(8), appended as 64-byte raw r||s.
   - Investigate: signing input construction, key selection, signature format, AAD/header bytes for Type 4 messages.
   - Compare Type 4 message byte-by-byte against Pod2 Frida reference (`/Users/james/Downloads/Pod2-o5app-beforeinsert.txt`).

7. **Implement command sequence counter management**
   - Track counter per session (observed: `9f492c` → `9f4935`, incrementing per command exchange)
   - Persist counter in session state for reconnection
   - Counter appears in TWi header and TwiCaching value (bytes 43-45)

8. **Implement ACK message construction**
   - ACK = AES-CCM encrypt with empty plaintext, producing 8-byte tag only
   - ACK is written to control characteristic (`2441`) after receiving pod response on data characteristic (`2443`)
   - ACK AAD uses type byte `81` (acknowledgment frame)

9. **Implement BLE fragmentation header**
   - 7-byte fragmentation header prepended to TWi packet on BLE writes
   - Parse incoming fragments and reassemble TWi packets
   - Pattern: `0000XXXXXXXXXXXX` where first 2 bytes are `0000`, remaining 5 vary per message

10. **Implement Phase 2 activation** (after prime 1 completes)
    - ProgramBasal: full 24-hour basal schedule (first Phase 2 command, state ACTIVATION_PROGRAMMED_BASAL)
    - ProgramAlert: clear LOC (#7), program system expiry (#2), shutdown imminent (#0, beepRepeat=every5Minutes(8)), auto-off (#0, duration=15min, autoOff=true, beepRepeat=2)
    - ProgramBolus: prime 2 / cannula fill (Type 4 signed)
    - CGM activation
    - Final status verification

11. **Implement session persistence (save/restore)**
    - Save: LTK derivative, nonce state, command counter, pod ID, session metadata
    - Restore: reload on app restart for reconnection without re-pairing
    - Model after TwiCaching 93-byte value structure

12. **Implement reconnection using stored session**
    - Skip pairing flow when LTK exists
    - Resume AES-CCM encryption with persisted nonce/counter state
    - Re-establish BLE subscriptions (NOTIFY on 2443, INDICATE on 2441)

13. **End-to-end test: complete Phase 1 activation on a real pod**
    - Verify full sequence: getPodVersion through expiry alert
    - Compare BLE traffic against Pod2 Frida captures
    - Confirm pod state transitions: FILLED -> UID_SET -> ENGAGING_CLUTCH_DRIVE -> CLUTCH_DRIVE_ENGAGED

## Debugging Reference (Quick Guide for New Agents)

This section consolidates the most critical debugging knowledge from 25+ test iterations. Read this FIRST when investigating O5 activation failures.

### Pod Failure Modes and What They Mean

**1. Pod disconnects (CBError code=7) after HELLO or during EAP-AKA:**
- Double HELLO: `blePairAndSetupPod()` established a second EAP-AKA session when `completeConfiguration()` already did. Check `needsSessionEstablishment` flag.
- RTS sent to O5 pod: O5 NEVER uses RTS/CTS. Check that `doRTS=false` for all O5 code paths.
- Tainted pod: pod was used in a failed attempt. Manufacturer data byte changes `0x00` to `0x80`. Use a factory-fresh pod.
- Malformed non-SLPE data sent as standard command: Sending raw binary data (e.g., registration payload) wrapped in `S0.0=...G0.0` SLPE format causes immediate disconnect. The pod cannot parse arbitrary binary blobs as Omnipod Messages.

**2. "Pod ACKs but no data response" (`emptyValue` error):**
When the pod sends SUCCESS (0x04) on the CMD characteristic but never sends data on the DATA characteristic, it means the pod received and parsed the TWi frame correctly but could NOT process the inner payload. The pod does NOT send error responses for crypto/parse failures -- it just silently drops the command. Common causes:
- **Wrong nonce state**: AES-CCM decrypt failure. Typically caused by a double command (e.g., double getPodVersion shifting nonce by 3) or a rejected command that still incremented the nonce.
- **Malformed inner payload**: Wrong SLPE format (e.g., using `formatKeys()` length prefixes for AID commands which should be plain ASCII).
- **Missing getPodVersion**: `getPodVersion` (AssignAddress with 0xffffffff) MUST be the first encrypted command after each new EAP-AKA session. Without it, the pod ignores subsequent commands.
- **Command not valid for pod state**: Pod at FILLED (state 2) rejects GetStatus with error 19, but the error response itself desynchronizes nonce state, causing the NEXT command to fail silently.
- **Type 4 ECDSA signature issue (NEW, test #26)**: ProgramBolus (Type 4 signed) fails silently while ProgramAlert (Type 1 unsigned) succeeds on the same session. If you see `emptyValue` specifically on programBolus after setPodUid and programAlert succeed, the issue is in the ECDSA signing path, not in general encryption or nonce state.

**3. Pod responds with wrong data format (`unknownBlockType`):**
- Check the SLPE GET suffix. Standard Omnipod commands must use `,G0.0` (not `,G3.12`). AID-specific commands use their own suffixes.
- `,G3.12` tells the pod to respond in AID status format (`3.12=` prefix) instead of standard format (`0.0=` prefix).

### AID Commands vs Standard Omnipod Commands (CRITICAL DISTINCTION)

These are two COMPLETELY DIFFERENT payload formats that share the same BLE transport:

| Aspect | Standard Omnipod Commands | O5 AID Commands |
|--------|--------------------------|-----------------|
| Examples | getPodVersion, setPodUid, programAlert, programBolus | UtcCommand, TdiCommand, TargetBgProfile, EgvCommand |
| SLPE wrapping | `S0.0=` + 2-byte length + Message bytes + `,G0.0` | ASCII key + data: `SE255.2=1771222561` (ASCII data) or `S3.2=` + raw binary bytes + `,G3.2` (binary data) |
| Length prefix | YES -- `StringLengthPrefixEncoding.formatKeys()` adds 2-byte big-endian length | **NO** -- plain string concatenation, no length bytes. Data portion is raw binary for TdiCommand, TargetBgProfile, AlgorithmInsulinHistory; ASCII for others. |
| Inner Message struct | YES -- 4-byte address + sequence + CRC at bytes 0-3 | **NO** -- raw ASCII key-value, no address/sequence/CRC |
| Response parsing | `StringLengthPrefixEncoding.parseKeys()` strips `0.0=` prefix + length | Strip ASCII prefix (e.g., `ES255.2=`, `3.2=`) directly from string |
| Implementation | `PodCommsSession` / `BleMessageTransport.getCmdMessage()` | `O5AidCommands.swift` / `BlePodComms.sendO5AidCommand()` |
| Frida reference | Payload starts with `ffffffff0006...` (hex of Message struct) | Payload is raw ASCII bytes: `53453235352E323D...` = `"SE255.2=..."` |

**Test #21 root cause**: `O5AidCommands` used `StringLengthPrefixEncoding.formatKeys()` which added 2-byte length prefixes. Frida shows the real app sends `"SE255.2=1771222561"` (18 bytes, plain ASCII). OmnipodKit was sending `"SE255.2=" + 0x000A + "1771276453"` (20 bytes, with length prefix). Pod received it, ACKed transport, but couldn't parse the inner payload.

### Double getPodVersion Prevention

`getPodVersion` (AssignAddress with address 0xffffffff) is sent at two points in the code:
1. **Inside `pairPod()`**: Sent as the last step of normal pairing, after EAP-AKA success.
2. **Inside `blePairAndSetupPod()`**: Sent before `o5PreSetupSteps()`, needed for the resume path when `pairPod()` was skipped.

On the initial pairing path, BOTH would run, causing a double getPodVersion. Each getPodVersion exchange shifts nonce state by 3 (encrypt command, decrypt response, encrypt ACK). The second one succeeds but leaves the nonce out of sync for subsequent AID commands.

**Fix**: `pairPodRanGetPodVersion` boolean flag is set to `true` when `pairPod()` runs. The `blePairAndSetupPod()` getPodVersion is only sent when this flag is `false` (resume path where `pairPod()` was skipped).

### Pod Progress States and Valid Commands

| State | Value | Name | Valid Commands | Invalid Commands |
|-------|-------|------|---------------|-----------------|
| 2 | FILLED | "Reminder initialized" (fresh O5 pod) | getPodVersion, AID commands, setPodUid | GetStatus (error 19) |
| 3 | UID_SET | "pairingCompleted" (after setPodUid) | programAlert, programBolus, getPodStatus | -- |
| 4 | ENGAGING_CLUTCH_DRIVE | (during prime) | getPodStatus (polling) | -- |
| 5 | CLUTCH_DRIVE_ENGAGED | (prime complete) | programAlert, Phase 2 commands | -- |

**Key rule**: GetStatus does NOT work at state 2 (FILLED). Sending it causes error 19 (`ERR_ILLEGAL_CMD_STATE`). The error response itself is a valid encrypted exchange that increments the nonce, so subsequent commands will use wrong nonce and fail silently with `emptyValue`.

### Session Establishment Rules

1. Each new BLE connection needs HELLO (0x06 on CMD char) + EAP-AKA before encrypted commands work.
2. You CANNOT establish two EAP-AKA sessions on the same connection -- pod disconnects (CBError 7) on second HELLO.
3. `needsSessionEstablishment` flag tracks whether `completeConfiguration()` already established a session.
4. **O5 messageNumber reset**: The inner Omnipod Message sequence number (`messageNumber`) must be reset to 0 after each O5 EAP-AKA session establishment. Frida confirms: getPodVersion(seq=0) → setPodUid(seq=2). `establishSession()` now resets `omnipodMessageNumber = 0` for O5 pods. On fresh pairing this was natural (podState nil → default 0), but on reconnect the stale value caused wrong sequence numbers.
5. `blePairAndSetupPod()` has three-branch logic:
   - **Fresh pair**: `pairPod()` handles HELLO + EAP-AKA + getPodVersion internally.
   - **Session already active** (`!needsSessionEstablishment` and `ck` valid): Skip HELLO + EAP-AKA entirely.
   - **Need new session** (reconnect with no active session): Send HELLO + establish EAP-AKA + getPodVersion.

### Firmware Version Differences

| Source | Firmware | Notes |
|--------|----------|-------|
| Pod2 Frida capture (reference) | FW 4.23.1.21, productId=5 | All protocol analysis and byte-level validation is based on this version |
| Recent test pods (2026-02-16) | FW 9.0.4 / 6.0.0 | Different firmware, same protocol so far. VersionResponse parsing may display differently depending on code path. |

Protocol behavior has been consistent across firmware versions tested, but be aware the reference captures are from 4.23.1.21.

### Comparing OmnipodKit Output Against Frida Reference

The primary reference for correct command encoding is the Pod2 Frida capture:
`/Users/james/Downloads/Pod2-o5app-beforeinsert.txt`

**For AID commands:**
- Frida logs each AID command as: `[pod-log] ... AID/QN Pod command: <Name>: <hex of ASCII payload>`
- The hex is the raw ASCII bytes, e.g., `53453235352E323D31373731323232353631` = `"SE255.2=1771222561"`
- OmnipodKit logs: `O5 AID Send: <name> payload=<ascii string> (<N> bytes)`
- Convert the Frida hex to ASCII and compare character-by-character against OmnipodKit's payload string.

**For standard commands (getPodVersion, setPodUid, programAlert, programBolus):**
- Frida logs plaintext as hex of the inner Message struct: `ffffffff0006...` (starts with 4-byte address)
- OmnipodKit logs the Message hex before encryption in `o5Send()`.
- Compare the hex bytes directly.

**For encrypted output:**
- Encrypted content will DIFFER between runs (different ephemeral keys, nonces, timestamps).
- Sizes and framing MUST match: same number of bytes, same TWi header structure, same SLPE prefix format.

### Key Log Patterns for Debugging

| Log Pattern | Meaning | Action |
|-------------|---------|--------|
| `[BLE RAW] WRITE ... type=withoutResponse` | Outgoing BLE write | Verify `withoutResponse` for O5 (not `withResponse`) |
| `[BLE RAW] CMD RECV: 0400010000` | Pod SUCCESS acknowledgment on CMD char | Transport OK, but does NOT mean command succeeded |
| `waitForCommand: got expected 0x04` | Transport-level ACK received | Good -- pod received the TWi frame |
| `Error reading message: emptyValue` | Pod didn't respond with data after ACK | Decrypt/parse failure -- see "Pod ACKs but no data response" above |
| `Disconnecting due to unresponsive pod` | OmnipodKit-initiated disconnect after timeout | Preceded by `emptyValue` -- check nonce state and payload format |
| `CBError code=7` | Pod-initiated BLE disconnect | Double HELLO, RTS on O5, or tainted pod state |
| `unknownBlockType(rawVal: 0)` | Response has wrong SLPE prefix format | Check GET suffix: should be `,G0.0` for standard commands |
| `Error reading message: podReturnedErrorCode(19)` | Pod rejected command (ERR_ILLEGAL_CMD_STATE) | Command not valid for pod's current progress state |
| `O5 AID Send: <name> payload=...` | AID command being sent | Compare payload string against Frida hex reference |
| `Session already established by completeConfiguration` | EAP-AKA session reuse | Good -- avoids double session establishment |
| `pairPodRanGetPodVersion=true, skipping second getPodVersion` | Double-getPodVersion prevention | Good -- prevents nonce desync |
| `emptyValue` on programBolus after programAlert succeeds | Type 4 ECDSA signing failure (test #26) | Signing path issue, not general crypto -- Type 1 commands work fine on same session |

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

### Frida session captures
**Pod1 steady-state session (2026-02-15, pod 2587929)**:
All in `/Users/james/Downloads/O5keys/KEYS/`:
- `frida_output_20260215_215748.log` — Complete Frida instrumentation log: BLE state dump, AES-CCM encrypt/decrypt, ECDSA signing, TwiCaching updates, session files, AndroidKeyStore enumeration
- `FRIDA_QUESTIONS.md` — Prioritized extraction plan documenting what to hook and why

**Pod2 activation session (2026-02-16, pod 2587930)**:
- `/Users/james/Downloads/Pod2-o5app-beforeinsert.txt` — Complete Frida log of Pod2 Phase 1 activation (pdmid 2587928, podId 0x277d1a). Includes AES-CCM plaintext captures for all commands, BLE write hex, ECDSA signing for prime bolus, pod state transitions (FILLED -> UID_SET -> ENGAGING_CLUTCH_DRIVE -> CLUTCH_DRIVE_ENGAGED). Primary source for the corrected activation order and alert parameters.

### Post-pairing command reference
- `/Users/james/repos/Omnipod5APK/POST_PAIR_COMMANDS.md` — Complete post-pairing command sequence documentation. Includes byte-level encoding for all commands (GetVersion, SetUniqueId, ProgramAlert, ProgramBolus, ProgramBasal, GetPodStatus, etc.), O5 AID command format, TWi message type signing rules, alert configurations, insulin schedule encoding, and full Phase 1/Phase 2 activation sequence validated against Pod2 Frida capture.

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
