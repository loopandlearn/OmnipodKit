//
//  PeripheralManager.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/PeripheralManager.swift
//  Based on CGMBLEKit/CGMBLEKit/PeripheralManager.swift
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import Foundation
import os.log

class PeripheralManager: NSObject {

    // TODO: Make private
    let log = OSLog(category: "OmniPeripheralManager")

    /// This is mutable, because CBPeripheral instances can seemingly become invalid, and need to be periodically re-fetched from CBCentralManager
    var peripheral: CBPeripheral {
        didSet {
            guard oldValue !== peripheral else {
                return
            }

            log.error("Replacing peripheral reference %{public}@ -> %{public}@", oldValue, peripheral)

            oldValue.delegate = nil
            peripheral.delegate = self

            queue.sync {
                self.needsConfiguration = true
            }
        }
    }

    var dataQueue: [Data] = []
    var cmdQueue: [Data] = []
    let queueLock = NSCondition()

    var idleStart: Date? = nil

    var needsReconnection: Bool {
        guard let start = idleStart else { return false }

        return Date().timeIntervalSince(start) > .minutes(2.9)
    }


    /// The dispatch queue used to serialize operations on the peripheral
    let queue = DispatchQueue(label: "com.loopkit.PeripheralManager.queue", qos: .unspecified)

    private let sessionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.OmnipodKit.OmnipodDevice.sessionQueue"
        queue.maxConcurrentOperationCount = 1

        return queue
    }()

    /// The condition used to signal command completion
    let commandLock = NSCondition()

    /// The required conditions for the operation to complete
    private var commandConditions = [CommandCondition]()

    /// Any error surfaced during the active operation
    private var commandError: Error?

    private(set) weak var central: CBCentralManager?

    /// Owning BluetoothManager, for the fresh-discovery connect-on-demand path (it sees didDiscover).
    weak var bluetoothManager: BluetoothManager?

    let profile: BlePodProfile
    let configuration: Configuration

    // Confined to `queue`
    private var needsConfiguration = true

    let podType: PodType

    weak var delegate: PeripheralManagerDelegate?

    init(peripheral: CBPeripheral, podType: PodType, centralManager: CBCentralManager) {
        self.peripheral = peripheral
        self.central = centralManager

        assert(podType.isDash || podType.isO5)
        self.podType = podType
        self.profile = podType.blePodProfile
        self.configuration = profile.makePeripheralConfiguration()

        super.init()

        peripheral.delegate = self

        assertConfiguration()
    }
}


// MARK: - Nested types
extension PeripheralManager {
    struct Configuration {
        var serviceCharacteristics: [CBUUID: [CBUUID]] = [:]
        var notifyingCharacteristics: [CBUUID: [CBUUID]] = [:]
        var valueUpdateMacros: [CBUUID: (_ manager: PeripheralManager) -> Void] = [:]
    }

    enum CommandCondition {
        case notificationStateUpdate(characteristicUUID: CBUUID, enabled: Bool)
        case valueUpdate(characteristic: CBCharacteristic, matching: ((Data?) -> Bool)?)
        case write(characteristic: CBCharacteristic)
        case discoverServices
        case discoverCharacteristicsForService(serviceUUID: CBUUID)
        case connect
    }
}

protocol PeripheralManagerDelegate: AnyObject {
    // Called from the PeripheralManager's queue
    func completeConfiguration(for manager: PeripheralManager) throws
}


// MARK: - Operation sequence management
extension PeripheralManager {

    func configureAndRun(_ block: @escaping (_ manager: PeripheralManager) -> Void) -> (() -> Void) {
        return {
            if BluetoothManager.connectOnDemandEnabled {
                // "Normally disconnected" model: the pod isn't held connected, so connect on demand
                // for this session (no forceful reconnect — that heuristic is what caused the ~28s
                // disconnect-then-wait stalls). If already connected (burst of sessions), no-op.
                if self.peripheral.state != .connected {
                    do {
                        try self.connectOnDemand(timeout: 20)
                    } catch let error {
                        self.log.error("[connectOnDemand] on-demand connect failed: %{public}@", String(describing: error))
                    }
                }
            } else if self.needsReconnection {
                self.log.default("Triggering forceful reconnect")
                do {
                    try self.reconnect(timeout: 5)
                } catch let error {
                    self.log.error("Error while forcing reconnection: %{public}@", String(describing: error))
                }
            }

            if !self.needsConfiguration && self.peripheral.services == nil {
                self.log.error("Configured peripheral has no services. Reconfiguring %{public}@", self.peripheral)
            }

            if self.needsConfiguration || self.peripheral.services == nil {
                do {
                    self.log.bleDebug("Applying configuration")
                    try self.applyConfiguration()
                    self.needsConfiguration = false

                    if let delegate = self.delegate {
                        try delegate.completeConfiguration(for: self)
                        self.log.bleDebug("Delegate configuration notified")
                    }

                    self.log.bleDebug("Peripheral configuration completed")
                } catch let error {
                    self.log.error("Error applying peripheral configuration: %{public}@", String(describing: error))
                    // Will retry
                }
            }

            block(self)
        }
    }

