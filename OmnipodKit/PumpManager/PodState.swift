//
//  PodState.swift
//  OmnipodKit
//
//  Based on Omni{BLE,Kit}/PumpManager/PodState.swift
//  Created by Joe Moran on 12/31/24.
//  Copyright © 2024 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import os.log

private let log = OSLog(category: "PodState")

enum SetupProgress: Int {
    case addressAssigned = 0
    case podPaired
    case startingPrime
    case priming
    case settingInitialBasalSchedule
    case initialBasalScheduleSet
    case startingInsertCannula
    case cannulaInserting
    case completed
    case activationTimeout
    case podIncompatible

    var isPaired: Bool {
        return self.rawValue >= SetupProgress.podPaired.rawValue
    }

    var primingNeverAttempted: Bool {
        return self.rawValue < SetupProgress.startingPrime.rawValue
    }

    var primingNeeded: Bool {
        return self.rawValue < SetupProgress.priming.rawValue
    }

    var needsInitialBasalSchedule: Bool {
        return self.rawValue < SetupProgress.initialBasalScheduleSet.rawValue
    }

    var needsCannulaInsertion: Bool {
        return self.rawValue < SetupProgress.completed.rawValue
    }

    var cannulaInsertionSuccessfullyStarted: Bool {
        return self.rawValue > SetupProgress.startingInsertCannula.rawValue
    }
}

// TODO: Mutating functions aren't guaranteed to synchronize read/write calls.
// mutating funcs should be moved to something like this:
// extension Locked where T == PodState {
// }
// XXX still needs be declared public with the current Trio implementation
public struct PodState: RawRepresentable, Equatable, CustomDebugStringConvertible {

    public typealias RawValue = [String: Any]

    let address: UInt32

    // XXX these variables still needs be declared public with the current Trio implementation
    public var expiresAt: Date? // set based on timeActive and can change with Pod clock drift and/or system time change
    public var activatedAt: Date?
    var deliveryStoppedAt: Date? // set on first pod fault or on pod deactivation

    var podTime: TimeInterval // pod time from the last response, always whole minute values
    var podTimeUpdated: Date? // time that the podTime value was last updated

    var setupUnitsDelivered: Double?

    let firmwareVersion: String // (PM version on Eros)
    let iFirmwareVersion: String // interface firmware version (PI version on Eros)
    let lotNo: UInt32
    let lotSeq: UInt32
    var podType: PodType

    var activeAlertSlots: AlertSet

    // XXX still needs be declared public with the current Trio implementation
    public var lastInsulinMeasurements: PodInsulinMeasurements?

    var unacknowledgedCommand: PendingCommand?

    var unfinalizedBolus: UnfinalizedDose?
    // XXX still needs be declared public with the current Trio implementation
    public var unfinalizedTempBasal: UnfinalizedDose?
    var unfinalizedSuspend: UnfinalizedDose?
    var unfinalizedResume: UnfinalizedDose?

    var finalizedDoses: [UnfinalizedDose]

    var dosesToStore: [UnfinalizedDose] {
        /// Also include unfinalized bolus and temp basal doses which are mututable until finalized.
        /// Suspends and resumes are now "finalized" upon getting a response confirming delivery state.
        return finalizedDoses + [unfinalizedBolus, unfinalizedTempBasal].compactMap {$0}
    }

    var suspendState: SuspendState

    var isSuspended: Bool {
        if case .suspended = suspendState {
            return true
        }
        return false
    }

    var fault: DetailedStatus?

    var primeFinishTime: Date?
    var setupProgress: SetupProgress
    var configuredAlerts: [AlertSlot: PodAlert]
    var insulinType: InsulinType

    // Allow a grace period while the unacknowledged command is first being sent.
    var needsCommsRecovery: Bool {
        if let unacknowledgedCommand = unacknowledgedCommand, !unacknowledgedCommand.isInFlight {
            return true
        }
        return false
    }

    // BLE specific variables
    var bleMessageTransportState: BleMessageTransportState
    var ltk: Data? = nil
    var bleIdentifier: String? = nil
    var signingKey: Data? = nil // O5 only

    // Eros specific variables
    var erosMessageTransportState: ErosMessageTransportState
    var nonceState: NonceState? = nil

