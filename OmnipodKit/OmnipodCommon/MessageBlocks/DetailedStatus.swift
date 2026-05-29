//
//  DetailedStatus.swift
//  OmnipodKit
//
//  From OmniBLE/OmnipodCommon/MessageBlocks/DetailedStatus.swift
//  Created by Pete Schwamb on 2/23/18.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//
import Foundation

// DetailedStatus is the PodInfo subtype 2 returned for a type 2 GetStatus command and
// is also returned on a pod fault for any command normally returning a StatusResponse
struct DetailedStatus: PodInfo, Equatable {
    // CMD 1  2  3  4  5 6  7  8 9 10 1112 1314 1516 17 18 19 20 21 2223
    // DATA   0  1  2  3 4  5  6 7  8  910 1112 1314 15 16 17 18 19 2021
    // 02 16 02 0J 0K LLLL MM NNNN PP QQQQ RRRR SSSS TT UU VV WW XX YYYY

    let podInfoType: PodInfoResponseSubType = .detailedStatus
    let podProgressStatus: PodProgressStatus
    let deliveryStatus: DeliveryStatus
    let bolusNotDelivered: Double
    let lastProgrammingMessageSeqNum: UInt8 // updated by pod for 03, 08, $11, $19, $1A, $1C, $1E & $1F command messages
    let totalInsulinDelivered: Double
    let faultEventCode: FaultEventCode
    let faultEventTimeSinceActivation: TimeInterval?
    let reservoirLevel: Double
    let timeActive: TimeInterval
    let unacknowledgedAlerts: AlertSet
    let faultAccessingTables: Bool
    let errorEventInfo: ErrorEventInfo?
    let receiverLowGain: UInt8
    let radioRSSI: UInt8
    let previousPodProgressStatus: PodProgressStatus?
    let possibleFaultCallingAddress: UInt16?
    let data: Data

    init(encodedData: Data) throws {
        guard encodedData.count >= 22 else {
            throw MessageBlockError.notEnoughData
        }

        guard PodProgressStatus(rawValue: encodedData[1]) != nil else {
            throw MessageError.unknownValue(value: encodedData[1], typeDescription: "PodProgressStatus")
        }
        self.podProgressStatus = PodProgressStatus(rawValue: encodedData[1])!

        self.bolusNotDelivered = Double((Int(encodedData[3] & 0x3) << 8) | Int(encodedData[4])) / Pod.pulsesPerUnit

        self.lastProgrammingMessageSeqNum = encodedData[5]

        self.totalInsulinDelivered = Double(encodedData[6...7].toBigEndian(UInt16.self)) / Pod.pulsesPerUnit

        self.faultEventCode = FaultEventCode(rawValue: encodedData[8])

        /// Older pod simulators didn't know that all faulted pods are suspended, so handle this here
        if self.faultEventCode.faultType != .noFaults {
            self.deliveryStatus = .suspended
        } else {
            self.deliveryStatus = DeliveryStatus(rawValue: encodedData[2] & 0xf)!
        }

        let minutesSinceActivation = encodedData[9...10].toBigEndian(UInt16.self)
        if minutesSinceActivation != 0xffff {
            self.faultEventTimeSinceActivation = TimeInterval(minutes: Double(minutesSinceActivation))
        } else {
            self.faultEventTimeSinceActivation = nil
        }

        self.reservoirLevel = Double((Int(encodedData[11] & 0x3) << 8) + Int(encodedData[12])) / Pod.pulsesPerUnit

        self.timeActive = TimeInterval(minutes: Double(encodedData[13...14].toBigEndian(UInt16.self)))

        self.unacknowledgedAlerts = AlertSet(rawValue: encodedData[15])

        self.faultAccessingTables = (encodedData[16] & 2) != 0

        if encodedData[17] == 0x00 {
            // no fault has occurred, errorEventInfo and previousPodProgressStatus not valid
            self.errorEventInfo = nil
            self.previousPodProgressStatus = nil
        } else {
            // fault has occurred, VV byte contains valid fault info
            let errorEventInfo = ErrorEventInfo(rawValue: encodedData[17])
            self.errorEventInfo = errorEventInfo
            // errorEventInfo.podProgressStatus is valid for both Eros and Dash on fault
            self.previousPodProgressStatus = errorEventInfo.podProgressStatus
        }

        // For Dash these values have always been zero
        self.receiverLowGain = UInt8(encodedData[18] >> 6)
        self.radioRSSI = UInt8(encodedData[18] & 0x3F)

        // For Eros, encodedData[19] (XX) byte is the same previousPodProgressStatus nibble in the VV byte on fault.
        // For Dash, encodedData[19] (XX) byte is uninitialized or unknown, so use VV byte for previousPodProgressStatus.

        // YYYY is only valid if there was a pod fault (PP != 0) on a Dash pod (WW == 0)
        // For Eros faults, YYYY is always uninitialized data from the previous command/response at the same buffer offset.
        if encodedData[8] != 0 && encodedData[18] == 0 {
            // For Dash faults, YYYY could be a calling address of the fault routine for the first return after a pod fault,
            // subsequent returns will be byte swapped data from previous command/response at the same buffer offset.
            self.possibleFaultCallingAddress = encodedData[20...21].toBigEndian(UInt16.self) // only potentially valid for Dash
        } else {
            // YYYY contents not valid (either uninitialized data for Eros or some unknown content for Dash).
            self.possibleFaultCallingAddress = nil
        }

        self.data = Data(encodedData)
    }