    func perform(_ block: @escaping (_ manager: PeripheralManager) -> Void) {
        queue.async(execute: configureAndRun(block))
    }

    func assertConfiguration() {
        if peripheral.state == .connected && central?.state == .poweredOn {
            perform { (_) in
                // Intentionally empty to trigger configuration if necessary
            }
        }
    }

    private func applyConfiguration(discoveryTimeout: TimeInterval = 2) throws {
        try discoverServices(configuration.serviceCharacteristics.keys.map { $0 }, timeout: discoveryTimeout)

        for service in peripheral.services ?? [] {
            log.default("Discovered service: %{public}@", service)
            guard let characteristics = configuration.serviceCharacteristics[service.uuid] else {
                // Not all services may have characteristics
                continue
            }
            try discoverCharacteristics(characteristics, for: service, timeout: discoveryTimeout)
        }

        for (serviceUUID, characteristicUUIDs) in configuration.notifyingCharacteristics {
            guard let service = peripheral.services?.itemWithUUID(serviceUUID) else {
                // Service not discovered — may be optional (e.g., heartbeat on unpaired O5 pods)
                log.info("Skipping notifications for undiscovered service: %{public}@", serviceUUID.uuidString)
                continue
            }

            for characteristicUUID in characteristicUUIDs {
                guard let characteristic = service.characteristics?.itemWithUUID(characteristicUUID) else {
                    log.info("Skipping notifications for undiscovered characteristic: %{public}@", characteristicUUID.uuidString)
                    continue
                }

                guard !characteristic.isNotifying else {
                    continue
                }

                try setNotifyValue(true, for: characteristic, timeout: discoveryTimeout)
            }
        }
    }
}


// MARK: - Synchronous Commands
extension PeripheralManager {
    /// - Throws: PeripheralManagerError
    func runCommand(timeout: TimeInterval, allowDisconnected: Bool = false, command: () -> Void) throws {
        // Prelude
        dispatchPrecondition(condition: .onQueue(queue))
        // allowDisconnected: for connect-on-demand, the command IS the connect — the peripheral is
        // legitimately disconnected here and becomes connected via the .connect condition.
        guard central?.state == .poweredOn && (allowDisconnected || peripheral.state == .connected) else {
            self.log.info("runCommand guard failed - bluetooth not running or peripheral not connected: peripheral %@", peripheral)
            self.log.info("runCommand guard failed - not ready: peripheral=%{public}@ centralState=%{public}@ peripheralState=%{public}@ queueDepth=%{public}d commandConditions=%{public}@",
                          peripheral,
                          central.map { String(describing: $0.state) } ?? "nil",
                          String(describing: peripheral.state),
                          sessionQueue.operationCount,
                          String(describing: commandConditions))
            throw PeripheralManagerError.notReady
        }

        commandLock.lock()

        defer {
            commandLock.unlock()
        }

        guard commandConditions.isEmpty else {
            log.error("runCommand precondition failed - pending command conditions already present: %{public}@", String(describing: commandConditions))
            throw PeripheralManagerError.emptyValue
        }

        // Run
        command()

        guard !commandConditions.isEmpty else {
            // If the command didn't add any conditions, then finish immediately
            return
        }

        // Postlude
        let signaled = commandLock.wait(until: Date(timeIntervalSinceNow: timeout))

        defer {
            commandError = nil
            commandConditions = []
        }

        guard signaled else {
            self.log.info("runCommand lock timeout reached - not signalled")
            let characteristicsReady = peripheral.getCommandCharacteristic(profile: profile) != nil && peripheral.getDataCharacteristic(profile: profile) != nil
            self.log.error("runCommand timeout - not signalled: timeout=%{public}.3f pendingConditions=%{public}@ characteristicsReady=%{public}@ queueDepth=%{public}d centralState=%{public}@ peripheralState=%{public}@",
                           timeout,
                           String(describing: commandConditions),
                           String(describing: characteristicsReady),
                           sessionQueue.operationCount,
                           central.map { String(describing: $0.state) } ?? "nil",
                           String(describing: peripheral.state))
            throw PeripheralManagerError.timeout(commandConditions)
        }

        if let error = commandError {
            throw PeripheralManagerError.cbPeripheralError(error)
        }
    }

