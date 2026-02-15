//
//  BlePodComms.swift
//  OmnipodKit
//
//  Based on OmniBLE/PumpManager/PodComms.swift
//  Created by Joe Moran on 4/15/25.
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//

import Foundation
import CoreBluetooth
import LoopKit
import os.log

class BlePodComms: PodComms {

    var manager: PeripheralManager? {
        didSet {
            manager?.delegate = self
        }
    }

    private var isPaired: Bool {
        get {
            return self.podState?.ltk != nil && self.podState!.ltk != nil && (self.podState!.ltk?.count ?? 0) > 0
        }
    }

    private var needsSessionEstablishment: Bool = false

    private let bluetoothManager = BluetoothManager()

    override init(podState: PodState?, podType: PodType, myId: UInt32 = 0, podId: UInt32 = 0) {
        super.init(podState: podState, podType: podType, myId: myId, podId: podId)
        bluetoothManager.podType = podType
        bluetoothManager.connectionDelegate = self
        if let podState = podState, let bleIdentifier = podState.bleIdentifier {
            bluetoothManager.connectToDevice(uuidString: bleIdentifier)
        }
    }

    override func forgetPod() {
        if let manager = manager {
            self.log.default("Removing %{public}@ from auto-connect ids", manager.peripheral)
            bluetoothManager.disconnectFromDevice(uuidString: manager.peripheral.identifier.uuidString)
        }
        super.forgetPod()
    }

