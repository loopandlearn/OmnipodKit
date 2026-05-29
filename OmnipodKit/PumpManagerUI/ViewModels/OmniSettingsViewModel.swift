//
//  OmniSettingsViewModel.swift
//  OmnipodKit
//
//  Based on OmniBLE/PumpManagerUI/ViewModels/OmniSettingsViewModel.swift
//  Created by Pete Schwamb on 3/8/20.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI
import HealthKit
import Combine


enum OmniSettingsViewAlert {
    case suspendError(Error)
    case resumeError(Error)
    case cancelManualBasalError(Error)
    case syncTimeError(OmniPumpManagerError)
}

enum ReservoirLevelHighlightState: String, Equatable {
    case normal
    case warning
    case critical
}

struct OmniSettingsNotice {
    let title: String
    let description: String
}

class OmniSettingsViewModel: ObservableObject {

    @Published var lifeState: PodLifeState

    @Published var activatedAt: Date?

    @Published var expiresAt: Date?

    @Published var beepPreference: BeepPreference

    @Published var silencePodPreference: SilencePodPreference

    @Published var silencePodEnd: Date?

    @Published var hasConnection: Bool // replaces both rileylinkConnected and isConnected

    var activatedAtString: String {
        guard let activatedAt = activatedAt else {
            return "—"
        }
        return dateFormatter.string(from: activatedAt)
    }

    var expiresAtString: String {
        guard let expiresAt = expiresAt else {
            return "—"
        }
        return dateFormatter.string(from: expiresAt)
    }

    var deliveryStoppedAtString: String {
        guard let deliveryStoppedAt = pumpManager.podDetails?.deliveryStoppedAt else {
            return "—"
        }
        return dateFormatter.string(from: deliveryStoppedAt)
    }

    var noDeliveryAtString: String {
        guard let expiresAt = expiresAt else {
            return "—"
        }
        /// Compute an adjusted activatedAt based on expiresAt which varies with pod clock skew
        let adjustedActivatedAt = expiresAt - Pod.nominalPodLife
        /// Use adjustedActivatedAt to compute the current adjusted pod shutdown time
        let noDeliveryAt = adjustedActivatedAt + Pod.serviceDuration
        return dateFormatter.string(from: noDeliveryAt)
    }

    var serviceTimeRemainingString: String? {
        guard let serviceTimeRemaining = pumpManager.podServiceTimeRemaining,
           let serviceTimeRemainingString = timeRemainingFormatter.string(from: serviceTimeRemaining) else
        {
            return nil
        }
        return serviceTimeRemainingString
    }

    // Expiration reminder date for current pod
    @Published var expirationReminderDate: Date?
    
    var allowedScheduledReminderDates: [Date]? {
        return pumpManager.allowedExpirationReminderDates
    }

    // Hours before expiration
    @Published var expirationReminderDefault: Int {
        didSet {
            self.pumpManager.defaultExpirationReminderOffset = .hours(Double(expirationReminderDefault))
        }
    }

    // Units to alert at
    @Published var lowReservoirAlertValue: Int

    // Default low reservoir alert value for new pods
    @Published var defaultLowReservoirAlertValue: Int

    @Published var basalDeliveryState: PumpManagerStatus.BasalDeliveryState?

    @Published var basalDeliveryRate: Double?

    @Published var activeAlert: OmniSettingsViewAlert? = nil {
        didSet {
            if activeAlert != nil {
                alertIsPresented = true
            }
        }
    }

    @Published var alertIsPresented: Bool = false {
        didSet {
            if !alertIsPresented {
                activeAlert = nil
            }
        }
    }

    @Published var reservoirLevel: ReservoirLevel?

    @Published var reservoirLevelHighlightState: ReservoirLevelHighlightState?

    @Published var synchronizingTime: Bool = false

    @Published var podCommState: PodCommState

    @Published var insulinType: InsulinType?

    @Published var podDetails: PodDetails?

    @Published var previousPodDetails: PodDetails?


    var timeZone: TimeZone {
        return pumpManager.status.timeZone
    }

    var viewTitle: String {
        return pumpManager.podType.description // "Omnipod Classic", "Omnipod DASH" or "Omnipod 5"
    }

    var isClockOffset: Bool {
        return pumpManager.isClockOffset
    }

    var isPodDataStale: Bool {
        return Date().timeIntervalSince(pumpManager.lastSync ?? .distantPast) > .minutes(12)
    }