    /// It's illegal to call this without first acquiring the commandLock
    ///
    /// - Parameter condition: The condition to add
    func addCondition(_ condition: CommandCondition) {
        dispatchPrecondition(condition: .onQueue(queue))
        commandConditions.append(condition)
    }

    func discoverServices(_ serviceUUIDs: [CBUUID], timeout: TimeInterval) throws {
        let servicesToDiscover = peripheral.servicesToDiscover(from: serviceUUIDs)

        guard servicesToDiscover.count > 0 else {
            return
        }

        try runCommand(timeout: timeout) {
            addCondition(.discoverServices)
            
            peripheral.discoverServices(serviceUUIDs)
        }
    }

    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID], for service: CBService, timeout: TimeInterval) throws {
        let characteristicsToDiscover = peripheral.characteristicsToDiscover(from: characteristicUUIDs, for: service)

        guard characteristicsToDiscover.count > 0 else {
            return
        }

        try runCommand(timeout: timeout) {
            addCondition(.discoverCharacteristicsForService(serviceUUID: service.uuid))

            peripheral.discoverCharacteristics(characteristicsToDiscover, for: service)
        }
    }

    func reconnect(timeout: TimeInterval) throws {
        try runCommand(timeout: timeout) {
            addCondition(.connect)
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    /// Connect-on-demand: issue a real connect() and wait for didConnect. Unlike reconnect(), this
    /// does NOT cancel first — it connects a peripheral we're deliberately keeping disconnected
    /// between commands. Logs the measured connect latency (the number that decides viability).
    func connectOnDemand(timeout: TimeInterval) throws {
        guard peripheral.state != .connected else { return }
        log.default("[connectOnDemand] connecting on demand (state=%{public}d, timeout=%{public}ds)", peripheral.state.rawValue, Int(timeout))
        // Go fully dark for the connect: ANY concurrent scan (even non-allowDuplicates wildcard)
        // starves connection completion on iOS — connect-on-demand with a "helper" scan reliably
        // TIMED OUT at 20s foreground, whereas a scan-free delayed connect always
        // completed. So stop scanning and let iOS complete the connect; the alarm scan resumes on
        // disconnect. (Latency without a scan is iOS's own reacquisition; measure it, optimize next.)
        let start = Date()
        do {
            try runCommand(timeout: timeout, allowDisconnected: true) {
                addCondition(.connect)
                // Scan-free connect: the peripheral is a known/recovered CBPeripheral (via
                // retrievePeripherals), so a plain connect() registers a pending connect and iOS
                // reacquires the pod on its own — no scan needed. Route through BluetoothManager so
                // the central call runs on managerQueue (see connectOnDemand helper).
                bluetoothManager?.connectOnDemand(peripheral)
            }
        } catch {
            // Unstick a connect that never completed, so didDisconnect/didFailToConnect fires
            // instead of leaving it wedged in .connecting. Queue-correct cancel via BluetoothManager.
            bluetoothManager?.disconnectOnDemand(peripheral)
            throw error
        }
        log.default("[connectOnDemand] connected in %{public}@s", String(format: "%.3f", Date().timeIntervalSince(start)))
    }

    /// - Throws: PeripheralManagerError
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic, timeout: TimeInterval) throws {
        try runCommand(timeout: timeout) {
            addCondition(.notificationStateUpdate(characteristicUUID: characteristic.uuid, enabled: enabled))

            peripheral.setNotifyValue(enabled, for: characteristic)
        }
    }

    /// - Throws: PeripheralManagerError
    func readValue(for characteristic: CBCharacteristic, timeout: TimeInterval) throws -> Data? {
        try runCommand(timeout: timeout) {
            addCondition(.valueUpdate(characteristic: characteristic, matching: nil))

            peripheral.readValue(for: characteristic)
        }

        return characteristic.value
    }

    /// - Throws: PeripheralManagerError
    func writeValue(_ value: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType, timeout: TimeInterval) throws {
        if type == .withoutResponse {
            log.bleDebug("[BLE RAW] WRITE %{public}@ type=withoutResponse canSend=%{public}@ (%{public}d bytes): %{public}@",
                        characteristic.uuid.uuidString, String(describing: peripheral.canSendWriteWithoutResponse), value.count, value.hexadecimalString)
        } else {
            log.bleDebug("[BLE RAW] WRITE %{public}@ type=withResponse (%{public}d bytes): %{public}@",
                        characteristic.uuid.uuidString, value.count, value.hexadecimalString)
        }
        try runCommand(timeout: timeout) {
            if case .withResponse = type {
                addCondition(.write(characteristic: characteristic))
            }

            peripheral.writeValue(value, for: characteristic, type: type)
        }
    }
}

