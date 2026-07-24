//
//  OmniPumpManagerState.swift
//  OmnipodKit
//
//  Based on Omni{BLE,Kit}/PumpManager/OmniBLEPumpManagerState.swift
//  Created by Joe Moran on 12/29/24.
//  Copyright © 2024 LoopKit Authors. All rights reserved.
//

import RileyLinkBLEKit
import LoopKit
import os.log

private let log = OSLog(category: "OmniPumpManagerState")

// XXX still needs be declared public with the current Trio implementation
public struct OmniPumpManagerState: RawRepresentable, Equatable {
    public typealias RawValue = PumpManager.RawStateValue

    var isOnboarded: Bool = false

    // XXX still needs be declared public with the current Trio implementation
    private(set) public var podState: PodState?

    // State should only be modifiable by PodComms
    mutating func updatePodStateFromPodComms(_ podState: PodState?) {
        self.podState = podState
    }

    var timeZone: TimeZone

    var basalSchedule: BasalSchedule

    var unstoredDoses: [UnfinalizedDose]

    var silencePod: Bool

    var silencePodEnd: Date? /// if set, the time at which Silence Pod Mode will automatically end

    var confirmationBeeps: BeepPreference

    var scheduledExpirationReminderOffset: TimeInterval?

    var defaultExpirationReminderOffset = Pod.defaultExpirationReminderOffset

    var lowReservoirReminderValue: Double

    var defaultLowReservoirReminderValue: Double

    var podAttachmentConfirmed: Bool

    public internal(set) var activeAlerts: Set<PumpManagerAlert>

    var alertsWithPendingAcknowledgment: Set<PumpManagerAlert>

    var acknowledgedTimeOffsetAlert: Bool

    internal var lastPumpDataReportDate: Date?

    internal var insulinType: InsulinType?

    // Persistence for the pod state of the previous pod,
    // for user review and manufacturer reporting.
    internal var previousPodState: PodState?

    // Indicates that the user has completed initial configuration
    // which means they have configured any parameters, but may not have paired a pod yet.
    var initialConfigurationCompleted: Bool = false

    internal var maxBasalRateUnitsPerHour: Double

    internal var maxBolusUnits: Double


    // From last status response
    var reservoirLevel: ReservoirLevel? {
        guard let level = podState?.lastInsulinMeasurements?.reservoirLevel else {
            return nil
        }
        return ReservoirLevel(rawValue: level)
    }

    var podType: PodType

    // Eros only state
    var rileyLinkConnectionManagerState: RileyLinkConnectionState? = nil
    var pairingAttemptAddress: UInt32? = nil
    var rileyLinkBatteryAlertLevel: Int? = nil
    var lastRileyLinkBatteryAlertDate: Date = .distantPast

    // BLE only state
    var controllerId: UInt32 = 0
    var podId: UInt32 = 0


    // Temporal state not persisted

    internal enum EngageablePumpState: Equatable {
        case engaging
        case disengaging
        case stable
    }

    internal var suspendEngageState: EngageablePumpState = .stable

    internal var bolusEngageState: EngageablePumpState = .stable

    internal var tempBasalEngageState: EngageablePumpState = .stable

    internal var lastStatusChange: Date = .distantPast


    // MARK: -

