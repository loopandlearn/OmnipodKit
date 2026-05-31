//
//  O5CommLogFixtures.swift
//  OmniTests
//
//  Send/receive payloads from Loop diagnostic report “Device Communication Log” (and the same
//  hex in HealthKit Export DeviceLog.json). Not RF/BLE packet captures (cf. openomni / Eros).
//
//  Captured while EJ was running Loop with an Omnipod 5 pod.
//
//  Reports:
//  - Loop Report 2026-05-31 10:22:22+02:00 EJ 0 insulin test.md  (pod activation, setup/prime)
//  - Loop Report 2026-05-31 13:54:21+02:00 EJ O5 test.md           (activation + manual 1.0 U bolus)
//  - Export-20260531T115736Z.zip / DeviceLog.json                  (cross-check; same hex)
//
//  Loop build at capture (from report Build Details):
//  - Loop DEV v3.14.1 (57), workspace branch feat/omnipodkit @ dae26a6
//  - OmnipodKit submodule: jwoglom/osaid-keymanager @ 9d58e05
//    (PKI/App Attest paths are out of scope for these tests; AID/bolus payloads match main builders.)
//
//  Active pod in primary capture (002A1C6E, activated 2026-05-31 08:06:34 UTC):
//  - Pod address / ID: 002A1C6E
//  - Controller ID (PDM): 002A1C6C
//  - Pod firmware: 9.0.3 (BLE 6.0.2), hardware 5
//  - Lot (decimal from PodState): 244867377, sequence: 530595
//  - Lot/TID in assign/version frames (hex): 0e986131 / 000818a3 (see comm log ffffffff0815… / …0c1d01…)
//
//  Secondary pod (002A1C6D, 2026-05-28): same AID/TDI/profile defaults; UTC timestamp differs;
//  1.0 U bolus 0x12 block matches 002A1C6E (2026-05-28 15:33:22 UTC).
//
//  Encoding notes:
//  - AID commands are UTF-8 ASCII in the comm log (not SLPE length-prefixed).
//  - BolusExtraCommand O5 uses subtype 0x12; beep/options byte in log is 0x00 (not 0x7c in source comments).
//

import Foundation
@testable import OmnipodKit

enum O5CommLogFixtures {

    private static func hex(_ string: String) -> Data {
        guard let data = Data(hexadecimalString: string) else {
            fatalError("Invalid fixture hex: \(string)")
        }
        return data
    }

    // MARK: - AID activation (2026-05-31 08:06:32 UTC, pod 002A1C6E)

    static let utcSend = hex("53453235352e323d31373830323134373932")
    static let utcRecvBody = hex("30")

    static let tdiSend = hex("53332e323d0003000e002c47332e32")
    static let tdiRecvBody = hex("0003000e00")

    static let diaSend = hex("53332e393d382c47332e39")
    static let diaRecvBody = hex("38")

    static let egvSend = hex("53332e373d333637303031352c47332e37")
    static let egvRecvBody = hex("33363730303135")

    static let insulinHistorySendPrefix = hex("5345322e313d00a8")
    static let insulinHistoryRecvBody = hex("30")

    /// Unix timestamp ASCII embedded in `utcSend` (`SE255.2=…`).
    static let utcTimestamp: UInt64 = 1780214792

    static let egvValue = "3670015"
    static let diaValue = "8"
    static let targetMgdl: UInt32 = 0x6e

    static let targetBgProfileSend: Data = {
        var data = hex("53332e313d00c0")
        for _ in 0..<48 {
            data.appendBigEndian(targetMgdl)
        }
        data.append(hex("2c47332e31"))
        return data
    }()

    static let targetBgProfileRecvBody: Data = {
        var data = hex("00c0")
        for _ in 0..<48 {
            data.appendBigEndian(targetMgdl)
        }
        return data
    }()

    static let algorithmInsulinHistorySend: Data = {
        var data = insulinHistorySendPrefix
        data.append(Data(count: 168))
        return data
    }()

    // MARK: - BolusExtraCommand 0x12 (20-byte block from comm log)

    static let oneUnitBolusExtra = hex("17120000c800030d400000000000000100c80000")
    static let primeBolusExtra = hex("1712000208000186a00000000000000100000000")
    static let cannulaBolusExtra = hex("1712000064000186a00000000000000100000000")

}
