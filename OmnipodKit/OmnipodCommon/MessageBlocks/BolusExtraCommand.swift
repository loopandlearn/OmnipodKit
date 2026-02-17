//
//  BolusExtraCommand.swift
//  OmnipodKit
//
//  From OmniBLE/OmnipodCommon/MessageBlocks/BolusExtraCommand.swift
//  Created by Pete Schwamb on 2/24/18.
//  Copyright © 2018 Pete Schwamb. All rights reserved.
//

import Foundation

struct BolusExtraCommand: MessageBlock {
    let blockType: MessageBlockType = .bolusExtra

    let acknowledgementBeep: Bool
    let completionBeep: Bool
    let programReminderInterval: TimeInterval
    let units: Double
    let timeBetweenPulses: TimeInterval
    let extendedUnits: Double
    let extendedDuration: TimeInterval
    let withPdmValue: Bool // O5 requires 0x12 (WITH_PDM_VALUE) instead of 0x0d (NO_VALUE)

    // 17 0d 7c 1770 00030d40 0000 00000000           -- DASH (15 bytes, type 0x0d)
    // 17 12 7c 0208 000186a0 0000 00000000 01 0000 0000 -- O5  (20 bytes, type 0x12)
    var data: Data {
        let beepOptions = (UInt8(programReminderInterval.minutes) & 0x3f) + (completionBeep ? (1<<6) : 0) + (acknowledgementBeep ? (1<<7) : 0)

        var data = Data([
            blockType.rawValue,
            withPdmValue ? 0x12 : 0x0d,
            beepOptions
            ])

        data.appendBigEndian(UInt16(round(units * Pod.pulsesPerUnit * 10)))
        data.appendBigEndian(UInt32(timeBetweenPulses.hundredthsOfMilliseconds))

        let pulseCountX10 = UInt16(round(extendedUnits * Pod.pulsesPerUnit * 10))
        data.appendBigEndian(pulseCountX10)

        let timeBetweenExtendedPulses = pulseCountX10 > 0 ? extendedDuration / (Double(pulseCountX10) / 10) : 0
        data.appendBigEndian(UInt32(timeBetweenExtendedPulses.hundredthsOfMilliseconds))

        if withPdmValue {
            data.append(0x01) // bolus source
            data.appendBigEndian(UInt16(0)) // meal pulses
            data.appendBigEndian(UInt16(0)) // correction pulses
        }

        return data
    }

    init(encodedData: Data) throws {
        if encodedData.count < 15 {
            throw MessageBlockError.notEnoughData
        }

        withPdmValue = encodedData[1] == 0x12
        acknowledgementBeep = encodedData[2] & (1<<7) != 0
        completionBeep = encodedData[2] & (1<<6) != 0
        programReminderInterval = TimeInterval(minutes: Double(encodedData[2] & 0x3f))

        units = Double(encodedData[3...].toBigEndian(UInt16.self)) / (Pod.pulsesPerUnit * 10)

        let delayCounts = encodedData[5...].toBigEndian(UInt32.self)
        timeBetweenPulses = TimeInterval(hundredthsOfMilliseconds: Double(delayCounts))

        let pulseCountX10 = encodedData[9...].toBigEndian(UInt16.self)
        extendedUnits = Double(pulseCountX10) / (Pod.pulsesPerUnit * 10)

        let intervalCounts = encodedData[11...].toBigEndian(UInt32.self)
        let timeBetweenExtendedPulses = TimeInterval(hundredthsOfMilliseconds: Double(intervalCounts))
        extendedDuration = timeBetweenExtendedPulses * (Double(pulseCountX10) / 10)
    }

    init(units: Double = 0, timeBetweenPulses: TimeInterval = Pod.secondsPerBolusPulse, extendedUnits: Double = 0.0, extendedDuration: TimeInterval = 0, acknowledgementBeep: Bool = false, completionBeep: Bool = false, programReminderInterval: TimeInterval = 0, withPdmValue: Bool = false) {
        self.acknowledgementBeep = acknowledgementBeep
        self.completionBeep = completionBeep
        self.programReminderInterval = programReminderInterval
        self.units = units
        self.timeBetweenPulses = timeBetweenPulses != 0 ? timeBetweenPulses : Pod.secondsPerBolusPulse
        self.extendedUnits = extendedUnits
        self.extendedDuration = extendedDuration
        self.withPdmValue = withPdmValue
    }
}

extension BolusExtraCommand: CustomDebugStringConvertible {
    var debugDescription: String {
        return "BolusExtraCommand(units:\(units), timeBetweenPulses:\(timeBetweenPulses), extendedUnits:\(extendedUnits), extendedDuration:\(extendedDuration), acknowledgementBeep:\(acknowledgementBeep), completionBeep:\(completionBeep), programReminderInterval:\(programReminderInterval.minutes))"
    }
}