    init(
        isOnboarded: Bool,
        podState: PodState?,
        timeZone: TimeZone,
        basalSchedule: BasalSchedule,
        maxBasalRateUnitsPerHour: Double,
        maxBolusUnits: Double,
        insulinType: InsulinType?,
        podType: PodType,
        rileyLinkConnectionManagerState: RileyLinkConnectionState? = nil, // Eros
        controllerId: UInt32? = nil, // BLE
        podId: UInt32? = nil) // BLE
    {
        self.isOnboarded = isOnboarded
        self.podState = podState
        self.timeZone = timeZone
        self.basalSchedule = basalSchedule
        self.insulinType = insulinType
        self.maxBasalRateUnitsPerHour = maxBasalRateUnitsPerHour
        self.maxBolusUnits = maxBolusUnits
        self.unstoredDoses = []
        self.silencePod = false
        self.silencePodEnd = nil
        self.confirmationBeeps = .manualCommands
        self.lowReservoirReminderValue = Pod.defaultLowReservoirReminder
        self.defaultLowReservoirReminderValue = Pod.defaultLowReservoirReminder
        self.podAttachmentConfirmed = false
        self.acknowledgedTimeOffsetAlert = false
        self.activeAlerts = []
        self.alertsWithPendingAcknowledgment = []

        self.podType = podType

        if podType.usesRileyLink {
            self.rileyLinkConnectionManagerState = rileyLinkConnectionManagerState
            self.controllerId = 0
            self.podId = 0
        } else if let controllerId = controllerId, let podId = podId {
            self.controllerId = controllerId
            self.podId = podId
        } else if podType == unknownOmnipodType {
            // Will be initialized later when podType is set
            self.controllerId = 0
            self.podId = 0
        } else {
            (self.controllerId, self.podId) = nextIds(podType: podType)
        }

        log.debug("[OmniPumpManagerState] init finished: %{public}@",
                  self.debugDescription)

    }