    var lastDeliveryStatusReceived: DeliveryStatus? // this variable is not persistent across app restarts


    init(
        address: UInt32,
        firmwareVersion: String,
        iFirmwareVersion: String,
        lotNo: UInt32,
        lotSeq: UInt32,
        insulinType: InsulinType,
        podType: PodType,

        // BLE specific variables
        bleMessageTransportState: BleMessageTransportState? = nil,
        ltk: Data? = nil,
        bleIdentifier: String? = nil,
        signingKey: Data? = nil, // O5 only

        // Eros specific variables
        erosMessageTransportState: ErosMessageTransportState? = nil,

        setupUnitsDelivered: Double? = nil,
        initialDeliveryStatus: DeliveryStatus? = nil)
    {
        self.address = address
        self.firmwareVersion = firmwareVersion
        self.iFirmwareVersion = iFirmwareVersion
        self.lotNo = lotNo
        self.lotSeq = lotSeq
        self.insulinType = insulinType
        self.podType = podType

        self.setupUnitsDelivered = setupUnitsDelivered // can be non-zero with simulator
        self.lastDeliveryStatusReceived = initialDeliveryStatus // can be non-nil when testing

        self.lastInsulinMeasurements = nil
        self.finalizedDoses = []
        self.suspendState = .resumed(Date())
        self.fault = nil
        self.activeAlertSlots = .none
        self.primeFinishTime = nil
        self.setupProgress = .addressAssigned
        self.configuredAlerts = [.slot7Expired: .waitingForPairingReminder]
        self.podTime = 0

        if podType.isEros {
            // Eros specific initializations, nonceState will be initialized on initial nonce resync()
            if let erosMessageTransportState = erosMessageTransportState {
                self.erosMessageTransportState = erosMessageTransportState
            } else {
                self.erosMessageTransportState = ErosMessageTransportState()
            }
            self.bleMessageTransportState = BleMessageTransportState()
        } else {
            // BLE specific initializations
            self.ltk = ltk
            self.bleIdentifier = bleIdentifier
            self.signingKey = signingKey // O5 only
            if let bleMessageTransportState = bleMessageTransportState {
                self.bleMessageTransportState = bleMessageTransportState
            } else {
                self.bleMessageTransportState = BleMessageTransportState()
            }
            self.erosMessageTransportState = ErosMessageTransportState()
        }
    }


    // MARK: - PodState computed var's

    var unfinishedSetup: Bool {
        return setupProgress != .completed
    }

    var readyForCannulaInsertion: Bool {
        guard let primeFinishTime = self.primeFinishTime else {
            return false
        }
        return !setupProgress.primingNeeded && primeFinishTime.timeIntervalSinceNow < 0
    }

    var isActive: Bool {
        return setupProgress == .completed && fault == nil
    }

    // variation on isActive that doesn't care if Pod is faulted
    var isSetupComplete: Bool {
        return setupProgress == .completed
    }

    var isFaulted: Bool {
        return fault != nil || setupProgress == .activationTimeout || setupProgress == .podIncompatible
    }

    // MARK: - 32-bit message nonce var's and func's

    var currentNonce: UInt32 {
        if self.nonceState != nil {
            // Eros pod, return the current 32-bit nonce
            return self.nonceState!.currentNonce
        }
        // For non-Eros pods the 32-bit message nonce must be this particular fixed value
        let fixedNonceValue: UInt32 = 0x494E532E
        return fixedNonceValue
    }

    mutating func advanceToNextNonce() {
        if self.nonceState != nil {
            // Eros pod, advance to the next 32-bit message nonce
            self.nonceState!.advanceToNextNonce()
            return
        }
        // For non-Eros pods this 32-bit message nonce is fixed and is never advanced
    }

    mutating func resyncNonce(syncWord: UInt16, sentNonce: UInt32, messageSequenceNum: Int) {
        if self.podType.isEros {
            // Need to initialize or reseed the pod's nonceState
            let sum = (sentNonce & 0xFFFF) + UInt32(crc16Table[messageSequenceNum]) + (lotNo & 0xFFFF) + (lotSeq & 0xFFFF)
            let seed = UInt16(sum & 0xFFFF) ^ syncWord
            self.nonceState = NonceState(lot: lotNo, tid: lotSeq, seed: seed)
        } else {
            print("resyncNonce expectedly called!") // Should never be called for non-Eros pod!
        }
    }

