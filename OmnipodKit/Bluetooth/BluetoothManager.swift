//
//  BluetoothManager.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/BluetoothManager.swift
//  Created by Randall Knutson on 10/10/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import Foundation
import LoopKit
import os.log

enum BluetoothManagerError: Error {
    case bluetoothNotAvailable(CBManagerState)
}

extension BluetoothManagerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .bluetoothNotAvailable(let state):
            switch state {
            case .poweredOff:
                return LocalizedString("Bluetooth is powered off", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.poweredOff)")
            case .resetting:
                return LocalizedString("Bluetooth is resetting", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.resetting)")
            case .unauthorized:
                return LocalizedString("Bluetooth use is unauthorized", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.unauthorized)")
            case .unsupported:
                return LocalizedString("Bluetooth use unsupported on this device", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.unsupported)")
            case .unknown:
                return LocalizedString("Bluetooth is unavailable for an unknown reason.", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.unknown)")
            default:
                return String(format: LocalizedString("Bluetooth is unavailable: %1$@", comment: "The format string for BluetoothManagerError.bluetoothNotAvailable for unknown state (1: the unknown state)"), String(describing: state))
            }
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .bluetoothNotAvailable(let state):
            switch state {
            case .poweredOff:
                return LocalizedString("Turn bluetooth on", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.poweredOff)")
            case .resetting:
                return LocalizedString("Try again", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.resetting)")
            case .unauthorized:
                return LocalizedString("Please enable bluetooth permissions for this app in system settings", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.unauthorized)")
            case .unsupported:
                return LocalizedString("Please use a different device with bluetooth capabilities", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.unsupported)")
            default:
                return nil
            }
        }
    }
}

protocol OmniConnectionDelegate: AnyObject {

    /**
     Tells the delegate that a peripheral has been connected to

     - parameter manager: The manager for the peripheral that was connected
     */
    func omnipodPeripheralDidConnect(manager: PeripheralManager)

    /**
     Tells the delegate that a connected peripheral has been restored from session restoration

     - parameter manager: The manager for the peripheral that was connected
     */
    func omnipodPeripheralWasRestored(manager: PeripheralManager)


    /**
     Tells the delegate that a peripheral was disconnected

     - parameter peripheral: The peripheral that was disconnected
     */
    func omnipodPeripheralDidDisconnect(peripheral: CBPeripheral, error: Error?)

    /**
     Tells the delegate that a peripheral failed to connect

     - parameter peripheral: The peripheral that failed to connect
     */
    func omnipodPeripheralDidFailToConnect(peripheral: CBPeripheral, error: Error?)

}


class BluetoothManager: NSObject {

    weak var connectionDelegate: OmniConnectionDelegate?

    private let podType: PodType

    private let log = OSLog(category: "BluetoothManager")

    /// Isolated to `managerQueue`
    private var manager: CBCentralManager! = nil
    
    /// Isolated to `managerQueue`
    private var devices: [Omni] = []
    
    /// Isolated to `managerQueue`
    private var discoveryModeEnabled: Bool = false

    /// Isolated to `managerQueue`
    private var autoConnectIDs: Set<String> = [] {
        didSet {
            updateConnections()
        }
    }

    /// The uuidPdmId is set after pairing...
    private var uuidPdmId: UInt32? = nil

    /// The O5 changes its service advertisement uuid from using FFFFFFFE the pdmId after pairing.
    /// This func is called to set this value to be used in uuid after pairing and with a nil (or 0) to reset.
    func setUuidPdmId(_ pdmId: UInt32?) {
        managerQueue.async {
            if let pdmId = pdmId, pdmId != 0 {
                self.log.bleDebug("Setting uuidPdmId to 0x%llx", pdmId)
                self.uuidPdmId = pdmId
            } else {
                self.uuidPdmId = nil
            }
        }
    }

    /// Isolated to `managerQueue`
    private var hasDiscoveredAllAutoConnectDevices: Bool {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        return autoConnectIDs.isSubset(of: devices.map { $0.manager.peripheral.identifier.uuidString })
    }

    // MARK: - Synchronization
    private let managerQueue = DispatchQueue(label: "com.OmnipodKit.bluetoothManagerQueue", qos: .unspecified)