    var isFaulted: Bool {
        return faultEventCode.faultType != .noFaults || podProgressStatus == .activationTimeExceeded
    }

    // Returns an appropropriate DASH PDM style Ref string for DetailedStatus. DASH Ref codes are all of
    // the form Ref: TT-VVVHH-IIIRR-FFF computed as {14|15|16|17|19}-{VV}{QQQQ/60}-{NNNN/20}{RRRR/20}-PP.
    var dashPdmRef: String? {
        let TT, VVV, HH, III, RR, FFF: UInt

        switch faultEventCode.faultType {

        case .noFaults:
            return nil  // not a pod fault

        // The DASH PDM defines the AlarmHazardPumpFailure type (TT=11), but
        // doesn't use it for anything including the 0x31 (-049) pod fault!

        // The DASH PDM uses the AlarmHazardPumpVolume type (TT=14) for the 0x18 (024) pod fault.
        case .reservoirEmpty:
            TT = 14     // DASH PDM Ref: 14-VVVHH-IIIRR-024

        // The DASH PDM uses the AlarmHazardPumpAutoOff type (TT=15) for a 0x29 (041) autoOff0 pod fault
        // (the only autoOff# it actually uses). While Loop doesn't use the Auto Off feature for anything,
        // map all autoOff# pod faults to AlarmHazardPumpAutoOff in case these ever do get used for something.
        case .autoOff0, .autoOff1, .autoOff2, .autoOff3, .autoOff4, .autoOff5, .autoOff6, .autoOff7:
            TT = 15     // DASH PDM Ref: 15-VVVHH-IIIRR-FFF

        // The DASH PDM uses the AlarmHazardPumpExpired type (TT=16) for the 0x1C (028) pod fault.
        case .exceededMaximumPodLife80Hrs:
            TT = 16     // DASH PDM Ref: 16-VVVHH-IIIRR-028

        // The DASH PDM uses the AlarmHazardPumpOcclusion type (TT=17) for an 0x14 (-020) occlusion fault.
        // Unlike the Eros PDM, the DASH PDM doesn't do anything special with the other values for this Ref code.
        case .occluded:
            TT = 17     // DASH PDM Ref: 17-VVVHH-IIIRR-020

        // The DASH PDM defines the AlarmHazardPumpActivate type (TT=18) and the
        // AlarmHazardPumpCommunications type (TT=20), but doesn't actually use either!

        // The DASH PDM uses the AlarmHazardPumpError type (TT=19) for all other pod faults.
        default:
            TT = 19     // DASH PDM Ref: 19-VVVHH-IIIRR-FFF
        }

        VVV = UInt(data[17]) // raw DetailedStatus VV byte
        if let faultTime = faultEventTimeSinceActivation {
            HH = UInt(faultTime.hours) // fault time in whole # of hours
        } else {
            HH = UInt(timeActive.hours) // active time in whole # of hours
        }
        III = UInt(totalInsulinDelivered) // whole units of insulin
        RR = UInt(self.reservoirLevel) // whole reservoir units, special 51.15 value used for > 50U will become 51 as needed
        FFF = UInt(faultEventCode.rawValue) // actual fault code value

        return String(format: "%02llu-%03llu%02llu-%03llu%02llu-%03llu", TT, VVV, HH, III, RR, FFF)
    }

    // Returns an appropropriate Eros PDM style Ref string for the Detailed Status.
    // For most types, Ref: TT-VVVHH-IIIRR-FFF computed as {19|17}-{VV}{QQQQ/60}-{NNNN/20}{RRRR/20}-PP
    var erosPdmRef: String? {
        let TT, VVV, HH, III, RR, FFF: UInt

        switch faultEventCode.faultType {
        case .noFaults, .reservoirEmpty, .exceededMaximumPodLife80Hrs:
            return nil      // no Eros PDM Ref # generated for these cases

        case .insulinDeliveryCommandError:
            // This fault is treated as a PDM fault which uses an alternate Ref format
            return "11-144-0018-00049" // all fixed values for this fault

        case .occluded:
            // Ref: 17-000HH-IIIRR-000
            TT = 17         // Occlusion detected Ref type
            VVV = 0         // no VVV value for an occlusion fault
            FFF = 0         // no FFF value for an occlusion fault

        default:
            // Ref: 19-VVVHH-IIIRR-FFF
            TT = 19         // pod fault Ref type
            VVV = UInt(data[17]) // use the raw VV byte value
            FFF = UInt(faultEventCode.rawValue)
        }

        if let faultTime = faultEventTimeSinceActivation {
            HH = UInt(faultTime.hours) // fault time in whole # of hours
        } else {
            HH = UInt(timeActive.hours) // active time in whole # of hours
        }
        III = UInt(totalInsulinDelivered) // whole units of insulin
        RR = UInt(self.reservoirLevel) // whole reservoir units, special 51.15 value used for > 50U will become 51 as needed

        return String(format: "%02llu-%03llu%02llu-%03llu%02llu-%03llu", TT, VVV, HH, III, RR, FFF)
    }

