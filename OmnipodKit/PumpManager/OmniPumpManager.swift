//
//  OmniPumpManager.swift
//  OmnipodKit
//
//  Based on Omni{BLE,Kit}/PumpManager/OmniBLEPumpManager.swift
//  Created by Joe Moran on 12/21/24.
//  Copyright © 2024 LoopKit Authors. All rights reserved.
//

import HealthKit
import LoopKit
import RileyLinkKit
import RileyLinkBLEKit
import CoreBluetooth
import UserNotifications
import Combine
import os.log

protocol PodStateObserver: AnyObject {
    func podStateDidUpdate(_ state: PodState?)
    func podConnectionStateDidChange(isConnected: Bool)
}

enum PodCommState: Equatable {
    case noPod
    case activating
    case active
    case fault(DetailedStatus?)
    case deactivating
}

enum OmniPumpManagerError: Error {
    case noPodPaired
    case insulinTypeNotConfigured
    case notReadyForCannulaInsertion
    case invalidSetting
    case podTypeNotConfigured
    case communication(Error)
    case state(Error)
}

extension OmniPumpManagerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noPodPaired:
            return LocalizedString("No pod paired", comment: "Error message shown when no pod is paired")
        case .insulinTypeNotConfigured:
            return LocalizedString("Insulin type not configured", comment: "Error description for insulin type not configured")
        case .notReadyForCannulaInsertion:
            return LocalizedString("Pod is not in a state ready for cannula insertion", comment: "Error message when cannula insertion fails because the pod is in an unexpected state")
        case .invalidSetting:
            return LocalizedString("Invalid Setting", comment: "Error description for invalid setting")
        case .podTypeNotConfigured:
            return LocalizedString("Pod type not configured", comment: "Error message when pod type is not configured")
        case .communication(let error):
            if let error = error as? LocalizedError {
                return error.errorDescription
            } else {
                return String(describing: error)
            }
        case .state(let error):
            if let error = error as? LocalizedError {
                return error.errorDescription
            } else {
                return String(describing: error)
            }
        }
    }

    var failureReason: String? {
        return nil
    }

    var recoverySuggestion: String? {
        switch self {
        case .noPodPaired:
            return LocalizedString("Please pair a new pod", comment: "Recovery suggestion shown when no pod is paired")
        default:
            return nil
        }
    }
}

// OmniPumpManager is declared as a derived class RileyLinkPumpManager
// even though for non-Eros pods the RileyLink code will not be used.
public class OmniPumpManager: RileyLinkPumpManager {

    // This string should match the PumpManagerIdentifier string.
    public static let pluginIdentifier: String = "Omni"

    // The displayed Insulin Pump name in Loop Settings and in the Pump Settings view
    public var localizedTitle: String

    static let podAlarmNotificationIdentifier = "Omni:\(LoopNotificationCategory.pumpFault.rawValue)"

    private lazy var cancellables = Set<AnyCancellable>()

    private var rileylinkConnected: Bool = false

    init(state: OmniPumpManagerState, rileyLinkDeviceProvider: RileyLinkDeviceProvider, dateGenerator: @escaping () -> Date = Date.init) {
        self.lockedState = Locked(state)
        let podComms: PodComms
        let podType = state.podType
        switch podType {
        case erosType:
            let erosPodComms = ErosPodComms.init(podState: state.podState, podType: podType)
            podComms = erosPodComms
        case dashType, omnipod5Type:
            let blePodComms = BlePodComms.init(podState: state.podState, podType: podType, myId: state.controllerId, podId: state.podId)
            podComms = blePodComms
        default:
            podComms = PodComms(podState: state.podState, podType: podType)
        }
        self.lockedPodComms = Locked(podComms)
        self.dateGenerator = dateGenerator
        self.localizedTitle = state.podType.description

        super.init(rileyLinkDeviceProvider: rileyLinkDeviceProvider)

        finishInit(podType: state.podType)
    }

    // Common initialization used after all mandatory fields are initialized
    fileprivate func finishInit(podType: PodType)
    {
        self.podComms.delegate = self
        self.podComms.messageLogger = self

        // If Eros, register for RileyLink device notifications
        if podType.isEros {
            NotificationCenter.default.publisher(for: .DeviceConnectionStateDidChange)
                .sink { [weak self] _ in
                    self?.updateRLConnectionStatus()
                }
                .store(in: &cancellables)
        }

        if podType.isDash {
            let nc = NotificationCenter.default
            nc.addObserver(
                self,
                selector: #selector(appMovedToBackground),
                name: UIApplication.didEnterBackgroundNotification,
                object: nil
            )
            nc.addObserver(
                self,
                selector: #selector(appMovedToForeground),
                name: UIApplication.willEnterForegroundNotification,
                object: nil
            )

            // Needed setup if pod keep alives might be used
            podKeepAliveSetup(refresh: refresh)
        }
    }

    func refresh() {
        // run in a separate thread?
        getPodStatus(canOptimize: true) { _ in }
    }

    public required convenience init?(rawState: PumpManager.RawStateValue) {
        guard let state = OmniPumpManagerState(rawValue: rawState) else {
            return nil
        }

        let deviceProvider: RileyLinkBluetoothDeviceProvider
        if let connectionManagerState = state.rileyLinkConnectionManagerState {
            deviceProvider = RileyLinkBluetoothDeviceProvider(autoConnectIDs: connectionManagerState.autoConnectIDs)
        } else {
            deviceProvider = RileyLinkBluetoothDeviceProvider(autoConnectIDs: [])
        }

        self.init(state: state, rileyLinkDeviceProvider: deviceProvider)

        deviceProvider.delegate = self
    }

    private var podComms: PodComms {
        get {
            return lockedPodComms.value
        }
        set {
            lockedPodComms.value = newValue
        }
    }

    private var lockedPodComms: Locked<PodComms>

    private let podStateObservers = WeakSynchronizedSet<PodStateObserver>()

    private let pumpDelegate = WeakSynchronizedDelegate<PumpManagerDelegate>()

    let log = OSLog(category: "OmniPumpManager")

    private var lastLoopRecommendation: Date?

    // Primarily used for testing
    let dateGenerator: () -> Date

    // XXX still needs be declared public with the current Trio implementation
    public var state: OmniPumpManagerState {
        return lockedState.value
    }

    private func setState(_ changes: (_ state: inout OmniPumpManagerState) -> Void) -> Void {
        return setStateWithResult(changes)
    }

    // Status can change even when state does not, because some status changes
    // purely based on time. This provides a mechanism to evaluate status changes
    // as time progresses and trigger status updates to clients.
    private func evaluateStatus() {
        setState { state in
            // status is evaluated in the setState call
        }
    }

    private func setStateWithResult<ReturnType>(_ changes: (_ state: inout OmniPumpManagerState) -> ReturnType) -> ReturnType {
        var oldValue: OmniPumpManagerState!
        var returnType: ReturnType!
        var shouldNotifyStatusUpdate = false
        var oldStatus: PumpManagerStatus?

        let newValue = lockedState.mutate { (state) in
            oldValue = state
            let oldStatusEvaluationDate = state.lastStatusChange
            let oldHighlight = buildPumpStatusHighlight(for: oldValue, andDate: oldStatusEvaluationDate)
            oldStatus = status(for: oldValue, at: oldStatusEvaluationDate)

            returnType = changes(&state)

            let newStatusEvaluationDate = Date()
            let newStatus = status(for: state, at: newStatusEvaluationDate)
            let newHighlight = buildPumpStatusHighlight(for: state, andDate: newStatusEvaluationDate)

            if oldStatus != newStatus || oldHighlight != newHighlight {
                shouldNotifyStatusUpdate = true
                state.lastStatusChange = newStatusEvaluationDate
            }
        }

        if oldValue.podState != newValue.podState {
            podStateObservers.forEach { (observer) in
                observer.podStateDidUpdate(newValue.podState)
            }

            if oldValue.podState?.lastInsulinMeasurements?.reservoirLevel != newValue.podState?.lastInsulinMeasurements?.reservoirLevel {
                if let lastInsulinMeasurements = newValue.podState?.lastInsulinMeasurements,
                   let reservoirLevel = lastInsulinMeasurements.reservoirLevel,
                   reservoirLevel != Pod.reservoirLevelAboveThresholdMagicNumber
                {
                    self.pumpDelegate.notify({ (delegate) in
                        self.log.info("DU: updating reservoir level %{public}@", String(describing: reservoirLevel))
                        delegate?.pumpManager(self, didReadReservoirValue: reservoirLevel, at: lastInsulinMeasurements.validTime) { _ in }
                    })
                }
            }

            if oldValue.podState?.setupProgress != newValue.podState?.setupProgress, newValue.podState?.setupProgress == .completed {
                self.pumpDelegate.notify() { (delegate) in
                    let date = Date()
                    let event = NewPumpEvent(date: date, dose: nil, raw: "Pod Change \(date)".data(using: .utf8)!, title: "Pod Change", type: .replaceComponent(componentType: .pump))
                    delegate?.pumpManager(self, hasNewPumpEvents: [event], lastReconciliation: self.lastSync, replacePendingEvents: false) { _ in }
                }
            }
        }

        // Ideally we ensure that oldValue.rawValue != newValue.rawValue, but the types aren't
        // defined as equatable
        pumpDelegate.notify { (delegate) in
            delegate?.pumpManagerDidUpdateState(self)
        }

        if let oldStatus = oldStatus, shouldNotifyStatusUpdate {
            notifyStatusObservers(oldStatus: oldStatus)
        }

        return returnType
    }

    private let lockedState: Locked<OmniPumpManagerState>

    private let statusObservers = WeakSynchronizedSet<PumpManagerStatusObserver>()

    private func notifyStatusObservers(oldStatus: PumpManagerStatus) {
        let status = self.status
        pumpDelegate.notify { (delegate) in
            delegate?.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
        }
        statusObservers.forEach { (observer) in
            observer.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
        }
    }

    private func logDeviceCommunication(_ message: String, type: DeviceLogEntryType = .send) {
        let podAddress: String
        if let address = state.podState?.address {
            podAddress = String(format: "%08X", address)
        } else {
            podAddress = "noPod   "
        }

        // Not dispatching here; if delegate queue is blocked, timestamps will be delayed
        self.pumpDelegate.delegate?.deviceManager(self, logEventForDeviceIdentifier: podAddress, type: type, message: message, completion: nil)
    }

    public func setMustProvideBLEHeartbeat(_ mustProvideBLEHeartbeat: Bool) {
        if self.state.podType.usesRileyLink {
            rileyLinkDeviceProvider.timerTickEnabled = self.state.isPumpDataStale || mustProvideBLEHeartbeat
        } else {
            provideHeartbeat = mustProvideBLEHeartbeat
        }
    }

    // The hasConnection var can be used to check the current connection status for all pod types.
    // For BLE pods, replaces the isConnected var which was true if the pod is currently connected.
    // For Eros pods, replaces the rileylinkConnected var in OmniKitUI/ViewModels/OmnpodSettingsViewModel
    // which was true if at least one RileyLink device is currently connected independent of pod availability.
    var hasConnection: Bool {
        if let blePodComms = self.podComms as? BlePodComms {
            // Return if the BLE pod is currently connected.
            return blePodComms.manager?.peripheral.state == .connected
        }
        if self.podComms is ErosPodComms {
            // Return if there is a currently connected RileyLink device.
            // N.B. This doesn't depend on whether there is even a paired pod.
            return self.rileylinkConnected
        }
        log.info("hasConnection: %@", OmniPumpManagerError.podTypeNotConfigured.localizedDescription)
        return false
    }


    // MARK: - BLE specific vars and funcs

    var deviceBLEName: String? {
        if let blePodComms = self.podComms as? BlePodComms {
            return blePodComms.manager?.peripheral.name
        }
        return nil
    }

    var provideHeartbeat: Bool = false  // Not persisted

    private var lastHeartbeat: Date = .distantPast

    private func issueHeartbeatIfNeeded() {
        if self.provideHeartbeat, dateGenerator().timeIntervalSince(lastHeartbeat) > .minutes(2) {
            self.pumpDelegate.notify { (delegate) in
                delegate?.pumpManagerBLEHeartbeatDidFire(self)
            }
            self.lastHeartbeat = Date()
        }
    }

    func omnipodPeripheralDidConnect(manager: PeripheralManager) {
        logDeviceCommunication("Pod connected \(manager.peripheral.identifier.uuidString)", type: .connection)
        notifyPodConnectionStateDidChange(isConnected: true)
    }

    func omnipodPeripheralDidDisconnect(peripheral: CBPeripheral, error: Error?) {
        logDeviceCommunication("Pod disconnected \(peripheral.identifier.uuidString) \(String(describing: error))", type: .connection)
        notifyPodConnectionStateDidChange(isConnected: false)
    }

    func omnipodPeripheralDidFailToConnect(peripheral: CBPeripheral, error: Error?) {
        logDeviceCommunication("Pod failed to connect \(peripheral.identifier.uuidString), \(String(describing: error))", type: .connection)
    }

    func omnipodPeripheralWasRestored(manager: PeripheralManager) {
        logDeviceCommunication("Pod peripheral was restored \(manager.peripheral.identifier.uuidString))", type: .connection)
        notifyPodConnectionStateDidChange(isConnected: manager.peripheral.state == .connected)
    }

    func notifyPodConnectionStateDidChange(isConnected: Bool) {
        podStateObservers.forEach { (observer) in
            observer.podConnectionStateDidChange(isConnected: isConnected)
        }
    }

    private let backgroundTask = BackgroundTask()
    @objc func appMovedToBackground() {
        backgroundTask.startBackgroundTask(hasPod: state.podState != nil)
    }

    @objc func appMovedToForeground() {
        backgroundTask.stopBackgroundTask()
    }

    typealias syncSilencePodStateFuncType = (_ silencePod: Bool, _ silencePodEnd: Date?) -> Void

    /// Function to be called when silencePod variables are updated
    private var syncSilencePodState: syncSilencePodStateFuncType?

    /// Initializes the resetSilencePodState var for callbacks when silence pod mode has changed
    func setSyncSilencePodState(_ callbackFunc: @escaping syncSilencePodStateFuncType) {
        syncSilencePodState = callbackFunc
    }