    // BLE specific
    mutating func incrementEapSeq() -> Int {
        self.bleMessageTransportState.eapSeq += 1
        return bleMessageTransportState.eapSeq
    }

    // MARK: - PodState update funcs

    // Saves the current pod timeActive and will initialize the activatedAtComputed at
    // pod startup and updates the expiresAt value to account for pod clock differences.
    private mutating func updatePodTimes(timeActive: TimeInterval) -> Date {
        let now = Date()

        guard timeActive >= self.podTime else {
            // The pod active time went backwards and thus we have an apparent reset fault.
            // Don't update any times or displayed expiresAt time will expectedly jump.
            return now
        }

        self.podTime = timeActive
        self.podTimeUpdated = now

        let activatedAtComputed = now - timeActive
        if activatedAt == nil {
            self.activatedAt = activatedAtComputed
        }
        let expiresAtComputed = activatedAtComputed + Pod.nominalPodLife
        if expiresAt == nil {
            self.expiresAt = expiresAtComputed
        } else if expiresAtComputed < self.expiresAt! || expiresAtComputed > (self.expiresAt! + TimeInterval(minutes: 1)) {
            // The computed expiresAt time is earlier than or more than a minute later than the current expiresAt time,
            // so use the computed expiresAt time instead to handle Pod clock drift and/or system time changes issues.
            // The more than a minute later test prevents oscillation of expiresAt based on the timing of the responses.
            self.expiresAt = expiresAtComputed
        }
        return now
    }

    mutating func updateFromStatusResponse(_ response: StatusResponse, at date: Date = Date()) {
        let now = updatePodTimes(timeActive: response.timeActive)
        updateDeliveryStatus(deliveryStatus: response.deliveryStatus, podProgressStatus: response.podProgressStatus, bolusNotDelivered: response.bolusNotDelivered, at: date)

        let setupUnits = setupUnitsDelivered ?? Pod.primeUnits + Pod.cannulaInsertionUnits + Pod.cannulaInsertionUnitsExtra

        // Calculated new delivered value which will be a negative value until setup has completed OR after a pod reset fault
        let calcDelivered = response.insulinDelivered - setupUnits

        // insulinDelivered should never be a negative value or decrease from the previous saved delivered value
        let prevDelivered = lastInsulinMeasurements?.delivered ?? 0
        let insulinDelivered = max(calcDelivered, prevDelivered)

        lastInsulinMeasurements = PodInsulinMeasurements(insulinDelivered: insulinDelivered, reservoirLevel: response.reservoirLevel, validTime: now)

        activeAlertSlots = response.alerts
    }

    mutating func registerConfiguredAlert(slot: AlertSlot, alert: PodAlert) {
        configuredAlerts[slot] = alert
    }

    mutating func finalizeAllDoses() {
        if let bolus = unfinalizedBolus {
            finalizedDoses.append(bolus)
            unfinalizedBolus = nil
        }

        if let tempBasal = unfinalizedTempBasal {
            finalizedDoses.append(tempBasal)
            unfinalizedTempBasal = nil
        }
    }

    // Giving up on pod; we will assume commands failed/succeeded in the direction of positive net delivery
    mutating func resolveAnyPendingCommandWithUncertainty() {
        guard let pendingCommand = unacknowledgedCommand else {
            return
        }

        switch pendingCommand {
        case .program(let program, _, let commandDate, _):

            if let dose = program.unfinalizedDose(at: commandDate, withCertainty: .uncertain, insulinType: insulinType) {
                switch dose.doseType {
                case .bolus:
                    if dose.isFinished() {
                        finalizedDoses.append(dose)
                    } else {
                        unfinalizedBolus = dose
                    }
                case .tempBasal:
                    // Assume a high temp succeeded, but low temp failed
                    if case .tempBasal(_, _, let isHighTemp, _) = program, isHighTemp {
                        if dose.isFinished() {
                            finalizedDoses.append(dose)
                        } else {
                            unfinalizedTempBasal = dose
                        }
                    }
                case .resume:
                    finalizedDoses.append(dose)
                case .suspend:
                    break // start program is never a suspend
                }
            }
        case .stopProgram(let stopProgram, _, let commandDate, _):
            // All stop programs result in reduced delivery, except for stopping a low temp, so we assume all stop
            // commands failed, except for low temp

            if stopProgram.contains(.tempBasal),
                let tempBasal = unfinalizedTempBasal,
                tempBasal.isHighTemp,
                !tempBasal.isFinished(at: commandDate)
            {
                unfinalizedTempBasal?.cancel(at: commandDate)
            }
        }
        self.unacknowledgedCommand = nil
    }