    public init?(rawValue: RawValue) {
        log.bleDebug("[OmniPumpManagerState] init with rawValue: %{public}@", String(describing: rawValue))

        let isOnboarded = rawValue["isOnboarded"] as? Bool ?? false

        let podState: PodState?
        if let podStateRaw = rawValue["podState"] as? PodState.RawValue {
            podState = PodState(rawValue: podStateRaw)
        } else {
            podState = nil
        }

        var podType: PodType
        if let podTypeRaw = rawValue["podType"] as? UInt8 {
            podType = PodType(rawValue: podTypeRaw)
        } else if let podState = podState {
            log.error("[OmniPumpManagerState] init with rawValue has no podType, using podState.podType=%{public}@",
                      String(describing: podState.podType))
            podType = podState.podType
        } else if rawValue["controllerId"] != nil {
            log.info("[OmniPumpManagerState] init with rawValue has no podType, using dashType")
            podType = dashType // OmniBLE
        } else {
            log.info("[OmniPumpManagerState] init with rawValue has no podType and no controllerId, using erosType")
            podType = erosType // OmniKit
        }

        let timeZone: TimeZone
        if let timeZoneSeconds = rawValue["timeZone"] as? Int,
            let tz = TimeZone(secondsFromGMT: timeZoneSeconds) {
            timeZone = tz
        } else {
            timeZone = TimeZone.currentFixed
        }

        let basalSchedule: BasalSchedule
        guard let rawBasalSchedule = rawValue["basalSchedule"] as? BasalSchedule.RawValue,
            let schedule = BasalSchedule(rawValue: rawBasalSchedule) else
        {
            return nil
        }
        basalSchedule = schedule

        var insulinType: InsulinType?
        if let rawInsulinType = rawValue["insulinType"] as? InsulinType.RawValue {
            insulinType = InsulinType(rawValue: rawInsulinType)
        }

        /// OmniKit/OmniBLE had a maximumTempBasalRate variable, but it was advertised to the user as a max basal rate.
        /// OmnipodKit renamed this to a more appropriate maxBasalRateUnitsPerHour, even though OmnipodKit isn't currently
        /// enforcing this for scheduled basal rates as Trio doesn't enforce this in its UI leading to confusing failures
        /// with an out of range value during operations like saving a basal schedule, resuming, setting pump time, etc.
        /// OmnipodKit is now also not enforcing this limit for temp basals rates to prevent various issues in Trio
        /// when its Maximum Basal Rate value isn't properly sync'ed with the OmniPumpManagerState values.
        let maxBasalRateUnitsPerHour = rawValue["maxBasalRateUnitsPerHour"] as? Double ??
                                        rawValue["maximumTempBasalRate"] as? Double ?? Pod.maximumBasalUnitsPerHour

        /// OmniKit/OmniBLE didn't had a maxBolusUnits state variable.  Default to the allowed maximum
        /// bolus value if not present to match previous OmniKit/OmniBLE behavior that relies on the app
        /// to do the only enforcement of the Therapy Setting bolus limit as was done in OmniKit/OmniBLE.
        let maxBolusUnits = rawValue["maxBolusUnits"] as? Double ?? Pod.maximumBolusUnits

        log.debug("@@@ [OmniPumpManagerState] initializing maxBasalRateUnitsPerHour to %{public}@ and maxBolusUnits to %{public}@",
                  String(describing: maxBasalRateUnitsPerHour), String(describing: maxBolusUnits))

        // Omnipod model specific values
        let rileyLinkConnectionManagerState: RileyLinkConnectionState?
        var controllerId, podId: UInt32?
        if podType.usesRileyLink {
            if let rileyLinkConnectionManagerStateRaw = rawValue["rileyLinkConnectionManagerState"] as? RileyLinkConnectionState.RawValue {
                rileyLinkConnectionManagerState = RileyLinkConnectionState(rawValue: rileyLinkConnectionManagerStateRaw)
            } else {
                rileyLinkConnectionManagerState = RileyLinkConnectionState(autoConnectIDs: [])
            }
            controllerId = nil
            podId = nil
        } else {
            rileyLinkConnectionManagerState = nil
            controllerId = rawValue["controllerId"] as? UInt32? ?? nil
            podId = rawValue["podId"] as? UInt32? ?? nil
            /// O5 specific checks of controllerId with the O5CertificateStore
            if podType.isO5, let myId = controllerId, myId != 0 {
                // Verify that the O5CertificateStore contains info for myId
                if O5CertificateStore.contains(myId) {
                    log.default("@@@ Verified controller id 0x%08X has O5 certificate", myId)
                } else if podState == nil {
                    // With no pod, just pick a new available controllerId to use
                    let newId = O5CertificateStore.pickControllerId
                    controllerId = newId
                    if newId != 0 {
                        podId = newId + 1
                        log.default("@@@ Switching O5 ids for certificate for 0x%08X", newId)
                    } else {
                        // There are no O5Certificates for any pdmId.
                        // Since we don't have a podState, just force a new
                        // pod selection and the O5 type will be disabled.
                        podType = unknownOmnipodType
                        podId = 0
                        log.error("@@@ No O5 certificates found -- disabled O5 pod type selection")
                    }
                }
            }
        }

        self.init(
            isOnboarded: isOnboarded,
            podState: podState,
            timeZone: timeZone,
            basalSchedule: basalSchedule,
            maxBasalRateUnitsPerHour: maxBasalRateUnitsPerHour,
            maxBolusUnits: maxBolusUnits,
            insulinType: insulinType ?? .novolog,
            podType: podType,
            rileyLinkConnectionManagerState: rileyLinkConnectionManagerState, // Eros only
            controllerId: controllerId, // non-Eros only
            podId: podId // non-Eros only
        )

        if let rawUnstoredDoses = rawValue["unstoredDoses"] as? [UnfinalizedDose.RawValue] {
            self.unstoredDoses = rawUnstoredDoses.compactMap( { UnfinalizedDose(rawValue: $0) } )
        } else {
            self.unstoredDoses = []
        }

        if let silencePodEnd = rawValue["silencePodEnd"] as? Date {
            /// Don't do anything here if silencePodEnd time has been reached so that
            /// the pod will be reprogrammed to use audible beeps on the next pod op.
            self.silencePodEnd = silencePodEnd
            self.silencePod = true /// must be true with a silence end time
        } else {
            self.silencePodEnd = nil
            self.silencePod = rawValue["silencePod"] as? Bool ?? false
        }

        if let rawBeeps = rawValue["confirmationBeeps"] as? BeepPreference.RawValue, let confirmationBeeps = BeepPreference(rawValue: rawBeeps) {
            self.confirmationBeeps = confirmationBeeps
        } else {
            self.confirmationBeeps = .manualCommands
        }

        self.scheduledExpirationReminderOffset = rawValue["scheduledExpirationReminderOffset"] as? TimeInterval
    
        self.defaultExpirationReminderOffset = rawValue["defaultExpirationReminderOffset"] as? TimeInterval ?? Pod.defaultExpirationReminderOffset
    
        self.lowReservoirReminderValue = rawValue["lowReservoirReminderValue"] as? Double ?? Pod.defaultLowReservoirReminder

        self.defaultLowReservoirReminderValue = rawValue["defaultLowReservoirReminderValue"] as? Double ?? self.lowReservoirReminderValue

        self.podAttachmentConfirmed = rawValue["podAttachmentConfirmed"] as? Bool ?? false

        self.initialConfigurationCompleted = rawValue["initialConfigurationCompleted"] as? Bool ?? true

        self.acknowledgedTimeOffsetAlert = rawValue["acknowledgedTimeOffsetAlert"] as? Bool ?? false

        if let lastPumpDataReportDate = rawValue["lastPumpDataReportDate"] as? Date {
            self.lastPumpDataReportDate = lastPumpDataReportDate
        }

        self.activeAlerts = []
        if let rawActiveAlerts = rawValue["activeAlerts"] as? [PumpManagerAlert.RawValue] {
            for rawAlert in rawActiveAlerts {
                if let alert = PumpManagerAlert(rawValue: rawAlert) {
                    self.activeAlerts.insert(alert)
                }
            }
        }

        self.alertsWithPendingAcknowledgment = []
        if let rawAlerts = rawValue["alertsWithPendingAcknowledgment"] as? [PumpManagerAlert.RawValue] {
            for rawAlert in rawAlerts {
                if let alert = PumpManagerAlert(rawValue: rawAlert) {
                    self.alertsWithPendingAcknowledgment.insert(alert)
                }
            }
        }

        if let prevPodStateRaw = rawValue["previousPodState"] as? PodState.RawValue {
            self.previousPodState = PodState(rawValue: prevPodStateRaw)
        } else {
            self.previousPodState = nil
        }

        if podType.isEros {
            // Some more Eros specific values
            if let pairingAttemptAddress = rawValue["pairingAttemptAddress"] as? UInt32 {
                self.pairingAttemptAddress = pairingAttemptAddress
            }
            self.rileyLinkBatteryAlertLevel = rawValue["rileyLinkBatteryAlertLevel"] as? Int
            self.lastRileyLinkBatteryAlertDate = rawValue["lastRileyLinkBatteryAlertDate"] as? Date ?? Date.distantPast
        }
    }