    var recoveryText: String? {
        if case .fault = podCommState {
            return LocalizedString("⚠️ Insulin delivery stopped. Change Pod now.", comment: "The action string on pod status page when pod faulted")
        } else if podOk && isPodDataStale {
            return LocalizedString("Make sure your phone and pod are close to each other. If communication issues persist, move to a new area.", comment: "The action string on pod status page when pod data is stale")
        } else if let serviceTimeRemaining = pumpManager.podServiceTimeRemaining, serviceTimeRemaining <= Pod.serviceDuration - Pod.nominalPodLife {
            if let serviceTimeRemainingString = serviceTimeRemainingString {
                return String(format: LocalizedString("Change Pod now. Insulin delivery will stop in %1$@ or when no more insulin remains.", comment: "Format string for the action string on pod status page when pod expired. (1: service time remaining)"), serviceTimeRemainingString)
            } else {
                return LocalizedString("Change Pod now. Insulin delivery will stop 8 hours after the Pod has expired or when no more insulin remains.", comment: "The action string on pod status page when pod expired")
            }
        } else {
            return nil
        }
    }

    var notice: OmniSettingsNotice? {
        if pumpManager.isClockOffset {
            return OmniSettingsNotice(
                title: LocalizedString("Time Change Detected", comment: "title for time change detected notice"),
                description: LocalizedString("The time on your pump is different from the current time. Your pump’s time controls your scheduled therapy settings. Scroll down to Pump Time row to review the time difference and configure your pump.", comment: "description for time change detected notice"))
        } else {
            return nil
        }
    }

    var isScheduledBasal: Bool {
        switch basalDeliveryState {
        case .active(_), .initiatingTempBasal:
            return true
        case .tempBasal(_), .cancelingTempBasal, .suspending, .suspended(_), .resuming, .none:
            return false
        }
    }