    private mutating func updateDeliveryStatus(deliveryStatus: DeliveryStatus, podProgressStatus: PodProgressStatus, bolusNotDelivered: Double, at date: Date) {

        // save the current pod delivery state for verification before any insulin delivery command
        self.lastDeliveryStatusReceived = deliveryStatus

        // See if the pod's deliveryStatus indicates some insulin delivery that podState isn't tracking
        if deliveryStatus.bolusing && unfinalizedBolus == nil { // active bolus that we aren't tracking
            if podProgressStatus.readyForDelivery {
                // Create an unfinalizedBolus with the remaining bolus amount to capture what we can.
                unfinalizedBolus = UnfinalizedDose(bolusAmount: bolusNotDelivered, startTime: date, scheduledCertainty: .certain, insulinType: insulinType, automatic: false)
            }
        }
        if deliveryStatus.tempBasalRunning && unfinalizedTempBasal == nil { // active temp basal that we aren't tracking
            // unfinalizedTempBasal = UnfinalizedDose(tempBasalRate: 0, startTime: date, duration: .minutes(30), isHighTemp: false, scheduledCertainty: .certain, insulinType: insulinType)
        }
        if !deliveryStatus.suspended && isSuspended { // active basal that we aren't tracking
            let resumeStartTime = date
            suspendState = .resumed(resumeStartTime)
            unfinalizedResume = UnfinalizedDose(resumeStartTime: resumeStartTime, scheduledCertainty: .certain, insulinType: insulinType)
        }

        if var bolus = unfinalizedBolus, !deliveryStatus.bolusing {
            // Due to clock drift or comms delays, boluses can finish earlier than we expect
            if !bolus.isFinished() {
                bolus.finishTime = date
            }
            finalizedDoses.append(bolus)
            unfinalizedBolus = nil
        }

        if var tempBasal = unfinalizedTempBasal, !deliveryStatus.tempBasalRunning {
            if !tempBasal.isFinished() {
                tempBasal.finishTime = date
            }
            finalizedDoses.append(tempBasal)
            unfinalizedTempBasal = nil
        }

        /// Resumes and suspends have no associated delivery amounts to be finalized,
        /// but we finalize these "doses" as soon as we have deliveryStatus confirmation
        /// so the associated resume and suspend events can be created without delay.

        if let resume = unfinalizedResume, !deliveryStatus.suspended {
            finalizedDoses.append(resume)
            unfinalizedResume = nil
        }

        if let suspend = unfinalizedSuspend, deliveryStatus.suspended {
            finalizedDoses.append(suspend)
            unfinalizedSuspend = nil
        }
    }

    @discardableResult
    mutating func handleCancelDosing(deliveryType: CancelDeliveryCommand.DeliveryType, bolusNotDelivered: Double, at now: Date = Date()) -> UnfinalizedDose?
    {
        var canceledDose: UnfinalizedDose? = nil

        if deliveryType.contains(.basal) {
            unfinalizedSuspend = UnfinalizedDose(suspendStartTime: now, scheduledCertainty: .certain)
            suspendState = .suspended(now)
        }

        if let tempBasal = unfinalizedTempBasal,
            let finishTime = tempBasal.finishTime,
            deliveryType.contains(.tempBasal),
            finishTime > now
        {
            unfinalizedTempBasal?.cancel(at: now)
            if !deliveryType.contains(.basal) {
                suspendState = .resumed(now)
            }
            canceledDose = unfinalizedTempBasal
            print("Interrupted temp basal: \(String(describing: canceledDose))")
        }

        if let bolus = unfinalizedBolus,
            let finishTime = bolus.finishTime,
            deliveryType.contains(.bolus),
            finishTime > now
        {
            unfinalizedBolus?.cancel(at: now, withRemaining: bolusNotDelivered)
            canceledDose = unfinalizedBolus
            print("Interrupted bolus: \(String(describing: canceledDose))")
        }

        return canceledDose
    }