    public var rawValue: RawValue {
        var value: [String : Any] = [
            "isOnboarded": isOnboarded,
            "timeZone": timeZone.secondsFromGMT(),
            "basalSchedule": basalSchedule.rawValue,
            "unstoredDoses": unstoredDoses.map { $0.rawValue },
            "silencePod": silencePod,
            "confirmationBeeps": confirmationBeeps.rawValue,
            "activeAlerts": activeAlerts.map { $0.rawValue },
            "podAttachmentConfirmed": podAttachmentConfirmed,
            "acknowledgedTimeOffsetAlert": acknowledgedTimeOffsetAlert,
            "alertsWithPendingAcknowledgment": alertsWithPendingAcknowledgment.map { $0.rawValue },
            "initialConfigurationCompleted": initialConfigurationCompleted,
            "maxBasalRateUnitsPerHour": maxBasalRateUnitsPerHour,
            "maxBolusUnits": maxBolusUnits,
            "controllerId": controllerId,
            "podId": podId,
        ]

        value["podType"] = podType.rawValue
        value["insulinType"] = insulinType?.rawValue
        value["podState"] = podState?.rawValue
        value["rileyLinkConnectionManagerState"] = rileyLinkConnectionManagerState?.rawValue
        value["scheduledExpirationReminderOffset"] = scheduledExpirationReminderOffset
        value["defaultExpirationReminderOffset"] = defaultExpirationReminderOffset
        value["lowReservoirReminderValue"] = lowReservoirReminderValue
        value["defaultLowReservoirReminderValue"] = defaultLowReservoirReminderValue
        value["lastPumpDataReportDate"] = lastPumpDataReportDate
        value["silencePodEnd"] = silencePodEnd
        value["previousPodState"] = previousPodState?.rawValue

        return value
    }
}

