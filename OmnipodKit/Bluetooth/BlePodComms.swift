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

fileprivate var skipO5AID9 = true // skips the 9th & slightly problematic O5 AID command that isn't even needed

class BlePodComms: PodComms {

    var manager: PeripheralManager? {
        didSet {
            manager?.delegate = self
        }
    }

    private var hasLTK: Bool {
        get {
            return (self.podState?.ltk?.count ?? 0) > 0
        }
    }

    private var needsSessionEstablishment: Bool = false

    private var bluetoothManager: BluetoothManager!

    override init(podState: PodState?, podType: PodType, myId: UInt32 = 0, podId: UInt32 = 0) {
        super.init(podState: podState, podType: podType, myId: myId, podId: podId)
        bluetoothManager = BluetoothManager(podType: podType)
        bluetoothManager.connectionDelegate = self
        if podState != nil && myId != 0 {
            bluetoothManager.setUuidPdmId(myId)
        } else {
            bluetoothManager.setUuidPdmId(nil)
        }
        if let podState = podState, let bleIdentifier = podState.bleIdentifier {
            bluetoothManager.connectToDevice(uuidString: bleIdentifier)
        }
    }

    override func forgetPod() {
        bluetoothManager.setUuidPdmId(nil)
        if let manager = manager {
            log.default("Removing %{public}@ from auto-connect ids", manager.peripheral)
            bluetoothManager.disconnectFromDevice(uuidString: manager.peripheral.identifier.uuidString)
        }
        super.forgetPod()
    }

    // Removes references to the bluetoothManager to avoid future
    // "Bluetooth use unsupported on this device" errors on the
    // next BlePodComms instantiation and subsequent usage.
    func forgetBluetoothManager() {
        bluetoothManager.connectionDelegate = nil
        bluetoothManager = nil
    }