    // MARK: - RawRepresentable
    public init?(rawValue: RawValue) {
        log.bleDebug("[PodState] init with rawValue: %{public}@", String(describing: rawValue))

        guard
            let address = rawValue["address"] as? UInt32,
            let lotNo = rawValue["lotNo"] as? UInt32 ?? rawValue["lot"] as? UInt32,
            let lotSeq = rawValue["lotSeq"] as? UInt32 ?? rawValue["tid"] as? UInt32
            else {
                return nil
            }

        self.address = address
        self.lotNo = lotNo
        self.lotSeq = lotSeq

        let formatVersion: Int = rawValue["version"] as? Int ?? 1

        if let firmwareVersion = rawValue["firmwareVersion"] as? String {
            self.firmwareVersion = firmwareVersion
        } else if let pmVersion = rawValue["pmVersion"] as? String {
            self.firmwareVersion = pmVersion // OmniKit
        } else {
            return nil
        }

        if let iFirmwareVersion = rawValue["iFirmwareVersion"] as? String {
            self.iFirmwareVersion = iFirmwareVersion
        } else if let bleFirmwareVersion = rawValue["bleFirmwareVersion"] as? String {
            self.iFirmwareVersion = bleFirmwareVersion // OmniBLE
        } else if let piVersion = rawValue["piVersion"] as? String {
            self.iFirmwareVersion = piVersion // OmniKit
        } else {
            return nil
        }

        if let activatedAt = rawValue["activatedAt"] as? Date {
            self.activatedAt = activatedAt
            if let expiresAt = rawValue["expiresAt"] as? Date {
                self.expiresAt = expiresAt
            } else {
                self.expiresAt = activatedAt + Pod.nominalPodLife
            }
            if let deliveryStoppedAt = rawValue["deliveryStoppedAt"] as? Date {
                self.deliveryStoppedAt = deliveryStoppedAt
            } else if let activeTime = rawValue["activeTime"] as? TimeInterval {
                self.deliveryStoppedAt = activatedAt + activeTime
            }
        }

        if let podTime = rawValue["podTime"] as? TimeInterval,
            let podTimeUpdated = rawValue["podTimeUpdated"] as? Date
        {
            self.podTime = podTime
            self.podTimeUpdated = podTimeUpdated
        } else {
            self.podTime = 0
            self.podTimeUpdated = Date()
        }

        if let setupUnitsDelivered = rawValue["setupUnitsDelivered"] as? Double {
            self.setupUnitsDelivered = setupUnitsDelivered
        }

        if let suspended = rawValue["suspended"] as? Bool {
            // Migrate old value
            if suspended {
                suspendState = .suspended(Date())
            } else {
                suspendState = .resumed(Date())
            }
        } else if let rawSuspendState = rawValue["suspendState"] as? SuspendState.RawValue, let suspendState = SuspendState(rawValue: rawSuspendState) {
            self.suspendState = suspendState
        } else {
            return nil
        }

        if let rawPendingCommand = rawValue["unacknowledgedCommand"] as? PendingCommand.RawValue {
            // When loading from raw state, we know comms are no longer in progress; this helps recover from a crash
            self.unacknowledgedCommand = PendingCommand(rawValue: rawPendingCommand)?.commsFinished
        } else {
            self.unacknowledgedCommand = nil
        }

        if let rawUnfinalizedBolus = rawValue["unfinalizedBolus"] as? UnfinalizedDose.RawValue {
            self.unfinalizedBolus = UnfinalizedDose(rawValue: rawUnfinalizedBolus)
        }

        if let rawUnfinalizedTempBasal = rawValue["unfinalizedTempBasal"] as? UnfinalizedDose.RawValue {
            self.unfinalizedTempBasal = UnfinalizedDose(rawValue: rawUnfinalizedTempBasal)
        }

        if let rawUnfinalizedSuspend = rawValue["unfinalizedSuspend"] as? UnfinalizedDose.RawValue {
            self.unfinalizedSuspend = UnfinalizedDose(rawValue: rawUnfinalizedSuspend)
        }

        if let rawUnfinalizedResume = rawValue["unfinalizedResume"] as? UnfinalizedDose.RawValue {
            self.unfinalizedResume = UnfinalizedDose(rawValue: rawUnfinalizedResume)
        }

        if let rawLastInsulinMeasurements = rawValue["lastInsulinMeasurements"] as? PodInsulinMeasurements.RawValue {
            self.lastInsulinMeasurements = PodInsulinMeasurements(rawValue: rawLastInsulinMeasurements)
        } else {
            self.lastInsulinMeasurements = nil
        }

        if let rawFinalizedDoses = rawValue["finalizedDoses"] as? [UnfinalizedDose.RawValue] {
            self.finalizedDoses = rawFinalizedDoses.compactMap( { UnfinalizedDose(rawValue: $0) } )
        } else {
            self.finalizedDoses = []
        }

        if let rawFault = rawValue["fault"] as? DetailedStatus.RawValue,
           let fault = DetailedStatus(rawValue: rawFault),
           fault.faultEventCode.faultType != .noFaults
        {
            self.fault = fault
        } else {
            self.fault = nil
        }

        if let alarmsRawValue = rawValue["alerts"] as? UInt8 {
            self.activeAlertSlots = AlertSet(rawValue: alarmsRawValue)
        } else {
            self.activeAlertSlots = .none
        }

        if let setupProgressRaw = rawValue["setupProgress"] as? Int,
            let setupProgress = SetupProgress(rawValue: setupProgressRaw)
        {
            self.setupProgress = setupProgress
        } else {
            // Migrate
            self.setupProgress = .completed
        }

        if let rawConfiguredAlerts = rawValue["configuredAlerts"] as? [String: PodAlert.RawValue], formatVersion >= 2 {
            var configuredAlerts = [AlertSlot: PodAlert]()
            for (rawSlot, rawAlert) in rawConfiguredAlerts {
                if let slotNum = UInt8(rawSlot), let slot = AlertSlot(rawValue: slotNum), let alert = PodAlert(rawValue: rawAlert) {
                    configuredAlerts[slot] = alert
                }
            }
            self.configuredAlerts = configuredAlerts
        } else {
            // Assume migration, and set up with alerts that are normally configured
            self.configuredAlerts = [
                .slot2ShutdownImminent: .shutdownImminent(offset: 0, absAlertTime: 0),
                .slot3ExpirationReminder: .expirationReminder(offset: 0, absAlertTime: 0),
                .slot4LowReservoir: .lowReservoir(units: 0),
                .slot5SuspendedReminder: .podSuspendedReminder(active: false, offset: 0, suspendTime: 0),
                .slot6SuspendTimeExpired: .suspendTimeExpired(offset: 0, suspendTime: 0),
                .slot7Expired: .expired(offset: 0, absAlertTime: 0, duration: 0)
            ]
        }

        self.primeFinishTime = rawValue["primeFinishTime"] as? Date

        if let rawInsulinType = rawValue["insulinType"] as? InsulinType.RawValue, let insulinType = InsulinType(rawValue: rawInsulinType) {
            self.insulinType = insulinType
        } else {
            self.insulinType = .novolog
        }

        if let podTypeRaw = rawValue["podType"] as? UInt8 {
            self.podType = PodType(rawValue: podTypeRaw)
        } else if rawValue["ltk"] != nil {
            log.error("[PodState] init with rawValue has missing podType, assuming dashType")
            self.podType = dashType // assume OmniBLE
        } else {
            self.podType = erosType // OmniKit
        }

        switch podType {
        case erosType:
            self.bleMessageTransportState = BleMessageTransportState() /// dummy intialization
            if let erosMessageTransportStateRaw = rawValue["erosMessageTransportState"] as? ErosMessageTransportState.RawValue,
                let erosMessageTransportState = ErosMessageTransportState(rawValue: erosMessageTransportStateRaw)
            {
                self.erosMessageTransportState = erosMessageTransportState
            } else {
                self.erosMessageTransportState = ErosMessageTransportState()
            }

        case dashType, omnipod5Type:
            self.erosMessageTransportState = ErosMessageTransportState() /// dummy initialization
            if let bleMessageTransportStateRaw = rawValue["bleMessageTransportState"] as? BleMessageTransportState.RawValue,
                let bleMessageTransportState = BleMessageTransportState(rawValue: bleMessageTransportStateRaw)
            {
                self.bleMessageTransportState = bleMessageTransportState
            } else if let bleMessageTransportStateRaw = rawValue["messageTransportState"] as? BleMessageTransportState.RawValue,
                let bleMessageTransportState = BleMessageTransportState(rawValue: bleMessageTransportStateRaw)
            {
                self.bleMessageTransportState = bleMessageTransportState
            } else {
                self.bleMessageTransportState = BleMessageTransportState()
            }

            // BLE pod type specific values
            if let ltkString = rawValue["ltk"] as? String,
                let bleIdentifier = rawValue["bleIdentifier"] as? String
            {
                self.ltk = Data(hexadecimalString: ltkString)
                self.bleIdentifier = bleIdentifier
            }

            if podType.isO5 {
                if let signingKeyString = rawValue["signingKey"] as? String {
                    // This is the normal path for new O5 pods which should
                    // have the 32-byte signingKey initialized during pairing.
                    self.signingKey = Data(hexadecimalString: signingKeyString)
                } else {
                    // One time during conversion due to adding signingKey to PodState,
                    // for new pods this will automatically be initialized during pairing.
                    let controllerId = controllerIdForPodId(podId: address)
                    self.signingKey = try? O5CertificateStore(controllerId: controllerId).signingKey.rawRepresentation
                    if self.signingKey == nil {
                        // Without a saved signingKey as well as the needed certificate for pdmId,
                        // this pod will not be able to do any insulin, cancel, or deactivation commands.
                        // This should only occur for an artificially created testing situation.
                        log.default("@@@ initializion failed for 0x%08llX, continuing in limited mode...", controllerId)
                    } else {
                        log.default("@@@ PodState signingKey initialized for 0x%08llX", controllerId)
                    }
                }
            }

        default:
            return nil
        }
    }