    let dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.timeStyle = .short
        dateFormatter.dateStyle = .medium
        dateFormatter.doesRelativeDateFormatting = true
        return dateFormatter
    }()

    let timeFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.timeStyle = .short
        dateFormatter.dateStyle = .none
        return dateFormatter
    }()

    let timeRemainingFormatter: DateComponentsFormatter = {
        let dateComponentsFormatter = DateComponentsFormatter()
        dateComponentsFormatter.allowedUnits = [.hour, .minute]
        dateComponentsFormatter.unitsStyle = .full
        dateComponentsFormatter.zeroFormattingBehavior = .dropAll
        return dateComponentsFormatter
    }()

    let basalRateFormatter: NumberFormatter = {
        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        numberFormatter.minimumFractionDigits = 1
        numberFormatter.minimumIntegerDigits = 1
        return numberFormatter
    }()

    var manualBasalTimeRemaining: TimeInterval? {
        if case .tempBasal(let dose) = basalDeliveryState, !(dose.automatic ?? true) {
            let remaining = dose.endDate.timeIntervalSinceNow
            if remaining > 0 {
                return remaining
            }
        }
        return nil
    }

    let reservoirVolumeFormatter = QuantityFormatter(for: .internationalUnit())

    var didFinish: (() -> Void)?

    var navigateTo: ((OmniUIScreen) -> Void)?

    private let pumpManager: OmniPumpManager

    init(pumpManager: OmniPumpManager) {
        self.pumpManager = pumpManager
        
        lifeState = pumpManager.lifeState
        activatedAt = pumpManager.podActivatedAt
        expiresAt = pumpManager.expiresAt
        basalDeliveryState = pumpManager.status.basalDeliveryState
        basalDeliveryRate = pumpManager.basalDeliveryRate
        reservoirLevel = pumpManager.reservoirLevel
        reservoirLevelHighlightState = pumpManager.reservoirLevelHighlightState
        expirationReminderDate = pumpManager.scheduledExpirationReminder
        expirationReminderDefault = Int(pumpManager.defaultExpirationReminderOffset.hours)
        lowReservoirAlertValue = Int(pumpManager.state.lowReservoirReminderValue)
        defaultLowReservoirAlertValue = Int(pumpManager.state.defaultLowReservoirReminderValue)
        podCommState = pumpManager.podCommState
        beepPreference = pumpManager.beepPreference
        silencePodPreference = pumpManager.silencePod ? .enabled : .disabled
        silencePodEnd = pumpManager.silencePodEnd
        hasConnection = pumpManager.hasConnection
        insulinType = pumpManager.insulinType
        podDetails = pumpManager.podDetails
        previousPodDetails = pumpManager.previousPodDetails

        pumpManager.addPodStateObserver(self, queue: DispatchQueue.main)
        pumpManager.addStatusObserver(self, queue: DispatchQueue.main)

        pumpManager.setSyncSilencePodState(syncSilencePodState)

        // Trigger refresh
        pumpManager.getPodStatus() { _ in }

        if pumpManager.podType.usesRileyLink {
            pumpManager.updateRLConnectionStatus()
        }
    }

    func changeTimeZoneTapped() {
        synchronizingTime = true
        pumpManager.setTime { (error) in
            DispatchQueue.main.async {
                self.synchronizingTime = false
                self.lifeState = self.pumpManager.lifeState
                if let error = error {
                    self.activeAlert = .syncTimeError(error)
                }
            }
        }
    }

    func doneTapped() {
        self.didFinish?()
    }

    // Stop using currently selected pod type
    func stopUsingPodTypeTapped() {
        // Setting podType to unknownOmnipodType forces OmniUICoordinator to selectPodType
        self.pumpManager.podType = unknownOmnipodType
        DispatchQueue.main.async {
            self.didFinish?()
        }
    }

    // Stop using the OmnipodKit pumpManager altogether
    func stopUsingPumpTypeTapped() {
        // Prevent a later "Bluetooth use unsupported on this device" error
        self.pumpManager.forgetBluetoothManager()
        pumpManager.notifyDelegateOfDeactivation {
            DispatchQueue.main.async {
                self.didFinish?()
            }
        }
    }

    func suspendDelivery(duration: TimeInterval) {
        pumpManager.suspendDelivery(withSuspendReminders: duration) { (error) in
            DispatchQueue.main.async {
                if let error = error {
                    self.activeAlert = .suspendError(error)
                }
            }
        }
    }

    func resumeDelivery() {
        pumpManager.resumeDelivery { (error) in
            DispatchQueue.main.async {
                if let error = error {
                    self.activeAlert = .resumeError(error)
                }
            }
        }
    }

    func runTemporaryBasalProgram(unitsPerHour: Double, for duration: TimeInterval, completion: @escaping (PumpManagerError?) -> Void) {
        pumpManager.enactTempBasal(unitsPerHour: unitsPerHour, for: duration, automatic: false, completion: completion)
    }

    func saveScheduledExpirationReminder(_ selectedDate: Date?, _ completion: @escaping (Error?) -> Void) {
        if let podExpiresAt = pumpManager.podExpiresAt {
            var intervalBeforeExpiration : TimeInterval?
            if let selectedDate = selectedDate {
                intervalBeforeExpiration = .hours(round(podExpiresAt.timeIntervalSince(selectedDate).hours))
            }
            pumpManager.updateExpirationReminder(intervalBeforeExpiration) { (error) in
                DispatchQueue.main.async {
                    if error == nil {
                        self.expirationReminderDate = selectedDate
                    }
                    completion(error)
                }
            }
        }
    }

    func saveLowReservoirReminder(_ selectedValue: Int, _ completion: @escaping (Error?) -> Void) {
        pumpManager.updateLowReservoirReminder(selectedValue) { (error) in
            DispatchQueue.main.async {
                if error == nil {
                    self.lowReservoirAlertValue = selectedValue
                }
                completion(error)
            }
        }
    }

    func saveDefaultLowReservoirReminder(_ selectedValue: Int, _ completion: @escaping (Error?) -> Void) {
        pumpManager.updateLowReservoirDefaultReminder(selectedValue) { (error) in
            DispatchQueue.main.async {
                if error == nil {
                    self.defaultLowReservoirAlertValue = selectedValue
                }
                completion(error)
            }
        }
    }

    func playTestBeeps() async throws {
        try await pumpManager.playTestBeeps()
    }

    func setConfirmationBeeps(_ preference: BeepPreference, _ completion: @escaping (_ error: LocalizedError?) -> Void) {
        pumpManager.setConfirmationBeeps(newPreference: preference) { error in
            DispatchQueue.main.async {
                if error == nil {
                    self.beepPreference = preference
                }
                completion(error)
            }
        }
    }

    /// Called by the Omni pump manager after the silencePodEnd reached and silence pod mode disabled.
    func syncSilencePodState(_ silencePod: Bool, _ silencePodEnd: Date?) {
        DispatchQueue.main.async {
            self.silencePodPreference = silencePod ? .enabled : .disabled
            self.silencePodEnd = silencePodEnd
        }
    }

    func setSilencePod(_ silencePodPreference: SilencePodPreference, silencePodEnd: Date?,
                       _ completion: @escaping (_ error: LocalizedError?) -> Void)
    {
        pumpManager.setSilencePod(silencePod: silencePodPreference == .enabled,
                                  silencePodEnd: silencePodEnd) { error in
            DispatchQueue.main.async {
                if error == nil {
                    self.silencePodPreference = silencePodPreference
                    self.silencePodEnd = silencePodEnd
                }
                completion(error)
            }
        }
    }

    func didChangeInsulinType(_ newType: InsulinType?) {
        self.pumpManager.insulinType = newType
    }

    var podOk: Bool {
        guard basalDeliveryState != nil else { return false }

        switch podCommState {
        case .noPod, .activating, .deactivating, .fault:
            return false
        default:
            return true
        }
    }

    var noPod: Bool {
        return podCommState == .noPod
    }

    var diagnosticCommands: DiagnosticCommands {
        return pumpManager
    }

    var podError: String? {
        switch podCommState {
        case .fault(let status):
            guard let status = status else {
                return LocalizedString("Pod Fault", comment: "Error message for reservoir view during unspecified pod fault")
            }
            switch status.faultEventCode.faultType {
            case .reservoirEmpty:
                return LocalizedString("No Insulin", comment: "Error message for reservoir view when reservoir empty")
            case .exceededMaximumPodLife80Hrs:
                return LocalizedString("Pod Expired", comment: "Error message for reservoir view when pod expired")
            case .occluded, .occlusionCheckStartup1, .occlusionCheckStartup2, .occlusionCheckTimeouts1, .occlusionCheckTimeouts2, .occlusionCheckTimeouts3, .occlusionCheckPulseIssue, .occlusionCheckBolusProblem, .occlusionCheckAboveThreshold, .occlusionCheckValueTooHigh:
                return LocalizedString("Pod Occlusion", comment: "Error message for reservoir view when pod occlusion checks failed")
            default:
                return String(format: LocalizedString("Pod Fault %1$03lld", comment: "Error message for reservoir view during general pod fault: (1: fault code value)"), status.faultEventCode.rawValue)
            }
        case .active:
            if isPodDataStale {
                return LocalizedString("Signal Loss", comment: "Error message for reservoir view during signal loss")
            } else {
                return nil
            }
        default:
            return nil
        }
    }

    func reservoirText(for level: ReservoirLevel) -> String {
        switch level {
        case .aboveThreshold:
            let quantity = HKQuantity(unit: .internationalUnit(), doubleValue: Pod.maximumReservoirReading)
            let thresholdString = reservoirVolumeFormatter.string(from: quantity, includeUnit: false) ?? ""
            let unitString = reservoirVolumeFormatter.localizedUnitStringWithPlurality(forValue: Pod.maximumReservoirReading, avoidLineBreaking: true)
            return String(format: LocalizedString("%1$@+ %2$@", comment: "Format string for reservoir level above max measurable threshold. (1: measurable reservoir threshold) (2: units)"),
                          thresholdString, unitString)
        case .valid(let value):
            let quantity = HKQuantity(unit: .internationalUnit(), doubleValue: value)
            return reservoirVolumeFormatter.string(from: quantity) ?? ""
        }
    }

    var suspendResumeActionText: String {
        let defaultText = LocalizedString("Suspend Insulin Delivery", comment: "Text for suspend resume button when insulin delivery active")

        guard podOk else {
            return defaultText
        }

        switch basalDeliveryState {
        case .suspending:
            return LocalizedString("Suspending insulin delivery...", comment: "Text for suspend resume button when insulin delivery is suspending")
        case .suspended:
            return LocalizedString("Resume Insulin Delivery", comment: "Text for suspend resume button when insulin delivery is suspended")
        case .resuming:
            return LocalizedString("Resuming insulin delivery...", comment: "Text for suspend resume button when insulin delivery is resuming")
        default:
            return defaultText
        }
    }

    var basalTransitioning: Bool {
        switch basalDeliveryState {
        case .suspending, .resuming:
            return true
        default:
            return false
        }
    }

    func suspendResumeButtonColor(guidanceColors: GuidanceColors) -> Color {
        guard podOk else {
            return Color.secondary
        }
        switch basalDeliveryState {
        case .suspending, .resuming:
            return Color.secondary
        case .suspended:
            return guidanceColors.warning
        default:
            return .accentColor
        }
    }

    func suspendResumeActionColor() -> Color {
        guard podOk else {
            return Color.secondary
        }
        switch basalDeliveryState {
        case .suspending, .resuming:
            return Color.secondary
        default:
            return Color.accentColor
        }
    }

    var isSuspendedOrResuming: Bool {
        switch basalDeliveryState {
        case .suspended, .resuming:
            return true
        default:
            return false
        }
    }

    var allowedTempBasalRates: [Double] {
        return Pod.supportedTempBasalRates.filter { $0 <= pumpManager.state.maxBasalRateUnitsPerHour }
    }

    var podType: PodType {
        return pumpManager.podType
    }

}