extension PeripheralManager {
    override var debugDescription: String {
        var items = [
            "## PeripheralManager",
            "peripheral: \(peripheral)",
        ]
        queue.sync {
            items.append("needsConfiguration: \(needsConfiguration)")
        }
        return items.joined(separator: "\n")
    }
}

// MARK: - Delegate methods executed on the central's queue
extension PeripheralManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        log.default("didDiscoverServices")
        commandLock.lock()

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .discoverServices = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        commandLock.lock()

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .discoverCharacteristicsForService(serviceUUID: service.uuid) = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        commandLock.lock()

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .notificationStateUpdate(characteristicUUID: characteristic.uuid, enabled: characteristic.isNotifying) = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log.error("[BLE RAW] didWriteValueFor %{public}@ ERROR: %{public}@", characteristic.uuid.uuidString, String(describing: error))
        } else {
            log.bleDebug("[BLE RAW] didWriteValueFor %{public}@ OK", characteristic.uuid.uuidString)
        }
        commandLock.lock()
        
        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .write(characteristic: characteristic) = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        commandLock.lock()

        if let macro = configuration.valueUpdateMacros[characteristic.uuid] {
            macro(self)
        }

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .valueUpdate(characteristic: characteristic, matching: let matching) = condition {
                return matching?(characteristic.value) ?? true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()

    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else {
            self.log.error("Error reading rssi: %{public}@", String(describing: RSSI))
            return
        }
        self.log.default("didReadRSSI: %{public}@", String(describing: RSSI))
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        log.bleDebug("[BLE RAW] peripheralIsReadyToSendWriteWithoutResponse — buffer was full, now ready")
    }

}


extension PeripheralManager {

    func clearCommsQueues() {
        queueLock.lock()
        if cmdQueue.count > 0 {
            self.log.default("Removing %{public}d leftover elements from command queue", cmdQueue.count)
            cmdQueue.removeAll()
        }
        if dataQueue.count > 0 {
            self.log.default("Removing %{public}d leftover elements from data queue", dataQueue.count)
            dataQueue.removeAll()
        }
        queueLock.unlock()
    }

    func centralManager(_ central: CBCentralManager, didDisconnect peripheral: CBPeripheral, error: Error?) {
        log.error("[DISCONNECT] PeripheralManager didDisconnect: error=%{public}@ peripheral=%{public}@",
                  String(describing: error), peripheral)
        self.queue.async {
            self.idleStart = nil
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.log.debug("PeripheralManager - didConnect: %@", peripheral)
        switch peripheral.state {
        case .connected:
            clearCommsQueues()

            /// maximumWriteValueLength (MTU minus 3-byte overhead) is the max bytes to write in a single operation.
            /// This may report 20 here (MTU 23) initially because iOS auto-negotiates the MTU asynchronously.
            /// iOS should auto-negotiate a maximumWriteValueLength of 244 for the O5 to match packetLayout.maxPayloadSize.
            /// completeConfiguration() polls until the maximumWriteValueLength settles before sending any protocol messages.
            /// For O5 withoutResponse, any writes exceeding maximumWriteValueLength are silently truncated — NOT fragmented.
            let maximumWriteValueLength = peripheral.maximumWriteValueLength(for: .withoutResponse)
            self.log.bleDebug("PeripheralManager - didConnect - maximumWriteValueLength: %{public}d, packetMaxPayloadSize: %{public}d", maximumWriteValueLength, profile.packetLayout.maxPayloadSize)

            self.log.debug("PeripheralManager - didConnect - running assertConfiguration")
            assertConfiguration()

            commandLock.lock()
            if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
                if case .connect = condition {
                    return true
                } else {
                    return false
                }
            }) {
                commandConditions.remove(at: index)

                if commandConditions.isEmpty {
                    commandLock.broadcast()
                }
            }
            commandLock.unlock()

        default:
            break
        }
    }
}

