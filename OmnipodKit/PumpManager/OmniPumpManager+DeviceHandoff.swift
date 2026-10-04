//
//  OmniPumpManager+DeviceHandoff.swift
//  OmnipodKit
//
//  Handing the pod to another controller: LoopKit's DeviceConfigurationSharing,
//  ExclusiveDeviceControl and PumpDeliveryOdometer. The kit keeps the contract's rules here:
//  an export carries no local state, live session or pending command; this controller's own
//  handle for the pod travels only in its `localState`, which the host saves and hands back at
//  the next adopt; an adopter owns the in-flight doses under the exporter's identities; a
//  controller that released drops its copies when it takes control back; and none books
//  delivery it did not command (PodState).
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import os.log

// MARK: - Configuration sharing

extension OmniPumpManager: DeviceConfigurationSharing {

    public func exportConfiguration() -> SharedDeviceConfiguration {
        state.sharedConfiguration(managerIdentifier: pluginIdentifier)
    }

    /// The state `init(adopting:localState:)` builds from, with this controller's own handle if
    /// `localState` holds one for the same pod; `takeControl()` searches if not.
    static func adoptedRawState(from configuration: SharedDeviceConfiguration, localState: [String: Any]?) -> RawStateValue? {
        guard let shared = OmniPumpManagerState(rawValue: configuration.state) else {
            return nil
        }
        let handle = shared.podState.flatMap { OmniPumpManagerState.handle(in: localState, forPodAddress: $0.address) }
        let adopted = shared.adopted(handle: handle)
        ConnectClock.beginAttempt(adoptedHandle: handle)
        return adopted.rawValue
    }

    public var isConfiguredByAnotherController: Bool {
        state.configuredByAnotherController
    }

    /// This controller's handle for its pod, from the manager's state.
    public var localState: [String: Any]? {
        state.localState
    }
}

extension OmniPumpManagerState {

    /// This controller's CoreBluetooth handle for the pod, with the pod's address so it is never
    /// used for another pod. Handles are per device, so the export never carries one.
    var localState: [String: Any]? {
        guard let pod = podState, let handle = pod.bleIdentifier else { return nil }
        return ["podAddress": pod.address, "bleIdentifier": handle]
    }

    /// The handle in `localState`, if it is for the pod at `address`.
    static func handle(in localState: [String: Any]?, forPodAddress address: UInt32) -> String? {
        guard let localState, localState["podAddress"] as? UInt32 == address else { return nil }
        return localState["bleIdentifier"] as? String
    }

    /// The export: facts about the pod, none of this controller's relationship to it.
    func sharedConfiguration(managerIdentifier: String) -> SharedDeviceConfiguration {
        var shared = self
        shared.podConnectionReleased = false
        shared.configuredByAnotherController = false
        shared.inFlightDosesInheritedAway = false
        shared.rileyLinkConnectionManagerState = nil
        shared.updatePodStateFromPodComms(podState?.sharedFacts)
        let measured = shared.podState?.lastInsulinMeasurements
        return SharedDeviceConfiguration(managerIdentifier: managerIdentifier,
                                         asOf: measured?.validTime ?? Date(),
                                         deliveredUnits: measured?.delivered,
                                         state: shared.rawValue)
    }

    /// Another controller's shared state as this one's: in-flight doses keep the exporter's
    /// identities, and delivery this controller did not command is not booked.
    func adopted(handle: String?) -> OmniPumpManagerState {
        var state = self
        var pod = podState?.sharedFacts
        pod?.bleIdentifier = handle
        pod?.untrackedDeliveryIsForeign = true
        state.updatePodStateFromPodComms(pod)
        state.podConnectionReleased = false
        state.configuredByAnotherController = true
        state.inFlightDosesInheritedAway = false
        state.rileyLinkConnectionManagerState = nil
        return state
    }

    /// Copies of a bolus or temp basal still in flight now belong to the controller taking over.
    mutating func releaseControl() {
        podConnectionReleased = true
        inFlightDosesInheritedAway = podState?.unfinalizedBolus != nil || podState?.unfinalizedTempBasal != nil
    }
}