    func connectToNewPod(_ completion: @escaping (Result<Omni, Error>) -> Void) {
        let discoveryStartTime = Date()

        setServicePodType(podType: self.podType)
        bluetoothManager.discoverPods { error in
            if let error = error {
                completion(.failure(error))
            } else {
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                    let devices = self.bluetoothManager.getConnectedDevices()

                    if devices.count > 1 {
                        self.log.default("Multiple pods found while scanning")
                        self.bluetoothManager.endPodDiscovery()
                        completion(.failure(PodCommsError.tooManyPodsFound))
                        timer.invalidate()
                    }

                    let elapsed = Date().timeIntervalSince(discoveryStartTime)

                    // If we've found a pod by 2 seconds, let's go.
                    if elapsed > TimeInterval(seconds: 2) && devices.count > 0 {
                        self.log.default("Found pod!")
                        let targetPod = devices.first!
                        self.bluetoothManager.connectToDevice(uuidString: targetPod.manager.peripheral.identifier.uuidString)
                        self.manager = targetPod.manager
                        targetPod.manager.delegate = self
                        self.bluetoothManager.endPodDiscovery()
                        completion(.success(devices.first!))
                        timer.invalidate()
                    }

                    if elapsed > TimeInterval(seconds: 10) {
                        self.log.default("No pods found while scanning")
                        self.bluetoothManager.endPodDiscovery()
                        completion(.failure(PodCommsError.noPodsFound))
                        timer.invalidate()
                    }
                }
            }
        }
    }

    // Handles all the common work to send and verify the version response for the two pairing pod commands, AssignAddress and SetupPod.
    private func bleSendPairMessage(blePodMessageTransport: BlePodMessageTransport, message: Message) throws -> VersionResponse {

        // We should already be holding podStateLock during calls to this function, so try() should fail
        assert(!podStateLock.try(), "\(#function) should be invoked while holding podStateLock")

        defer {
            if self.podState != nil {
                log.debug("bleSendPairMessage saving current message transport state %@", String(reflecting: blePodMessageTransport))
                self.podState!.bleMessageTransportState = BleMessageTransportState(ck: blePodMessageTransport.ck, noncePrefix: blePodMessageTransport.noncePrefix, msgSeq: blePodMessageTransport.msgSeq, nonceSeq: blePodMessageTransport.nonceSeq, messageNumber: blePodMessageTransport.messageNumber)
            }
        }

        log.debug("bleSendPairMessage: attempting to use PodMessageTransport %@ to send message %@", String(reflecting: blePodMessageTransport), String(reflecting: message))
        let podMessageResponse = try blePodMessageTransport.sendMessage(message)

        if let fault = podMessageResponse.fault {
            log.error("bleSendPairMessage pod fault: %{public}@", String(describing: fault))
            if let podState = self.podState, podState.fault == nil {
                self.podState!.fault = fault
            }
            throw PodCommsError.podFault(fault: fault)
        }

        guard let versionResponse = podMessageResponse.messageBlocks[0] as? VersionResponse else {
            log.error("bleSendPairMessage unexpected response: %{public}@", String(describing: podMessageResponse))
            let responseType = podMessageResponse.messageBlocks[0].blockType
            throw PodCommsError.unexpectedResponse(response: responseType)
        }

        log.debug("bleSendPairMessage: returning versionResponse %@", String(describing: versionResponse))
        return versionResponse
    }

    private func pairPod(insulinType: InsulinType) throws {
        // We should already be holding podStateLock during calls to this function, so try() should fail
        assert(!podStateLock.try(), "\(#function) should be invoked while holding podStateLock")

        guard let manager = manager else { throw PodCommsError.podNotConnected }

        let ids: Ids
        let response: PairResult
        let ltk: Data
        switch self.podType {
        case dashType:
            ids = Ids(myId: self.myId, podId: self.podId)
            let ltkExchanger = LTKExchanger(manager: manager, ids: ids)
            response = try ltkExchanger.negotiateLTK()
            ltk = response.ltk
        case omnipod5Type:
            // O5 controller/pod IDs MUST match the TLS certificate pdmid.
            // Override any stale persisted IDs to ensure TWi headers match the crypto layer.
            let certPdmid = O5CertificateStore.pdmid
            if self.myId != certPdmid {
                log.default("O5: Correcting myId from %X to certificate pdmid %X", self.myId, certPdmid)
                self.myId = certPdmid
                self.podId = certPdmid + 1
            }
            ids = Ids(myId: self.myId, podId: self.podId)
            let o5LTKExchanger = try O5LTKExchanger(manager: manager, ids: ids)
            response = try o5LTKExchanger.o5negotiateLTK()
            ltk = response.ltk
        default:
            throw OmniPumpManagerError.podTypeNotConfigured
        }

        guard podId == response.address else {
            log.debug("podId 0x%x doesn't match response value!: %{public}@", podId, String(describing: response))
            throw PodCommsError.invalidAddress(address: response.address, expectedAddress: self.podId)
        }

        log.info("Establish an Eap Session")
        guard let bleMessageTransportState = try establishSession(ltk: ltk, eapSeq: 1, msgSeq: Int(response.msgSeq)) else {
            log.debug("pairPod: failed to create messageTransportState!")
            throw PodCommsError.noPodPaired
        }
 
        log.info("LTK and encrypted transport now ready, messageTransportState: %@", String(reflecting: bleMessageTransportState))

        // If we get here, we have the LTK all set up and we should be able use encrypted pod messages
        let blePodMessageTransport = BlePodMessageTransport(manager: manager, myId: self.myId, podId: self.podId, state: bleMessageTransportState)
        blePodMessageTransport.messageLogger = messageLogger

        // For Dash this command is vestigal and doesn't actually assign the address (podId)
        // any more as this is done earlier when the LTK is setup. But this Omnipod comamnd is still
        // needed albiet using 0xffffffff for the address while the Eros sets the 0x1f0xxxxx ID.
        let assignAddress = AssignAddressCommand(address: 0xffffffff)
        let message = Message(address: 0xffffffff, messageBlocks: [assignAddress], sequenceNum: blePodMessageTransport.messageNumber)

        let versionResponse = try bleSendPairMessage(blePodMessageTransport: blePodMessageTransport, message: message)

        // Now create the real PodState using the current transport state and the versionResponse info
        log.debug("pairPod: creating PodState for versionResponse %{public}@ and transport %{public}@", String(describing: versionResponse), String(describing: blePodMessageTransport.state))

        self.podState = PodState(
            address: self.podId,
            firmwareVersion: String(describing: versionResponse.firmwareVersion),
            iFirmwareVersion: String(describing: versionResponse.iFirmwareVersion),
            lotNo: versionResponse.lot,
            lotSeq: versionResponse.tid,
            insulinType: insulinType,
            podType: versionResponse.podType,
            bleMessageTransportState: blePodMessageTransport.state,
            ltk: ltk,
            bleIdentifier: manager.peripheral.identifier.uuidString
        )

        // podState setupProgress state should be addressAssigned

        // Now that we have podState, check for an activation timeout condition that can be noted in setupProgress
        guard versionResponse.podProgressStatus != .activationTimeExceeded else {
            // The 2 hour window for the initial pairing has expired
            self.podState?.setupProgress = .activationTimeout
            throw PodCommsError.activationTimeExceeded
        }

        log.debug("pairPod: self.PodState bleMessageTransportState now: %@", String(reflecting: self.podState?.bleMessageTransportState))
    }

    private func establishSession(ltk: Data, eapSeq: Int, msgSeq: Int = 1) throws -> BleMessageTransportState? {
        // We should already be holding podStateLock during calls to this function, so try() should fail
        assert(!podStateLock.try(), "\(#function) should be invoked while holding podStateLock")

        guard let manager = manager else { throw PodCommsError.noPodPaired }
        let eapAkaExchanger = try SessionEstablisher(manager: manager, ltk: ltk, eapSqn: eapSeq, myId: self.myId, podId: self.podId, msgSeq: msgSeq)

        let result = try eapAkaExchanger.negotiateSessionKeys()

        switch result {
        case .SessionNegotiationResynchronization(let keys):
            log.debug("Received EAP SQN resynchronization: %@", keys.synchronizedEapSqn.data.hexadecimalString)
            if self.podState != nil {
                let eapSeq = keys.synchronizedEapSqn.toInt()
                log.debug("Updating EAP SQN to: %d", eapSeq)
                self.podState!.bleMessageTransportState.eapSeq = eapSeq
            }
            return nil
        case .SessionKeys(let keys):
            log.debug("Session Established")
            // log.debug("CK: %@", keys.ck.hexadecimalString)
            log.info("msgSequenceNumber: %@", String(keys.msgSequenceNumber))
            // log.info("NoncePrefix: %@", keys.nonce.prefix.hexadecimalString)

            let omnipodMessageNumber = self.podState?.bleMessageTransportState.messageNumber ?? 0
            let bleMessageTransportState = BleMessageTransportState(
                ck: keys.ck,
                noncePrefix: keys.nonce.prefix,
                eapSeq: eapSeq,
                msgSeq: keys.msgSequenceNumber,
                messageNumber: omnipodMessageNumber
            )

            if self.podState != nil {
                log.debug("Setting podState transport state to %{public}@", String(describing: bleMessageTransportState))
                self.podState!.bleMessageTransportState = bleMessageTransportState
            } else {
                log.debug("Used keys %@ to create bleMessageTransportState: %@", String(reflecting: keys), String(reflecting: bleMessageTransportState))
            }
            return bleMessageTransportState
        }
    }

    private func establishNewSession() throws {
        // We should already be holding podStateLock during calls to this function, so try() should fail
        assert(!podStateLock.try(), "\(#function) should be invoked while holding podStateLock")

        guard self.podState != nil, let ltk = self.podState!.ltk else {
            throw PodCommsError.noPodPaired
        }

        let mts = try establishSession(ltk: ltk, eapSeq: self.podState!.incrementEapSeq())
        if mts == nil {
            let mts = try establishSession(ltk: ltk, eapSeq: self.podState!.incrementEapSeq())
            if mts == nil {
                throw PodCommsError.diagnosticMessage(str: "Received resynchronization SQN for the second time")
            }
        }
    }

    private func setupPod(timeZone: TimeZone) throws {
        guard let manager = manager else { throw PodCommsError.podNotConnected }

        // We should already be holding podStateLock during calls to this function, so try() should fail
        assert(!podStateLock.try(), "\(#function) should be invoked while holding podStateLock")

        let blePodMessageTransport = BlePodMessageTransport(manager: manager, myId: self.myId, podId: self.podId, state: podState!.bleMessageTransportState)
        blePodMessageTransport.messageLogger = messageLogger

        let dateComponents = SetupPodCommand.dateComponents(date: Date(), timeZone: timeZone)
        let setupPod = SetupPodCommand(address: podState!.address, dateComponents: dateComponents, lot: UInt32(podState!.lotNo), tid: podState!.lotSeq)

        let message = Message(address: 0xffffffff, messageBlocks: [setupPod], sequenceNum: blePodMessageTransport.messageNumber)

        log.debug("setupPod: calling bleSendPairMessage %@ for message %@", String(reflecting: blePodMessageTransport), String(describing: message))
        let versionResponse = try bleSendPairMessage(blePodMessageTransport: blePodMessageTransport, message: message)

        // Verify that the fundemental pod constants returned match the expected constant values in the Pod struct.
        // To actually be able to handle different fundemental values in Loop things would need to be reworked to save
        // these values in some persistent PodState and then make sure that everything properly works using these values.
        var errorStrings: [String] = []
        if let pulseSize = versionResponse.pulseSize, pulseSize != Pod.pulseSize  {
            errorStrings.append(String(format: "Pod reported pulse size of %.3fU different than expected %.3fU", pulseSize, Pod.pulseSize))
        }
        if let secondsPerBolusPulse = versionResponse.secondsPerBolusPulse, secondsPerBolusPulse != Pod.secondsPerBolusPulse  {
            errorStrings.append(String(format: "Pod reported seconds per pulse rate of %.1f different than expected %.1f", secondsPerBolusPulse, Pod.secondsPerBolusPulse))
        }
        if let secondsPerPrimePulse = versionResponse.secondsPerPrimePulse, secondsPerPrimePulse != Pod.secondsPerPrimePulse  {
            errorStrings.append(String(format: "Pod reported seconds per prime pulse rate of %.1f different than expected %.1f", secondsPerPrimePulse, Pod.secondsPerPrimePulse))
        }
        if let primeUnits = versionResponse.primeUnits, primeUnits != Pod.primeUnits {
            errorStrings.append(String(format: "Pod reported prime bolus of %.2fU different than expected %.2fU", primeUnits, Pod.primeUnits))
        }
        if let cannulaInsertionUnits = versionResponse.cannulaInsertionUnits, Pod.cannulaInsertionUnits != cannulaInsertionUnits {
            errorStrings.append(String(format: "Pod reported cannula insertion bolus of %.2fU different than expected %.2fU", cannulaInsertionUnits, Pod.cannulaInsertionUnits))
        }
        if let serviceDuration = versionResponse.serviceDuration {
            if serviceDuration < Pod.serviceDuration {
                errorStrings.append(String(format: "Pod reported service duration of %.0f hours shorter than expected %.0f", serviceDuration.hours, Pod.serviceDuration.hours))
            } else if serviceDuration > Pod.serviceDuration {
                log.info("Pod reported service duration of %.0f hours limited to expected %.0f", serviceDuration.hours, Pod.serviceDuration.hours)
            }
        }

        let errMess = errorStrings.joined(separator: ".\n")
        if errMess.isEmpty == false {
            log.error("%@", errMess)
            self.podState?.setupProgress = .podIncompatible
            throw PodCommsError.podIncompatible(str: errMess)
        }

        if versionResponse.podProgressStatus == .pairingCompleted && self.podState?.setupProgress.isPaired == false {
            log.info("Version Response %{public}@ indicates pod pairing is now complete", String(describing: versionResponse))
            self.podState?.setupProgress = .podPaired
        }
    }

    func blePairAndSetupPod(
        timeZone: TimeZone,
        insulinType: InsulinType,
        messageLogger: MessageLogger?,
        _ block: @escaping (_ result: SessionRunResult) -> Void
    ) {
        guard let manager = manager else {
            // no available BLE pump to communicate with
            block(.failure(PodCommsError.noResponse))
            return
        }

        let myId = self.myId
        let podId = self.podId
        log.info("Attempting to pair using myId %X and podId %X", myId, podId)

        manager.runSession(withName: "Pair and setup pod") { [weak self] in
            do {
                guard let self = self else { fatalError() }

                // Synchronize access to podState
                self.podStateLock.lock()
                defer {
                    self.podStateLock.unlock()
                }

                try manager.sendHello(myId: myId)
                try manager.enableNotifications() // Seemingly this cannot be done before the hello command, or the pod disconnects

                if (!self.isPaired) {
                    try self.pairPod(insulinType: insulinType)
                } else {
                    try self.establishNewSession()
                }

                guard self.podState != nil else {
                    block(.failure(PodCommsError.noPodPaired))
                    return
                }

                if self.podState!.setupProgress.isPaired == false {
                    try self.setupPod(timeZone: timeZone)
                }

                guard self.podState!.setupProgress.isPaired else {
                    self.log.error("Unexpected podStatus setupProgress value of %{public}@", String(describing: self.podState!.setupProgress))
                    throw PodCommsError.invalidData
                }

                // Run a session now for any post-pairing commands
                let blePodMessageTransport = BlePodMessageTransport(manager: manager, myId: myId, podId: podId, state: self.podState!.bleMessageTransportState)
                blePodMessageTransport.messageLogger = self.messageLogger
                let podSession = PodCommsSession(podState: self.podState!, transport: blePodMessageTransport, delegate: self)

                block(.success(session: podSession))
            } catch let error as PodCommsError {
                block(.failure(error))
            } catch {
                block(.failure(PodCommsError.commsError(error: error)))
            }
        }
    }

    func bleRunSession(withName name: String, _ block: @escaping (_ result: SessionRunResult) -> Void) {

        guard let manager = manager, manager.peripheral.state == .connected else {
            block(.failure(PodCommsError.podNotConnected))
            return
        }

        manager.runSession(withName: name) { () in

            // Synchronize access to podState
            self.podStateLock.lock()
            defer {
                self.podStateLock.unlock()
            }

            guard self.podState != nil else {
                block(.failure(PodCommsError.noPodPaired))
                return
            }

            let blePodMessageTransport = BlePodMessageTransport(manager: manager, myId: self.myId, podId: self.podId, state: self.podState!.bleMessageTransportState)
            blePodMessageTransport.messageLogger = self.messageLogger
            let podSession = PodCommsSession(podState: self.podState!, transport: blePodMessageTransport, delegate: self)
            block(.success(session: podSession))
        }
    }


    // MARK: - CustomDebugStringConvertible

    override var debugDescription: String {
        return super.debugDescription +
            "* peripheral.name: \(optionalString(manager?.peripheral.name))\n"
    }
}


