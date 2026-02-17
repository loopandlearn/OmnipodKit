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

    // MARK: - O5 Debug: Skip LTK exchange and use a cached pairing result
    // Set to a saved pairing result to skip LTK exchange and pod discovery,
    // connecting directly to the pod by BLE UUID and re-establishing the EAP-AKA
    // session with the stored LTK. Set to nil for normal pairing.
    static let savedO5PairingResult: O5SavedPairingResult? = nil

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
        // O5 Debug: skip scanning and connect directly to known pod UUID
        if let saved = BlePodComms.savedO5PairingResult {
            let knownUUID = saved.bleUUID
            log.info("O5 DEBUG: Skipping pod discovery, connecting directly to %{public}@ (%{public}@)", saved.name, knownUUID)

            setServicePodType(podType: self.podType)
            guard let device = bluetoothManager.retrieveAndConnectKnownPod(uuidString: knownUUID) else {
                log.error("O5 DEBUG: Failed to retrieve peripheral for UUID %{public}@", knownUUID)
                completion(.failure(PodCommsError.noPodsFound))
                return
            }

            self.manager = device.manager
            device.manager.delegate = self

            let connectStartTime = Date()
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                let elapsed = Date().timeIntervalSince(connectStartTime)
                if device.manager.peripheral.state == .connected {
                    self.log.default("O5 DEBUG: Connected to known pod in %.1f sec", elapsed)
                    completion(.success(device))
                    timer.invalidate()
                } else if elapsed > TimeInterval(seconds: 15) {
                    self.log.error("O5 DEBUG: Timeout connecting to known pod")
                    completion(.failure(PodCommsError.noPodsFound))
                    timer.invalidate()
                }
            }
            return
        }

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
            if let saved = BlePodComms.savedO5PairingResult {
                // Skip LTK exchange — use saved pairing result
                log.info("O5 DEBUG: Using saved LTK from %{public}@", saved.name)
                ltk = Data(hexadecimalString: saved.ltk)!
                response = PairResult(ltk: ltk, address: saved.podAddress, msgSeq: saved.msgSeq)
            } else {
                ids = Ids(myId: self.myId, podId: self.podId)
                let o5LTKExchanger = try O5LTKExchanger(manager: manager, ids: ids)
                response = try o5LTKExchanger.o5negotiateLTK()
                ltk = response.ltk
            }
        default:
            throw OmniPumpManagerError.podTypeNotConfigured
        }

        guard podId == response.address else {
            log.debug("podId 0x%x doesn't match response value!: %{public}@", podId, String(describing: response))
            throw PodCommsError.invalidAddress(address: response.address, expectedAddress: self.podId)
        }

        log.info("Establish an Eap Session")
        let eapSeq = BlePodComms.savedO5PairingResult?.eapSeq ?? 1
        guard let bleMessageTransportState = try establishSession(ltk: ltk, eapSeq: eapSeq, msgSeq: Int(response.msgSeq)) else {
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
        // PRIMARY mode (controller initiates challenge).
        let sessionMode: SessionKeyMode = .PRIMARY
        let eapAkaExchanger = try SessionEstablisher(manager: manager, ltk: ltk, eapSqn: eapSeq, myId: self.myId, podId: self.podId, msgSeq: msgSeq, podType: self.podType, mode: sessionMode)

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

            // O5 pods restart the inner Omnipod Message sequence from 0 after each new
            // EAP-AKA session. Frida confirms: getPodVersion(seq=0) → setPodUid(seq=2).
            // DASH pods may need to preserve the counter across sessions.
            let omnipodMessageNumber = (self.podType == omnipod5Type) ? 0 : (self.podState?.bleMessageTransportState.messageNumber ?? 0)
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

    // MARK: - O5 Pre-SetupPod Steps

    /// Performs the O5-specific intermediate steps between AssignAddress (getPodVersion) and SetupPod.
    ///
    /// From Frida capture of real O5 app activation (Pod2, pdmid 2587928):
    ///   Real O5 activation sequence (after pairing + EAP-AKA):
    ///     [0] getPodVersion (AssignAddress with 0xffffffff) -> VersionResponse (FILLED)
    ///     [1] UtcCommand: SE255.2=[timestamp]         (set pod UTC time)
    ///     [2] TdiCommand: S3.2=0003000E00,G3.2        (therapy delivery info)
    ///     [3] TargetBgProfile: S3.1=00c0[...],G3.1    (48 half-hour BG targets)
    ///     [4] DiaCommand: S3.9=8,G3.9                 (duration of insulin action)
    ///     [5] EgvCommand: S3.7=3670015,G3.7           (CGM/EGV config)
    ///     [6-8] AlgorithmInsulinHistory x3: SE2.1=    (insulin history, 24 records each)
    ///     [9] UnifiedAidPodStatus: G3.12               (AID status query)
    ///     [10] SetupPod -> VersionResponse (UID_SET)
    ///
    /// NOTE: The real O5 app does NOT send GetStatus between getPodVersion and the AID commands,
    /// nor between the AID commands and SetupPod. The pod rejects GetStatus at progress state 2
    /// with ERR_ILLEGAL_CMD_STATE (error code 19).
    private func o5PreSetupSteps(blePodMessageTransport: BlePodMessageTransport) throws {
        // We should already be holding podStateLock during calls to this function
        assert(!podStateLock.try(), "\(#function) should be invoked while holding podStateLock")

        log.info("O5: Beginning pre-SetupPod intermediate steps")

        // Helper to save transport state after each successful step
        let saveState = {
            if self.podState != nil {
                self.podState!.bleMessageTransportState = blePodMessageTransport.state
                self.log.debug("O5: Saved transport state: msgSeq=%{public}d, nonceSeq=%{public}d, messageNumber=%{public}d",
                         blePodMessageTransport.msgSeq, blePodMessageTransport.nonceSeq, blePodMessageTransport.messageNumber)
            }
        }

        // O5 AID setup commands (UTC, TDI, TargetBG, DIA, EGV, InsulinHistory x3, AidStatus)
        log.info("O5: Sending AID setup commands")
        try o5SendAidSetupCommands(transport: blePodMessageTransport)
        saveState()

        log.info("O5: Pre-SetupPod steps complete, proceeding to SetupPod")
    }

    /// Sends the O5-specific AID setup commands between GetStatus and SetupPod.
    ///
    /// These 9 command exchanges use an ASCII key-value protocol (SET+GET, GET-only, Extended SET)
    /// wrapped in SLPE, sent through the encrypted Type 1 transport. The sequence matches the
    /// real O5 app behavior observed via Frida (Pod2, pdmid 2587928).
    ///
    /// Command sequence:
    ///   1. UtcCommand — SE255.2=[unix_timestamp]
    ///   2. TdiCommand — S3.2=0003000E00,G3.2
    ///   3. TargetBgProfileCommand — S3.1=00c0[48 x 4-byte targets],G3.1
    ///   4. DiaCommand — S3.9=8,G3.9
    ///   5. EgvCommand — S3.7=3670015,G3.7
    ///   6-8. AlgorithmInsulinHistoryCommand x3 — SE2.1=00a8[168 bytes zeros]
    ///   9. UnifiedAidPodStatusCommand — G3.12
    private func o5SendAidSetupCommands(transport: BlePodMessageTransport) throws {

        // Command 1: UTC time
        log.info("O5 AID [1/9]: UtcCommand — setting pod UTC time")
        do {
            let (payload, prefix) = O5AidCommands.UtcCommand.payload()
            let response = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
            let responseStr = String(data: response, encoding: .utf8) ?? response.hexadecimalString
            log.info("O5 AID [1/9]: UtcCommand response: %{public}@", responseStr)
        } catch {
            log.error("O5 AID [1/9]: UtcCommand failed: %{public}@", String(describing: error))
            throw error
        }

        // Command 2: TDI (Therapy Delivery Information)
        log.info("O5 AID [2/9]: TdiCommand — setting therapy delivery info")
        do {
            let (payload, prefix) = O5AidCommands.TdiCommand.payload()
            let response = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
            let responseStr = String(data: response, encoding: .utf8) ?? response.hexadecimalString
            log.info("O5 AID [2/9]: TdiCommand response: %{public}@", responseStr)
        } catch {
            log.error("O5 AID [2/9]: TdiCommand failed: %{public}@", String(describing: error))
            throw error
        }

        // Command 3: Target BG Profile (48 half-hour targets, all 110 mg/dL)
        log.info("O5 AID [3/9]: TargetBgProfileCommand — setting 48 half-hour BG targets (all 110 mg/dL)")
        do {
            let (payload, prefix) = O5AidCommands.TargetBgProfileCommand.payload()
            let response = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
            log.info("O5 AID [3/9]: TargetBgProfileCommand response: %{public}d bytes", response.count)
        } catch {
            log.error("O5 AID [3/9]: TargetBgProfileCommand failed: %{public}@", String(describing: error))
            throw error
        }

        // Command 4: DIA (Duration of Insulin Action)
        log.info("O5 AID [4/9]: DiaCommand — setting DIA=8")
        do {
            let (payload, prefix) = O5AidCommands.DiaCommand.payload()
            let response = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
            let responseStr = String(data: response, encoding: .utf8) ?? response.hexadecimalString
            log.info("O5 AID [4/9]: DiaCommand response: %{public}@", responseStr)
        } catch {
            log.error("O5 AID [4/9]: DiaCommand failed: %{public}@", String(describing: error))
            throw error
        }

        // Command 5: EGV (Estimated Glucose Value config)
        log.info("O5 AID [5/9]: EgvCommand — setting EGV config=3670015")
        do {
            let (payload, prefix) = O5AidCommands.EgvCommand.payload()
            let response = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
            let responseStr = String(data: response, encoding: .utf8) ?? response.hexadecimalString
            log.info("O5 AID [5/9]: EgvCommand response: %{public}@", responseStr)
        } catch {
            log.error("O5 AID [5/9]: EgvCommand failed: %{public}@", String(describing: error))
            throw error
        }

        // Commands 6-8: Algorithm Insulin History (3 batches of 24 zero records)
        for batch in 1...3 {
            log.info("O5 AID [%{public}d/9]: AlgorithmInsulinHistoryCommand batch %{public}d/3", batch + 5, batch)
            do {
                let (payload, prefix) = O5AidCommands.AlgorithmInsulinHistoryCommand.payload()
                let response = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
                let responseStr = String(data: response, encoding: .utf8) ?? response.hexadecimalString
                log.info("O5 AID [%{public}d/9]: AlgorithmInsulinHistory batch %{public}d/3 response: %{public}@",
                         batch + 5, batch, responseStr)
            } catch {
                log.error("O5 AID [%{public}d/9]: AlgorithmInsulinHistory batch %{public}d/3 failed: %{public}@",
                          batch + 5, batch, String(describing: error))
                throw error
            }
        }

        // Command 9: Unified AID Pod Status query
        log.info("O5 AID [9/9]: UnifiedAidPodStatusCommand — querying AID status")
        do {
            let (payload, prefix) = O5AidCommands.UnifiedAidPodStatusCommand.payload()
            let response = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
            log.info("O5 AID [9/9]: UnifiedAidPodStatus response: %{public}d bytes — %{public}@",
                     response.count, response.hexadecimalString)
        } catch {
            log.error("O5 AID [9/9]: UnifiedAidPodStatusCommand failed: %{public}@", String(describing: error))
            throw error
        }

        log.info("O5 AID: All 9 AID setup command exchanges complete")
    }

    /// Sends a GetStatus command via the encrypted transport and returns the StatusResponse.
    /// Falls back to returning a minimal synthetic StatusResponse if the pod returns a
    /// VersionResponse instead (observed in btsnoop for the pre-SetupPod GetStatus).

    private func setupPod(timeZone: TimeZone) throws {
        guard let manager = manager else { throw PodCommsError.podNotConnected }

        // We should already be holding podStateLock during calls to this function, so try() should fail
        assert(!podStateLock.try(), "\(#function) should be invoked while holding podStateLock")

        let blePodMessageTransport = BlePodMessageTransport(manager: manager, myId: self.myId, podId: self.podId, state: podState!.bleMessageTransportState)
        blePodMessageTransport.messageLogger = messageLogger

        var dateComponents = SetupPodCommand.dateComponents(date: Date(), timeZone: timeZone)

        // O5 pods expect 12-hour format (0-11) matching Java Calendar.HOUR (field 10).
        // Fresh pod test confirmed: hour=20 (24h) causes error 33, hour must be % 12.
        if self.podType == omnipod5Type {
            dateComponents.hour = (dateComponents.hour ?? 0) % 12
        }

        let setupPod = SetupPodCommand(address: podState!.address, dateComponents: dateComponents, lot: UInt32(podState!.lotNo), tid: podState!.lotSeq)

        let message = Message(address: 0xffffffff, messageBlocks: [setupPod], sequenceNum: blePodMessageTransport.messageNumber)

        log.debug("setupPod: calling bleSendPairMessage %@ for message %@", String(reflecting: blePodMessageTransport), String(describing: message))
        let versionResponse = try bleSendPairMessage(blePodMessageTransport: blePodMessageTransport, message: message)

        // Check for activation timeout condition
        guard versionResponse.podProgressStatus != .activationTimeExceeded else {
            // The 2 hour window for the initial pairing has expired
            self.podState?.setupProgress = .activationTimeout
            throw PodCommsError.activationTimeExceeded
        }

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

                var pairPodRanGetPodVersion = false
                if (!self.isPaired) {
                    // Fresh pod: full pairing sequence (HELLO + LTK + EAP-AKA)
                    try manager.sendHello(myId: myId)
                    try manager.enableNotifications() // Seemingly this cannot be done before the hello command, or the pod disconnects
                    try self.pairPod(insulinType: insulinType)
                    pairPodRanGetPodVersion = true  // pairPod() sends getPodVersion internally
                } else if !self.needsSessionEstablishment,
                          let ck = self.podState?.bleMessageTransportState.ck,
                          !ck.isEmpty {
                    // Already paired with active session (completeConfiguration already ran).
                    // Skip HELLO + EAP-AKA to avoid double-session disconnect.
                    self.log.info("Session already established by completeConfiguration, skipping HELLO + EAP-AKA")
                } else {
                    // Paired but no active session: re-establish
                    try manager.sendHello(myId: myId)
                    try manager.enableNotifications()
                    try self.establishNewSession()
                }

                guard self.podState != nil else {
                    block(.failure(PodCommsError.noPodPaired))
                    return
                }

                // O5 pods require getPodVersion (AssignAddress) as the first encrypted command
                // after each new EAP-AKA session, followed by AID setup commands, then SetupPod.
                if self.podState!.setupProgress.isPaired == false && self.podType == omnipod5Type {
                    let preSetupTransport = BlePodMessageTransport(
                        manager: manager, myId: myId, podId: podId,
                        state: self.podState!.bleMessageTransportState
                    )
                    preSetupTransport.messageLogger = self.messageLogger

                    // getPodVersion (AssignAddress with 0xffffffff) must be the first encrypted
                    // command after each EAP-AKA session. pairPod() sends it during initial pairing;
                    // on resume (pairPod skipped) we must send it here. Sending it TWICE
                    // desynchronizes nonce state — pod ACKs transport but can't decrypt AID commands.
                    if !pairPodRanGetPodVersion {
                        self.log.info("O5: Sending getPodVersion (AssignAddress) before AID commands")
                        let assignAddress = AssignAddressCommand(address: 0xffffffff)
                        let message = Message(address: 0xffffffff, messageBlocks: [assignAddress], sequenceNum: preSetupTransport.messageNumber)
                        let versionResponse = try self.bleSendPairMessage(blePodMessageTransport: preSetupTransport, message: message)
                        self.log.info("O5: getPodVersion response: FW %{public}@, progress %{public}@",
                                     String(describing: versionResponse.firmwareVersion),
                                     String(describing: versionResponse.podProgressStatus))
                    } else {
                        self.log.info("O5: Skipping getPodVersion (already sent by pairPod)")
                    }

                    self.log.info("O5: Running pre-SetupPod intermediate steps (AID commands)")
                    try self.o5PreSetupSteps(blePodMessageTransport: preSetupTransport)

                    // Save transport state back to podState after the intermediate steps
                    self.podState!.bleMessageTransportState = preSetupTransport.state
                    self.log.info("O5: Pre-SetupPod steps complete, transport state saved")
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

                // For O5 pods, create the certificate store for Type 4 signed message sending
                let certStore: O5CertificateStore? = self.podType == omnipod5Type ? (try? O5CertificateStore()) : nil
                let podSession = PodCommsSession(podState: self.podState!, transport: blePodMessageTransport, delegate: self, o5CertStore: certStore)

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

            // For O5 pods, create the certificate store for Type 4 signed message sending
            let certStore: O5CertificateStore? = self.podType == omnipod5Type ? (try? O5CertificateStore()) : nil
            let podSession = PodCommsSession(podState: self.podState!, transport: blePodMessageTransport, delegate: self, o5CertStore: certStore)
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
                self.needsSessionEstablishment = false
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