extension PodState {

    /// The pod without this controller's handle, session keys, per-session counters or pending
    /// command. The EAP sequence and message number travel; the pod resynchronizes both.
    var sharedFacts: PodState {
        var pod = self
        pod.bleIdentifier = nil
        pod.unacknowledgedCommand = nil
        pod.lastDeliveryStatusReceived = nil
        pod.untrackedDeliveryIsForeign = false
        pod.bleMessageTransportState = BleMessageTransportState(ck: nil, noncePrefix: nil,
                                                                eapSeq: bleMessageTransportState.eapSeq,
                                                                messageNumber: bleMessageTransportState.messageNumber)
        return pod
    }

    /// Another controller ran the pod: forget the last delivery status, book no untracked delivery,
    /// and with `dropInFlight` drop the in-flight copies so the pod's status resolves them.
    mutating func resolveAfterForeignControl(dropInFlight: Bool) {
        lastDeliveryStatusReceived = nil
        untrackedDeliveryIsForeign = true
        if dropInFlight {
            unfinalizedBolus = nil
            unfinalizedTempBasal = nil
        }
    }
}

extension PodComms {

    /// Drops this controller's handle for the pod; the manager's state follows through the delegate.
    func forgetHandle() {
        podStateLock.lock()
        podState?.bleIdentifier = nil
        podStateLock.unlock()
    }
}

// MARK: - Exclusive control

extension OmniPumpManager: ExclusiveDeviceControl {

    public var isControlReleased: Bool {
        state.podConnectionReleased
    }

    /// Stops bidding for the pod's one BLE connection; pod state, pairing and keys are kept.
    /// Copies of a bolus or temp basal still in flight now belong to the controller taking over.
    public func releaseControl() {
        setState { $0.releaseControl() }
        (podComms as? BlePodComms)?.releaseConnection()

        // A saved handle that never connected is wrong: drop it from the pod state, so
        // `localState` goes nil and the next adopt searches.
        if let unproven = ConnectClock.adoptedHandleThatNeverConnected() {
            podComms.forgetHandle()
            omnipodLogDeviceEvent("saved handle \(unproven) never connected — forgotten; the next adopt searches")
        }
    }

    /// Takes the pod back after a release, or starts the search an adopted manager needs.
    public func takeControl() {
        if state.podConnectionReleased {
            resumeControl()
            (podComms as? BlePodComms)?.rearmConnection()
        }
        if takeControlNeedsSearch, let address = state.podState?.address {
            (podComms as? BlePodComms)?.beginTakeoverSearch(podId: address)
        }
    }

    /// Lifts the release (see PodState.resolveAfterForeignControl).
    private func resumeControl() {
        ConnectClock.beginAttempt(adoptedHandle: nil)
        (podComms as? BlePodComms)?.resolveAfterForeignControl(dropInFlight: state.inFlightDosesInheritedAway)
        setState { state in
            state.podConnectionReleased = false
            state.inFlightDosesInheritedAway = false
        }
    }

    public var isControlReady: Bool {
        #if targetEnvironment(simulator)
        // The simulator has no radio, so no peripheral ever connects; any pod counts as ready.
        return state.podState != nil
        #else
        return peripheralStateDescription == "connected"
        #endif
    }

    /// Goes looking for the pod by address instead of waiting to hear it.
    @discardableResult
    public func escalateTakeControl() -> String? {
        guard let address = state.podState?.address, let ble = podComms as? BlePodComms else { return nil }
        if state.podConnectionReleased {
            resumeControl()
        }
        ble.escalateTakeover(podId: address)
        return String(format: "scan-adopt armed for pod 0x%X", address)
    }

    public func connectionDiagnostics() -> String? {
        guard let ble = (podComms as? BlePodComms)?.bluetoothManager else { return nil }
        return "\(ble.loanBleDiagnostics) pod=\(peripheralStateDescription) · \(ConnectClock.summary(since: ConnectClock.attemptStartedAt))"
    }