extension CBPeripheral {
    func getCommandCharacteristic(profile: BlePodProfile) -> CBCharacteristic? {
        guard let service = services?.itemWithUUID(profile.serviceUUID) else {
            return nil
        }

        let val = service.characteristics?.itemWithUUID(profile.commandCharacteristicUUID)
        if val == nil {
            return nil
        }
        return val
    }

    func getDataCharacteristic(profile: BlePodProfile) -> CBCharacteristic? {
        guard let service = services?.itemWithUUID(profile.serviceUUID) else {
            return nil
        }

        let val = service.characteristics?.itemWithUUID(profile.dataCharacteristicUUID)
        if val == nil {
            return nil
        }
        return val
    }
}


// MARK: - Command session management
extension PeripheralManager {
    func runSession(withName name: String , _ block: @escaping () -> Void) {
        self.log.default("Scheduling session %{public}@", name)

        sessionQueue.addOperation({ [weak self] in
            self?.perform { (manager) in
                manager.log.default("======================== %{public}@ ===========================", name)
                block()
                manager.log.default("------------------------ %{public}@ ---------------------------", name)
                self?.idleStart = Date()
                self?.log.default("Start of idle at %{public}@", String(describing: self?.idleStart))
                self?.scheduleIdleDisconnectIfNeeded()
            }
        })
    }

    /// Connect-on-demand: after a session goes idle, if no further session is queued, disconnect
    /// the pod so it's left "normally disconnected" (and advertising/observable) between commands.
    /// The delay is kept SHORT (see `BluetoothManager.idleDisconnectSeconds`) so a background heartbeat-wake
    /// cycle disconnects before iOS suspends the app — letting the StartDelay probe re-arm (it needs a
    /// disconnected pod). The status→dose burst still shares one connection: each session resets `idleStart`,
    /// so the disconnect only lands this many seconds after the LAST command. (Foreground / Pod Keep Alive
    /// hold the connection separately via `shouldHoldConnection`, so this delay only bites while backgrounded.)
    private func scheduleIdleDisconnectIfNeeded() {
        guard BluetoothManager.connectOnDemandEnabled else { return }
        let idleDelay: TimeInterval = BluetoothManager.idleDisconnectSeconds
        let idleAt = idleStart
        queue.asyncAfter(deadline: .now() + idleDelay) { [weak self] in
            guard let self = self, BluetoothManager.connectOnDemandEnabled else { return }
            // Keep-alive: skip the idle-disconnect whenever we want the pod held connected — while the app
            // is active (foreground keep-alive: connection-gated UI live, in-app commands instant), OR when
            // a background Pod Keep Alive mode (silentTune/rileyLink) is selected for phone/pod combos where
            // a disconnect→reconnect is unreliable. When Pod Keep Alive is disabled this is just foreground.
            if self.bluetoothManager?.shouldHoldConnection == true {
                self.log.default("[connectOnDemand] holding connection (keep-alive) — skip idle-disconnect")
                return
            }
            // Only disconnect if we're still idle (no newer session) and nothing is queued/running.
            guard self.idleStart == idleAt, self.sessionQueue.operationCount == 0,
                  self.peripheral.state == .connected else { return }
            self.log.default("[connectOnDemand] idle ~%{public}ds, no queued session -> disconnecting", Int(idleDelay))
            // Queue-correct cancel: route through BluetoothManager so it runs on managerQueue. Cancelling
            // from this (PeripheralManager) queue raced CoreBluetooth's teardown and wedged the next connect.
            self.bluetoothManager?.disconnectOnDemand(self.peripheral)
        }
    }
}
