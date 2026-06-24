//
//  O5CommLogFixtures.swift
//  OmniTests
//
//  Hex command/response bodies from Loop device communication log exports.
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

    // MARK: - AID activation

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

    // MARK: - VersionResponse

    static let assignVersionResponse = hex("011509000306000205020e986131000818a305a741afa203b8")
    static let assignVersionResponseAddress: UInt32 = 0xA741AFA2
    static let setupVersionResponse = hex("011b13881008340a5009000306000205030e986131000818a3002a1c6e02b5")
    static let capturedLot: UInt32 = 0x0E986131
    static let capturedTid: UInt32 = 0x000818A3
    static let capturedPodAddress: UInt32 = 0x002A1C6E

    // MARK: - BolusExtraCommand 0x12

    static let oneUnitBolusExtra = hex("17120000c800030d400000000000000100c80000")
    static let primeBolusExtra = hex("1712000208000186a00000000000000100000000")
    static let cannulaBolusExtra = hex("1712000064000186a00000000000000100000000")

}