// MARK: - OmniConnectionDelegate

extension BlePodComms: OmniConnectionDelegate {
    func omnipodPeripheralWasRestored(manager: PeripheralManager) {
        if let podState = podState, manager.peripheral.identifier.uuidString == podState.bleIdentifier {
            self.manager = manager
            self.delegate?.omnipodPeripheralWasRestored(manager: manager)
        }
    }

    func omnipodPeripheralDidConnect(manager: PeripheralManager) {
        if let podState = podState, manager.peripheral.identifier.uuidString == podState.bleIdentifier {
            needsSessionEstablishment = true
            self.manager = manager
            self.delegate?.omnipodPeripheralDidConnect(manager: manager)
        }
    }

    func omnipodPeripheralDidDisconnect(peripheral: CBPeripheral, error: Error?) {
        if let podState = podState, peripheral.identifier.uuidString == podState.bleIdentifier {
            self.delegate?.omnipodPeripheralDidDisconnect(peripheral: peripheral, error: error)
            log.debug("omnipodPeripheralDidDisconnect... will auto-reconnect")
        }
    }

    func omnipodPeripheralDidFailToConnect(peripheral: CBPeripheral, error: Error?) {
        if let podState = podState, peripheral.identifier.uuidString == podState.bleIdentifier {
            self.delegate?.omnipodPeripheralDidFailToConnect(peripheral: peripheral, error: error)
            log.debug("omnipodPeripheralDidDisconnect... will auto-reconnect")
        }
    }

}

