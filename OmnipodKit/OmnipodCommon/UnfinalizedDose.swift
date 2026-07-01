//
//  UnfinalizedDose.swift
//  OmnipodKit
//
//  From OmniBLE/OmnipodCommon/UnfinalizedDose.swift
//  Created by Pete Schwamb on 9/5/18.
//  Copyright © 2018 Pete Schwamb. All rights reserved.
//

import Foundation
import LoopKit

// XXX still needs be declared public with the current Trio implementation
public struct UnfinalizedDose: RawRepresentable, Equatable, CustomStringConvertible {
    public typealias RawValue = [String: Any]

    enum DoseType: Int {
        case bolus = 0
        case tempBasal
        case suspend
        case resume
    }

    enum ScheduledCertainty: Int {
        case certain = 0
        case uncertain

        var localizedDescription: String {
            switch self {
            case .certain:
                return LocalizedString("Certain", comment: "String describing a dose that was certainly scheduled")
            case .uncertain:
                return LocalizedString("Uncertain", comment: "String describing a dose that was possibly scheduled")
            }
        }
    }

    private let insulinFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 3
        return formatter
    }()

    private let shortDateFormatter: DateFormatter = {
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .short
        timeFormatter.timeStyle = .medium
        return timeFormatter
    }()

    private let dateFormatter = ISO8601DateFormatter()

    fileprivate var uniqueKey: Data {
        return "\(doseType) \(scheduledUnits ?? units) \(dateFormatter.string(from: startTime))".data(using: .utf8)!
    }

    let doseType: DoseType
    var units: Double
    // XXX still needs be declared public with the current Trio implementation
    public var automatic: Bool // Tracks if this dose was issued automatically or manually
    var scheduledUnits: Double? // Tracks the scheduled units, as boluses may be canceled before finishing, at which point units would reflect actual delivered volume.
    var scheduledTempRate: Double? // Tracks the original temp rate, as during finalization the units are discretized to pump pulses, changing the actual rate
    let startTime: Date
    var duration: TimeInterval?
    var scheduledCertainty: ScheduledCertainty
    var isHighTemp: Bool =
        false // Track this for situations where cancelling temp basal is unacknowledged, and recovery fails, and we have to assume the most possible delivery
    var insulinType: InsulinType?
    var bolusReference: String? // Opaque, caller-supplied reference echoed back on the resulting DoseEntry; not interpreted by the pump

    var finishTime: Date? {
        get {
            duration != nil ? startTime.addingTimeInterval(duration!) : nil
        }
        set {
            duration = newValue?.timeIntervalSince(startTime)
        }
    }

    func progress(at date: Date = Date()) -> Double {
        guard let duration = duration else {
            return 0
        }
        let elapsed = -startTime.timeIntervalSince(date)
        return min(elapsed / duration, 1)
    }

    // XXX still needs be declared public with the current Trio implementation
    public func isFinished(at date: Date = Date()) -> Bool {
        progress(at: date) >= 1
    }

    // Units per hour
    var rate: Double {
        guard let duration = duration else {
            return 0
        }
        return units / duration.hours
    }

    var finalizedUnits: Double? {
        guard isFinished() else {
            return nil
        }
        return units
    }

    init(
        bolusAmount: Double,
        startTime: Date,
        scheduledCertainty: ScheduledCertainty,
        insulinType: InsulinType,
        automatic: Bool = false,
        bolusReference: String? = nil
    ) {
        doseType = .bolus
        units = bolusAmount
        self.startTime = startTime
        duration = TimeInterval(bolusAmount / Pod.bolusDeliveryRate)
        self.scheduledCertainty = scheduledCertainty
        scheduledUnits = nil
        self.automatic = automatic
        self.insulinType = insulinType
        self.bolusReference = bolusReference
    }

    init(
        tempBasalRate: Double,
        startTime: Date,
        duration: TimeInterval,
        isHighTemp: Bool,
        automatic: Bool,
        scheduledCertainty: ScheduledCertainty,
        insulinType: InsulinType
    ) {
        doseType = .tempBasal
        units = tempBasalRate * duration.hours
        self.startTime = startTime
        self.duration = duration
        self.scheduledCertainty = scheduledCertainty
        scheduledUnits = nil
        self.automatic = automatic
        self.isHighTemp = isHighTemp
        self.insulinType = insulinType
    }

    init(suspendStartTime: Date, scheduledCertainty: ScheduledCertainty) {
        doseType = .suspend
        units = 0
        startTime = suspendStartTime
        self.scheduledCertainty = scheduledCertainty
        automatic = false
    }

    init(resumeStartTime: Date, scheduledCertainty: ScheduledCertainty, insulinType: InsulinType) {
        doseType = .resume
        units = 0
        startTime = resumeStartTime
        self.scheduledCertainty = scheduledCertainty
        automatic = false
        self.insulinType = insulinType
    }

    mutating func cancel(at date: Date, withRemaining remaining: Double? = nil) {
        guard let finishTime = finishTime, date < finishTime else {
            return
        }

        scheduledUnits = units

        // Guard against negative duration if clock has changed
        let newDuration = max(0, date.timeIntervalSince(startTime))

        switch doseType {
        case .bolus:
            let oldRate = rate
            if let remaining = remaining {
                // Guard against negative bolus if incorrectly called a 2nd time or with a bad remaining
                if remaining <= units {
                    units -= remaining
                }
            } else {
                units = oldRate * newDuration.hours
            }
        case .tempBasal:
            scheduledTempRate = rate
            units = floor(rate * newDuration.hours * Pod.pulsesPerUnit) / Pod.pulsesPerUnit
            print(
                "Temp basal scheduled units: \(String(describing: scheduledUnits)), delivered units: \(units), duration: \(newDuration.minutes)"
            )
        default:
            break
        }
        duration = newDuration
    }

    func isMutable(at date: Date = Date()) -> Bool {
        switch doseType {
        case .bolus,
             .tempBasal:
            return !isFinished(at: date)
        default:
            return false
        }
    }

    public var description: String {
        let unitsStr = insulinFormatter.string(from: units) ?? ""
        let startTimeStr = shortDateFormatter.string(from: startTime)
        let durationStr = duration?.format(using: [.minute, .second]) ?? ""
        switch doseType {
        case .bolus:
            if let scheduledUnits = scheduledUnits {
                let scheduledUnitsStr = insulinFormatter.string(from: scheduledUnits) ?? "?"
                return String(
                    format: LocalizedString(
                        "InterruptedBolus: %1$@ U (%2$@ U scheduled) %3$@ %4$@ %5$@",
                        comment: "The format string describing a bolus that was interrupted. (1: The amount delivered)(2: The amount scheduled)(3: Start time of the dose)(4: duration)(5: scheduled certainty)"
                    ),
                    unitsStr,
                    scheduledUnitsStr,
                    startTimeStr,
                    durationStr,
                    scheduledCertainty.localizedDescription
                )
            } else {
                return String(
                    format: LocalizedString(
                        "Bolus: %1$@U %2$@ %3$@ %4$@",
                        comment: "The format string describing a bolus. (1: The amount delivered)(2: Start time of the dose)(3: duration)(4: scheduled certainty)"
                    ),
                    unitsStr,
                    startTimeStr,
                    durationStr,
                    scheduledCertainty.localizedDescription
                )
            }
        case .tempBasal:
            let volumeStr = insulinFormatter.string(from: units) ?? "?"
            let rateStr = NumberFormatter.localizedString(from: NSNumber(value: scheduledTempRate ?? rate), number: .decimal)
            return String(
                format: LocalizedString(
                    "TempBasal: %1$@ U/hour %2$@ %3$@ %4$@ U %5$@",
                    comment: "The format string describing a temp basal. (1: The rate)(2: Start time)(3: duration)(4: volume)(5: scheduled certainty"
                ),
                rateStr,
                startTimeStr,
                durationStr,
                volumeStr,
                scheduledCertainty.localizedDescription
            )
        case .suspend:
            return String(
                format: LocalizedString(
                    "Suspend: %1$@ %2$@",
                    comment: "The format string describing a suspend. (1: Time)(2: Scheduled certainty"
                ),
                startTimeStr,
                scheduledCertainty.localizedDescription
            )
        case .resume:
            return String(
                format: LocalizedString(
                    "Resume: %1$@ %2$@",
                    comment: "The format string describing a resume. (1: Time)(2: Scheduled certainty"
                ),
                startTimeStr,
                scheduledCertainty.localizedDescription
            )
        }
    }

    var eventTitle: String {
        switch doseType {
        case .bolus:
            return LocalizedString("Bolus", comment: "Pump Event title for UnfinalizedDose with doseType of .bolus")
        case .resume:
            return LocalizedString("Resume", comment: "Pump Event title for UnfinalizedDose with doseType of .resume")
        case .suspend:
            return LocalizedString("Suspend", comment: "Pump Event title for UnfinalizedDose with doseType of .suspend")
        case .tempBasal:
            return LocalizedString("Temp Basal", comment: "Pump Event title for UnfinalizedDose with doseType of .tempBasal")
        }
    }

    // RawRepresentable
    public init?(rawValue: RawValue) {
        guard
            let rawDoseType = rawValue["doseType"] as? Int,
            let doseType = DoseType(rawValue: rawDoseType),
            let units = rawValue["units"] as? Double,
            let startTime = rawValue["startTime"] as? Date,
            let rawScheduledCertainty = rawValue["scheduledCertainty"] as? Int,
            let scheduledCertainty = ScheduledCertainty(rawValue: rawScheduledCertainty)
        else {
            return nil
        }

        self.doseType = doseType
        self.units = units
        self.startTime = startTime
        self.scheduledCertainty = scheduledCertainty

        scheduledUnits = rawValue["scheduledUnits"] as? Double

        scheduledTempRate = rawValue["scheduledTempRate"] as? Double

        duration = rawValue["duration"] as? Double

        if let automatic = rawValue["automatic"] as? Bool {
            self.automatic = automatic
        } else {
            if case .tempBasal = doseType {
                self.automatic = true
            } else {
                automatic = false
            }
        }

        if let isHighTemp = rawValue["isHighTemp"] as? Bool {
            self.isHighTemp = isHighTemp
        } else {
            isHighTemp = false
        }

        if let rawInsulinType = rawValue["insulinType"] as? InsulinType.RawValue {
            insulinType = InsulinType(rawValue: rawInsulinType)
        }

        bolusReference = rawValue["bolusReference"] as? String
    }

    public var rawValue: RawValue {
        var rawValue: RawValue = [
            "doseType": doseType.rawValue,
            "units": units,
            "startTime": startTime,
            "scheduledCertainty": scheduledCertainty.rawValue,
            "automatic": automatic,
            "isHighTemp": isHighTemp
        ]

        rawValue["scheduledUnits"] = scheduledUnits
        rawValue["scheduledTempRate"] = scheduledTempRate
        rawValue["duration"] = duration
        rawValue["insulinType"] = insulinType?.rawValue
        rawValue["bolusReference"] = bolusReference

        return rawValue
    }
}