extension OmniSettingsViewModel: PodStateObserver {
    func podStateDidUpdate(_ state: PodState?) {
        lifeState = self.pumpManager.lifeState
        basalDeliveryRate = self.pumpManager.basalDeliveryRate
        reservoirLevel = self.pumpManager.reservoirLevel
        activatedAt = state?.activatedAt
        expiresAt = state?.expiresAt
        reservoirLevelHighlightState = self.pumpManager.reservoirLevelHighlightState
        expirationReminderDate = self.pumpManager.scheduledExpirationReminder
        podCommState = self.pumpManager.podCommState
        beepPreference = self.pumpManager.beepPreference
        insulinType = self.pumpManager.insulinType
        podDetails = self.pumpManager.podDetails
        previousPodDetails = self.pumpManager.previousPodDetails
    }
 
    func podConnectionStateDidChange(isConnected: Bool) {
        self.hasConnection = isConnected
    }
}


extension OmniSettingsViewModel: PumpManagerStatusObserver {
    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {
        basalDeliveryState = self.pumpManager.status.basalDeliveryState
    }
}

extension OmniPumpManager {
    var lifeState: PodLifeState {
        switch podCommState {
        case .fault(let status):
            guard let status = status else {
                return .expired
            }
            switch status.faultEventCode.faultType {
            case .exceededMaximumPodLife80Hrs:
                return .expired
            default:
                let remaining = Pod.nominalPodLife - (status.faultEventTimeSinceActivation ?? Pod.nominalPodLife)
                let podTimeUntilReminder = remaining - (state.scheduledExpirationReminderOffset ?? 0)
                if remaining > 0 {
                    return .timeRemaining(timeUntilExpiration: remaining, timeUntilExpirationReminder: podTimeUntilReminder)
                } else {
                    return .expired
                }
            }

        case .noPod:
            return .noPod
        case .activating:
            return .podActivating
        case .deactivating:
            return .podDeactivating
        case .active:
            if let podTimeRemaining = podTimeRemaining {
                if podTimeRemaining > 0 {
                    let podTimeUntilReminder = podTimeRemaining - (state.scheduledExpirationReminderOffset ?? 0)
                    return .timeRemaining(timeUntilExpiration: podTimeRemaining, timeUntilExpirationReminder: podTimeUntilReminder)
                } else {
                    return .expired
                }
            } else {
                return .podDeactivating
            }
        }
    }