// MARK: - PeripheralManagerDelegate

extension BlePodComms: PeripheralManagerDelegate {

    func completeConfiguration(for manager: PeripheralManager) throws {
        log.default("PodComms completeConfiguration: isPaired=%{public}@ needsSessionEstablishment=%{public}@", String(describing: self.isPaired), String(describing: needsSessionEstablishment))

        if self.isPaired && needsSessionEstablishment {
            let myId = self.myId

            self.podStateLock.lock()
            defer {
                self.podStateLock.unlock()

            }

            do {
                try manager.sendHello(myId: myId)
                try manager.enableNotifications() // Seemingly this cannot be done before the hello command, or the pod disconnects
                try self.establishNewSession()
                self.delegate?.podCommsDidEstablishSession(self)
            } catch {
                self.log.error("Pod session sync error: %{public}@", String(describing: error))
            }

        } else {
            log.default("Session already established.")
        }
    }
}

extension BlePodComms: PodCommsSessionDelegate {
    // We hold podStateLock for the duration of the PodCommsSession
    func podCommsSession(_ podCommsSession: PodCommsSession, didChange state: PodState) {
        
        // We should already be holding podStateLock during calls to this function, so try() should fail
        assert(!podStateLock.try(), "\(#function) should be invoked while holding podStateLock")

        podCommsSession.assertOnSessionQueue()
        self.podState = state
    }
}
