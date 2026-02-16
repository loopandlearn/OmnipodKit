//
//  Pod.swift
//  OmnipodKit
//
//  From OmniBLE/OmnipodCommon/Pod.swift
//  Created by Pete Schwamb on 4/4/18.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import Foundation

struct Pod {
    // Volume of U100 insulin in one motor pulse
    // Must agree with value returned by pod during the pairing process.
    static let pulseSize: Double = 0.05

    // Number of pulses required to deliver one unit of U100 insulin
    static let pulsesPerUnit: Double = 1 / Pod.pulseSize

    // Seconds per pulse for boluses
    // Checked to verify it agrees with value returned by pod during the pairing process.
    static let secondsPerBolusPulse: Double = 2

    // Units per second for boluses
    static let bolusDeliveryRate: Double = Pod.pulseSize / Pod.secondsPerBolusPulse

    // Seconds per pulse for priming/cannula insertion
    // Checked to verify it agrees with value returned by pod during the pairing process.
    static let secondsPerPrimePulse: Double = 1

    // Units per second for priming/cannula insertion
    static let primeDeliveryRate: Double = Pod.pulseSize / Pod.secondsPerPrimePulse

    // Expiration advisory window: time after expiration alert, and end of service imminent alarm
    static let expirationAdvisoryWindow = TimeInterval(hours: 7)

    // End of service imminent window, relative to pod end of service
    static let endOfServiceImminentWindow = TimeInterval(hours: 1)

    // Total pod service time. A fault is triggered if this time is reached before pod deactivation.
    // Checked to verify it agrees with value returned by pod during the pairing process.
    static let serviceDuration = TimeInterval(hours: 80)

    // Nomimal pod life (72 hours)
    static let nominalPodLife = Pod.serviceDuration - Pod.endOfServiceImminentWindow - Pod.expirationAdvisoryWindow

    // Maximum reservoir level reading
    static let maximumReservoirReading: Double = 50

    // Reservoir level magic number indicating 50+ U remaining
    static let reservoirLevelAboveThresholdMagicNumber: Double = 51.15

    // Reservoir Capacity
    static let reservoirCapacity: Double = 200

    // The internal zero basal rate varies between Eros and DASH
    // For Eros its 0.0, for DASH its nearZeroBasalRate
    static let nearZeroBasalRate = 0.01

    // Maximum number of basal schedule entries supported
    static let maximumBasalScheduleEntryCount: Int = 24

    // Minimum duration of a single basal schedule entry
    static let minimumBasalScheduleEntryDuration = TimeInterval.minutes(30)

    // Supported temp basal durations (30m to 12h)
    static let supportedTempBasalDurations: [TimeInterval] = (1...24).map { Double($0) * TimeInterval(minutes: 30) }

    // Supported temp basal rates are 0 to 30U/hr in 0.05 units increments
    static let supportedTempBasalRates: [Double] = (0...600).map { Double($0) / Double(Pod.pulsesPerUnit) }

    // Default amount for priming bolus using secondsPerPrimePulse timing.
    // Checked to verify it agrees with value returned by pod during the pairing process.
    static let primeUnits = 2.6

    // Default amount for cannula insertion bolus using secondsPerPrimePulse timing.
    // Checked to verify it agrees with value returned by pod during the pairing process.
    static let cannulaInsertionUnits = 0.5

    static let cannulaInsertionUnitsExtra = 0.0 // edit to add a fixed additional amount of insulin during cannula insertion

    // Default and limits for expiration reminder alerts
    static let defaultExpirationReminderOffset = TimeInterval(hours: 2)
    static let expirationReminderAlertMinHoursBeforeExpiration = 1
    static let expirationReminderAlertMaxHoursBeforeExpiration = 24
    
    // Threshold used to display pod end of life warnings
    static let timeRemainingWarningThreshold = TimeInterval(days: 1)
    
    // Default low reservoir alert limit in Units
    static let defaultLowReservoirReminder: Double = 10

    // O5 user expiry alert offset: 352 minutes (5h52m) before nominal pod life.
    // This produces an alert at 3968 minutes (~66h8m) from activation,
    // matching the O5 app's Frida-captured value.
    static let o5UserExpiryOffset = TimeInterval(minutes: 352)
    
    // Allowed Low Reservoir reminder values
    static let allowedLowReservoirReminderValues = Array(stride(from: 1, through: 50, by: 1))

    // Pod firmware imposed maximum basal rate
    static let maximumBasalUnitsPerHour = 30.0

    // Pod firmware imposed maximum bolus size
    static let maximumBolusUnits = 30.0
}

// DeliveryStatus used in StatusResponse and DetailedStatus
// Since bits 1 & 2 are exclusive and bits 4 & 8 are exclusive,
// these are all the possible values that can be returned.
enum DeliveryStatus: UInt8, CustomStringConvertible {
    case suspended = 0
    case scheduledBasal = 1
    case tempBasalRunning = 2
    case priming = 4 // bolusing while suspended, should only occur during priming
    case bolusInProgress = 5
    case bolusAndTempBasal = 6
    case extendedBolusWhileSuspended = 8 // should never occur
    case extendedBolusRunning = 9
    case extendedBolusAndTempBasal = 10

    var suspended: Bool {
        return self == .suspended || self == .priming || self == .extendedBolusWhileSuspended
    }

    var bolusing: Bool {
        return self == .bolusInProgress || self == .bolusAndTempBasal || self == .extendedBolusRunning || self == .extendedBolusAndTempBasal || self == .priming || self == .extendedBolusWhileSuspended
    }

    var tempBasalRunning: Bool {
        return self == .tempBasalRunning || self == .bolusAndTempBasal || self == .extendedBolusAndTempBasal
    }

    var extendedBolusRunning: Bool {
        return self == .extendedBolusRunning || self == .extendedBolusAndTempBasal || self == .extendedBolusWhileSuspended
    }

    var description: String {
        switch self {
        case .suspended:
            return LocalizedString("Suspended", comment: "Delivery status when insulin delivery is suspended")
        case .scheduledBasal:
            return LocalizedString("Scheduled basal", comment: "Delivery status when scheduled basal is running")
        case .tempBasalRunning:
            return LocalizedString("Temp basal running", comment: "Delivery status when temp basal is running")
        case .priming:
            return LocalizedString("Priming", comment: "Delivery status when pod is priming")
        case .bolusInProgress:
            return LocalizedString("Bolusing", comment: "Delivery status when bolusing")
        case .bolusAndTempBasal:
            return LocalizedString("Bolusing with temp basal", comment: "Delivery status when bolusing and temp basal is running")
        case .extendedBolusWhileSuspended:
            return LocalizedString("Extended bolus running while suspended", comment: "Delivery status when extended bolus is running while suspended")
        case .extendedBolusRunning:
            return LocalizedString("Extended bolus running", comment: "Delivery status when extended bolus is running")
        case .extendedBolusAndTempBasal:
            return LocalizedString("Extended bolus running with temp basal", comment: "Delivery status when extended bolus and temp basal is running")
        }
    }
}