    public var rawValue: RawValue {
        var rawValue: RawValue = [
            "version": 3, // <= 2 used by OmniKit & OmniBLE
            "address": address,
            "firmwareVersion": firmwareVersion,
            "iFirmwareVersion": iFirmwareVersion,
            "lotNo": lotNo,
            "lotSeq": lotSeq,
            "suspendState": suspendState.rawValue,
            "finalizedDoses": finalizedDoses.map({ $0.rawValue }),
            "alerts": activeAlertSlots.rawValue,
            "setupProgress": setupProgress.rawValue,
            "insulinType": insulinType.rawValue,
        ]

        rawValue["podType"] = podType.rawValue
        rawValue["unacknowledgedCommand"] = unacknowledgedCommand?.rawValue
        rawValue["unfinalizedBolus"] = unfinalizedBolus?.rawValue
        rawValue["unfinalizedTempBasal"] = unfinalizedTempBasal?.rawValue
        rawValue["unfinalizedSuspend"] = unfinalizedSuspend?.rawValue
        rawValue["unfinalizedResume"] = unfinalizedResume?.rawValue
        rawValue["lastInsulinMeasurements"] = lastInsulinMeasurements?.rawValue
        rawValue["fault"] = fault?.rawValue
        rawValue["primeFinishTime"] = primeFinishTime
        rawValue["activatedAt"] = activatedAt
        rawValue["expiresAt"] = expiresAt
        rawValue["deliveryStoppedAt"] = deliveryStoppedAt
        rawValue["podTime"] = podTime
        rawValue["podTimeUpdated"] = podTimeUpdated
        rawValue["setupUnitsDelivered"] = setupUnitsDelivered

        if configuredAlerts.count > 0 {
            let rawConfiguredAlerts = Dictionary(uniqueKeysWithValues:
                                                    configuredAlerts.map { slot, alarm in (String(describing: slot.rawValue), alarm.rawValue) })
            rawValue["configuredAlerts"] = rawConfiguredAlerts
        }

        if podType.isEros {
            rawValue["erosMessageTransportState"] = erosMessageTransportState.rawValue
        } else {
            rawValue["bleMessageTransportState"] = bleMessageTransportState.rawValue
            if let bleIdentifier = bleIdentifier {
                rawValue["bleIdentifier"] = bleIdentifier
            }
            if let ltk = ltk {
                rawValue["ltk"] = ltk.hexadecimalString
            }
            // O5 only
            if let signingKey = signingKey {
                rawValue["signingKey"] = signingKey.hexadecimalString
            }
        }

        return rawValue
    }