    init(podType: PodType) {
        self.podType = podType
        super.init()

        managerQueue.sync {
            self.manager = CBCentralManager(delegate: self, queue: managerQueue, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.OmnipodKit"])
        }
    }
    
    @discardableResult
    private func addPeripheral(_ peripheral: CBPeripheral, podAdvertisement: PodAdvertisement?) -> Omni {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        var device: Omni! = devices.first(where: { $0.manager.peripheral.identifier == peripheral.identifier })

        if let device = device {
            log.default("Matched peripheral %{public}@ to existing device: %{public}@", peripheral, String(describing: device))
            device.manager.peripheral = peripheral
            if let podAdvertisement = podAdvertisement {
                device.advertisement = podAdvertisement
            }
        } else {
            device = Omni(peripheralManager: PeripheralManager(peripheral: peripheral, podType: podType, centralManager: manager), advertisement: podAdvertisement)
            devices.append(device)
            log.info("Created device")
        }
        return device
    }
    
    // MARK: - Actions
    
    func discoverPods(completion: @escaping (BluetoothManagerError?) -> Void) {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.sync {
            self.discoverPods(completion)
        }
    }
    
    func endPodDiscovery() {
        managerQueue.sync {
            self.discoveryModeEnabled = false
            self.manager.stopScan()
            
            // Disconnect from all devices not in our connection list
            for device in devices {
                let peripheral = device.manager.peripheral
                if !autoConnectIDs.contains(peripheral.identifier.uuidString) &&
                   (peripheral.state == .connected || peripheral.state == .connecting)
                {
                    log.default("Disconnecting from peripheral: %{public}@", peripheral)
                    manager.cancelPeripheralConnection(peripheral)
                }
            }
        }
    }
    
    func connectToDevice(uuidString: String) {
        managerQueue.async {
            self.autoConnectIDs.insert(uuidString)
            // If powered on and peripheral not yet in devices, retrieve it now.
            // This handles the user-terminated app restart where willRestoreState wasn't called.
            if self.manager.state == .poweredOn,
               !self.devices.contains(where: { $0.manager.peripheral.identifier.uuidString == uuidString }),
               let uuid = UUID(uuidString: uuidString),
               let peripheral = self.manager.retrievePeripherals(withIdentifiers: [uuid]).first
            {
                self.log.default("connectToDevice: retrieved peripheral %{public}@ via retrievePeripherals", uuidString)
                self.addPeripheral(peripheral, podAdvertisement: nil)
                self.manager.connect(peripheral, options: nil)
            }
        }
    }

    /// Retrieve a known peripheral by UUID (without scanning), add it to devices, and initiate connection.
    /// Returns the Omni device synchronously; the actual BLE connection completes asynchronously.
    func retrieveAndConnectKnownPod(uuidString: String) -> Omni? {
        var result: Omni?
        managerQueue.sync {
            guard manager.state == .poweredOn, let uuid = UUID(uuidString: uuidString) else { return }
            let peripherals = manager.retrievePeripherals(withIdentifiers: [uuid])
            guard let peripheral = peripherals.first else {
                log.error("retrieveAndConnectKnownPod: no peripheral found for UUID %{public}@", uuidString)
                return
            }
            let device = addPeripheral(peripheral, podAdvertisement: nil)
            autoConnectIDs.insert(uuidString)
            manager.connect(peripheral, options: nil)
            log.default("retrieveAndConnectKnownPod: initiating connection to %{public}@", peripheral)
            result = device
        }
        return result
    }
    
    func disconnectFromDevice(uuidString: String) {
        managerQueue.async {
            self.autoConnectIDs.remove(uuidString)
        }
    }
    
    private func updateConnections() {
        guard manager.state == .poweredOn else {
            log.debug("Skipping updateConnections until state is poweredOn")
            return
        }
        
        for device in devices {
            let peripheral = device.manager.peripheral
            if autoConnectIDs.contains(peripheral.identifier.uuidString) {
                if peripheral.state == .disconnected || peripheral.state == .disconnecting {
                    log.info("updateConnections: Connecting to peripheral: %{public}@", peripheral)
                    manager.connect(peripheral, options: nil)
                }
            } else {
                if peripheral.state == .connected || peripheral.state == .connecting {
                    log.info("updateConnections: Disconnecting from peripheral: %{public}@", peripheral)
                    manager.cancelPeripheralConnection(peripheral)
                }
            }
        }
    }

    private func discoverPods(_ completion: @escaping (BluetoothManagerError?) -> Void) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("discoverPods()")

        guard manager.state == .poweredOn else {
            completion(.bluetoothNotAvailable(manager.state))
            return
        }

        // We will attempt to connect to all pairable devices when in discovery mode
        discoveryModeEnabled = true
        for device in devices {
            let peripheral = device.manager.peripheral
            if peripheral.state == .disconnected || peripheral.state == .disconnecting {
                log.info("discoverPods: Connecting to peripheral: %{public}@", peripheral)
                manager.connect(peripheral, options: nil)
            }
        }
        startScanning()

        completion(nil)
    }

    private func startScanning() {
        let serviceUUID: CBUUID
        if podType.isO5, let pdmId = uuidPdmId {
            // The O5 service advertisement UUID is now using the pdmId
            serviceUUID = o5ServiceAdvertisementUUID(pdmId)
        } else {
            serviceUUID = podType.blePodProfile.advertisementServiceUUID
        }
        log.default("Start scanning for %{public}@", serviceUUID.uuidString)
        manager.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }

    private func stopScanning() {
        log.default("Stop scanning")
        manager.stopScan()
    }

    // MARK: - Accessors

    func getConnectedDevices() -> [Omni] {
        var connected: [Omni] = []
        managerQueue.sync {
            connected = self.devices.filter { $0.manager.peripheral.state == .connected }
        }
        return connected
    }