    var basalDeliveryRate: Double? {
        guard let podState = state.podState, !podState.isFaulted && !podState.isSuspended else {
            return nil // no pod, pod is faulted, or pod is suspended
        }
        if let tempBasal = podState.unfinalizedTempBasal, !tempBasal.isFinished() {
            // return the current unfinalized temp basal rate
            return tempBasal.rate
        }
        // return the scheduled basal rate for the current time
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = state.timeZone
        return state.basalSchedule.currentRate(using: calendar, at: dateGenerator())
    }

    fileprivate var podServiceTimeRemaining : TimeInterval? {
        guard let podTimeRemaining = podTimeRemaining, state.podState?.isFaulted == false else {
            return nil
        }
        return max(0, Pod.serviceDuration - Pod.nominalPodLife + podTimeRemaining)
    }

    private func podDetails(fromPodState podState: PodState, andDeviceName deviceName: String?) -> PodDetails {
        return PodDetails(
            podType: podState.podType,
            address: podState.address,
            lotNumber: podState.lotNo,
            sequenceNumber: podState.lotSeq,
            firmwareVersion: podState.firmwareVersion,
            bleFirmwareVersion: podState.iFirmwareVersion,
            deviceName: deviceName,
            totalDelivery: podState.lastInsulinMeasurements?.delivered,
            lastStatus: podState.lastInsulinMeasurements?.validTime,
            fault: podState.fault,
            activatedAt: podState.activatedAt,
            deliveryStoppedAt: podState.deliveryStoppedAt,
            podTime: podState.podTime,
        )
    }

    var podDetails: PodDetails? {
        guard let podState = state.podState else {
            return nil
        }
        return podDetails(fromPodState: podState, andDeviceName: deviceBLEName)
    }

    var previousPodDetails: PodDetails? {
        guard let podState = state.previousPodState else {
            return nil
        }
        return podDetails(fromPodState: podState, andDeviceName: nil)
    }

}

extension OmniPumpManager: DiagnosticCommands {
    func pumpManagerDetails() -> String {
        return debugDescription
    }
}