    // MARK: - RileyLink specific vars and funcs

    // Adapted from OmniKit/OmniKitUI/ViewModel/OmnipodSettingsViewModel:updateConnectionStatus().
    // Maintains the private rileyLinkConnected variable and notifies about RL connection updates.
    func updateRLConnectionStatus() {
        guard self.podComms is ErosPodComms else {
            return
        }

        rileyLinkDeviceProvider.getDevices { (devices) in
            DispatchQueue.main.async { [self] in
                let isRLConnected = devices.firstConnected != nil
                // Update our private local state variable formerly in OmnnipodSettingsViewModel
                self.rileylinkConnected = isRLConnected
                // Notify UI about a connection change using the updated RL connection state
                self.notifyPodConnectionStateDidChange(isConnected: isRLConnected)
            }
        }
    }

    var rileyLinkBatteryAlertLevel: Int? {
        get {
            return state.rileyLinkBatteryAlertLevel
        }
        set {
            setState { state in
                state.rileyLinkBatteryAlertLevel = newValue
            }
        }
    }

    public override var rileyLinkConnectionManagerState: RileyLinkConnectionState? {
        get {
            return state.rileyLinkConnectionManagerState
        }
        set {
            setState { (state) in
                state.rileyLinkConnectionManagerState = newValue
            }
        }
    }

    public override func deviceTimerDidTick(_ device: RileyLinkDevice) {
        pumpDelegate.notify { (delegate) in
            delegate?.pumpManagerBLEHeartbeatDidFire(self)
        }
    }

    public override func device(_ device: RileyLinkDevice, didUpdateBattery level: Int) {
        let repeatInterval: TimeInterval = .hours(1)

        if let alertLevel = state.rileyLinkBatteryAlertLevel,
           level <= alertLevel,
           state.lastRileyLinkBatteryAlertDate.addingTimeInterval(repeatInterval) < Date()
        {
            self.setState { state in
                state.lastRileyLinkBatteryAlertDate = Date()
            }
            self.pumpDelegate.notify { delegate in
                let identifier = Alert.Identifier(managerIdentifier: self.pluginIdentifier, alertIdentifier: "lowRLBattery")
                let alertBody = String(format: LocalizedString("\"%1$@\" has a low battery", comment: "Format string for low battery alert body for RileyLink. (1: device name)"), device.name ?? "unnamed")
                let content = Alert.Content(title: LocalizedString("Low RileyLink Battery", comment: "Title for RileyLink low battery alert"), body: alertBody, acknowledgeActionButtonLabel: LocalizedString("OK", comment: "Acknowledge button label for RileyLink low battery alert"))
                delegate?.issueAlert(Alert(identifier: identifier, foregroundContent: content, backgroundContent: content, trigger: .immediate))
            }
        }
    }


    // MARK: - CustomDebugStringConvertible

    public override var debugDescription: String {
        var retVal: String = "## OmniPumpManager\n"
        if state.podType.usesRileyLink {
            retVal += super.debugDescription
        } else {
            retVal += "* provideHeartbeat: \(provideHeartbeat)\n"
        }
        retVal += [
            "",
            "* podComms: \(String(reflecting: podComms))",
            "* connected: \(hasConnection)",
            "* statusObservers.count: \(statusObservers.cleanupDeallocatedElements().count)",
            "* status: \(String(describing: status))",
            "",
            "* podStateObservers.count: \(podStateObservers.cleanupDeallocatedElements().count)",
            "* state: \(String(reflecting: state))",
            ""
        ].joined(separator: "\n")
        return retVal
    }
}

extension OmniPumpManager {
    // MARK: - PodStateObserver

    func addPodStateObserver(_ observer: PodStateObserver, queue: DispatchQueue) {
        podStateObservers.insert(observer, queue: queue)
    }

    func removePodStateObserver(_ observer: PodStateObserver) {
        podStateObservers.removeElement(observer)
    }

    private func status(for state: OmniPumpManagerState, at date: Date = Date()) -> PumpManagerStatus {
        return PumpManagerStatus(
            timeZone: state.timeZone,
            device: device(for: state),
            pumpBatteryChargeRemaining: nil,
            basalDeliveryState: basalDeliveryState(for: state, at: date),
            bolusState: bolusState(for: state, at: date),
            insulinType: state.insulinType,
            deliveryIsUncertain: state.podState?.needsCommsRecovery == true
        )
    }

    private func device(for state: OmniPumpManagerState) -> HKDevice {
        if let podState = state.podState {
            return HKDevice(
                name: pluginIdentifier,
                manufacturer: "Insulet",
                model: state.podType.description,
                hardwareVersion: String(state.podType.rawValue),
                firmwareVersion: podState.firmwareVersion + " " + podState.iFirmwareVersion,
                softwareVersion: String(OmnipodKitVersionNumber),
                localIdentifier: String(format:"%04X", podState.address),
                udiDeviceIdentifier: nil
            )
        } else {
            return HKDevice(
                name: pluginIdentifier,
                manufacturer: "Insulet",
                model: state.podType.description,
                hardwareVersion: nil,
                firmwareVersion: nil,
                softwareVersion: String(OmnipodKitVersionNumber),
                localIdentifier: nil,
                udiDeviceIdentifier: nil
            )
        }
    }

    private func basalDeliveryState(for state: OmniPumpManagerState, at date: Date = Date()) -> PumpManagerStatus.BasalDeliveryState {
        // Treat a non-active (faulted or setup incomplete) pod just like no pod
        guard let podState = state.podState, podState.isActive else {
            return .active(.distantPast)
        }

        switch state.suspendEngageState {
        case .engaging:
            return .suspending
        case .disengaging:
            return .resuming
        case .stable:
            break
        }

        switch state.tempBasalEngageState {
        case .engaging:
            return .initiatingTempBasal
        case .disengaging:
            return .cancelingTempBasal
        case .stable:
            if let tempBasal = podState.unfinalizedTempBasal, !tempBasal.isFinished(at: date) {
                return .tempBasal(DoseEntry(tempBasal))
            }
            switch podState.suspendState {
            case .resumed(let date):
                return .active(date)
            case .suspended(let date):
                return .suspended(date)
            }
        }
    }

    private func bolusState(for state: OmniPumpManagerState, at date: Date = Date()) -> PumpManagerStatus.BolusState {
        guard let podState = state.podState else {
            return .noBolus
        }

        switch state.bolusEngageState {
        case .engaging:
            return .initiating
        case .disengaging:
            return .canceling
        case .stable:
            if let bolus = podState.unfinalizedBolus, !bolus.isFinished(at: date) {
                return .inProgress(DoseEntry(bolus))
            }
        }
        return .noBolus
    }

    // Returns true if there an unfinishedDose for a manual bolus (independent of whether it is finished)
    private var hasUnfinalizedManualBolus: Bool {
        if let automatic = state.podState?.unfinalizedBolus?.automatic, !automatic {
            return true
        }
        return false
    }

    // Returns true if there an unfinishedDose for a manual temp basal (independent of whether it is finished)
    private var hasUnfinalizedManualTempBasal: Bool {
        if let automatic = state.podState?.unfinalizedTempBasal?.automatic, !automatic {
            return true
        }
        return false
    }

    // Returns a computed pod time based on the pod time in the last response
    private var podTime: TimeInterval {
        get {
            guard let podState = state.podState else {
                return 0
            }
            let elapsed = -(podState.podTimeUpdated?.timeIntervalSinceNow ?? 0)
            let podActiveTime = podState.podTime + elapsed
            return podActiveTime
        }
    }

    // Returns a suitable beep command MessageBlock based the current beep preferences and
    // whether there is an unfinializedDose for a manual temp basal &/or a manual bolus.
    private func beepMessageBlock(beepType: BeepType) -> MessageBlock? {
        guard state.confirmationBeeps.shouldBeepForManualCommand && !state.silencePod else {
            return nil
        }

        // Enable temp basal & basal completion beeps if there is a cooresponding manual unfinalizedDose
        let beepMessageBlock = BeepConfigCommand(
            beepType: beepType,
            tempBasalCompletionBeep: self.hasUnfinalizedManualTempBasal,
            bolusCompletionBeep: self.hasUnfinalizedManualBolus
        )

        return beepMessageBlock
    }

    /// Handles reconfiguring the pod for audible alerts and getting all the silencePod
    /// related variables updated when the silencePodEnd time has been reached.
    private func handleSilencePodEnd(session: PodCommsSession) {
        if let silencePodEnd = state.silencePodEnd, Date() >= silencePodEnd {
            log.default("@@@ handleSilencePodEnd: end time %{public}@ reached, disabling silence mode", String(describing: silencePodEnd))

            /// Use doSetSilencePod() to do all the hard work of resetting pod alerts to use audio beeps
            /// and updating the pod completion beep state for any active manual insulin delivery if needed.
            doSetSilencePod(session: session, silencePod: false, silencePodEnd: nil) { error in
                if let error = error {
                    self.log.default("@@@ handleSilencePodEnd: disable silence mode failed: %{public}@", error.localizedDescription)
                } else {
                    // Call back to sync the UI silence pod state variables
                    self.syncSilencePodState?(false, nil)
                }
            }
        }
    }

    private func podCommState(for state: OmniPumpManagerState) -> PodCommState {
        guard let podState = state.podState else {
            return .noPod
        }
        guard !podState.isFaulted else {
            return .fault(podState.fault) // nil for activationTimeout and podIncompatible
        }

        if podState.isActive {
            return .active
        } else if !podState.isSetupComplete {
            return .activating
        }
        return .deactivating // Can't be reached and thus will never be returned
    }

    var podCommState: PodCommState {
        return podCommState(for: state)
    }

    var podActivatedAt: Date? {
        return state.podState?.activatedAt
    }

    var podExpiresAt: Date? {
        return state.podState?.expiresAt
    }

    var hasActivePod: Bool {
        return state.hasActivePod
    }

    var hasSetupPod: Bool {
        return state.hasSetupPod
    }

    // If time remaining is negative, the pod has been expired for that amount of time.
    var podTimeRemaining: TimeInterval? {
        guard let expiresAt = state.podState?.expiresAt else { return nil }
        return expiresAt.timeIntervalSince(dateGenerator())
    }

    private var shouldWarnPodEOL: Bool {
        let eolDisplayActiveTime = Pod.timeRemainingWarningThreshold + (state.scheduledExpirationReminderOffset ?? 0.0)
        guard let podTimeRemaining = podTimeRemaining,
              podTimeRemaining > 0 && podTimeRemaining <= eolDisplayActiveTime else
        {
            return false
        }

        return true
    }

    var durationBetweenLastPodCommAndActivation: TimeInterval? {
        guard let lastPodCommDate = state.podState?.lastInsulinMeasurements?.validTime,
              let activationTime = podActivatedAt else
        {
            return nil
        }

        return lastPodCommDate.timeIntervalSince(activationTime)
    }

    var beepPreference: BeepPreference {
        get {
            return state.confirmationBeeps
        }
    }

    var silencePod: Bool {
        get {
            return state.silencePod
        }
    }

    var silencePodEnd: Date? {
        get {
            return state.silencePodEnd
        }
    }

    // From last status response
    var reservoirLevel: ReservoirLevel? {
        return state.reservoirLevel
    }

    var podTotalDelivery: HKQuantity? {
        guard let delivery = state.podState?.lastInsulinMeasurements?.delivered else {
            return nil
        }
        return HKQuantity(unit: .internationalUnit(), doubleValue: delivery)
    }

    var lastStatusDate: Date? {
        guard let date = state.podState?.lastInsulinMeasurements?.validTime else {
            return nil
        }
        return date
    }

    var defaultExpirationReminderOffset: TimeInterval {
        set {
            setState { (state) in
                state.defaultExpirationReminderOffset = newValue
            }
        }
        get {
            state.defaultExpirationReminderOffset
        }
    }

    var lowReservoirReminderValue: Double {
        set {
            setState { (state) in
                state.lowReservoirReminderValue = newValue
            }
        }
        get {
            state.lowReservoirReminderValue
        }
    }

    var defaultLowReservoirReminderValue: Double {
        set {
            setState { (state) in
                state.defaultLowReservoirReminderValue = newValue
            }
        }
        get {
            state.defaultLowReservoirReminderValue
        }
    }

    var podAttachmentConfirmed: Bool {
        set {
            setState { (state) in
                state.podAttachmentConfirmed = newValue
            }
        }
        get {
            state.podAttachmentConfirmed
        }
    }

    var initialConfigurationCompleted: Bool {
        set {
            setState { (state) in
                state.initialConfigurationCompleted = newValue
            }
        }
        get {
            state.initialConfigurationCompleted
        }
    }

    var expiresAt: Date? {
        return state.podState?.expiresAt
    }