extension OmniPumpManagerState {
    var hasActivePod: Bool {
        return podState?.isActive == true
    }

    var hasSetupPod: Bool {
        return podState?.isSetupComplete == true
    }

    var isPumpDataStale: Bool {
        let pumpStatusAgeTolerance = TimeInterval(minutes: 6)
        let pumpDataAge = -(self.lastPumpDataReportDate ?? .distantPast).timeIntervalSinceNow
        return pumpDataAge > pumpStatusAgeTolerance
    }
}

extension OmniPumpManagerState: CustomDebugStringConvertible {
    public var debugDescription: String {
        var retVal = [
            "## OmniPumpManagerState",
            "* isOnboarded: \(isOnboarded)",
            "* timeZone: \(timeZone)",
            "* basalSchedule: \(String(describing: basalSchedule))",
            "* maxBasalRateUnitsPerHour: \(maxBasalRateUnitsPerHour)",
            "* maxBolusUnits: \(maxBolusUnits)",
            "* unstoredDoses: \(String(describing: unstoredDoses))",
            "* suspendEngageState: \(String(describing: suspendEngageState))",
            "* bolusEngageState: \(String(describing: bolusEngageState))",
            "* tempBasalEngageState: \(String(describing: tempBasalEngageState))",
            "* lastPumpDataReportDate: \(optionalString(lastPumpDataReportDate))",
            "* isPumpDataStale: \(String(describing: isPumpDataStale))",
            "* silencePod: \(String(describing: silencePod))",
            "* silencePodEnd: \(optionalString(silencePodEnd))",
            "* confirmationBeeps: \(String(describing: confirmationBeeps))",
            "* insulinType: \(optionalString(insulinType))",
            "* scheduledExpirationReminderOffset: \(optionalString(scheduledExpirationReminderOffset?.timeIntervalStr))",
            "* defaultExpirationReminderOffset: \(defaultExpirationReminderOffset.timeIntervalStr)",
            "* lowReservoirReminderValue: \(lowReservoirReminderValue)",
            "* defaultLowReservoirReminderValue: \(defaultLowReservoirReminderValue)",
            "* podAttachmentConfirmed: \(podAttachmentConfirmed)",
            "* activeAlerts: \(activeAlerts)",
            "* alertsWithPendingAcknowledgment: \(alertsWithPendingAcknowledgment)",
            "* acknowledgedTimeOffsetAlert: \(acknowledgedTimeOffsetAlert)",
            "* initialConfigurationCompleted: \(initialConfigurationCompleted)",
            "* podType: \(podType)",
            "",
        ].joined(separator: "\n")
        if podType.usesRileyLink {
            retVal += [
                "* pairingAttemptAddress: \(optionalString(pairingAttemptAddress))",
                "* rileyLinkBatteryAlertLevel: \(optionalString(rileyLinkBatteryAlertLevel))",
                "* lastRileyLinkBatteryAlertDate \(optionalString(lastRileyLinkBatteryAlertDate))",
                "* rileyLinkConnectionManagerState: \(optionalString(rileyLinkConnectionManagerState))",
            ].joined(separator: "\n")
        } else {
            retVal += [
                "* controllerId: \(String(format: "%08X", controllerId))",
                "* podId: \(String(format: "%08X", podId))",
            ].joined(separator: "\n")
        }
        retVal += [
            "",
            "",
            "* podState: \(optionalString(podState))",
            "",
            "* previousPodState: \(optionalString(previousPodState))",
            "",
        ].joined(separator: "\n")
        return retVal
    }
}