private extension TimeInterval {
    func format(using units: NSCalendar.Unit) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = units
        formatter.unitsStyle = .full
        formatter.zeroFormattingBehavior = .dropLeading
        formatter.maximumUnitCount = 2

        return formatter.string(from: self)
    }
}

extension NewPumpEvent {
    init(_ dose: UnfinalizedDose) {
        let entry = DoseEntry(dose)
        self.init(date: dose.startTime, dose: entry, raw: dose.uniqueKey, title: dose.eventTitle)
    }
}

extension DoseEntry {
    init(_ dose: UnfinalizedDose) {
        switch dose.doseType {
        case .bolus:
            self = DoseEntry(
                type: .bolus,
                startDate: dose.startTime,
                endDate: dose.finishTime,
                value: dose.scheduledUnits ?? dose.units,
                unit: .units,
                deliveredUnits: dose.finalizedUnits,
                insulinType: dose.insulinType,
                automatic: dose.automatic,
                isMutable: dose.isMutable(),
                bolusReference: dose.bolusReference
            )
        case .tempBasal:
            self = DoseEntry(
                type: .tempBasal,
                startDate: dose.startTime,
                endDate: dose.finishTime,
                value: dose.scheduledTempRate ?? dose.rate,
                unit: .unitsPerHour,
                deliveredUnits: dose.finalizedUnits,
                insulinType: dose.insulinType,
                automatic: dose.automatic,
                isMutable: dose.isMutable()
            )
        case .suspend:
            self = DoseEntry(suspendDate: dose.startTime)
        case .resume:
            self = DoseEntry(resumeDate: dose.startTime, insulinType: dose.insulinType)
        }
    }
}

extension StartProgram {
    func unfinalizedDose(
        at programDate: Date,
        withCertainty certainty: UnfinalizedDose.ScheduledCertainty,
        insulinType: InsulinType
    ) -> UnfinalizedDose? {
        switch self {
        case let .bolus(volume: volume, automatic: automatic, bolusReference: bolusReference):
            return UnfinalizedDose(
                bolusAmount: volume,
                startTime: programDate,
                scheduledCertainty: certainty,
                insulinType: insulinType,
                automatic: automatic,
                bolusReference: bolusReference
            )
        case let .tempBasal(unitsPerHour: rate, duration: duration, isHighTemp, automatic):
            return UnfinalizedDose(
                tempBasalRate: rate,
                startTime: programDate,
                duration: duration,
                isHighTemp: isHighTemp,
                automatic: automatic,
                scheduledCertainty: certainty,
                insulinType: insulinType
            )
        case .basalProgram:
            return UnfinalizedDose(resumeStartTime: programDate, scheduledCertainty: certainty, insulinType: insulinType)
        }
    }
}