    func buildPumpStatusHighlight(for state: OmniPumpManagerState, andDate date: Date = Date()) -> PumpStatusHighlight? {
        if state.podState?.needsCommsRecovery == true {
            return PumpStatusHighlight(
                localizedMessage: LocalizedString("Comms Issue", comment: "Status highlight that delivery is uncertain."),
                imageName: "exclamationmark.circle.fill",
                state: .critical)
        }

        switch podCommState(for: state) {
        case .activating:
            return PumpStatusHighlight(
                localizedMessage: LocalizedString("Finish Setup", comment: "Status highlight that when pod is activating."),
                imageName: "exclamationmark.circle.fill",
                state: .warning)
        case .deactivating:
            return PumpStatusHighlight(
                localizedMessage: LocalizedString("Finish Deactivation", comment: "Status highlight that when pod is deactivating."),
                imageName: "exclamationmark.circle.fill",
                state: .warning)
        case .noPod:
            return PumpStatusHighlight(
                localizedMessage: LocalizedString("No Pod", comment: "Status highlight that when no pod is paired."),
                imageName: "exclamationmark.circle.fill",
                state: .warning)
        case .fault(let detail):
            var message = LocalizedString("Pod Error", comment: "Status highlight message for other alarm.")
            guard let detail = detail else {
                return PumpStatusHighlight(
                    localizedMessage: message,
                    imageName: "exclamationmark.circle.fill",
                    state: .critical)
            }
            switch detail.faultEventCode.faultType {
            case .reservoirEmpty:
                message = LocalizedString("No Insulin", comment: "Status highlight message for emptyReservoir alarm.")
            case .exceededMaximumPodLife80Hrs:
                message = LocalizedString("Pod Expired", comment: "Status highlight message for podExpired alarm.")
            case .occluded:
                message = LocalizedString("Pod Occlusion", comment: "Status highlight message for occlusion alarm.")
            default:
                break
            }
            return PumpStatusHighlight(
                localizedMessage: message,
                imageName: "exclamationmark.circle.fill",
                state: .critical)
        case .active:
            let timeSinceLastResponse = date.timeIntervalSince(state.podState?.podTimeUpdated ?? .distantPast)
            if let reservoirPercent = state.reservoirLevel?.percentage, reservoirPercent == 0 {
                return PumpStatusHighlight(
                    localizedMessage: LocalizedString("No Insulin", comment: "Status highlight that a pump is out of insulin."),
                    imageName: "exclamationmark.circle.fill",
                    state: .critical)
            } else if state.podState?.isSuspended == true {
                return PumpStatusHighlight(
                    localizedMessage: LocalizedString("Insulin Suspended", comment: "Status highlight that insulin delivery was suspended."),
                    imageName: "pause.circle.fill",
                    state: .warning)
            } else if timeSinceLastResponse > .minutes(12) {
                return PumpStatusHighlight(
                    localizedMessage: LocalizedString("Signal Loss", comment: "Status highlight when communications with the pod haven't happened recently."),
                    imageName: "exclamationmark.circle.fill",
                    state: .critical)
            } else if isRunningManualTempBasal(for: state) {
                return PumpStatusHighlight(
                    localizedMessage: LocalizedString("Manual Basal", comment: "Status highlight when manual temp basal is running."),
                    imageName: "exclamationmark.circle.fill",
                    state: .warning)
            }
            return nil
        }
    }

    func isRunningManualTempBasal(for state: OmniPumpManagerState) -> Bool {
        if let tempBasal = state.podState?.unfinalizedTempBasal, !tempBasal.isFinished(), !tempBasal.automatic {
            return true
        }
        return false
    }

    var reservoirLevelHighlightState: ReservoirLevelHighlightState? {
        guard let reservoirLevel = reservoirLevel else {
            return nil
        }

        switch reservoirLevel {
        case .aboveThreshold:
            return .normal
        case .valid(let value):
            if value > state.lowReservoirReminderValue {
                return .normal
            } else if value > 0 {
                return .warning
            } else {
                return .critical
            }
        }
    }

    func buildPumpLifecycleProgress(for state: OmniPumpManagerState) -> PumpLifecycleProgress? {
        switch podCommState {
        case .active:
            if shouldWarnPodEOL,
               let podTimeRemaining = podTimeRemaining
            {
                let percentCompleted = max(0, min(1, (1 - (podTimeRemaining / Pod.nominalPodLife))))
                return PumpLifecycleProgress(percentComplete: percentCompleted, progressState: .warning)
            } else if let podTimeRemaining = podTimeRemaining, podTimeRemaining <= 0 {
                // Pod is expired
                return PumpLifecycleProgress(percentComplete: 1, progressState: .critical)
            }
            return nil
        case .fault(let detail):
            if let detail = detail,
               detail.faultEventCode.faultType == FaultEventCode.FaultEventType.exceededMaximumPodLife80Hrs
            {
                return PumpLifecycleProgress(percentComplete: 100, progressState: .critical)
            } else {
                if shouldWarnPodEOL,
                   let durationBetweenLastPodCommAndActivation = durationBetweenLastPodCommAndActivation
                {
                    let percentCompleted = max(0, min(1, durationBetweenLastPodCommAndActivation / Pod.nominalPodLife))
                    return PumpLifecycleProgress(percentComplete: percentCompleted, progressState: .dimmed)
                }
            }
            return nil
        case .noPod, .activating, .deactivating:
            return nil
        }
    }

    var podType: PodType {
        set {
            assert(state.podState == nil) // switching pod type only allowed with no pod

            if state.podType == unknownOmnipodType {
                log.info("Setting OmniPumpManager podType to %{public}@", newValue.briefName)
            } else if state.podType != newValue {
                log.info("Changing OmniPumpManager podType from %{public}@ to %{public}@", state.podType.briefName, newValue.briefName)
            } else if newValue == omnipod5Type {
                log.info("OmniPumpManager podType resetting %{public}@ state", omnipod5Type.briefName)
            } else {
                log.info("OmniPumpManager podType remains %{public}@", newValue.briefName)
                return
            }

            forgetBluetoothManager()

            let podComms: PodComms
            switch newValue {
            case erosType:
                let erosPodComms = ErosPodComms.init(podState: nil, podType: newValue)
                podComms = erosPodComms
            case dashType, omnipod5Type:
                let blePodComms = BlePodComms.init(podState: nil, podType: newValue, myId: state.controllerId, podId: state.podId)
                podComms = blePodComms
            default:
                podComms = PodComms(podState: nil, podType: newValue)
            }

            self.lockedPodComms = Locked(podComms)
            self.localizedTitle = newValue.description // set the OmniSettingsView title

            setState { (state) in
                state.podType = newValue
            }

            finishInit(podType: newValue)

            self.prepForNewPod() // reset the Id's as appropriate for the new pod type
        }
        get {
            state.podType
        }
    }

    // Reset all the per pod state kept in pump manager state which doesn't span pods
    fileprivate func resetPerPodPumpManagerState() {

        // Reset any residual per pod slot based pump manager alerts
        // (i.e., all but timeOffsetChangeDetected which isn't actually used)
        let podAlerts = state.activeAlerts.filter { $0 != .timeOffsetChangeDetected }
        for alert in podAlerts {
            self.retractAlert(alert: alert)
        }

        self.setState { (state) in
            // Reset alertsWithPendingAcknowledgment which are all pod slot based
            state.alertsWithPendingAcknowledgment = []

            // Reset other miscellaneous state variables that are actually per pod
            state.podAttachmentConfirmed = false
            state.acknowledgedTimeOffsetAlert = false
        }
    }


    // MARK: - Pod comms

    /// Refresh the cached O5 controllerId / podId from the cert store after the
    /// user has fetched or imported a new certificate. Only valid before a pod
    /// session exists; rotating these mid-session would orphan a live pod since
    /// the values are baked into the session keys derived at pairing time.
    func refreshO5IdsFromCertStore() {
        guard state.podType.isO5, state.podState == nil else { return }
        prepForNewPod()
    }

    private func prepForNewPod() {

        let podType = state.podType
        setState { state in
            // Don't wipe out the previous PodState when switching pod types
            if let podState = state.podState {
                state.previousPodState = podState
                /// If deliveryStoppedAt hasn't been already set during pod fault handling or pod deactivation
                /// (always the case for a simulator), set deliveryStoppedAt with the current time
                if podState.deliveryStoppedAt == nil {
                    state.previousPodState?.deliveryStoppedAt = Date()
                }
            }

            switch podType {
            case erosType:
                // Eros doesn't use these id's
                state.controllerId = 0
                state.podId = 0
                self.log.info("@@@ prepForNewPod: resetting controllerId and podId for Eros pod")

            case dashType, omnipod5Type:
                // nextIds() will verify any existing O5 ids and then (re)set the
                // controllerId as needed and advance podId to the next in the rotation.
                (state.controllerId, state.podId) = nextIds(podType: podType, controllerId: state.controllerId, podId: state.podId)
                self.log.info("@@@ prepForNewPod: set controllerId to 0x%08X and podId to 0x%08X", state.controllerId, state.podId)

            default:
                // Reset the id's so they will be initialized when the pod type is selected.
                state.controllerId = 0
                state.podId = 0
                self.log.info("@@@ prepForNewPod: resetting controllerId and podId")
            }
        }

        // This call will set the PodComms podState to nil and the PodCommDelegate will then be called from there with a
        // nil PodComms PodState which will then invoke updatePodStateFromPodComms(nil) to set self.state.podState to nil.
        self.podComms.prepForNewPod(myId: self.state.controllerId, podId: self.state.podId)
    }

    func forgetPod(completion: @escaping () -> Void) {

        self.podComms.handleDiscardedPodDosing(podTime: podTime, reservoirLevel: reservoirLevel?.rawValue)

        self.podComms.forgetPod()

        self.resetPerPodPumpManagerState()

        if let dosesToStore = state.podState?.dosesToStore {
            store(doses: dosesToStore, completion: { error in
                self.setState({ (state) in
                    if error != nil {
                        state.unstoredDoses.append(contentsOf: dosesToStore)
                    }
                })
                self.prepForNewPod()
                completion()
            })
        } else {
            prepForNewPod()
            completion()
        }
    }

    // If applicable forget the BluetoothManager for current podComms
    // to avoid future "Bluetooth use unsupported on this device" errors.
    func forgetBluetoothManager() {
        if let blePodComms = self.lockedPodComms.value as? BlePodComms {
            blePodComms.forgetBluetoothManager()
        }
    }


    // MARK: Testing

    #if targetEnvironment(simulator)
    private func jumpStartPod(address: UInt32, lotNo: UInt32, lotSeq: UInt32, fault: DetailedStatus? = nil, startDate: Date? = nil, mockFault: Bool) {
        let start = startDate ?? Date()
        let fakeLtk = Data(hexadecimalString: "fedcba98765432100123456789abcdef")!
        var podState = PodState(address: address, firmwareVersion: "jumpstarted", iFirmwareVersion: "jumpstarted", lotNo: lotNo, lotSeq: lotSeq, insulinType: insulinType ?? .novolog, podType: state.podType, ltk: fakeLtk, bleIdentifier: "0000-0000", setupUnitsDelivered: Pod.primeUnits)

        podState.setupProgress = .podPaired
        podState.activatedAt = start
        podState.expiresAt = start + .hours(72)

        let fault = mockFault ? try? DetailedStatus(encodedData: Data(hexadecimalString: "020f0000000900345c000103ff0001000005ae056029")!) : nil
        podState.fault = fault

        let podComms: PodComms
        if state.podType.usesRileyLink {
            let erosPodComms = ErosPodComms.init(podState: podState, podType: state.podType)
            podComms = erosPodComms
        } else {
            let blePodComms = BlePodComms.init(podState: podState, podType: state.podType, myId: state.controllerId, podId: state.podId)
            podComms = blePodComms
        }

        self.lockedPodComms = Locked(podComms)
        self.localizedTitle = state.podType.description

        finishInit(podType: state.podType)

        self.resetPerPodPumpManagerState()

        setState({ (state) in
            state.updatePodStateFromPodComms(podState)
            state.scheduledExpirationReminderOffset = state.defaultExpirationReminderOffset
        })
    }
    #endif


    // MARK: - Pairing

    // Called on the main thread
    func pairAndPrime(completion: @escaping (PumpManagerResult<TimeInterval>) -> Void) {

        guard state.podType != unknownOmnipodType else {
            completion(.failure(.configuration(OmniPumpManagerError.podTypeNotConfigured)))
            return
        }

        guard let insulinType = insulinType else {
            completion(.failure(.configuration(OmniPumpManagerError.insulinTypeNotConfigured)))
            return
        }

        #if targetEnvironment(simulator)
        // If we're in the simulator, create a mock PodState
        let mockFaultDuringPairing = false
        let mockCommsErrorDuringPairing = false
        let mockStartDate = Date()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(2)) {
            if self.state.podType.usesRileyLink {
                let address: UInt32 = self.state.podState?.address ?? 0x1f1f1f1f
                self.jumpStartPod(address: address, lotNo: 135601809, lotSeq: 0800525, startDate: mockStartDate, mockFault: mockFaultDuringPairing)
            } else {
                let address: UInt32 = self.state.podState?.address ?? 0x17171717
                self.jumpStartPod(address: address, lotNo: 135601809, lotSeq: 0800525, startDate: mockStartDate, mockFault: mockFaultDuringPairing)
            }
            let fault: DetailedStatus? = self.setStateWithResult({ (state) in
                var podState = state.podState
                podState?.setupProgress = .priming
                state.updatePodStateFromPodComms(podState)
                return state.podState?.fault
            })
            if let fault = fault {
                completion(.failure(PumpManagerError.deviceState(PodCommsError.podFault(fault: fault))))
            } else if mockCommsErrorDuringPairing {
                completion(.failure(PumpManagerError.communication(PodCommsError.noResponse)))
            } else {
                let mockPrimeDuration = TimeInterval(.seconds(3))
                completion(.success(mockPrimeDuration))
            }
        }
        #else

        /// Calls the completion handler for a failure with an appropriate PumpManagerError value
        func completionFailure(_ error: LocalizedError?) {
            if self.state.podState?.isFaulted == true {
                /// If the pod has faulted, return as a non-recoverable deviceState error
                completion(.failure(.deviceState(error)))
            } else {
                /// Other errors are returned as a potentially recoverable communication error
                completion(.failure(.communication(error)))
            }
        }

        // Runs the priming session on the paired pod
        let primeSession = { (result: PodComms.SessionRunResult) in
            switch result {
            case .success(let session):
                // We're on the session queue
                session.assertOnSessionQueue()

                self.log.default("Beginning pod prime")

                // Clean up any previously un-stored doses if needed
                let unstoredDoses = self.state.unstoredDoses
                if self.store(doses: unstoredDoses, in: session) {
                    self.setState({ (state) in
                        state.unstoredDoses.removeAll()
                    })
                }

                do {
                    let primeFinishedAt = try session.prime()
                    completion(.success(primeFinishedAt))
                } catch let error {
                    completionFailure(error as? LocalizedError)
                }
            case .failure(let error):
                completionFailure(error)
            }
        }

        // Return true if not yet paired
        let needsPairing = setStateWithResult({ (state) -> Bool in
            guard let podState = state.podState else {
                // Needs pairing with no podState which indicates that
                // the AssignAddress command has not run successfully.
                return true
            }

            // Use setupProgress.isPaired to test if the SetupPod command has
            // been run which advances setupProgress upon successful completion.
            return podState.setupProgress.isPaired == false
        })