    // MARK: - CustomDebugStringConvertible

    public var debugDescription: String {
        let retVal = [
            "### PodState",
            "* address: \(String(format: "%08llX", address))",
            "* bleIdentifier: \(optionalString(bleIdentifier))",
            "* activatedAt: \(optionalString(activatedAt))",
            "* expiresAt: \(optionalString(expiresAt))",
            "* deliveryStoppedAt: \(optionalString(deliveryStoppedAt))",
            "* podTime: \(podTime.timeIntervalStr)",
            "* podTimeUpdated: \(optionalString(podTimeUpdated))",
            "* setupUnitsDelivered: \(optionalInsulinString(setupUnitsDelivered))",
            "* firmwareVersion: \(firmwareVersion)",
            "* iFirmwareVersion: \(iFirmwareVersion)",
            "* lotNo: \(lotNo)",
            "* lotSeq: \(lotSeq)",
            "* podTypeValue: \(podType.rawValue)",
            "* suspendState: \(suspendState)",
            "* unacknowledgedCommand: \(optionalString(unacknowledgedCommand))",
            "* unfinalizedBolus: \(optionalString(unfinalizedBolus))",
            "* unfinalizedTempBasal: \(optionalString(unfinalizedTempBasal))",
            "* unfinalizedSuspend: \(optionalString(unfinalizedSuspend))",
            "* unfinalizedResume: \(optionalString(unfinalizedResume))",
            "* finalizedDoses: \(String(describing: finalizedDoses))",
            "* activeAlertsSlots: \(alertSetString(alertSet: activeAlertSlots))",
            "* delivered: \(optionalInsulinString(lastInsulinMeasurements?.delivered))",
            "* reservoirLevel: \(lastInsulinMeasurements == nil || lastInsulinMeasurements!.reservoirLevel == nil || lastInsulinMeasurements!.reservoirLevel == Pod.reservoirLevelAboveThresholdMagicNumber ? "50+" : lastInsulinMeasurements!.reservoirLevel!.twoDecimals) U",
            "* setupProgress: \(setupProgress)",
            "* primeFinishTime: \(optionalString(primeFinishTime))",
            "* configuredAlerts: \(configuredAlertsString(configuredAlerts: configuredAlerts))",
            "* insulinType: \(optionalString(insulinType))",
            "* messageTransportState: \(podType.usesRileyLink ? String(describing: erosMessageTransportState) : String(describing: bleMessageTransportState))",
            "* pdmRef: \(optionalString(fault?.pdmRef))",
            "* fault: \(optionalString(fault))",
        ].joined(separator: "\n")
        return retVal
    }
}

enum SuspendState: Equatable, RawRepresentable {
    typealias RawValue = [String: Any]

    private enum SuspendStateType: Int {
        case suspend, resume
    }

    case suspended(Date)
    case resumed(Date)

    private var identifier: Int {
        switch self {
        case .suspended:
            return 1
        case .resumed:
            return 2
        }
    }

    init?(rawValue: RawValue) {
        guard let suspendStateType = rawValue["case"] as? SuspendStateType.RawValue,
            let date = rawValue["date"] as? Date else {
                return nil
        }
        switch SuspendStateType(rawValue: suspendStateType) {
        case .suspend?:
            self = .suspended(date)
        case .resume?:
            self = .resumed(date)
        default:
            return nil
        }
    }

    var rawValue: RawValue {
        switch self {
        case .suspended(let date):
            return [
                "case": SuspendStateType.suspend.rawValue,
                "date": date
            ]
        case .resumed(let date):
            return [
                "case": SuspendStateType.resume.rawValue,
                "date": date
            ]
        }
    }
}