    override var debugDescription: String {
        
        var report = [
            "## BluetoothManager",
            "central: \(manager!)"
        ]

        for device in devices {
            report.append(String(reflecting: device))
            report.append("")
        }

        return report.joined(separator: "\n\n")
    }
}


extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("%{public}@: %{public}@", #function, String(describing: central.state.rawValue))

        if case .poweredOn = central.state {
            // bluetooth may have reset; update peripheral references
            for device in devices {
                if let newPeripheral = central.retrievePeripherals(withIdentifiers: [device.manager.peripheral.identifier]).first {
                    log.debug("Re-connecting to known peripheral %{public}@", newPeripheral.identifier.uuidString)
                    device.manager.peripheral = newPeripheral
                    central.connect(newPeripheral)
                }
            }

            // Recover peripherals from autoConnectIDs that aren't yet in devices.
            // This handles the user-terminated app restart where willRestoreState wasn't called.
            let knownDeviceIDs = Set(devices.map { $0.manager.peripheral.identifier.uuidString })
            for uuidString in autoConnectIDs where !knownDeviceIDs.contains(uuidString) {
                if let uuid = UUID(uuidString: uuidString),
                   let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first
                {
                    log.default("Recovered peripheral from autoConnectIDs: %{public}@", uuidString)
                    addPeripheral(peripheral, podAdvertisement: nil)
                    central.connect(peripheral, options: nil)
                }
            }

            updateConnections()
            
            if (discoveryModeEnabled || !hasDiscoveredAllAutoConnectDevices) && !manager.isScanning {
                startScanning()
            } else if !discoveryModeEnabled && manager.isScanning {
                stopScanning()
            }
        }

        for device in devices {
            device.manager.assertConfiguration()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        log.info("Omni %{public}@: %{public}@", #function, dict)

        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                let device = addPeripheral(peripheral, podAdvertisement: nil)
                
                if autoConnectIDs.contains(peripheral.identifier.uuidString) {
                    if peripheral.state == .connected {
                        connectionDelegate?.omnipodPeripheralWasRestored(manager: device.manager)
                    }
                } else if peripheral.state == .connected || peripheral.state == .connecting {
                    // Don't disconnect — autoConnectIDs may not be populated yet due to init ordering.
                    // updateConnections() will clean up any truly unwanted peripherals after autoConnectIDs is set.
                    log.info("Restored peripheral %{public}@ not yet in autoConnectIDs, deferring cleanup to updateConnections", peripheral.identifier.uuidString)
                }
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.debug("%{public}@: %{public}@, %{public}@", #function, peripheral, advertisementData)

        if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            log.default("[SCAN] ManufacturerData: %{public}@ (%{public}lld bytes)", mfgData.hexadecimalString, mfgData.count)
        }

        if let podAdvertisement = PodAdvertisement(advertisementData, podType: podType) {
            addPeripheral(peripheral, podAdvertisement: podAdvertisement)
            
            if discoveryModeEnabled && peripheral.state == .disconnected && podAdvertisement.pairable {
                // Connect to any pairable device, during discovery
                log.default("Connecting to pairable device %{public} in discovery mode", peripheral)
                manager.connect(peripheral, options: nil)
            } else if autoConnectIDs.contains(peripheral.identifier.uuidString) && peripheral.state == .disconnected {
                log.debug("Reonnecting to autoconnect device")
                manager.connect(peripheral, options: nil)
            } else {
                log.info("Ignoring paired or unconnectable peripheral: %{public}@", peripheral)
            }
        } else {
            log.info("Ignoring peripheral with unexpected advertisement data: %{public}@", advertisementData)
        }
        
        if !discoveryModeEnabled && central.isScanning && hasDiscoveredAllAutoConnectDevices {
            log.debug("All peripherals discovered")
            stopScanning()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.debug("%{public}@: %{public}@", #function, peripheral)
        
        // Proxy connection events to peripheral manager
        for device in devices where device.manager.peripheral.identifier == peripheral.identifier {
            device.manager.centralManager(central, didConnect: peripheral)
            connectionDelegate?.omnipodPeripheralDidConnect(manager: device.manager)

            // Get an RSSI reading for logging
            peripheral.readRSSI()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        // Proxy disconnection events to peripheral manager
        for device in devices where device.manager.peripheral.identifier == peripheral.identifier {
            device.manager.centralManager(central, didDisconnect: peripheral, error: error)
        }

        connectionDelegate?.omnipodPeripheralDidDisconnect(peripheral: peripheral, error: error)

        if autoConnectIDs.contains(peripheral.identifier.uuidString) {
            log.debug("Reconnecting disconnected autoconnect peripheral")
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.error("%{public}@: %{public}@", #function, String(describing: error))

        connectionDelegate?.omnipodPeripheralDidFailToConnect(peripheral: peripheral, error: error)

        if autoConnectIDs.contains(peripheral.identifier.uuidString) {
            central.connect(peripheral, options: nil)
        }
    }
}