    /// The last EAP SQN resync: another controller established sessions since our last contact.
    public var lastForeignSessionAt: Date? {
        (podComms as? BlePodComms)?.lastSqnResync?.at
    }

    public var takeControlNeedsSearch: Bool {
        podComms is BlePodComms && state.podState != nil && state.podState?.bleIdentifier == nil
    }

    /// An adopter searches for a BLE pod unless `localState` holds this controller's handle for it.
    public static func takeControlNeedsSearch(adopting configuration: SharedDeviceConfiguration, localState: [String: Any]?) -> Bool {
        guard let shared = OmniPumpManagerState(rawValue: configuration.state),
              shared.podType == dashType || shared.podType == omnipod5Type,
              let pod = shared.podState else { return false }
        return OmniPumpManagerState.handle(in: localState, forPodAddress: pod.address) == nil
    }

    public var hostRadioNeedsReset: Bool {
        ConnectClock.wedgeSignature(since: ConnectClock.attemptStartedAt)
    }

    /// The pod peripheral's CoreBluetooth state, for diagnostics.
    var peripheralStateDescription: String {
        guard let peripheral = (podComms as? BlePodComms)?.manager?.peripheral else {
            return "no-peripheral"
        }
        switch peripheral.state {
        case .disconnected:  return "disconnected"
        case .connecting:    return "connecting"
        case .connected:     return "connected"
        case .disconnecting: return "DISCONNECTING(wedged?)"
        @unknown default:    return "unknown(\(peripheral.state.rawValue))"
        }
    }
}

// MARK: - Delivered-total odometer

extension OmniPumpManager: PumpDeliveryOdometer {

    public var deliveredUnits: (units: Double, at: Date)? {
        guard let measured = state.podState?.lastInsulinMeasurements else { return nil }
        return (measured.delivered, measured.validTime)
    }

    public var deliveryPulseUnits: Double { Pod.pulseSize }

    /// A real status read, bypassing the freshness shortcut in ensureCurrentPumpData.
    public func refreshDeliveredUnits(completion: @escaping (Bool) -> Void) {
        #if targetEnvironment(simulator)
        // No radio in the simulator: fake the round-trip and stamp a measurement, as jumpStartPod does.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return completion(false) }
            self.setState { state in
                if state.podState?.lastInsulinMeasurements == nil {
                    var pod = state.podState
                    let delivered = pod?.setupUnitsDelivered ?? Pod.primeUnits
                    pod?.lastInsulinMeasurements = PodInsulinMeasurements(
                        insulinDelivered: delivered, reservoirLevel: nil, validTime: Date())
                    state.updatePodStateFromPodComms(pod)
                }
            }
            self.log.default("refreshDeliveredUnits simulated OK (no radio in the simulator)")
            completion(true)
        }
        #else
        getPodStatus(canOptimize: false) { result in
            if case .success(let status) = result, status != nil {
                completion(true)
            } else {
                completion(false)
            }
        }
        #endif
    }
}

// MARK: - Connect clock

/// CoreBluetooth's connect and disconnect edges, stamped as they happen, so a host polling on a
/// deferred timer can tell "connected late" from "looked late". Observation only.
enum ConnectClock {
    private static let lock = NSLock()
    private static var _lastConnectAt: Date?
    private static var _lastDisconnectAt: Date?
    private static var _connectCount = 0
    private static var _lastReason: String?
    private static var _reasons: [String] = []
    /// Kept apart from `_lastReason`: a retry storm floods failures and would evict the one
    /// reason an established link died for.
    private static var _lastDisconnectReason: String?
    /// When CBErrorDomain#11 (connection limit) was last seen, for the wedge test.
    private static var _lastCode11At: Date?
    private static var _attemptStartedAt: Date?
    private static var _adoptedHandle: String?

    /// When the current take began: at adopt, or at a take after a release.
    static var attemptStartedAt: Date? { lock.lock(); defer { lock.unlock() }; return _attemptStartedAt }
    static var connectCount: Int { lock.lock(); defer { lock.unlock() }; return _connectCount }