        // Common code that invokes blePairAndSetupPod and then a primingSession if successful
        func blePairSetupPrimePod(blePodComms: BlePodComms) {
            blePodComms.blePairAndSetupPod(timeZone: .currentFixed, insulinType: insulinType, messageLogger: self) { (result) in
                switch result {
                case .success:
                    // Calls completion
                    primeSession(result)
                case .failure(let error):
                    self.log.error("blePairAndSetupAndPrimePod failed with %{public}@", String(describing: error))
                    completionFailure(error)
                }
            }
        }

        // If an O5, verify we have the needed O5 certificate data before starting
        if state.podType.isO5 && !O5CertificateStore.contains(state.controllerId) {
            completion(.failure(.configuration(PodCommsError.noCertificateFound)))
            return
        }

        if needsPairing {

            self.log.default("Pairing pod before priming")

            if let erosPodComms = self.podComms as? ErosPodComms {
                // Create random address with 20 bits to match PDM, could easily use 24 bits instead.
                // This value is stashed the the OmnipodPumpManagerState as this value cannot vary
                // on consecutive Eros pairing attempts to avoid losing the pod in some situations.
                if self.state.pairingAttemptAddress == nil {
                    self.lockedState.mutate { (state) in
                        let upperByte = UInt32(erosType.topIdByte) << 24
                        state.pairingAttemptAddress = upperByte | (arc4random() & 0x000fffff)
                    }
                }

                let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
                erosPodComms.erosAssignAddressAndSetupPod(
                    address: self.state.pairingAttemptAddress!,
                    using: rileyLinkSelector,
                    timeZone: .currentFixed,
                    insulinType: insulinType,
                    messageLogger: self)
                { (result) in
                    switch result {
                    case .success:
                        self.lockedState.mutate { (state) in
                            state.pairingAttemptAddress = nil
                        }

                        // Have new podState, reset all the per pod pump manager state
                        self.resetPerPodPumpManagerState()

                        self.pumpDelegate.notify { (delegate) in
                            delegate?.pumpManagerPumpWasReplaced(self)
                        }

                        // Calls completion
                        primeSession(result)
                    case .failure(let error):
                        completionFailure(error)
                    }
                }
            } else if let blePodComms = self.podComms as? BlePodComms {
                if state.podState != nil {
                    // Already have a podState, but pairing not yet complete
                    blePairSetupPrimePod(blePodComms: blePodComms)
                } else {
                    blePodComms.connectToNewPod { result in
                        switch result {
                        case .failure(let error):
                            completion(.failure(.communication(error as? LocalizedError)))
                            completionFailure(error as? LocalizedError)
                        case .success:
                            // Have new podState, reset all the per pod pump manager state
                            self.resetPerPodPumpManagerState()

                            if self.usingInPlayPod == true && self.iPhoneWithPossibleInPlayIssues {
                                if Storage.shared.podKeepAlive.value == .disabled {
                                    // Enable the most conservative pod keep alive mode
                                    // that should work through the for pod setup process.
                                    self.log.debug("@@@ Enabling pod keep alives")
                                    Storage.shared.podKeepAlive.value = .whenOpen
                                }
                            }

                            self.pumpDelegate.notify { (delegate) in
                                delegate?.pumpManagerPumpWasReplaced(self)
                            }

                            blePairSetupPrimePod(blePodComms: blePodComms)
                        }
                    }
                }
            } else {
                completion(.failure(.configuration(OmniPumpManagerError.podTypeNotConfigured)))
            }
        } else {
            self.log.default("Pod already paired. Continuing.")

            // Resuming the pod setup, try to ensure pod comms will work right away
            self.resumingPodSetup()

            self.runSession(withName: "Prime pod") { (result) in
                // Calls completion
                primeSession(result)
            }
        }
        #endif
    }

    // Called on the main thread
    func insertCannula(completion: @escaping (Result<TimeInterval,OmniPumpManagerError>) -> Void) {
        
        #if targetEnvironment(simulator)
        let mockDelay = TimeInterval(seconds: 3)
        let mockFaultDuringInsertCannula = false
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + mockDelay) {
            let result = self.setStateWithResult({ (state) -> Result<TimeInterval,OmniPumpManagerError> in
                if mockFaultDuringInsertCannula {
                    let fault = try! DetailedStatus(encodedData: Data(hexadecimalString: "020d0000000e00c36a020703ff020900002899080082")!)
                    var podState = state.podState
                    podState?.fault = fault
                    state.updatePodStateFromPodComms(podState)
                    return .failure(OmniPumpManagerError.communication(PodCommsError.podFault(fault: fault)))
                }

                // Mock success
                var podState = state.podState
                podState?.setupProgress = .completed
                state.updatePodStateFromPodComms(podState)
                return .success(mockDelay)
            })

            completion(result)
        }
        #else
        let preError = setStateWithResult({ (state) -> OmniPumpManagerError? in
            guard let podState = state.podState, podState.readyForCannulaInsertion else
            {
                return .notReadyForCannulaInsertion
            }

            if !podState.setupProgress.needsCannulaInsertion {
                self.log.debug("### Skipping return of unneeded 'Pod already paired' error")
            }

            state.scheduledExpirationReminderOffset = state.defaultExpirationReminderOffset
            state.lowReservoirReminderValue = state.defaultLowReservoirReminderValue

            if let silencePodEnd = state.silencePodEnd, silencePodEnd <= Date() {
                /// The silencePodEnd time has been reached before we are about to the
                /// cannula insertion which does the initial alert programming for the new pod.
                /// Update our silencePod state and the pod will be initialized for non-silent alerts.
                state.silencePod = false
                state.silencePodEnd = nil
            }

            return nil
        })

        if let error = preError {
            completion(.failure(.state(error)))
            return
        }

        let timeZone = self.state.timeZone

        self.runSession(withName: "Insert cannula") { (result) in
            switch result {
            case .success(let session):
                if self.state.podState?.setupProgress.cannulaInsertionSuccessfullyStarted == true {
                    // Resuming the pod setup, try to ensure pod comms will work right away
                    self.resumingPodSetup()
                }
                do {
                    if self.state.podState?.setupProgress.needsInitialBasalSchedule == true {
                        let scheduleOffset = timeZone.scheduleOffset(forDate: Date())
                        try session.programInitialBasalSchedule(self.state.basalSchedule, scheduleOffset: scheduleOffset)

                        session.dosesForStorage() { (doses) -> Bool in
                            return self.store(doses: doses, in: session)
                        }
                    }

                    var alerts: [PodAlert] = []
                    let silencePod = self.state.silencePod
                    if self.state.defaultExpirationReminderOffset > 0 {
                        let expirationReminderTime = Pod.nominalPodLife - self.state.defaultExpirationReminderOffset
                        alerts.append(.expirationReminder(offset: self.podTime, absAlertTime: expirationReminderTime, silent: silencePod))
                    }
                    if self.state.lowReservoirReminderValue > 0 {
                        alerts.append(.lowReservoir(units: self.state.lowReservoirReminderValue, silent: silencePod))
                    }
                    let finishWait = try session.insertCannula(optionalAlerts: alerts, silent: silencePod)
                    completion(.success(finishWait))
                } catch let error {
                    completion(.failure(.communication(error)))
                }
            case .failure(let error):
                completion(.failure(.communication(error)))
            }
        }
        #endif
    }

    func checkCannulaInsertionFinished(completion: @escaping (OmniPumpManagerError?) -> Void) {
#if targetEnvironment(simulator)
        completion(nil)
#else
        self.runSession(withName: "Check cannula insertion finished") { (result) in
            switch result {
            case .success(let session):
                do {
                    try session.checkInsertionCompleted()
                    completion(nil)
                } catch let error {
                    self.log.error("Failed to fetch pod status: %{}@", String(describing: error))
                    completion(.communication(error))
                }
            case .failure(let error):
                self.log.error("Failed to fetch pod status: %{}@", String(describing: error))
                completion(.communication(error))
            }
        }
#endif
    }

    // Called when resuming a pod setup operation which sometimes can fail on the first pod command in various situations.
    // Attempting a getStatus and sleeping a couple of seconds on errors greatly improves the odds for first pod command success.
    func resumingPodSetup() {
        let sleepTime:UInt32 = 2

        if !hasConnection {
            self.log.debug("### Pod setup resume pod not connected, sleeping %d seconds", sleepTime)
            sleep(sleepTime)
        }

        guard state.podState?.setupProgress.isPaired == true else {
            self.log.debug("### Pod setup resume skipping getStatus as not yet paired")
            return
        }

        self.runSession(withName: "Resuming pod setup") { (result) in
            switch result {
            case .success(let session):
                let status = try? session.getStatus(noSeqGetStatus: true)
                if status == nil {
                    self.log.debug("### Pod setup resume getStatus failed, sleeping %d seconds", sleepTime)
                    sleep(sleepTime)
                }
            case .failure(let error):
                self.log.debug("### Pod setup resume session failure, sleeping %d seconds: %@", sleepTime, error.localizedDescription)
                sleep(sleepTime)
            }
        }
    }

    // If the last delivery status received is invalid or there is an unacknowledged command, execute a getStatus command
    // for the current PodCommsSession. If the getStatus fails, return its error to be passed on to the higher level.
    // Return nil if comms looks OK or the getStatus was successful.
    private func tryToValidateComms(session: PodCommsSession) -> LocalizedError? {

        // Since we're already connected for this session, have a delivery status, and no unacknowledged command, we're all good to go.
        if self.state.podState?.lastDeliveryStatusReceived != nil && self.state.podState?.unacknowledgedCommand == nil {
            return nil
        }

        // Attempt to do a getStatus to try to resolve any outstanding comms issues
        do {
            let _ = try session.getStatus()
            self.log.debug("### tryToValidateComms getStatus resolved all pending comms issues")
            return nil
        } catch let error {
            self.log.debug("### tryToValidateComms getStatus failed, returning: %@", error.localizedDescription)
            return error as? LocalizedError
        }
    }

    // Used to serialize a set of Pod Commands for a given session - vectors to correct version
    private func runSession(withName name: String, _ block: @escaping (_ result: PodComms.SessionRunResult) -> Void) {
        if let blePodComms = self.podComms as? BlePodComms {
            blePodComms.bleRunSession(withName: name, block)
        } else if let erosPodComms = self.podComms as? ErosPodComms {
            let device = self.rileyLinkDeviceProvider.firstConnectedDevice
            erosPodComms.erosRunSession(withName: name, using: device, block)
        } else {
            block(.failure(.diagnosticMessage(str: OmniPumpManagerError.podTypeNotConfigured.localizedDescription)))
        }
    }

    // Shared handler for getPodStatus() and post-connnect() that does a getStatus()
    // (unless canOptimize is true and a StatusResponse had been recently received)
    // and other associated actions that need to be regularly performed.
    // Returns the getStatus() StatusResponse when the command isn't skipped.
    fileprivate func handlePodUpdatesAsNeeded(session: PodCommsSession, canOptimize: Bool) -> StatusResponse? {

        // First see if a timed silence pod mode has ended
        handleSilencePodEnd(session: session)

        // Next do the getStatus() call unless we can optimize and it
        // has been less than optimizeInterval since the last response.
        let optimizeInterval = TimeInterval(seconds: 115)
        let timeSinceLastResponse = -(self.state.podState?.podTimeUpdated ?? .distantPast).timeIntervalSinceNow
        let status: StatusResponse?
        if canOptimize && timeSinceLastResponse < optimizeInterval {
            self.log.debug("### skipping getStatus() with last status %@ ago", timeSinceLastResponse.timeIntervalStr)
            status = nil
        } else {
            status = try? session.getStatus(noSeqGetStatus: true)
        }

        // Silence any pending acknowledged alerts
        silenceAcknowledgedAlerts()

        // If we have new status, store the dosesForStorage which updates lastPumpDataReportDate
        if status != nil {
            session.dosesForStorage() { (doses) -> Bool in
                return store(doses: doses, in: session)
            }
        }

        // Finally, issue a heartbeat if needed
        issueHeartbeatIfNeeded()

        return status
    }

    // MARK: - Pump Commands

    // Performs a pod get status and performs other associated actions.
    // If canOptimize, the getStatus can be skipped if a response has been recently returned.
    // The returned StatusResponse will be nil if getStatus() was skipped as an optimization.
    func getPodStatus(canOptimize: Bool = false,
                      completion: ((_ result: PumpManagerResult<StatusResponse?>) -> Void)? = nil)
    {

        // Don't use guard state.hasActivePod here as it prevents getPodStatus from working
        // after the pod has been paired, but before the pod setup process has been completed.
        guard state.podState?.setupProgress.isPaired == true, state.podState?.fault == nil else {
            completion?(.failure(PumpManagerError.configuration(OmniPumpManagerError.noPodPaired)))
            return
        }

        self.runSession(withName: "Get pod status") { (result) in
            do {
                switch result {
                case .success(let session):
                    let status = self.handlePodUpdatesAsNeeded(session: session, canOptimize: canOptimize)
                    completion?(.success(status))
                case .failure(let error):
                    self.evaluateStatus()
                    throw error
                }
            } catch let error {
                completion?(.failure(.communication(error as? LocalizedError)))
                self.log.error("Failed to fetch pod status: %{public}@", String(describing: error))
            }
        }
    }

    func getDetailedStatus() async throws -> DetailedStatus {

        // use hasSetupPod here instead of hasActivePod as DetailedStatus can be read with a faulted Pod
        guard self.hasSetupPod else {
            throw PumpManagerError.configuration(OmniPumpManagerError.noPodPaired)
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.runSession(withName: "Get detailed status") { (result) in
                do {
                    switch result {
                    case .success(let session):
                        self.handleSilencePodEnd(session: session)

                        let beepBlock = self.beepMessageBlock(beepType: .bipBip)
                        let detailedStatus = try session.getDetailedStatus(beepBlock: beepBlock)
                        session.dosesForStorage({ (doses) -> Bool in
                            self.store(doses: doses, in: session)
                        })
                        continuation.resume(returning: detailedStatus)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                } catch let error {
                    self.log.error("Failed to fetch detailed status: %{public}@", String(describing: error))
                    continuation.resume(throwing: PumpManagerError.communication(error as? LocalizedError))
                }
            }
        }
    }

    func acknowledgePodAlerts(_ alertsToAcknowledge: AlertSet, completion: @escaping (_ alerts: AlertSet?) -> Void) {
        guard self.hasActivePod else {
            completion(nil)
            return
        }

        self.runSession(withName: "Acknowledge Alerts") { (result) in
            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure:
                completion(nil)
                return
            }

            self.handleSilencePodEnd(session: session)
            do {
                let beepBlock = self.beepMessageBlock(beepType: .bipBip)
                let alerts = try session.acknowledgeAlerts(alerts: alertsToAcknowledge, beepBlock: beepBlock)
                completion(alerts)
            } catch {
                completion(nil)
            }
        }
    }

    func setTime(completion: @escaping (OmniPumpManagerError?) -> Void) {

        let timeZone = TimeZone.currentFixed
#if targetEnvironment(simulator)
        // Just update the pump manager state
        self.setState { (state) in
            state.timeZone = timeZone
        }
        completion(nil)
#else
        // Just update the pump manager state if there is no active Pod
        guard self.hasActivePod else {
            self.setState { (state) in
                state.timeZone = timeZone
            }
            completion(nil)
            return
        }

        guard let podState = state.podState, podState.isSetupComplete else {
            // A cancel delivery command before pod setup is complete will fault the pod
            completion(.state(PodCommsError.setupNotComplete))
            return
        }

        guard podState.unfinalizedBolus?.isFinished() != false else {
            completion(.state(PodCommsError.unfinalizedBolus))
            return
        }

        self.runSession(withName: "Set time zone") { (result) in
            switch result {
            case .success(let session):
                do {
                    self.handleSilencePodEnd(session: session)

                    let beep = self.silencePod ? false : self.beepPreference.shouldBeepForManualCommand
                    let _ = try session.setTime(timeZone: timeZone, basalSchedule: self.state.basalSchedule, date: Date(), acknowledgementBeep: beep)
                    self.clearSuspendReminder()
                    self.setState { (state) in
                        state.timeZone = timeZone
                    }
                    completion(nil)
                } catch let error {
                    completion(.communication(error))
                }
            case .failure(let error):
                completion(.communication(error))
            }
        }
#endif
    }

    func setBasalSchedule(_ schedule: BasalSchedule, completion: @escaping (Error?) -> Void) {
        /// Trio doesn't enforce the maximum basal rates for the basal schedule and
        /// doesn't limit maximum basal rates settings based on the basal schedule.
        /// For now just disable this enforcement to match the previous behavior.
        //for entry in schedule.entries {
        //    guard entry.rate <= state.maxBasalRateUnitsPerHour else {
        //        completion(PumpManagerError.configuration(OmniPumpManagerError.invalidSetting))
        //        return
        //    }
        //}

        guard state.hasActivePod else {
            // If there's no active pod yet, just save the basal schedule
            self.setState { (state) in
                state.basalSchedule = schedule
            }
            completion(nil)
            return
        }

        guard state.podState?.setupProgress == .completed else {
            // A cancel delivery command before pod setup is complete will fault the pod
            completion(PumpManagerError.deviceState(PodCommsError.setupNotComplete))
            return
        }

        guard state.podState?.unfinalizedBolus?.isFinished() != false else {
            completion(PumpManagerError.deviceState(PodCommsError.unfinalizedBolus))
            return
        }

        let timeZone = self.state.timeZone

        self.runSession(withName: "Save Basal Profile") { (result) in
            do {
                switch result {
                case .success(let session):
                    if let error = self.tryToValidateComms(session: session) {
                        completion(error)
                        return 
                    }

                    self.handleSilencePodEnd(session: session)

                    let scheduleOffset = timeZone.scheduleOffset(forDate: Date())
                    let result = session.cancelDelivery(deliveryType: .all)
                    switch result {
                    case .certainFailure(let error):
                        throw error
                    case .unacknowledged(let error):
                        throw error
                    case .success:
                        break
                    }
                    let beep = self.silencePod ? false : self.beepPreference.shouldBeepForManualCommand
                    let _ = try session.setBasalSchedule(schedule: schedule, scheduleOffset: scheduleOffset, acknowledgementBeep: beep)
                    self.clearSuspendReminder()

                    self.setState { (state) in
                        state.basalSchedule = schedule
                    }
                    completion(nil)
                case .failure(let error):
                    throw error
                }
            } catch let error {
                self.log.error("Save basal profile failed: %{public}@", String(describing: error))
                completion(error)
            }
        }
    }

    // Called on the main thread.
    // The UI is responsible for serializing calls to this method;
    // it does not handle concurrent calls.
    func deactivatePod(completion: @escaping (OmniPumpManagerError?) -> Void) {
        #if targetEnvironment(simulator)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(2)) {
            completion(nil)
        }
        #else
        guard self.state.podState != nil else {
            completion(OmniPumpManagerError.noPodPaired)
            return
        }

        self.runSession(withName: "Deactivate pod") { (result) in
            switch result {
            case .success(let session):
                do {
                    try session.deactivatePod()
                    completion(nil)
                } catch let error {
                    completion(OmniPumpManagerError.communication(error))
                }
            case .failure(let error):
                completion(OmniPumpManagerError.communication(error))
            }
        }
        #endif
    }

    func playTestBeeps() async throws {
        guard self.hasActivePod else {
            throw OmniPumpManagerError.noPodPaired
        }
        guard state.podState?.unfinalizedBolus?.scheduledCertainty == .uncertain || state.podState?.unfinalizedBolus?.isFinished() != false else {
            self.log.info("Skipping Play Test Beeps due to bolus still in progress.")
            throw PodCommsError.unfinalizedBolus
        }

        try await withCheckedThrowingContinuation { continuation in
            self.runSession(withName: "Play Test Beeps") { (result) in
                switch result {
                case .success(let session):
                    self.handleSilencePodEnd(session: session)

                    // preserve the pod's completion beep state which gets reset playing beeps
                    let enabled: Bool = self.silencePod ? false : self.beepPreference.shouldBeepForManualCommand
                    let result = session.beepConfig(
                        beepType: .bipBeepBipBeepBipBeepBipBeep,
                        tempBasalCompletionBeep: enabled && self.hasUnfinalizedManualTempBasal,
                        bolusCompletionBeep: enabled && self.hasUnfinalizedManualBolus
                    )

                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func readPulseLog() async throws -> String {
        // use hasSetupPod to be able to read pulse log from a faulted Pod
        guard self.hasSetupPod else {
            throw OmniPumpManagerError.noPodPaired
        }

        guard state.podState?.isFaulted == true || state.podState?.unfinalizedBolus?.scheduledCertainty == .uncertain || state.podState?.unfinalizedBolus?.isFinished() != false else
        {
            self.log.info("Skipping Read Pulse Log due to bolus still in progress.")
            throw PodCommsError.unfinalizedBolus
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.runSession(withName: "Read Pulse Log") { (result) in
                switch result {
                case .success(let session):
                    self.handleSilencePodEnd(session: session)

                    do {
                        // read the most recent 50 entries from the pulse log
                        let beepBlock = self.beepMessageBlock(beepType: .bipBeeeeep)
                        let podInfoResponse = try session.readPodInfo(podInfoResponseSubType: .pulseLogRecent, beepBlock: beepBlock)
                        guard let podInfoPulseLogRecent = podInfoResponse.podInfo as? PodInfoPulseLogRecent else {
                            self.log.error("Unable to decode PulseLogRecent: %s", String(describing: podInfoResponse))
                            throw PodCommsError.unexpectedResponse(response: .podInfoResponse)
                        }
                        let lastPulseNumber = Int(podInfoPulseLogRecent.indexLastEntry)
                        let str = pulseLogString(pulseLogEntries: podInfoPulseLogRecent.pulseLog, lastPulseNumber: lastPulseNumber)
                        continuation.resume(returning: str)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func readPulseLogPlus() async throws -> String {
        // use hasSetupPod here instead of hasActivePod as PodInfo can be read with a faulted Pod
        guard self.hasSetupPod else {
            throw OmniPumpManagerError.noPodPaired
        }
        guard state.podState?.isFaulted == true || state.podState?.unfinalizedBolus?.scheduledCertainty == .uncertain || state.podState?.unfinalizedBolus?.isFinished() != false else
        {
            self.log.info("Skipping Read Pulse Log Plus due to bolus still in progress.")
            throw PodCommsError.unfinalizedBolus
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.runSession(withName: "Read Pulse Log Plus") { (result) in
                do {
                    switch result {
                    case .success(let session):
                        self.handleSilencePodEnd(session: session)

                        let beepBlock = self.beepMessageBlock(beepType: .bipBeeeeep)
                        let podInfoResponse = try session.readPodInfo(podInfoResponseSubType: .pulseLogPlus, beepBlock: beepBlock)
                        guard let podInfoPulseLogPlus = podInfoResponse.podInfo as? PodInfoPulseLogPlus else {
                            self.log.error("Unable to decode Pulse Log Plus: %s", String(describing: podInfoResponse))
                            throw PodCommsError.unexpectedResponse(response: .podInfoResponse)
                        }
                        let str = pulseLogPlusString(podInfoPulseLogPlus: podInfoPulseLogPlus)
                        continuation.resume(returning: str)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func readActivationTime() async throws -> String {
        // use hasSetupPod here instead of hasActivePod as PodInfo can be read with a faulted Pod
        guard self.hasSetupPod else {
            throw OmniPumpManagerError.noPodPaired
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.runSession(withName: "Read Activation Time") { (result) in
                do {
                    switch result {
                    case .success(let session):
                        self.handleSilencePodEnd(session: session)

                        let beepBlock = self.beepMessageBlock(beepType: .beepBeep)
                        let podInfoResponse = try session.readPodInfo(podInfoResponseSubType: .activationTime, beepBlock: beepBlock)
                        guard let podInfoActivationTime = podInfoResponse.podInfo as? PodInfoActivationTime else {
                            self.log.error("Unable to decode Activation Time: %s", String(describing: podInfoResponse))
                            throw PodCommsError.unexpectedResponse(response: .podInfoResponse)
                        }
                        let str = activationTimeString(podInfoActivationTime: podInfoActivationTime)
                        continuation.resume(returning: str)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func readTriggeredAlerts() async throws -> String {
        // use hasSetupPod here instead of hasActivePod as PodInfo can be read with a faulted Pod
        guard self.hasSetupPod else {
            throw OmniPumpManagerError.noPodPaired
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.runSession(withName: "Read Triggered Alerts") { (result) in
                do {
                    switch result {
                    case .success(let session):
                        self.handleSilencePodEnd(session: session)

                        let beepBlock = self.beepMessageBlock(beepType: .beepBeep)
                        let podInfoResponse = try session.readPodInfo(podInfoResponseSubType: .triggeredAlerts, beepBlock: beepBlock)
                        guard let podInfoTriggeredAlerts = podInfoResponse.podInfo as? PodInfoTriggeredAlerts else {
                            self.log.error("Unable to decode Read Triggered Alerts: %s", String(describing: podInfoResponse))
                            throw PodCommsError.unexpectedResponse(response: .podInfoResponse)
                        }
                        let str = triggeredAlertsString(podInfoTriggeredAlerts: podInfoTriggeredAlerts)
                        continuation.resume(returning: str)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                } catch let error {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func setConfirmationBeeps(newPreference: BeepPreference, completion: @escaping (OmniPumpManagerError?) -> Void) {

        #if targetEnvironment(simulator)
        let justUpdateState = true
        #else
        // Just update the pump manager state if there is no active Pod or if currently silenced
        let justUpdateState = !state.hasActivePod || state.silencePod
        #endif

        let name = String(format: "Set Beep Preference to %@", String(describing: newPreference))
        if justUpdateState {
            self.log.default("%{public}@ for internal state only", name)
            self.setState { state in
                state.confirmationBeeps = newPreference
            }
            completion(nil)
            return
        }

        self.runSession(withName: name) { (result) in
            switch result {
            case .success(let session):
                if let error = self.tryToValidateComms(session: session) {
                    completion(.communication(error))
                    return 
                }

                self.handleSilencePodEnd(session: session)

                /// If not currently silenced, update pod beep state for any in progress manual insulin delivery based on newPreference.
                /// If currently silenced, no need to do anything as any in progress manual insulin completion beeping is already disabled.
                if !self.silencePod {
                    let enabled = newPreference.shouldBeepForManualCommand
                    if let error = self.updateManualInsulinBeepState(session: session, enabled: enabled) {
                        completion(.communication(error))
                    } else {
                        self.setState { state in
                            state.confirmationBeeps = newPreference
                        }
                        completion(nil)
                    }
                }
            case .failure(let error):
                completion(.communication(error))
            }
        }
    }

    /// Enable/disable the Pod completion beep state for any in program unfinalized manual insulin delivery as needed
    private func updateManualInsulinBeepState(session: PodCommsSession, enabled: Bool) -> Error? {
        guard self.hasUnfinalizedManualTempBasal || self.hasUnfinalizedManualBolus else {
            return nil // no in progress manual insulin delivery, no updates needed
        }

        let result = session.beepConfig(
            beepType: enabled ?  .bipBip : .noBeepNonCancel,
            tempBasalCompletionBeep: enabled && self.hasUnfinalizedManualTempBasal,
            bolusCompletionBeep: enabled && self.hasUnfinalizedManualBolus
        )

        switch result {
        case .success:
            return nil
        case .failure(let error):
            return error
        }
    }

    /// Called from UI when Silence Pod mode or the Silence Pod End time has changed.
    /// When the Silence Pod mode changes, handles reconfiguring all active pod alerts.
    func setSilencePod(silencePod: Bool, silencePodEnd: Date?, completion: @escaping (OmniPumpManagerError?) -> Void) {

        /// If a silencePodEnd is given, it must be in the future and silencePod must be enabled
        if let silencePodEnd = silencePodEnd, !(silencePodEnd > Date() && silencePod) {
            completion(OmniPumpManagerError.invalidSetting)
            return
        }

        #if targetEnvironment(simulator)
        let justUpdateState = true
        #else
        // Just update the pump manager state if there is no active Pod
        // or if the Silence Pod state will not be changing.
        let justUpdateState = !self.hasActivePod || state.silencePod == silencePod
        #endif

        let name = String(format: "%@ Pod", silencePod ? "Silence" : "Unsilence")
        if justUpdateState {
            self.log.default("%{public}@", name)
            self.setState { state in
                state.silencePod = silencePod
                state.silencePodEnd = silencePodEnd
            }
            completion(nil)
            return
        }

        self.runSession(withName: name) { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.communication(error))
                return
            }

            if let error = self.tryToValidateComms(session: session) {
                completion(.communication(error))
                return 
            }
    
            self.doSetSilencePod(session: session, silencePod: silencePod, silencePodEnd: silencePodEnd, completion: completion)
        }
    }

    /// Do the actual work for setting or resetting Silence Pod mode which involves reprogramming all active pod alerts
    /// to either silence or audiable mode and updating the internal pump manager Silence Pod variables. Will also handle
    /// updating the pod's internal beep completion beep state for any in progress manual insulin delivery if needed.
    private func doSetSilencePod(session: PodCommsSession,
                                 silencePod: Bool,
                                 silencePodEnd: Date?,
                                 completion: @escaping (OmniPumpManagerError?) -> Void)
    {
        guard let configuredAlerts = self.state.podState?.configuredAlerts,
              let activeAlertSlots = self.state.podState?.activeAlertSlots,
              let reservoirLevel = self.state.podState?.lastInsulinMeasurements?.reservoirLevel?.rawValue else
        {
            self.log.error("Missing pod state!") // should never happen
            completion(OmniPumpManagerError.noPodPaired)
            return
        }

        let beepBlock: MessageBlock?
        if !self.beepPreference.shouldBeepForManualCommand {
            // No enabled completion beeps to worry about for any in-progress manual delivery
            beepBlock = nil
        } else if silencePod {
            // Disable completion beeps for any in-progress manual delivery w/o beeping
            beepBlock = BeepConfigCommand(beepType: .noBeepNonCancel)
        } else {
            // Emit a confirmation beep and enable completion beeps for any in-progress manual delivery
            beepBlock = BeepConfigCommand(
                beepType: .bipBip,
                tempBasalCompletionBeep: self.hasUnfinalizedManualTempBasal,
                bolusCompletionBeep: self.hasUnfinalizedManualBolus
            )
        }

        let podAlerts = regeneratePodAlerts(silent: silencePod, configuredAlerts: configuredAlerts, activeAlertSlots: activeAlertSlots, currentPodTime: self.podTime, currentReservoirLevel: reservoirLevel)

        do {
            // Since non-responsive pod comms are currently only resolved for insulin related commands,
            // it's possible that a response from a previous successful pod alert configuration can be lost
            // and thus the alert won't get reset here when reconfiguring pod alerts with a new silence pod state.
            let acknowledgeAll = true   // protect against lost alert configuration response related issues
            try session.configureAlerts(podAlerts, acknowledgeAll: acknowledgeAll, beepBlock: beepBlock)
            self.setState { (state) in
                state.silencePod = silencePod
                state.silencePodEnd = silencePodEnd
            }
            /// If beepPreference is currently set to beep for manual commands, update the internal pod beep completion
            /// state for any in progress manual insulin delivery based on the value of the new Silence Pod state just set.
            if self.beepPreference.shouldBeepForManualCommand {
                _ = updateManualInsulinBeepState(session: session, enabled: !silencePod)
            }
            completion(nil)
        } catch {
            self.log.error("Configure alerts %{public}@ failed: %{public}@", String(describing: podAlerts), String(describing: error))
            completion(.communication(error))
        }
    }

    // Running on any iPhone 16 or an iPhone 17e which are known
    // to have BLE reconnect issues with InPlay BLE DASH pods?
    var iPhoneWithPossibleInPlayIssues: Bool {

        let iPhoneModel = UIDevice.modelName
        if iPhoneModel.contains("iPhone 16") || iPhoneModel == "iPhone 17e" {
            return true
        }

        return false
    }

    // Using an InPlay BLE pod?
    var usingInPlayPod: Bool? {

        if let blePodComms = podComms as? BlePodComms, let deviceBLEName = blePodComms.manager?.peripheral.name {
            return deviceBLEName == "InPlay BLE"
        }
        return nil // don't know -- maybe not paired yet
    }
}


// MARK: - PumpManager

extension OmniPumpManager: PumpManager {

    public static var onboardingMaximumBasalScheduleEntryCount: Int {
        return Pod.maximumBasalScheduleEntryCount
    }

    public static var onboardingSupportedMaximumBolusVolumes: [Double] {
        return onboardingSupportedBolusVolumes
    }

    public var supportedMaximumBolusVolumes: [Double] {
        return supportedBolusVolumes
    }

    public static var onboardingSupportedBolusVolumes: [Double] {
        // 0.05 units for rates between 0.05-30U
        // 0 is not a supported bolus volume
        return (1...600).map { Double($0) / Double(Pod.pulsesPerUnit) }
    }

    public var supportedBolusVolumes: [Double] {
        // 0.05 units for rates between 0.05-30U
        // 0 is not a supported bolus volume
        return (1...600).map { Double($0) / Double(Pod.pulsesPerUnit) }
    }

    public static var onboardingSupportedBasalRates: [Double] {
        // Non-Eros pods supports a zero basal rate while Eros pods do not.
        // Since this var is must be declared as static, we cannot return a
        // value that changes based on whether or not this is an Eros instance.
        // But since any onboarding basal setup performed before picking an
        // insulin pump, the pump independent onboarding must disallow zero
        // basal rates and thus this var is not too relevant anyways as it was
        // supposedly something that added to help handle Loop 2.x to 3.x migration.
        return (1...600).map { Double($0) / Double(Pod.pulsesPerUnit) }
    }

    public var supportedBasalRates: [Double] {
        // 0.05 units for rates up to 30 U/hr
        if self.state.podType.isEros {
            // Eros doesn't support a zero scheduled basal rate
            return (1...600).map { Double($0) / Double(Pod.pulsesPerUnit) }
        }
        // 0 U/hr is a supported scheduled basal rate for non-Eros pods
        return (0...600).map { Double($0) / Double(Pod.pulsesPerUnit) }
    }

    public func roundToSupportedBolusVolume(units: Double) -> Double {
        // We do support rounding a 0 U volume to 0
        return supportedBolusVolumes.last(where: { $0 <= units }) ?? 0
    }

    public func roundToSupportedBasalRate(unitsPerHour: Double) -> Double {
        // We do support rounding a 0 U/hr rate to 0
        return supportedBasalRates.last(where: { $0 <= unitsPerHour }) ?? 0
    }

    public func estimatedDuration(toBolus units: Double) -> TimeInterval {
        TimeInterval(units / Pod.bolusDeliveryRate)
    }

    public var maximumBasalScheduleEntryCount: Int {
        return Pod.maximumBasalScheduleEntryCount
    }

    public var minimumBasalScheduleEntryDuration: TimeInterval {
        return Pod.minimumBasalScheduleEntryDuration
    }

    public var pumpRecordsBasalProfileStartEvents: Bool {
        return false
    }

    public var pumpReservoirCapacity: Double {
        return Pod.reservoirCapacity
    }

    public var isOnboarded: Bool { state.isOnboarded }

    var insulinType: InsulinType? {
        get {
            return self.state.insulinType
        }
        set {
            if let insulinType = newValue {
                self.setState { (state) in
                    state.insulinType = insulinType
                }
                self.podComms.updateInsulinType(insulinType)
            }
        }
    }

    public var lastSync: Date? {
        return self.state.podState?.lastInsulinMeasurements?.validTime
    }

    public var status: PumpManagerStatus {
        // Acquire the lock just once
        let state = self.state

        return status(for: state)
    }

    public var rawState: PumpManager.RawStateValue {
        return state.rawValue
    }

    public var pumpManagerDelegate: PumpManagerDelegate? {
        get {
            return pumpDelegate.delegate
        }
        set {
            pumpDelegate.delegate = newValue
        }
    }

    public var delegateQueue: DispatchQueue! {
        get {
            return pumpDelegate.queue
        }
        set {
            pumpDelegate.queue = newValue
        }
    }


    // MARK: Methods

    func completeOnboard() {
        setState({ (state) in
            state.isOnboarded = true
        })
    }

    public func suspendDelivery(completion: @escaping (Error?) -> Void) {
        let suspendTime: TimeInterval = .minutes(0) // untimed suspend with reminder beeps
        suspendDelivery(withSuspendReminders: suspendTime, completion: completion)
    }

    // A nil suspendReminder is untimed with no reminders beeps, a suspendReminder of 0 is untimed using reminders beeps, otherwise it
    // specifies a suspend duration implemented using an appropriate combination of suspended reminder and suspend time expired beeps.
    func suspendDelivery(withSuspendReminders suspendReminder: TimeInterval? = nil, completion: @escaping (Error?) -> Void) {
        guard self.hasActivePod else {
            completion(OmniPumpManagerError.noPodPaired)
            return
        }

        self.runSession(withName: "Suspend") { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(error)
                return
            }

            defer {
                self.setState({ (state) in
                    state.suspendEngageState = .stable
                })
            }
            self.setState({ (state) in
                state.suspendEngageState = .engaging
            })

            if let error = self.tryToValidateComms(session: session) {
                completion(error)
                return
            }

            self.handleSilencePodEnd(session: session)

            // Use a beepBlock for the confirmation beep to avoid getting 3 beeps using cancel command beeps!
            let beepBlock = self.beepMessageBlock(beepType: .beeeeeep)
            let result = session.suspendDelivery(suspendReminder: suspendReminder, silent: self.silencePod, beepBlock: beepBlock)
            switch result {
            case .certainFailure(let error):
                self.log.error("Failed to suspend: %{public}@", String(describing: error))
                completion(error)
            case .unacknowledged(let error):
                self.log.error("Failed to suspend: %{public}@", String(describing: error))
                completion(error)
            case .success:
                session.dosesForStorage() { (doses) -> Bool in
                    return self.store(doses: doses, in: session)
                }
                completion(nil)
            }
        }
    }

    public func resumeDelivery(completion: @escaping (Error?) -> Void) {
        guard self.hasActivePod else {
            completion(OmniPumpManagerError.noPodPaired)
            return
        }

        self.runSession(withName: "Resume") { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(error)
                return
            }

            defer {
                self.setState({ (state) in
                    state.suspendEngageState = .stable
                })
            }

            self.setState({ (state) in
                state.suspendEngageState = .disengaging
            })

            if let error = self.tryToValidateComms(session: session) {
                completion(error)
                return 
            }

            self.handleSilencePodEnd(session: session)

            do {
                let scheduleOffset = self.state.timeZone.scheduleOffset(forDate: Date())
                let beep = self.silencePod ? false : self.beepPreference.shouldBeepForManualCommand
                let _ = try session.resumeBasal(schedule: self.state.basalSchedule, scheduleOffset: scheduleOffset, acknowledgementBeep: beep)
                self.clearSuspendReminder()
                session.dosesForStorage() { (doses) -> Bool in
                    return self.store(doses: doses, in: session)
                }
                completion(nil)
            } catch (let error) {
                completion(error)
            }
        }
    }

    fileprivate func clearSuspendReminder() {
        self.pumpDelegate.notify { (delegate) in
            delegate?.retractAlert(identifier: Alert.Identifier(managerIdentifier: self.pluginIdentifier, alertIdentifier: PumpManagerAlert.suspendEnded(triggeringSlot: nil).alertIdentifier))
            delegate?.retractAlert(identifier: Alert.Identifier(managerIdentifier: self.pluginIdentifier, alertIdentifier: PumpManagerAlert.suspendEnded(triggeringSlot: nil).repeatingAlertIdentifier))
        }
    }

    public func addStatusObserver(_ observer: PumpManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }

    public func removeStatusObserver(_ observer: PumpManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }

    public func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        let shouldFetchStatus = setStateWithResult { (state) -> Bool? in
            guard state.hasActivePod else {
                return nil // No active pod
            }

            return state.isPumpDataStale
        }

        if state.podType.usesRileyLink {
            checkRileyLinkBattery()
        }

        switch shouldFetchStatus {
        case .none:
            completion?(self.lastSync)
            return // No active pod
        case true?:
            log.default("Fetching status because pumpData is too old")
            getPodStatus(canOptimize: true) { _ in
                completion?(self.lastSync)
            }
        case false?:
            log.default("Skipping status update because pumpData is fresh")
            completion?(self.lastSync)
            silenceAcknowledgedAlerts()
            issueHeartbeatIfNeeded()
        }
    }

    // RL only
    private func checkRileyLinkBattery() {
        if state.podType.usesRileyLink {
            rileyLinkDeviceProvider.getDevices { devices in
                for device in devices {
                    device.updateBatteryLevel()
                }
            }
        }
    }


    // MARK: - Programming Delivery

    public func enactBolus(units: Double, activationType: BolusActivationType, completion: @escaping (PumpManagerError?) -> Void) {
        guard self.hasActivePod else {
            completion(.configuration(OmniPumpManagerError.noPodPaired))
            return
        }

        guard units <= state.maxBolusUnits else {
            completion(.configuration(OmniPumpManagerError.invalidSetting))
            return
        }

        // Round to nearest supported volume
        let enactUnits = roundToSupportedBolusVolume(units: units)

        self.runSession(withName: "Bolus") { (result) in
            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.communication(error))
                return
            }

            defer {
                self.setState({ (state) in
                    state.bolusEngageState = .stable
                })
            }
            self.setState({ (state) in
                state.bolusEngageState = .engaging
            })

            if let error = self.tryToValidateComms(session: session) {
                completion(.communication(error))
                return
            }

            self.handleSilencePodEnd(session: session)

            let acknowledgementBeep, completionBeep: Bool
            if self.silencePod {
                acknowledgementBeep = false
                completionBeep = false
            } else {
                acknowledgementBeep = self.beepPreference.shouldBeepForCommand(automatic: activationType.isAutomatic)
                completionBeep = self.beepPreference.shouldBeepForManualCommand && !activationType.isAutomatic
            }

            // Use a lastDeliveryStatusReceived?.suspended != true test here to not return a pod suspended failure if
            // there is not a valid last delivery status (which shouldn't even happen now with tryToValidateComms()).
            guard let podState = self.state.podState, !podState.isSuspended && podState.lastDeliveryStatusReceived?.suspended != true else {
                self.log.info("Not enacting bolus because podState or last status received indicates pod is suspended")
                completion(.deviceState(PodCommsError.podSuspended))
                return
            }

            // Use bits for the program reminder interval (not used by app)
            //   This trick enables determination, from just the hex messages
            //     of the log file, whether bolus was manually initiated by the
            //     user or automatically initiated by app.
            //   The max possible "reminder" value, 0x3F, would cause the pod to beep
            //      in 63 minutes if bolus had not completed by then.
            let bolusWasAutomaticIndicator: TimeInterval = activationType.isAutomatic ? TimeInterval(minutes: 0x3F) : 0

            let result = session.bolus(units: enactUnits, automatic: activationType.isAutomatic, acknowledgementBeep: acknowledgementBeep, completionBeep: completionBeep, programReminderInterval: bolusWasAutomaticIndicator)

            switch result {
            case .success:
                session.dosesForStorage() { (doses) -> Bool in
                    return self.store(doses: doses, in: session)
                }
                completion(nil)
            case .certainFailure(let error):
                self.log.error("enactBolus failed: %{public}@", String(describing: error))
                completion(.communication(error))
            case .unacknowledged:
                completion(.uncertainDelivery)
            }
        }
    }

    public func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
        guard self.hasActivePod else {
            completion(.failure(.deviceState(OmniPumpManagerError.noPodPaired)))
            return
        }

        guard state.podState?.setupProgress == .completed else {
            // A cancel delivery command before pod setup is complete will fault the pod
            completion(.failure(PumpManagerError.deviceState(PodCommsError.setupNotComplete)))
            return
        }

        self.runSession(withName: "Cancel Bolus") { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.failure(.communication(error)))
                return
            }

            do {
                defer {
                    self.setState({ (state) in
                        state.bolusEngageState = .stable
                    })
                }
                self.setState({ (state) in
                    state.bolusEngageState = .disengaging
                })

                if let bolus = self.state.podState?.unfinalizedBolus, !bolus.isFinished(), bolus.scheduledCertainty == .uncertain {
                    let status = try session.getStatus()

                    if !status.deliveryStatus.bolusing {
                        completion(.success(nil))
                        return
                    }
                }

                self.handleSilencePodEnd(session: session)

                // when cancelling a bolus use the built-in type 6 beeeeeep to match PDM if confirmation beeps are enabled
                let beepType: BeepType = self.beepPreference.shouldBeepForManualCommand && !self.silencePod ? .beeeeeep : .noBeepCancel
                let result = session.cancelDelivery(deliveryType: .bolus, beepType: beepType)
                switch result {
                case .certainFailure(let error):
                    throw error
                case .unacknowledged(let error):
                    throw error
                case .success(_, let canceledBolus):
                    session.dosesForStorage() { (doses) -> Bool in
                        return self.store(doses: doses, in: session)
                    }

                    let canceledDoseEntry: DoseEntry? = canceledBolus != nil ? DoseEntry(canceledBolus!) : nil
                    completion(.success(canceledDoseEntry))
                }
            } catch {
                completion(.failure(.communication(error as? LocalizedError)))
            }
        }
    }

    // Legacy version called via the PumpManager interface that wasn't updated to include an automatic variable as enactBolus() was
    public func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval, completion: @escaping (PumpManagerError?) -> Void) {
        enactTempBasal(unitsPerHour: unitsPerHour, for: duration, automatic: true, completion: completion)
    }

    public func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval, automatic: Bool, completion: @escaping (PumpManagerError?) -> Void) {

        if unitsPerHour > state.maxBasalRateUnitsPerHour {
            /// The app is trying to set a TBR above the configured max basal.
            /// This might happen if the app isn't properly sync'ing its max
            /// basal rate value to the Pump Manager in certain situations.
            /// Rather than returning an invalidSetting error that will cause Trio
            /// to get into a tizzy and stop looping, just log a debug message
            /// to note this condition for debugging purposes and continue on.
            //completion(.configuration(OmniPumpManagerError.invalidSetting))
            log.error("@@@ enactTempBasal requested unitsPerHour %{public}@ exceeds configured maxBasal of %{public}@!",
                      String(describing: unitsPerHour), String(describing: state.maxBasalRateUnitsPerHour))
        }

        guard self.hasActivePod, let podState = self.state.podState else {
            completion(.configuration(OmniPumpManagerError.noPodPaired))
            return
        }

        guard podState.setupProgress == .completed else {
            // A cancel delivery command before pod setup is complete will fault the pod
            completion(.deviceState(PodCommsError.setupNotComplete))
            return
        }

        // Legal duration values are [virtual] zero (to cancel current temp basal) or between 30 min and 12 hours
        guard duration < .ulpOfOne || (duration >= .minutes(30) && duration <= .hours(12)) else {
            completion(.configuration(OmniPumpManagerError.invalidSetting))
            return
        }

        // Round to nearest supported rate
        let rate = roundToSupportedBasalRate(unitsPerHour: unitsPerHour)

        self.runSession(withName: "Enact Temp Basal") { (result) in
            self.log.info("Enact temp basal %.03fU/hr for %ds", rate, Int(duration))
            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.communication(error))
                return
            }

            if let error = self.tryToValidateComms(session: session) {
                completion(.communication(error))
                return
            }

            self.handleSilencePodEnd(session: session)

            let acknowledgementBeep, completionBeep: Bool
            if self.silencePod {
                acknowledgementBeep = false
                completionBeep = false
            } else {
                acknowledgementBeep = self.beepPreference.shouldBeepForCommand(automatic: automatic)
                completionBeep = self.beepPreference.shouldBeepForManualCommand && !automatic
            }

            // Use a lastDeliveryStatusReceived?.suspended != true test here to not return a pod suspended failure if
            // there is not a valid last delivery status (which shouldn't even happen now with tryToValidateComms()).
            guard let podState = self.state.podState, !podState.isSuspended && podState.lastDeliveryStatusReceived?.suspended != true else {
                self.log.info("Not enacting bolus because podState or last status received indicates pod is suspended")
                completion(.deviceState(PodCommsError.podSuspended))
                return
            }

            // A resume scheduled basal delivery request is denoted by a 0 duration that cancels any existing temp basal.
            let resumingScheduledBasal = duration < .ulpOfOne

            if podState.unfinalizedBolus?.isFinished() == false && !resumingScheduledBasal {
                // The PDM would not start a new TB with a bolus in progress becuase of the UI.
                // OmniKit and OmniBLE roughly maintained this model by just using the bolus timing
                // without a strict enforcement which would involve adding some getstatus calls
                // For now, attempt to remove this restriction wasn't never strictly needed.
                self.log.info("Enacting temp basal with podState indicating an unfinalizedBolus bolus")
            }

            // Do the safe cancel TB command when resuming scheduled basal delivery OR if unfinalizedTempBasal indicates a
            // running a temp basal OR if we don't have the last pod delivery status confirming that no temp basal is running.
            if resumingScheduledBasal || podState.unfinalizedTempBasal != nil ||
                podState.lastDeliveryStatusReceived == nil || podState.lastDeliveryStatusReceived!.tempBasalRunning
            {
                let status: StatusResponse

                // if resuming scheduled basal delivery & an acknowledgement beep is needed, use the cancel TB beep
                let beepType: BeepType = resumingScheduledBasal && acknowledgementBeep ? .beep : .noBeepCancel
                let result = session.cancelDelivery(deliveryType: .tempBasal, beepType: beepType)
                switch result {
                case .certainFailure(let error):
                    completion(.communication(error))
                    return
                case .unacknowledged(let error):
                    completion(.communication(error))
                    return
                case .success(let cancelTempStatus, _):
                    status = cancelTempStatus
                }

                guard !status.deliveryStatus.suspended else {
                    self.log.info("Canceling temp basal because status return indicates pod is suspended!")
                    completion(.communication(PodCommsError.podSuspended))
                    return
                }
            } else {
                self.log.info("Skipped Cancel TB command before enacting temp basal")
            }

            defer {
                self.setState({ (state) in
                    state.tempBasalEngageState = .stable
                })
            }

            if resumingScheduledBasal {
                self.setState({ (state) in
                    state.tempBasalEngageState = .disengaging
                })
                session.dosesForStorage() { (doses) -> Bool in
                    return self.store(doses: doses, in: session)
                }
                completion(nil)
            } else {
                self.setState({ (state) in
                    state.tempBasalEngageState = .engaging
                })

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = self.state.timeZone
                let scheduledRate = self.state.basalSchedule.currentRate(using: calendar, at: self.dateGenerator())
                let isHighTemp = rate > scheduledRate

                let result = session.setTempBasal(rate: rate, duration: duration, isHighTemp: isHighTemp, automatic: automatic, acknowledgementBeep: acknowledgementBeep, completionBeep: completionBeep)
                switch result {
                case .success:
                    session.dosesForStorage() { (doses) -> Bool in
                        return self.store(doses: doses, in: session)
                    }
                    completion(nil)
                case .unacknowledged(let error):
                    self.log.error("Temp basal uncertain error: %@", String(describing: error))
                    completion(.communication(error))
                case .certainFailure(let error):
                    self.log.error("setTempBasal failed: %{public}@", String(describing: error))
                    completion(.communication(error))
                }
            }
        }
    }

    /// Returns a dose estimator for the current bolus, if one is in progress
    public func createBolusProgressReporter(reportingOn dispatchQueue: DispatchQueue) -> DoseProgressReporter? {
        if case .inProgress(let dose) = bolusState(for: self.state) {
            return PodDoseProgressEstimator(dose: dose, pumpManager: self, reportingQueue: dispatchQueue)
        }
        return nil
    }

    public func syncBasalRateSchedule(items scheduleItems: [RepeatingScheduleValue<Double>], completion: @escaping (Result<BasalRateSchedule, Error>) -> Void) {
        let newSchedule = BasalSchedule(repeatingScheduleValues: scheduleItems, podType: state.podType)
        setBasalSchedule(newSchedule) { (error) in
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(BasalRateSchedule(dailyItems: scheduleItems, timeZone: self.state.timeZone)!))
            }
        }
    }

    public func syncDeliveryLimits(limits deliveryLimits: DeliveryLimits, completion: @escaping (Result<DeliveryLimits, Error>) -> Void) {
        setState { state in
            if let maxBasalRate = deliveryLimits.maximumBasalRate?.doubleValue(for: .internationalUnitsPerHour),
               let maxBolus = deliveryLimits.maximumBolus?.doubleValue(for: .internationalUnit())
            {
                log.debug("@@@ syncDeliveryLimits setting maxBasalRate to %{public}@ and maxBolus to %{public}@",
                          String(describing: maxBasalRate), String(describing: maxBolus))
                state.maxBasalRateUnitsPerHour = maxBasalRate
                state.maxBolusUnits = maxBolus
                completion(.success(deliveryLimits))
            } else {
                log.error("@@@ syncDeliveryLimits failed with deliveryLimits of %{public}@", String(describing: deliveryLimits))
                completion(.failure(OmniPumpManagerError.invalidSetting))
            }
        }
    }


    // MARK: - Alerts

    var isClockOffset: Bool {
        let now = dateGenerator()
        return TimeZone.current.secondsFromGMT(for: now) != state.timeZone.secondsFromGMT(for: now)
    }

    func checkForTimeOffsetChange() {
        let isAlertActive = state.activeAlerts.contains(.timeOffsetChangeDetected)

        if !isAlertActive && isClockOffset && !state.acknowledgedTimeOffsetAlert {
            issueAlert(alert: .timeOffsetChangeDetected)
        } else if isAlertActive && !isClockOffset {
            retractAlert(alert: .timeOffsetChangeDetected)
        }
    }

    func updateExpirationReminder(_ intervalBeforeExpiration: TimeInterval?, completion: @escaping (OmniPumpManagerError?) -> Void) {

        guard self.hasActivePod, let podState = state.podState, let expiresAt = podState.expiresAt else {
            completion(OmniPumpManagerError.noPodPaired)
            return
        }

        self.runSession(withName: "Update Expiration Reminder") { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.communication(error))
                return
            }

            self.handleSilencePodEnd(session: session)

            let podTime = self.podTime
            var expirationReminderPodTime: TimeInterval = 0 // default to expiration reminder alert inactive

            // If the interval before expiration is not a positive value (e.g., it's in the past),
            // then the pod alert will get the default alert time of 0 making this alert inactive.
            if let intervalBeforeExpiration = intervalBeforeExpiration, intervalBeforeExpiration > 0 {
                let timeUntilReminder = expiresAt.addingTimeInterval(-intervalBeforeExpiration).timeIntervalSince(self.dateGenerator())
                // Only bother to set an expiration reminder pod alert if it is still at least a couple of minutes in the future
                if timeUntilReminder > .minutes(2) {
                    expirationReminderPodTime = podTime + timeUntilReminder
                    self.log.debug("Update Expiration timeUntilReminder=%@, podTime=%@, expirationReminderPodTime=%@", timeUntilReminder.timeIntervalStr, podTime.timeIntervalStr, expirationReminderPodTime.timeIntervalStr)
                }
            }

            let expirationReminder = PodAlert.expirationReminder(offset: podTime, absAlertTime: expirationReminderPodTime, silent: self.silencePod)
            do {
                let beepBlock = self.beepMessageBlock(beepType: .beep)
                try session.configureAlerts([expirationReminder], beepBlock: beepBlock)
                self.setState({ (state) in
                    state.scheduledExpirationReminderOffset = intervalBeforeExpiration
                })
                completion(nil)
            } catch {
                completion(.communication(error))
                return
            }
        }
    }

    var allowedExpirationReminderDates: [Date]? {

        guard let expiration = state.podState?.expiresAt else {
            return nil
        }

        let allDates = Array(stride(
            from: -Pod.expirationReminderAlertMaxHoursBeforeExpiration,
            through: -Pod.expirationReminderAlertMinHoursBeforeExpiration,
            by: 1)).map
        { (i: Int) -> Date in
            expiration.addingTimeInterval(.hours(Double(i)))
        }
        let now = dateGenerator()
        // Have a couple minutes of slop to avoid confusion trying to set an expiration reminder too close to now
        return allDates.filter { $0.timeIntervalSince(now) > .minutes(2) }
    }

    var scheduledExpirationReminder: Date? {
        guard let expiration = state.podState?.expiresAt, let offset = state.scheduledExpirationReminderOffset, offset > 0 else {
            return nil
        }

        // It is possible the scheduledExpirationReminderOffset does not fall on the hour, but instead be a few seconds off
        // since the allowedExpirationReminderDates are by the hour, force the offset to be on the hour
        return expiration.addingTimeInterval(-.hours(round(offset.hours)))
    }

    // Updates the low reservior reminder value for the current pod
    func updateLowReservoirReminder(_ value: Int, completion: @escaping (OmniPumpManagerError?) -> Void) {

        guard self.hasActivePod else {
            completion(OmniPumpManagerError.noPodPaired)
            return
        }

        let supportedValue = min(max(0, Double(value)), Pod.maximumReservoirReading)
        guard let currentReservoirLevel = self.reservoirLevel?.rawValue, currentReservoirLevel > supportedValue else {
            // Since the new low reservoir alert level is not below the current reservoir value,
            // just return an error as setting this alert will cause an immediate low reservoir alert.
            completion(OmniPumpManagerError.invalidSetting)
            return
        }

        self.runSession(withName: "Program Low Reservoir Reminder") { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.communication(error))
                return
            }

            self.handleSilencePodEnd(session: session)

            let lowReservoirReminder = PodAlert.lowReservoir(units: supportedValue, silent: self.silencePod)
            do {
                let beepBlock = self.beepMessageBlock(beepType: .beep)
                try session.configureAlerts([lowReservoirReminder], beepBlock: beepBlock)
                self.lowReservoirReminderValue = supportedValue
                self.log.default("Set Low Reservoir Reminder for current pod to %d U", value)
                completion(nil)
            } catch {
                completion(.communication(error))
                return
            }
        }
    }

    // Updates the default low reservior reminder value for future pods
    func updateLowReservoirDefaultReminder(_ value: Int, completion: @escaping (OmniPumpManagerError?) -> Void) {
        let supportedValue = min(max(0, Double(value)), Pod.maximumReservoirReading)
        self.log.default("Set Default Low Reservoir Reminder to %d U", value)
        self.defaultLowReservoirReminderValue = supportedValue
        completion(nil)
    }

    func issueAlert(alert: PumpManagerAlert) {
        let identifier = Alert.Identifier(managerIdentifier: self.pluginIdentifier, alertIdentifier: alert.alertIdentifier)
        let loopAlert = Alert(identifier: identifier, foregroundContent: alert.foregroundContent, backgroundContent: alert.backgroundContent, trigger: .immediate)
        pumpDelegate.notify { (delegate) in
            delegate?.issueAlert(loopAlert)
        }

        if let repeatInterval = alert.repeatInterval {
            // Schedule an additional repeating 15 minute reminder for suspend period ended.
            let repeatingIdentifier = Alert.Identifier(managerIdentifier: self.pluginIdentifier, alertIdentifier: alert.repeatingAlertIdentifier)
            let loopAlert = Alert(identifier: repeatingIdentifier, foregroundContent: alert.foregroundContent, backgroundContent: alert.backgroundContent, trigger: .repeating(repeatInterval: repeatInterval))
            pumpDelegate.notify { (delegate) in
                delegate?.issueAlert(loopAlert)
            }
        }

        self.setState { (state) in
            state.activeAlerts.insert(alert)
        }
    }

    func retractAlert(alert: PumpManagerAlert) {
        let identifier = Alert.Identifier(managerIdentifier: self.pluginIdentifier, alertIdentifier: alert.alertIdentifier)
        pumpDelegate.notify { (delegate) in
            delegate?.retractAlert(identifier: identifier)
        }
        if alert.isRepeating {
            let repeatingIdentifier = Alert.Identifier(managerIdentifier: self.pluginIdentifier, alertIdentifier: alert.repeatingAlertIdentifier)
            pumpDelegate.notify { (delegate) in
                delegate?.retractAlert(identifier: repeatingIdentifier)
            }
        }
        self.setState { (state) in
            state.activeAlerts.remove(alert)
        }
    }

    private func alertsChanged(oldAlerts: AlertSet, newAlerts: AlertSet) {
        guard let podState = state.podState else {
            preconditionFailure("trying to manage alerts without podState")
        }

        let (added, removed) = oldAlerts.compare(to: newAlerts)
        for slot in added {
            if let podAlert = podState.configuredAlerts[slot] {
                log.default("Alert slot triggered: %{public}@", String(describing: slot))
                if let pumpManagerAlert = getPumpManagerAlert(for: podAlert, slot: slot) {
                    issueAlert(alert: pumpManagerAlert)
                } else {
                    log.default("Ignoring alert: %{public}@", String(describing: podAlert))
                }
            } else {
                log.error("Unconfigured alert slot triggered: %{public}@", String(describing: slot))
                let pumpManagerAlert = PumpManagerAlert.unexpectedAlert(triggeringSlot: slot)
                issueAlert(alert: pumpManagerAlert)
            }
        }
        for alert in removed {
            log.default("Alert slot cleared: %{public}@", String(describing: alert))
        }
    }

    private func getPumpManagerAlert(for podAlert: PodAlert, slot: AlertSlot) -> PumpManagerAlert? {

        switch podAlert {
        case .shutdownImminent:
            return PumpManagerAlert.podExpireImminent(triggeringSlot: slot)
        case .expirationReminder:
            guard let podState = state.podState, let expiresAt = podState.expiresAt else {
                preconditionFailure("trying to lookup expiresAt")
            }
            let timeToExpiry = TimeInterval(hours: expiresAt.timeIntervalSince(dateGenerator()).hours.rounded())
            return PumpManagerAlert.userPodExpiration(triggeringSlot: slot, scheduledExpirationReminderOffset: timeToExpiry)
        case .lowReservoir(let units, _):
            return PumpManagerAlert.lowReservoir(triggeringSlot: slot, lowReservoirReminderValue: units)
        case .suspendTimeExpired:
            return PumpManagerAlert.suspendEnded(triggeringSlot: slot)
        case .expired:
            return PumpManagerAlert.podExpiring(triggeringSlot: slot)
        default:
            // No PumpManagerAlerts are used for any other pod alerts (including suspendInProgress).
            return nil
        }
    }

    private func silenceAcknowledgedAlerts() {
        // Only attempt to clear one per cycle (more than one should be rare)
        if let alert = state.alertsWithPendingAcknowledgment.first {
            if let slot = alert.triggeringSlot {
                self.runSession(withName: "Silence already acknowledged alert") { (result) in
                    switch result {
                    case .success(let session):
                        do {
                            let _ = try session.acknowledgeAlerts(alerts: AlertSet(slots: [slot]))
                        } catch {
                            return
                        }
                        self.setState { state in
                            state.activeAlerts.remove(alert)
                            state.alertsWithPendingAcknowledgment.remove(alert)
                        }
                    case .failure:
                        return
                    }
                }
            }
        }
    }

    private func notifyPodFault(fault: DetailedStatus) {
        pumpDelegate.notify { delegate in
            let content = Alert.Content(title: fault.faultEventCode.notificationTitle,
                                        body: fault.faultEventCode.notificationBody,
                                        acknowledgeActionButtonLabel: LocalizedString("OK", comment: "Alert acknowledgment OK button"))
            delegate?.issueAlert(Alert(identifier: Alert.Identifier(managerIdentifier: OmniPumpManager.podAlarmNotificationIdentifier,
                                                                    alertIdentifier: fault.faultEventCode.description),
                                       foregroundContent: content, backgroundContent: content,
                                       trigger: .immediate))
        }
    }


    // MARK: - Reporting Doses

    // This cannot be called from within the lockedState lock!
    func store(doses: [UnfinalizedDose], in session: PodCommsSession) -> Bool {
        session.assertOnSessionQueue()

        // We block the session until the data's confirmed stored by the delegate
        let semaphore = DispatchSemaphore(value: 0)
        var success = false

        store(doses: doses) { (error) in
            success = (error == nil)
            semaphore.signal()
        }

        semaphore.wait()

        if success {
            setState { (state) in
                state.lastPumpDataReportDate = Date()
            }
        }
        return success
    }

    func store(doses: [UnfinalizedDose], completion: @escaping (_ error: Error?) -> Void) {
        let lastSync = self.lastSync

        pumpDelegate.notify { (delegate) in
            guard let delegate = delegate else {
                preconditionFailure("pumpManagerDelegate cannot be nil")
            }

            delegate.pumpManager(self, hasNewPumpEvents: doses.map { NewPumpEvent($0) }, lastReconciliation: lastSync, replacePendingEvents: true) { (error) in
                if let error = error {
                    self.log.error("Error storing pod events: %@", String(describing: error))
                } else {
                    self.log.info("DU: Stored pod events: %@", String(describing: doses))
                }

                completion(error)
            }
        }
    }
}

extension OmniPumpManager: MessageLogger {
    func didSend(_ message: Data) {
        self.logDeviceCommunication(message.hexadecimalString, type: .send)
    }

    func didReceive(_ message: Data) {
        self.logDeviceCommunication(message.hexadecimalString, type: .receive)
    }

    func didError(_ message: String) {
        self.logDeviceCommunication(message, type: .error)
    }
}

extension OmniPumpManager: PodCommsDelegate {

    // Not used for Eros pods
    func podCommsDidEstablishSession(_ podComms: PodComms) {

        guard podComms.podState?.isSetupComplete == true else {
            self.log.debug("### Skipping post-connect processing with incomplete setup")
            return
        }

        self.runSession(withName: "Post-connect status fetch") { result in
            switch result {
            case .success(let session):
                let _ = self.handlePodUpdatesAsNeeded(session: session, canOptimize: true)
            case .failure:
                // Errors can be ignored here.
                break
            }
        }
    }

    func podComms(_ podComms: PodComms, didChange podState: PodState?) {
        if let podState = podState {
            let (newFault, oldAlerts, newAlerts) = setStateWithResult { (state) -> (DetailedStatus?,AlertSet,AlertSet) in
                if (state.suspendEngageState == .engaging && podState.isSuspended) ||
                   (state.suspendEngageState == .disengaging && !podState.isSuspended)
                {
                    state.suspendEngageState = .stable
                }

                let newFault: DetailedStatus?

                // Check for new fault state
                if state.podState?.fault == nil, let fault = podState.fault {
                    newFault = fault
                } else {
                    newFault = nil
                }

                let oldAlerts: AlertSet = state.podState?.activeAlertSlots ?? AlertSet.none
                let newAlerts: AlertSet = podState.activeAlertSlots

                state.updatePodStateFromPodComms(podState)

                return (newFault, oldAlerts, newAlerts)
            }

            if let newFault = newFault {
                notifyPodFault(fault: newFault)
            }

            if oldAlerts != newAlerts {
                self.alertsChanged(oldAlerts: oldAlerts, newAlerts: newAlerts)
            }
        } else {
            // Resetting podState
            setState { state in
                state.updatePodStateFromPodComms(podState)
            }
        }
    }
}

extension OmniPumpManager: AlertSoundVendor {
    public func getSoundBaseURL() -> URL? {
        return nil
    }

    public func getSounds() -> [Alert.Sound] {
        return []
    }
}


// MARK: - AlertResponder implementation

extension OmniPumpManager {
    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        guard self.hasActivePod, !state.activeAlerts.isEmpty else {
            log.default("@@@ Skipping acknowledge alert %{public}@ with no active pod or alerts", alertIdentifier)
            completion(nil)
            return
        }

        var found = false
        for alert in state.activeAlerts {
            if alert.alertIdentifier == alertIdentifier || alert.repeatingAlertIdentifier == alertIdentifier {
                found = true
                // If this alert was triggered by the pod find the slot to clear it.
                if let slot = alert.triggeringSlot {
                    // Special case handling for the suspend time expired alert
                    if (self.state.podState?.isSuspended == true || self.state.podState?.lastDeliveryStatusReceived?.suspended == true) &&
                        slot == .slot6SuspendTimeExpired
                    {
                        // Don't clear this pod alert here with the pod still suspended so that the suspend time expired
                        // pod alert beeping will continue until the pod is resumed which will then deactivate this alert.
                        log.default("Skipping acknowledgement of suspend time expired alert with a suspended pod")
                        completion(nil)
                        return
                    }

                    // Acknowledge the pod alert for the triggering slot
                    self.runSession(withName: "Acknowledge Alert") { (result) in
                        switch result {
                        case .success(let session):
                            self.handleSilencePodEnd(session: session)

                            do {
                                let beepBlock = self.beepMessageBlock(beepType: .beep)
                                let _ = try session.acknowledgeAlerts(alerts: AlertSet(slots: [slot]), beepBlock: beepBlock)
                            } catch {
                                self.setState { state in
                                    state.alertsWithPendingAcknowledgment.insert(alert)
                                }
                                completion(error)
                                return
                            }
                            self.setState { state in
                                state.activeAlerts.remove(alert)
                            }
                            completion(nil)
                        case .failure(let error):
                            self.setState { state in
                                state.alertsWithPendingAcknowledgment.insert(alert)
                            }
                            completion(error)
                        }
                    }
                } else {
                    // Non-pod alert
                    self.setState { state in
                        state.activeAlerts.remove(alert)
                        if alert == .timeOffsetChangeDetected {
                            state.acknowledgedTimeOffsetAlert = true
                        }
                    }
                    completion(nil)
                }
            }
        }

        if !found {
            log.error("@@@ acknowledge alert %{public}@ not found!", alertIdentifier)
            completion(nil)
        }
    }
}