    func connectToNewPod(_ completion: @escaping (Result<Omni, Error>) -> Void) {
        let discoveryStartTime = Date()

        bluetoothManager.discoverPods { error in
            if let error = error {
                completion(.failure(error))
                return
            }
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
                    let targetPod = devices.first!
                    let uuidString = targetPod.manager.peripheral.identifier.uuidString
                    self.log.default("Found pod UUID %{public}@!", uuidString)
                    self.bluetoothManager.connectToDevice(uuidString: uuidString)
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
        /* NOTREACHED */
    }

    // A specialized send message function for the two pairing pod commands,
    // AssignAddress and SetupPod, which return 2 VersionResponses variations.
    private func bleSendPairMessage(transport: BlePodMessageTransport, message: Message) throws -> VersionResponse {

        // We should already be holding podStateLock during calls to this function, so try() should fail
        assert(!podStateLock.try(), "\(#function) should be invoked while holding podStateLock")

        defer {
            if self.podState != nil {
                log.debug("bleSendPairMessage saving current message transport state %{public}@", transport.state.inlineDescription)
                self.podState!.bleMessageTransportState = BleMessageTransportState(ck: transport.ck, noncePrefix: transport.noncePrefix, msgSeq: transport.msgSeq, nonceSeq: transport.nonceSeq, messageNumber: transport.messageNumber)
            }
        }

        log.debug("bleSendPairMessage: attempting to use transport state %{public}@ to send message %{public}@",
            transport.state.inlineDescription, String(describing: message))
        let podMessageResponse = try transport.sendMessage(message)

        if let fault = podMessageResponse.fault {
            log.error("bleSendPairMessage pod fault: %{public}@", String(describing: fault))
            if let podState = self.podState, podState.fault == nil {
                self.podState!.fault = fault
            }
            throw PodCommsError.podFault(fault: fault)
        }

        // Got an error response which could be a result of sending a duplicate
        // SetupPod command on a pairing retry if the response wasn't seen.
        if let errorResponse = podMessageResponse.messageBlocks[0] as? ErrorResponse {
            switch errorResponse.errorResponseType {
            case .nonretryableError(let errorCode, let faultEventCode, let podProgress):
                log.error("@@@ Pairing command error: code %llu, %{public}@, pod progress %{public}@", errorCode, String(describing: faultEventCode), String(describing: podProgress))
                if podState != nil, podState!.setupProgress != .podPaired {
                    log.info("@@@ bleSendPairMessage: setting podPaired to avoid duplicate SetupPod command attempts")
                    podState!.setupProgress = .podPaired
                }
            default:
                break
            }
        }

        guard let versionResponse = podMessageResponse.messageBlocks[0] as? VersionResponse else {
            log.error("bleSendPairMessage unexpected response: %{public}@", String(describing: podMessageResponse))
            let responseType = podMessageResponse.messageBlocks[0].blockType
            throw PodCommsError.unexpectedResponse(response: responseType)
        }

        log.debug("bleSendPairMessage: returning versionResponse %@", String(describing: versionResponse))
        return versionResponse
    }

    // Handles negotiating the LTK (if needed), establishing the session and transport,
    // running the AssignVesion command, and then creating the PodState for the pod.
    private func pairPod(insulinType: InsulinType) throws {
        // We should already be holding podStateLock during calls to this function, so try() should fail
        assert(!podStateLock.try(), "\(#function) should be invoked while holding podStateLock")

        guard let manager = manager else { throw PodCommsError.podNotConnected }

        let ids: Ids
        let response: PairResult
        let ltk: Data
        let eapSeq: Int
        let signingKey: Data?

        ids = Ids(myId: self.myId, podId: self.podId)
        log.bleDebug("@@@ Calling LKExchanger for myId 0x%llx podId 0x%llx", ids.myIdAddr, ids.podIdAddr)
        switch podType {
        case dashType:
            let dashLTKExchanger = DashLTKExchanger(manager: manager, ids: ids)
            response = try dashLTKExchanger.negotiateLTK()
            ltk = response.ltk
            signingKey = nil
        case omnipod5Type:
            let o5LTKExchanger = try O5LTKExchanger(manager: manager, ids: ids)
            response = try o5LTKExchanger.o5negotiateLTK()
            ltk = response.ltk
            signingKey = try? O5CertificateStore(controllerId: myId).signingKey.rawRepresentation
        default:
            throw OmniPumpManagerError.podTypeNotConfigured
        }
        eapSeq = 1

        guard podId == response.address else {
            log.error("@@@ podId 0x%llx doesn't match response value!: %{public}@", podId, String(describing: response))
            throw PodCommsError.invalidAddress(address: response.address, expectedAddress: podId)
        }

        log.info("Establish an Eap Session")
        let msgSeq = Int(response.msgSeq)
        guard let bleMessageTransportState = try establishSession(ltk: ltk, eapSeq: eapSeq, msgSeq: msgSeq) else {
            log.error("@@@ pairPod: failed to establish session!")
            throw PodCommsError.noPodPaired
        }

        log.info("LTK and encrypted transport now ready, messageTransportState: %{public}@", bleMessageTransportState.inlineDescription)

        // If we get here, we have the LTK all set up and we should be able use encrypted pod messages
        let transport = BlePodMessageTransport(manager: manager, myId: myId, podId: podId, state: bleMessageTransportState, signingKey: signingKey)
        transport.messageLogger = messageLogger

        // This command doesn't actually assign the address (podId) any more for
        // BLE pod types as this is done earlier when the LTK was being negotiated.
        // For BLE pods this command is still required, albiet using 0xffffffff for the
        // address while for Eros pods this command actually sets the 0x1f0xxxxx pod ID.
        let assignAddress = AssignAddressCommand(address: 0xffffffff)
        let message = Message(address: 0xffffffff, messageBlocks: [assignAddress], sequenceNum: transport.messageNumber)

        let versionResponse = try bleSendPairMessage(transport: transport, message: message)

        // Now create the real PodState using the current transport state and the versionResponse info
        log.bleDebug("@@@ pairPod: creating PodState for versionResponse %{public}@ and transport state %{public}@", String(describing: versionResponse), transport.state.inlineDescription)

        self.podState = PodState(
            address: podId,
            firmwareVersion: String(describing: versionResponse.firmwareVersion),
            iFirmwareVersion: String(describing: versionResponse.iFirmwareVersion),
            lotNo: versionResponse.lot,
            lotSeq: versionResponse.tid,
            insulinType: insulinType,
            podType: versionResponse.podType,
            bleMessageTransportState: transport.state,
            ltk: ltk,
            bleIdentifier: manager.peripheral.identifier.uuidString,
            signingKey: signingKey,
        )

        // podState setupProgress state should be addressAssigned

        // After the SetupPod command has been run and the pod is finished pairing,
        // O5 pods changes its service advertisement to use the pdm id in its uuid.
        bluetoothManager.setUuidPdmId(myId)

        // Now that we have podState, check for an activation timeout condition that can be noted in setupProgress
        guard versionResponse.podProgressStatus != .activationTimeExceeded else {
            // The 2 hour window for the initial pairing has expired
            self.podState?.setupProgress = .activationTimeout
            throw PodCommsError.activationTimeExceeded
        }

        log.bleDebug("@@@ pairPod: podState transport state is %{public}@", self.podState!.bleMessageTransportState.inlineDescription)
    }

    private func establishSession(ltk: Data, eapSeq: Int, msgSeq: Int = 1) throws -> BleMessageTransportState? {
        // We should already be holding podStateLock during calls to this function, so try() should fail
        assert(!podStateLock.try(), "\(#function) should be invoked while holding podStateLock")

        guard let manager = manager else { throw PodCommsError.noPodPaired }

        // PRIMARY mode (controller initiates challenge).
        // SECONDARY mode was tested for O5 post-pairing reconnections (tests #24, #25)
        // but the pod never initiates an EAP-AKA challenge — it expects PRIMARY always.
        let sessionMode: SessionKeyMode = .PRIMARY
        let eapAkaExchanger = try SessionEstablisher(manager: manager, ltk: ltk, eapSqn: eapSeq, myId: myId, podId: podId, msgSeq: msgSeq, podType: podType, mode: sessionMode)

        let result = try eapAkaExchanger.negotiateSessionKeys()

        switch result {
        case .SessionNegotiationResynchronization(let keys):
            log.bleDebug("@@@ Received EAP SQN resynchronization: %@", keys.synchronizedEapSqn.data.hexadecimalString)
            if podState != nil {
                let eapSeq = keys.synchronizedEapSqn.toInt()
                log.bleDebug("@@@ Updating EAP SQN to: %lld", eapSeq)
                podState!.bleMessageTransportState.eapSeq = eapSeq
            }
            return nil
        case .SessionKeys(let keys):
            log.bleDebug("@@@ Session Established, msgSequenceNumber: %{public}@", String(keys.msgSequenceNumber))
            //log.bleDebug("@@@ CK: %{public}@", keys.ck.hexadecimalString)
            //log.bleDebug("@@@ NoncePrefix: %{public}@", keys.nonce.prefix.hexadecimalString)

            // The O5 app seems to set the Omnipod message # to 0 at the start of a new EAP-AKA
            // session while OmniBLE tries to use the next sequential Omnipod message number.
            // OmnipodKit handles both like OmniBLE and trys to keep seqential message numbering.
            let omnipodMessageNumber = podState?.bleMessageTransportState.messageNumber ?? 0
            let transportState = BleMessageTransportState(
                ck: keys.ck,
                noncePrefix: keys.nonce.prefix,
                eapSeq: eapSeq,
                msgSeq: keys.msgSequenceNumber,
                messageNumber: omnipodMessageNumber
            )

            if podState != nil {
                log.bleDebug("@@@ Setting podState transport state to %{public}@", transportState.inlineDescription)
                podState!.bleMessageTransportState = transportState
            } else {
                log.bleDebug("@@@ Used keys %{public}@ to create transport state %{public}@", String(describing: keys), transportState.inlineDescription)
            }
            return transportState
        }
    }

    private func establishNewSession() throws {
        // We should already be holding podStateLock during calls to this function, so try() should fail
        assert(!podStateLock.try(), "\(#function) should be invoked while holding podStateLock")

        guard let ltk = podState?.ltk else {
            throw PodCommsError.noPodPaired
        }

        let mts = try establishSession(ltk: ltk, eapSeq: podState!.incrementEapSeq())
        if mts == nil {
            let mts = try establishSession(ltk: ltk, eapSeq: podState!.incrementEapSeq())
            if mts == nil {
                throw PodCommsError.diagnosticMessage(str: "Received resynchronization SQN for the second time")
            }
        }
    }

    /// Handles executing the required O5 AID setup commands and updates the podState's transport state as needed.
    /// To be call for an O5 only after pairPod() sucessfully creates a podState and before setupPod() is called.
    private func handleO5Setup() throws {
        // The AssignAddress command successfully run in pairPod() creates podState
        assert(podState != nil, "handleO5Setup() called with no podState")

        // Only to be run for an O5 pod and before the SetupPod command has been run
        guard podType.isO5 && podState!.setupProgress.isPaired == false else {
            return
        }

        guard let manager = manager else { throw PodCommsError.podNotConnected }

        let transport = BlePodMessageTransport(manager: manager, myId: myId, podId: podId, state: podState!.bleMessageTransportState, signingKey: podState?.signingKey)
        transport.messageLogger = messageLogger

        defer {
            log.bleDebug("@@@ handleO5Setup(): saving current message transport state %{public}@", transport.state.inlineDescription)
            podState!.bleMessageTransportState = BleMessageTransportState(ck: transport.ck, noncePrefix: transport.noncePrefix, msgSeq: transport.msgSeq, nonceSeq: transport.nonceSeq, messageNumber: transport.messageNumber)
        }

        // Perform the needed O5 AID setup commands
        log.info("@@@ Sending O5 AID setup commands")
        try o5SendAidSetupCommands(transport: transport)
        log.info("@@@ O5 AID setup complete")

        // The podState's bleMessageTransportState will be updated when the above defer block is executed.
    }

    // MARK: - O5 Specific AID Setup commands

    /// Sends the O5-specific AID setup commands between GetStatus and SetupPod.
    ///
    /// These 9 command exchanges use an ASCII key-value protocol (SET+GET, GET-only, Extended SET)
    /// wrapped in SLPE, sent through the encrypted Type 1 transport.
    ///
    /// Command sequence:
    ///   1. UtcCommand — SE255.2=[unix_timestamp]
    ///   2. TdiCommand — S3.2=0003000E00,G3.2
    ///   3. TargetBgProfileCommand — S3.1=00c0[48 x 4-byte targets],G3.1
    ///   4. DiaCommand — S3.9=8,G3.9
    ///   5. EgvCommand — S3.7=3670015,G3.7
    ///   6-8. AlgorithmInsulinHistoryCommand x3 — SE2.1=00a8[168 bytes zeros]
    ///   9. [not needed] AidPodStatusCommand — G3.11 (majorVersion less than 7), else UnifiedAidPodStatusCommand — G3.12
    private func o5SendAidSetupCommands(transport: BlePodMessageTransport) throws {

        // Command 1: UTC time
        log.bleDebug("@@@ O5 AID [1/9]: UtcCommand — setting pod UTC time")
        do {
            let (payload, prefix) = O5AidCommands.UtcCommand.payload()
            let response = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
            let responseStr = String(data: response, encoding: .utf8) ?? response.hexadecimalString
            log.bleDebug("@@@ O5 AID [1/9]: UtcCommand response: %{public}@", responseStr)
        } catch {
            log.error("@@@ O5 AID [1/9]: UtcCommand failed: %{public}@", String(describing: error))
            throw error
        }

        // Command 2: TDI (Therapy Delivery Information)
        log.bleDebug("@@@ O5 AID [2/9]: TdiCommand — setting therapy delivery info")
        do {
            let (payload, prefix) = O5AidCommands.TdiCommand.payload()
            let response = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
            let responseStr = String(data: response, encoding: .utf8) ?? response.hexadecimalString
            log.bleDebug("@@@ O5 AID [2/9]: TdiCommand response: %{public}@", responseStr)
        } catch {
            log.error("@@@ O5 AID [2/9]: TdiCommand failed: %{public}@", String(describing: error))
            throw error
        }

        // Command 3: Target BG Profile (48 half-hour targets, all 110 mg/dL)
        log.bleDebug("@@@ O5 AID [3/9]: TargetBgProfileCommand — setting 48 half-hour BG targets (all 110 mg/dL)")
        do {
            let (payload, prefix) = O5AidCommands.TargetBgProfileCommand.payload()
            let response = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
            log.bleDebug("@@@ O5 AID [3/9]: TargetBgProfileCommand response: %{public}lld bytes", response.count)
        } catch {
            log.error("@@@ O5 AID [3/9]: TargetBgProfileCommand failed: %{public}@", String(describing: error))
            throw error
        }

        // Command 4: DIA (Duration of Insulin Action)
        log.bleDebug("@@@ O5 AID [4/9]: DiaCommand — setting DIA=8")
        do {
            let (payload, prefix) = O5AidCommands.DiaCommand.payload()
            let response = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
            let responseStr = String(data: response, encoding: .utf8) ?? response.hexadecimalString
            log.bleDebug("@@@ O5 AID [4/9]: DiaCommand response: %{public}@", responseStr)
        } catch {
            log.error("@@@ O5 AID [4/9]: DiaCommand failed: %{public}@", String(describing: error))
            throw error
        }

        // Command 5: EGV (Estimated Glucose Value config)
        log.bleDebug("@@@ O5 AID [5/9]: EgvCommand — setting EGV config=3670015")
        do {
            let (payload, prefix) = O5AidCommands.EgvCommand.payload()
            let response = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
            let responseStr = String(data: response, encoding: .utf8) ?? response.hexadecimalString
            log.bleDebug("@@@ O5 AID [5/9]: EgvCommand response: %{public}@", responseStr)
        } catch {
            log.error("@@@ O5 AID [5/9]: EgvCommand failed: %{public}@", String(describing: error))
            throw error
        }

        // Commands 6-8: Algorithm Insulin History (3 batches of 24 zero records)
        for batch in 1...3 {
            log.bleDebug("@@@ O5 AID [%{public}lld/9]: AlgorithmInsulinHistoryCommand batch %{public}lld/3", batch + 5, batch)
            do {
                let (payload, prefix) = O5AidCommands.AlgorithmInsulinHistoryCommand.payload()
                let response = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
                let responseStr = String(data: response, encoding: .utf8) ?? response.hexadecimalString
                log.bleDebug("@@@ O5 AID [%{public}lld/9]: AlgorithmInsulinHistory batch %{public}lld/3 response: %{public}@",
                             batch + 5, batch, responseStr)
            } catch {
                log.error("@@@ O5 AID [%{public}lld/9]: AlgorithmInsulinHistory batch %{public}lld/3 failed: %{public}@",
                              batch + 5, batch, String(describing: error))
                throw error
            }
        }

        // Command 9: AID Pod Status query (generation-specific).
        // Hasn't been required to be run in every versions tested,
        // so OK to just skip this command if majorVersion not available.
        let majorVersion = parseMajorVersion(from: podState!.firmwareVersion)
        if skipO5AID9 || majorVersion == nil {
            log.bleDebug("@@@ O5 AID [9/9]: skipping Pod Status query...")
        } else {
            do {
                let useGen1AidPodStatus = o5PodIsV1(majorVersion: majorVersion!)
                if useGen1AidPodStatus {
                    let (payload, prefix) = O5AidCommands.AidPodStatusCommand.payload()
                    let response = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
                    log.bleDebug("@@@ O5 AID [9/9]: AidPodStatusCommand (G3.11) response: %lld bytes — %{public}@",
                             response.count, response.hexadecimalString)
                } else {
                    let (payload, prefix) = O5AidCommands.UnifiedAidPodStatusCommand.payload()
                    let response = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
                    log.bleDebug("@@@ O5 AID [9/9]: UnifiedAidPodStatusCommand (G3.12) response: %lld bytes — %{public}@",
                             response.count, response.hexadecimalString)
                }
            } catch {
                log.error("@@@ O5 AID [9/9]: AID Pod Status command failed: %{public}@", String(describing: error))
                throw error
            }
        }
    }

    private func parseMajorVersion(from firmwareVersion: String) -> Int? {
        return firmwareVersion
            .split(separator: ".", omittingEmptySubsequences: true)
            .first
            .flatMap { Int($0) }
    }

    private func o5PodIsV1(majorVersion: Int) -> Bool {
        return majorVersion < 7
    }

    // Send the SetupPod command to finalize the pairing and
    // verify values returned to that ensure pod is compatible.
    private func setupPod(timeZone: TimeZone) throws {
        guard let manager = manager else { throw PodCommsError.podNotConnected }

        // We should already be holding podStateLock during calls to this function, so try() should fail
        assert(!podStateLock.try(), "\(#function) should be invoked while holding podStateLock")
        assert(podState != nil, "setupPod called with no podState!")

        let transport = BlePodMessageTransport(manager: manager, myId: myId, podId: podId, state: podState!.bleMessageTransportState, signingKey: podState!.signingKey)
        transport.messageLogger = messageLogger

        log.bleDebug("setupPod() starting transport state %{public}@", transport.state.inlineDescription)

        let dateComponents = SetupPodCommand.dateComponents(date: Date(), timeZone: timeZone)
        let setupPod = SetupPodCommand(address: podState!.address, dateComponents: dateComponents, lot: UInt32(podState!.lotNo), tid: podState!.lotSeq)

        let message = Message(address: 0xffffffff, messageBlocks: [setupPod], sequenceNum: transport.messageNumber)

        log.debug("setupPod: calling bleSendPairMessage using transport state %{public}@ for message %{public}@",
            transport.state.inlineDescription, String(describing: message))
        let versionResponse = try bleSendPairMessage(transport: transport, message: message)

        // Check for activation timeout condition
        guard versionResponse.podProgressStatus != .activationTimeExceeded else {
            // The 2 hour window for the initial pairing has expired
            self.podState!.setupProgress = .activationTimeout
            throw PodCommsError.activationTimeExceeded
        }

        // Verify that the fundemental pod constants returned match the expected constant values in the Pod struct.
        // To actually be able to handle different fundemental values in Loop things would need to be reworked to save
        // these values in some persistent PodState and then make sure that everything properly works using these values.
        var errorStrings: [String] = []
        if versionResponse.podType.rawValue != self.podType.rawValue {
            errorStrings.append(String(format: "Pod reported product ID %lld doesn't match expected %lld", versionResponse.podType.rawValue, self.podType.rawValue))
        }
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
            log.error("%{public}@", errMess)
            podState!.setupProgress = .podIncompatible
            throw PodCommsError.podIncompatible(str: errMess)
        }

        // Update setupProgress to podPaired if needed to mark that setupPod() shouldn't be called again.
        if versionResponse.podProgressStatus == .pairingCompleted && podState!.setupProgress.isPaired == false {
            log.info("Version Response %{public}@ indicates pod pairing is now complete", String(describing: versionResponse))
            podState!.setupProgress = .podPaired
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

        log.info("@@@ Attempting to pair and setup pod using myId 0x%llX and podId 0x%llX", myId, podId)

        manager.runSession(withName: "Pair and setup pod") { [weak self] in
            do {
                guard let self = self else { fatalError() }

                // Synchronize access to podState
                podStateLock.lock()
                defer {
                    podStateLock.unlock()
                }

                if !hasLTK {
                    // Fresh pod: full pairing sequence (HELLO + LTK + EAP-AKA)
                    try manager.sendHello(myId: myId)
                    try manager.enableNotifications() // Seemingly this cannot be done before the hello command, or the pod disconnects
                    try pairPod(insulinType: insulinType)
                } else if !needsSessionEstablishment,
                          let ck = podState?.bleMessageTransportState.ck,
                          !ck.isEmpty {
                    // Already paired with active session (completeConfiguration already ran).
                    // Skip HELLO + EAP-AKA to avoid double-session disconnect.
                    log.info("@@@ Session already established by completeConfiguration, skipping HELLO + EAP-AKA")
                } else {
                    // Paired but no active session: re-establish
                    try manager.sendHello(myId: myId)
                    try manager.enableNotifications()
                    try establishNewSession()
                }

                guard podState != nil else {
                    block(.failure(PodCommsError.noPodPaired))
                    return
                }

                // The O5 specific AID setup commands must be done
                // after the AssignAddress command is run in pairPod()
                // and before the SetupPod command is run in setupPod().
                if podType.isO5 && podState!.setupProgress.isPaired == false {
                    try handleO5Setup()
                }

                if podState!.setupProgress.isPaired == false {
                    // Haven't successfully run setupPod(), do it now
                    try setupPod(timeZone: timeZone)
                }

                guard podState!.setupProgress.isPaired else {
                    log.error("@@@ Unexpected podStatus setupProgress value of %{public}@", String(describing: podState!.setupProgress))
                    throw PodCommsError.invalidData
                }

                // Now create the pod comms session to be returned for the post-pairing commands
                let transport = BlePodMessageTransport(manager: manager, myId: myId, podId: podId, state: podState!.bleMessageTransportState, signingKey: podState!.signingKey)
                transport.messageLogger = messageLogger

                let podSession = PodCommsSession(podState: podState!, transport: transport, delegate: self)

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

            let transport = BlePodMessageTransport(manager: manager, myId: self.myId, podId: self.podId, state: self.podState!.bleMessageTransportState, signingKey: self.podState!.signingKey)
            transport.messageLogger = self.messageLogger

            let podSession = PodCommsSession(podState: self.podState!, transport: transport, delegate: self)
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
            log.bleDebug("omnipodPeripheralWasRestored for %@", manager.peripheral.identifier.uuidString)
            self.manager = manager
            delegate?.omnipodPeripheralWasRestored(manager: manager)
        }
    }

    func omnipodPeripheralDidConnect(manager: PeripheralManager) {
        if let podState = podState, manager.peripheral.identifier.uuidString == podState.bleIdentifier {
            log.bleDebug("omnipodPeripheralDidConnect for %@", manager.peripheral.identifier.uuidString)
            needsSessionEstablishment = true
            self.manager = manager
            delegate?.omnipodPeripheralDidConnect(manager: manager)
        }
    }

    func omnipodPeripheralDidDisconnect(peripheral: CBPeripheral, error: Error?) {
        if let podState = podState, peripheral.identifier.uuidString == podState.bleIdentifier {
            log.bleDebug("omnipodPeripheralDidDisconnect for %@", peripheral.identifier.uuidString)
            delegate?.omnipodPeripheralDidDisconnect(peripheral: peripheral, error: error)
        }
    }

    func omnipodPeripheralDidFailToConnect(peripheral: CBPeripheral, error: Error?) {
        if let podState = podState, peripheral.identifier.uuidString == podState.bleIdentifier {
            log.bleDebug("omnipodPeripheralDidFailToConnect for %@", peripheral.identifier.uuidString)
            delegate?.omnipodPeripheralDidFailToConnect(peripheral: peripheral, error: error)
        }
    }

}

// MARK: - PeripheralManagerDelegate

extension BlePodComms: PeripheralManagerDelegate {

    func completeConfiguration(for manager: PeripheralManager) throws {
        if hasLTK && needsSessionEstablishment {
            /// Try to ensure that the maximumWriteValueLength (MTU - 3 byte header) is large enough before
            /// sending O5 protocol messages as iOS auto-negotiates the MTU asynchronously after connect.
            /// We need the maximumWriteValueLength >= packet max payload size per write (244 for O5).
            /// For O5 using .withoutResponse, writes exceeding this value will be silently truncated.
            if manager.podType.isO5 {
                let requiredMaxPayload = manager.profile.packetLayout.maxPayloadSize
                var attempts = 0
                var maxWriteValue = manager.peripheral.maximumWriteValueLength(for: .withoutResponse)
                while maxWriteValue < requiredMaxPayload && attempts < 10 {
                    log.bleDebug("maximumWriteValueLength not yet settled (%{public}lld < %{public}lld), waiting... (attempt %{public}lld/10)", maxWriteValue, requiredMaxPayload, attempts + 1)
                    Thread.sleep(forTimeInterval: 0.2)
                    maxWriteValue = manager.peripheral.maximumWriteValueLength(for: .withoutResponse)
                    attempts += 1
                }
                log.bleDebug("maximumWriteValueLength settled after %{public}lld polls: maximumWriteValueLength=%{public}lld (required=%{public}lld)", attempts, maxWriteValue, requiredMaxPayload)
                if maxWriteValue < requiredMaxPayload {
                    log.error("WARNING: maximumWriteValueLength (%{public}lld) below required minimum (%{public}lld). Large writes may be truncated!", maxWriteValue, requiredMaxPayload)
                }
            }

            podStateLock.lock()
            defer {
                podStateLock.unlock()
            }

            do {
                try manager.sendHello(myId: myId)
                try manager.enableNotifications() // Seemingly this cannot be done before the hello command, or the pod disconnects
                try establishNewSession()
                needsSessionEstablishment = false
                delegate?.podCommsDidEstablishSession(self)
            } catch {
                log.error("Pod session sync error: %{public}@", String(describing: error))
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
        podState = state
    }
}