    static func beginAttempt(adoptedHandle: String?) {
        lock.lock()
        _lastConnectAt = nil; _lastDisconnectAt = nil; _connectCount = 0
        _lastReason = nil; _reasons = []; _lastDisconnectReason = nil; _lastCode11At = nil
        _attemptStartedAt = Date()
        _adoptedHandle = adoptedHandle
        lock.unlock()
    }

    /// The handle this attempt's adopt attached from `localState`, if it never connected. Once per
    /// attempt; the caller drops it.
    static func adoptedHandleThatNeverConnected() -> String? {
        lock.lock()
        let adopted = _adoptedHandle, connected = _connectCount > 0
        _adoptedHandle = nil
        lock.unlock()
        guard let adopted, !connected else { return nil }
        return adopted
    }

    /// CoreBluetooth's reason a link ended; nil means this process cancelled it.
    private static func describe(_ error: Error?) -> String {
        guard let error = error else { return "reason=nil(local-cancel?)" }
        let ns = error as NSError
        return "reason=\(ns.domain)#\(ns.code)"
    }

    private static func isCode11(_ error: Error?) -> Bool {
        guard let ns = error as NSError? else { return false }
        return ns.domain == "CBErrorDomain" && ns.code == 11
    }

    static func noteConnect(appState: String) {
        lock.lock()
        _lastConnectAt = Date(); _connectCount += 1
        _reasons.append("+\(_connectCount)@\(appState)")
        if _reasons.count > 12 { _reasons.removeFirst() }
        lock.unlock()
    }

    static func noteDisconnect(error: Error?, appState: String) {
        let d = describe(error)
        lock.lock()
        if isCode11(error) { _lastCode11At = Date() }
        _lastDisconnectAt = Date(); _lastDisconnectReason = d
        _reasons.append("-\(d)@\(appState)")
        if _reasons.count > 12 { _reasons.removeFirst() }
        lock.unlock()
    }

    static func noteFailToConnect(error: Error?, appState: String) {
        let d = describe(error)
        lock.lock()
        if isCode11(error) { _lastCode11At = Date() }
        _lastReason = d
        _reasons.append("x\(d)@\(appState)")
        if _reasons.count > 12 { _reasons.removeFirst() }
        lock.unlock()
    }

    /// A take is wedged if the system refused a connection slot during it or no connect landed;
    /// only a Bluetooth toggle clears that. For takes only: a quiet pod mid-session also has zero connects.
    static func isWedge(lastCode11At: Date?, lastConnectAt: Date?, since: Date) -> Bool {
        if let c11 = lastCode11At, c11 >= since { return true }
        let connectedThisAttempt = lastConnectAt.map { $0 >= since } ?? false
        return !connectedThisAttempt
    }

    static func wedgeSignature(since start: Date?) -> Bool {
        guard let start = start else { return false }
        lock.lock()
        let c11 = _lastCode11At, c = _lastConnectAt
        lock.unlock()
        return isWedge(lastCode11At: c11, lastConnectAt: c, since: start)
    }

    /// One field for a log line, relative to the attempt's start: the flap trail with each edge's
    /// reason and the app state it fired in.
    static func summary(since start: Date?) -> String {
        lock.lock()
        let c = _lastConnectAt, d = _lastDisconnectAt, n = _connectCount
        let r = _lastReason, trail = _reasons, dr = _lastDisconnectReason
        lock.unlock()
        guard let start = start else { return "cb: (no anchor)" }
        func rel(_ t: Date?) -> String { t.map { String(format: "+%.1fs", $0.timeIntervalSince(start)) } ?? "never" }
        let why = r.map { " · lastFail=\($0)" } ?? ""
        let dwhy = dr.map { " · lastDrop=\($0)" } ?? ""
        let tr = trail.isEmpty ? "" : " · trail[\(trail.joined(separator: " "))]"
        return "cb: didConnect \(rel(c)) (n=\(n)) · didDisconnect \(rel(d))\(dwhy)\(why)\(tr)"
    }
}
