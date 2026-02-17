//
//  O5SavedPairingResult.swift
//  OmnipodKit
//
//  Debug helper: stores pairing details from a previous successful O5 pairing
//  so we can skip LTK exchange and reconnect directly to a pod for testing.
//

import Foundation

struct O5SavedPairingResult {
    /// Human-readable label for logging
    let name: String
    /// CoreBluetooth peripheral UUID
    let bleUUID: String
    /// 16-byte LTK as hex string
    let ltk: String
    /// Pod address (UInt32)
    let podAddress: UInt32
    /// TWi message sequence number at end of pairing
    let msgSeq: UInt8
    /// EAP-AKA sequence number for next session (1 = first session, 2+ = re-establishment)
    let eapSeq: Int

    // MARK: - Saved sessions

    /// Pod1 — first successful pairing (2026-02-15, pdmid 2587928)
    static let pod1 = O5SavedPairingResult(
        name: "Pod1 (2026-02-15)",
        bleUUID: "74CF60D7-6A27-EED6-9C1D-BDA1ACA5546F",
        ltk: "f43fde8e37f453bca32a5c448b2abe52",
        podAddress: 0x277d19,
        msgSeq: 6,
        eapSeq: 1
    )

    /// Pod3 — successful pairing (2026-02-16, pdmid 2587928), one EAP session already established
    static let pod3 = O5SavedPairingResult(
        name: "Pod3 (2026-02-16)",
        bleUUID: "F72CE383-DD81-63CF-DB56-EA07A42475F1",
        ltk: "e61bdad7be42488d91bba7b848d13803",
        podAddress: 0x277d19,
        msgSeq: 8,
        eapSeq: 2
    )

    /// Pod4 — successful pairing (2026-02-16 ~11:30pm, pdmid 2584724 = 0x277094)
    /// Pairing completed (P0=0xa5) but post-pairing EAP-AKA session establishment
    /// failed due to BLE disconnect (CBErrorDomain code=7). No EAP session was ever
    /// established, so eapSeq=1. The pod is paired but needs session establishment.
    /// Pod cert serial: 6f590e4f97e114c400ecc689e7b9056839810210
    /// Config#10 [00001010] — kdfZeroControllerID=true
    static let pod4 = O5SavedPairingResult(
        name: "Pod4 (2026-02-16 11:30pm)",
        bleUUID: "3FE369C7-22A0-2344-5393-EB967FB49AE3",
        ltk: "4f1da4ab399c275afdb8be816adb2089",
        podAddress: 0x277095,
        msgSeq: 6,
        eapSeq: 1
    )
}