    // Returns an appropropriate PDM style Ref string for DetailedStatus.
    var pdmRef: String? {
        // Use the WW byte to select either an Eros or Dash style PDM Ref string
        if data[18] != 0 {
            return erosPdmRef
        }
        return dashPdmRef
    }
}

extension DetailedStatus: CustomDebugStringConvertible {
    typealias RawValue = Data
    var debugDescription: String {
        var result = [
            "## DetailedStatus",
            "* rawHex: \(data.hexadecimalString)",
            "* podProgressStatus: \(podProgressStatus)",
            "* deliveryStatus: \(deliveryStatus.description)",
            "* bolusNotDelivered: \(bolusNotDelivered.twoDecimals) U",
            "* lastProgrammingMessageSeqNum: \(lastProgrammingMessageSeqNum)",
            "* totalInsulinDelivered: \(totalInsulinDelivered.twoDecimals) U",
            "* reservoirLevel: \(reservoirLevel == Pod.reservoirLevelAboveThresholdMagicNumber ? "50+" : reservoirLevel.twoDecimals) U",
            "* timeActive: \(timeActive.timeIntervalStr)",
            "* unacknowledgedAlerts: \(unacknowledgedAlerts)",
            "",
            ].joined(separator: "\n")
        if radioRSSI != 0 {
            result += [
                "* receiverLowGain: \(receiverLowGain)",
                "* radioRSSI: \(radioRSSI)",
                "",
                ].joined(separator: "\n")
        }
        if faultEventCode.faultType != .noFaults {
            result += [
                "* faultEventCode: \(faultEventCode.description)",
                "* faultAccessingTables: \(faultAccessingTables)",
                "* faultEventTimeSinceActivation: \(faultEventTimeSinceActivation?.timeIntervalStr ?? "NA")",
                "* errorEventInfo: \(errorEventInfo?.description ?? "NA")",
                "* previousPodProgressStatus: \(previousPodProgressStatus?.description ?? "NA")",
                "* possibleFaultCallingAddress: \(possibleFaultCallingAddress != nil ? String(format: "0x%04llx", possibleFaultCallingAddress!) : "NA")",
                "",
                ].joined(separator: "\n")
        }
        return result
    }
}

extension DetailedStatus: RawRepresentable {
    init?(rawValue: Data) {
        do {
            try self.init(encodedData: rawValue)
        } catch {
            return nil
        }
    }

    var rawValue: Data {
        return data
    }
}

// Type for the ErrorEventInfo VV byte if valid
//    a: insulin state table corruption found during error logging
//   bb: internal 2-bit occlusion type
//    c: immediate bolus in progress during error
// dddd: Pod Progress at time of first logged fault event
//
struct ErrorEventInfo: CustomStringConvertible, Equatable {
    let rawValue: UInt8
    let insulinStateTableCorruption: Bool // 'a' bit
    let occlusionType: Int // 'bb' 2-bit occlusion type
    let immediateBolusInProgress: Bool // 'c' bit
    let podProgressStatus: PodProgressStatus // 'dddd' bits

    var errorEventInfo: ErrorEventInfo? {
        return ErrorEventInfo(rawValue: rawValue)
    }

    var description: String {
        let hexString = String(format: "%02llX", rawValue)
        return [
            "rawValue: 0x\(hexString)",
            "insulinStateTableCorruption: \(insulinStateTableCorruption)",
            "occlusionType: \(occlusionType)",
            "immediateBolusInProgress: \(immediateBolusInProgress)",
            "podProgressStatus: \(podProgressStatus)",
            ].joined(separator: ", ")
    }

    init(rawValue: UInt8) {
        self.rawValue = rawValue
        self.insulinStateTableCorruption = (rawValue & 0x80) != 0
        self.occlusionType = Int((rawValue & 0x60) >> 5)
        self.immediateBolusInProgress = (rawValue & 0x10) != 0
        self.podProgressStatus = PodProgressStatus(rawValue: rawValue & 0xF)!
    }
}
