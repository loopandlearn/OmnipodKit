//
//  PodCommsSession.swift
//  OmnipodKit
//
//  Based on Omni{BLE,Kit}/PumpManager/PodCommsSession.swift
//  Created by Joe Moran on 12/29/2024
//  Copyright © 2024 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import os.log

enum PodCommsError: Error {
    case noPodPaired
    case invalidData
    case noResponse
    case noResponseRL // Eros only
    case emptyResponse
    case podAckedInsteadOfReturningResponse
    case unexpectedPacketType(packetType: PacketType) // Eros only
    case unexpectedResponse(response: MessageBlockType)
    case unknownResponseType(rawType: UInt8)
    case invalidAddress(address: UInt32, expectedAddress: UInt32)
    case noRileyLinkAvailable // Eros only
    case podNotConnected
    case unfinalizedBolus
    case unfinalizedTempBasal
    case nonceResyncFailed
    case podSuspended
    case podFault(fault: DetailedStatus)
    case commsError(error: Error)
    case unacknowledgedMessage(sequenceNumber: Int, error: Error)
    case unacknowledgedCommandPending
    case rejectedMessage(errorCode: UInt8)
    case podChange
    case activationTimeExceeded
    case rssiTooLow // Eros only
    case rssiTooHigh // Eros only
    case diagnosticMessage(str: String)
    case podIncompatible(str: String)
    case noPodsFound
    case tooManyPodsFound // BLE pods only
    case setupNotComplete
    case noCertificateFound // O5 only
}

extension PodCommsError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noPodPaired:
            return LocalizedString("No pod paired", comment: "Error message shown when no pod is paired")
        case .invalidData:
            return nil
        case .noResponse, .noResponseRL:
            return LocalizedString("No response from pod", comment: "Error message shown when no response from pod was received")
        case .emptyResponse:
            return LocalizedString("Empty response from pod", comment: "Error message shown when empty response from pod was received")
        case .podAckedInsteadOfReturningResponse:
            return LocalizedString("Pod sent ack instead of response", comment: "Error message shown when pod sends ack instead of response")
        case .unexpectedPacketType:
            return nil
        case .unexpectedResponse:
            return LocalizedString("Unexpected response from pod", comment: "Error message shown when empty response from pod was received")
        case .unknownResponseType:
            return nil
        case .invalidAddress(address: let address, expectedAddress: let expectedAddress):
            return String(format: LocalizedString("Invalid address 0x%llx. Expected 0x%llx", comment: "Error message for when unexpected address is received (1: received address) (2: expected address)"), address, expectedAddress)
        case .noRileyLinkAvailable:
            return LocalizedString("No RileyLink available", comment: "Error message shown when no response from pod was received")
        case .podNotConnected:
            return LocalizedString("Pod not connected", comment: "Error message shown when the pod is not connected.")
        case .unfinalizedBolus:
            return LocalizedString("Bolus in progress", comment: "Error message shown when operation could not be completed due to existing bolus in progress")
        case .unfinalizedTempBasal:
            return LocalizedString("Temp basal in progress", comment: "Error message shown when temp basal could not be set due to existing temp basal in progress")
        case .nonceResyncFailed:
            return nil
        case .podSuspended:
            return LocalizedString("Pod is suspended", comment: "Error message action could not be performed because pod is suspended")
        case .podFault(let fault):
            let faultDescription = String(describing: fault.faultEventCode)
            return String(format: LocalizedString("Pod Fault: %1$@", comment: "Format string for pod fault code"), faultDescription)
        case .commsError(let error):
            if isVerboseBluetoothCommsError(error) {
                return LocalizedString("Possible Bluetooth issue", comment: "Error description for possible bluetooth issue")
            }
            return error.localizedDescription
        case .unacknowledgedMessage(_, let error):
            return error.localizedDescription
        case .unacknowledgedCommandPending:
            return LocalizedString("Communication issue: Unacknowledged command pending.", comment: "Error message when command is rejected because an unacknowledged command is pending.")
        case .rejectedMessage(let errorCode):
            let codeDescription = ErrorResponseCode.descriptionFor(code: errorCode)
            return String(format: LocalizedString("Command error %1$llu: %2$@", comment: "Format string for invalid message error code (1: error code number) (2: error description)"), errorCode, codeDescription)
        case .podChange:
            return LocalizedString("Unexpected pod change", comment: "Format string for unexpected pod change")
        case .activationTimeExceeded:
            return LocalizedString("Activation time exceeded", comment: "Format string for activation time exceeded")
        case .rssiTooLow: // occurs when pod is too far for reliable pairing, but can sometimes occur at other distances & positions
            return LocalizedString("Poor signal strength", comment: "Format string for poor pod signal strength")
        case .rssiTooHigh: // only occurs when pod is too close for reliable pairing
            return LocalizedString("Signal strength too high", comment: "Format string for pod signal strength too high")
        case .diagnosticMessage(let str):
            return str
        case .podIncompatible(let str):
            return str
        case .noPodsFound:
            return LocalizedString("No pods found", comment: "Error message for PodCommsError.noPodsFound")
        case .tooManyPodsFound:
            return LocalizedString("Too many pods found", comment: "Error message for PodCommsError.tooManyPodsFound")
        case .setupNotComplete:
            return LocalizedString("Pod setup is not complete", comment: "Error description when pod setup is not complete")
        case .noCertificateFound:
            return LocalizedString("No certificate found", comment: "Error message when no certificate found")
        }
    }

//    var failureReason: String? {
//        return nil
//    }

    var recoverySuggestion: String? {
        switch self {
        case .noPodPaired:
            return nil
        case .invalidData:
            return nil
        case .noResponse:
            return LocalizedString("Make sure iPhone is nearby the active pod", comment: "Recovery suggestion when no response is received from pod")
        case .noResponseRL:
            return LocalizedString("Please try repositioning the pod or the RileyLink and try again", comment: "Recovery suggestion when no response is received from pod")
        case .emptyResponse:
            return nil
        case .podAckedInsteadOfReturningResponse:
            return LocalizedString("Try again", comment: "Recovery suggestion when ack received instead of response")
        case .unexpectedPacketType:
            return nil
        case .unexpectedResponse:
            return nil
        case .unknownResponseType:
            return nil
        case .invalidAddress:
            return LocalizedString("Crosstalk possible. Please move to a new location", comment: "Recovery suggestion when unexpected address received")
        case .noRileyLinkAvailable: // Eros only
            return LocalizedString("Make sure your RileyLink is nearby and powered on", comment: "Recovery suggestion when no RileyLink is available")
        case .podNotConnected:
            return LocalizedString("Make sure your pod is nearby and try again", comment: "Recovery suggestion when no pod is available")
        case .unfinalizedBolus:
            return LocalizedString("Wait for existing bolus to finish, or cancel bolus", comment: "Recovery suggestion when operation could not be completed due to existing bolus in progress")
        case .unfinalizedTempBasal:
            return LocalizedString("Wait for existing temp basal to finish, or suspend to cancel", comment: "Recovery suggestion when operation could not be completed due to existing temp basal in progress")
        case .nonceResyncFailed:
            return nil
        case .podSuspended:
            return LocalizedString("Resume delivery", comment: "Recovery suggestion when pod is suspended")
        case .podFault:
            return nil
        case .commsError(let error):
            if isVerboseBluetoothCommsError(error) {
                return LocalizedString("Try adjusting pod position or toggle Bluetooth off and then on in iPhone Settings", comment: "Recovery suggestion for possible bluetooth issue")
            }
            return nil
        case .unacknowledgedMessage:
            return nil
        case .unacknowledgedCommandPending:
            return nil
        case .rejectedMessage:
            return nil
        case .podChange:
            return LocalizedString("Please bring only original pod in range or deactivate original pod", comment: "Recovery suggestion on unexpected pod change")
        case .activationTimeExceeded:
            return nil
        case .rssiTooLow: // Eros only
            return LocalizedString("Please reposition the RileyLink relative to the pod", comment: "Recovery suggestion when pairing signal strength is too low")
        case .rssiTooHigh: // Eros only
            return LocalizedString("Please reposition the RileyLink further from the pod", comment: "Recovery suggestion when pairing signal strength is too high")
        case .diagnosticMessage:
            return nil
        case .podIncompatible:
            return nil
        case .noPodsFound:
            return LocalizedString("Make sure your pod is filled and nearby", comment: "Recovery suggestion for PodCommsError.noPodsFound")
        case .tooManyPodsFound:
            return LocalizedString("Move to a new area away from any other pods and try again", comment: "Recovery suggestion for PodCommsError.tooManyPodsFound")
        case .setupNotComplete:
            return nil
        case .noCertificateFound:
            return LocalizedString("Rebuild app with needed certificate data", comment: "Recovery suggestion with missing certificate")
        }
    }

    var isFaulted: Bool {
        switch self {
        case .podFault, .activationTimeExceeded, .podIncompatible:
            return true
        default:
            return false
        }
    }

    // BLE pods only
    func isVerboseBluetoothCommsError(_ error: Error) -> Bool {
        if let peripheralManagerError = error as? PeripheralManagerError {
            switch peripheralManagerError {
            case .cbPeripheralError:
                print("### Verbose Bluetooth comms error: \(peripheralManagerError.localizedDescription)")
                return true
            default:
                break
            }
        }
        if let podProtocolError = error as? PodProtocolError {
            switch podProtocolError {
            case .invalidLTKKey, .pairingException, .messageIOException, .couldNotParseMessageException:
                print("### Verbose Bluetooth comms error: \(podProtocolError.localizedDescription)")
                return true
            default:
                break
            }
        }
        return false
    }
}

protocol PodCommsSessionDelegate: AnyObject {
    func podCommsSession(_ podCommsSession: PodCommsSession, didChange state: PodState)
}

class PodCommsSession: MessageTransportDelegate {

    let log = OSLog(category: "PodCommsSession")

    private var podState: PodState {
        didSet {
            assertOnSessionQueue()
            delegate.podCommsSession(self, didChange: podState)
        }
    }

    private unowned let delegate: PodCommsSessionDelegate
    private var transport: MessageTransport

    // used for testing
    var mockCurrentDate: Date?
    var currentDate: Date {
        return mockCurrentDate ?? Date()
    }

    init(podState: PodState, transport: MessageTransport, delegate: PodCommsSessionDelegate) {
        self.podState = podState
        self.transport = transport
        self.delegate = delegate
        self.transport.delegate = self
    }

    /// Sets the podState's deliveryStoppedAt if not already set or it is
    /// later than the computed actual stopped time using the podTime.
    private func setDeliverytoppedAt(podTime: TimeInterval?) {
        let computedStoppedAt: Date
        if let podTime = podTime, let expiresAt = podState.expiresAt {
            /// Use expiresAt which slides with pod clock skew to compute an adjusted activatedAt
            /// which can be then be used to compute the actual stopped at time based on pod time.
            let adjustedActivatedAt = expiresAt - Pod.nominalPodLife
            computedStoppedAt = adjustedActivatedAt + podTime
        } else {
            computedStoppedAt = currentDate
        }
        /// Set the podState's deliveryStoppedAt if it isn't set yet or if our computed value is earlier than the current value
        if podState.deliveryStoppedAt == nil || computedStoppedAt < podState.deliveryStoppedAt! {
            podState.deliveryStoppedAt = computedStoppedAt
        }
    }

    // Handles updating PodState on first pod fault seen
    private func handlePodFault(fault: DetailedStatus) {
        if podState.fault == nil {
            podState.fault = fault // save the first fault returned
            setDeliverytoppedAt(podTime: fault.faultEventTimeSinceActivation)
            let derivedStatusResponse = StatusResponse(detailedStatus: fault)
            if podState.unacknowledgedCommand != nil {
                // Process the pending unacknowledgeCommnd to handle any pending doses matters for an unacknowledged
                // command before calling handleCancelDosing() to deal with the final dosing adjustments from pod fault.
                // N.B., recoverUnacknowledgedCommand() skips using bolusNotDelivered for a stopProgram with a faulted pod.
                recoverUnacknowledgedCommand(using: derivedStatusResponse)
            }
            podState.handleCancelDosing(deliveryType: .all, bolusNotDelivered: derivedStatusResponse.bolusNotDelivered, at: currentDate)
            podState.updateFromStatusResponse(derivedStatusResponse, at: currentDate)
        }
        log.error("Pod Fault: %@", String(describing: fault))
    }

    // Will throw either PodCommsError.podFault or PodCommsError.activationTimeExceeded
    private func throwPodFault(fault: DetailedStatus) throws {
        handlePodFault(fault: fault)
        if fault.podProgressStatus == .activationTimeExceeded {
            // avoids a confusing "No fault" error when activation time is exceeded
            throw PodCommsError.activationTimeExceeded
        }
        throw PodCommsError.podFault(fault: fault)
    }

    /// Performs a message exchange, handling nonce resync, pod faults
    ///
    /// - Parameters:
    ///   - messageBlocks: The message blocks to send
    ///   - beepBlock: Optional confirmation beep block message to append to the message blocks to send
    ///   - expectFollowOnMessage: If true, the pod will expect another message within 4 minutes, or will alarm with an 0x33 (51) fault.
    /// - Returns: The received message response
    /// - Throws:
    ///     - PodCommsError.podFault
    ///     - PodCommsError.unexpectedResponse
    ///     - PodCommsError.rejectedMessage
    ///     - PodCommsError.nonceResyncFailed
    ///     - PodCommsError.unacknowledgedMessage
    ///     - MessageError
    ///             OmniBLE only
    ///     - PodCommsError.noResponse
    ///     - PodCommsError.commsError.MessageError
    ///     - PodCommsError.commsError.PeripheralManagerError
    ///     - PodCommsError.commsError.PodProtocolError
    ///             Eros only
    ///     - PodCommsError.noResponseRL
    ///     - RileyLinkDeviceError
    func send<T: MessageBlock>(_ messageBlocks: [MessageBlock], beepBlock: MessageBlock? = nil, expectFollowOnMessage: Bool = false) throws -> T {

        var triesRemaining = 2  // Retries only happen for nonce resync
        var blocksToSend = messageBlocks

        // If a beep block was specified & the pod isn't faulted AND there isn't an unacknowledged
        // command for a getStatus command, append the beep block to emit the confirmation beep.
        // Since a beep command changes lastProgrammingMessageSeqNum, we need skip appending a beep
        // block while still trying to resolve an unacknowldged delivery command with getStatus calls.
        if let beepBlock = beepBlock, podState.isFaulted == false &&
            !(podState.unacknowledgedCommand != nil && blocksToSend[0].blockType == .getStatus)
        {
            blocksToSend += [beepBlock]
        }

        if blocksToSend.contains(where: { $0 as? NonceResyncableMessageBlock != nil }) {
            podState.advanceToNextNonce()
        }

        var sentNonce: UInt32?
        var messageNumber = transport.messageNumber
        if let getStatusCommand = messageBlocks[0] as? GetStatusCommand,
           getStatusCommand.podInfoType == .noSeqStatus
        {
            // For the special type 7 non-Eros noSeqStatus getStatus command,
            // back up the Omnipod msg # here to its previous value so that
            // this message will have same msg # the last received response.
            messageNumber = messageNumber == 0 ? 0b1111 : messageNumber - 1
        }

        while (triesRemaining > 0) {
            triesRemaining -= 1

            for command in blocksToSend {
                if let nonceBlock = command as? NonceResyncableMessageBlock {
                    sentNonce = nonceBlock.nonce
                    break // N.B. all nonce commands in single message should have the same value
                }
            }

            let message = Message(address: podState.address, messageBlocks: blocksToSend, sequenceNum: messageNumber, expectFollowOnMessage: expectFollowOnMessage)

            // Clear the lastDeliveryStatusReceived variable which is used to guard against possible 0x31 pod faults
            let savedLastDeliveryStatusReceived = podState.lastDeliveryStatusReceived
            podState.lastDeliveryStatusReceived = nil

            let response: Message
            do {
                response = try transport.sendMessage(message)
            } catch {
                // Some transport errors are due to checks performed before attempting any IO.
                // For these cases, restore lastDeliveryStatusReceived to its previous value
                // to avoid having to do an extra getStatus to recover in tryToValidateComms().
                if let podCommsError = error as? PodCommsError,
                    case .podNotConnected = podCommsError, case .noCertificateFound = podCommsError
                {
                    log.debug("@@@ Restoring lastDeliveryStatusReceived for pre-check error")
                    podState.lastDeliveryStatusReceived = savedLastDeliveryStatusReceived
                }
                throw error
            }

            // Simulate fault
            //let podInfoResponse = try PodInfoResponse(encodedData: Data(hexadecimalString: "0216020d0000000000ab6a038403ff03860000285708030d0000")!)
            //let response = Message(address: podState.address, messageBlocks: [podInfoResponse], sequenceNum: message.sequenceNum)

            if let responseMessageBlock = response.messageBlocks[0] as? T {
                log.info("POD Response: %{public}@", String(describing: responseMessageBlock))
                return responseMessageBlock
            }

            if let fault = response.fault {
                if podState.unacknowledgedCommand != nil && blocksToSend[0].blockType != .getStatus {
                    // Clear the unacknowledgedCommand for this attempted non-getStatus command since
                    // it was for this send and thus it was actually acknowledged -- with a pod fault.
                    podState.unacknowledgedCommand = nil
                }
                try throwPodFault(fault: fault) // always throws
            }

            let responseType = response.messageBlocks[0].blockType
            guard let errorResponse = response.messageBlocks[0] as? ErrorResponse else {
                log.error("Unexpected response: %{public}@", String(describing: response.messageBlocks[0]))
                throw PodCommsError.unexpectedResponse(response: responseType)
            }

            switch errorResponse.errorResponseType {
            case .badNonce(let nonceResyncKey):
                guard let sentNonce = sentNonce else {
                    log.error("Unexpected bad nonce response: %{public}@", String(describing: response.messageBlocks[0]))
                    throw PodCommsError.unexpectedResponse(response: responseType)
                }
                podState.resyncNonce(syncWord: nonceResyncKey, sentNonce: sentNonce, messageSequenceNum: Int(message.sequenceNum))
                log.info("resyncNonce(syncWord: 0x%02llx, sentNonce: 0x%04llx, messageSequenceNum: %lld) -> 0x%04llx", nonceResyncKey, sentNonce, message.sequenceNum, podState.currentNonce)
                blocksToSend = blocksToSend.map({ (block) -> MessageBlock in
                    if var resyncableBlock = block as? NonceResyncableMessageBlock {
                        log.info("Replaced old nonce 0x%04llx with resync nonce 0x%04llx", resyncableBlock.nonce, podState.currentNonce)
                        resyncableBlock.nonce = podState.currentNonce
                        return resyncableBlock
                    }
                    return block
                })
                podState.advanceToNextNonce()
                break
            case .nonretryableError(let errorCode, let faultEventCode, let podProgress):
                log.error("Command error: code %llu, %{public}@, pod progress %{public}@", errorCode, String(describing: faultEventCode), String(describing: podProgress))
                throw PodCommsError.rejectedMessage(errorCode: errorCode)
            }
        }
        throw PodCommsError.nonceResyncFailed
    }

    // Returns time at which prime is expected to finish.
    func prime() throws -> TimeInterval {
        let primeDuration: TimeInterval = .seconds(Pod.primeUnits / Pod.primeDeliveryRate) + 3 // as per PDM

        // If priming has never been attempted on this pod, handle the pre-prime setup tasks.
        // A FaultConfig can only be done before the prime bolus or the pod will generate an 049 fault.
        if podState.setupProgress.primingNeverAttempted {
            if !podState.podType.isO5 {
                // This FaultConfig command will set Tab5[$16] to 0 during pairing, which disables $6x faults.
                // This command can't be used (like this at least) on an O5 as it will return error 11.
                let _: StatusResponse = try send([FaultConfigCommand(nonce: podState.currentNonce, tab5Sub16: 0, tab5Sub17: 0)])
            }

            // Set up the finish pod setup reminder alert which beeps every 5 minutes for 1 hour
            let finishSetupReminder = PodAlert.finishSetupReminder
            try configureAlerts([finishSetupReminder])
        } else {
            // Not the first time through, check to see if prime bolus was successfully started
            let status = try getStatus()
            if status.podProgressStatus == .priming || status.podProgressStatus == .primingCompleted {
                podState.setupProgress = .priming
                return podState.primeFinishTime?.timeIntervalSinceNow ?? primeDuration
            }
        }

        // Mark Pod.primeUnits (2.6U) bolus delivery with Pod.primeDeliveryRate (1) between pulses for prime

        let primeFinishTime = currentDate + primeDuration
        podState.primeFinishTime = primeFinishTime
        podState.setupProgress = .startingPrime

        let timeBetweenPulses = TimeInterval(seconds: Pod.secondsPerPrimePulse)
        let scheduleCommand = SetInsulinScheduleCommand(nonce: podState.currentNonce, units: Pod.primeUnits, timeBetweenPulses: timeBetweenPulses)
        let bolusInfo: BolusInfo?
        if podState.podType.isO5 {
            // O5 uses an BolusExtraCommand format with bolusInfo
            bolusInfo = BolusInfo()
        } else {
            // Eros or DASH doesn't use bolusInfo
            bolusInfo = nil
        }

        let bolusExtraCommand = BolusExtraCommand(units: Pod.primeUnits, timeBetweenPulses: timeBetweenPulses, bolusInfo: bolusInfo)
        let status: StatusResponse = try send([scheduleCommand, bolusExtraCommand])
        podState.updateFromStatusResponse(status, at: currentDate)
        podState.setupProgress = .priming
        return primeFinishTime.timeIntervalSinceNow
    }

    func programInitialBasalSchedule(_ basalSchedule: BasalSchedule, scheduleOffset: TimeInterval) throws {
        if podState.setupProgress == .settingInitialBasalSchedule {
            // We started basal schedule programming, but didn't get confirmation somehow, so check status
            let status = try getStatus()
            if status.podProgressStatus == .basalInitialized {
                podState.setupProgress = .initialBasalScheduleSet
                return
            }
        }

        podState.setupProgress = .settingInitialBasalSchedule
        // Set basal schedule
        let _ = try setBasalSchedule(schedule: basalSchedule, scheduleOffset: scheduleOffset)
        podState.setupProgress = .initialBasalScheduleSet
    }

    //
    // Attempts to resolve any pending unacknowledged command by calling getStatus().
    // podState.unacknowledgeCommand is guaranteed to be nil upon successful return.
    // Throws PodCommsError.unacknowledgedCommandPending if unsuccessful for any reason.
    //
    private func tryToResolvePendingCommand() throws {

        guard podState.unacknowledgedCommand != nil else {
            return // no pending unacknowledged command to resolve
        }

        do {
            _ = try getStatus() // should resolve the pending unacknowledged command if successful
        } catch let error {
            log.error("GetStatus failed trying to resolve pending unacknowledged command: %{public}@", String(describing: error))
            throw PodCommsError.unacknowledgedCommandPending
        }

        // Verify that getStatus successfully resolved the pending unacknowledged command.
        guard podState.unacknowledgedCommand == nil else {
            log.error("Successful getStatus didn't resolve the pending unacknowledged command!")
            throw PodCommsError.unacknowledgedCommandPending
        }

        log.info("Successfully resolved pending unacknowledged command")
    }

    // Configures the given pod alert(s) and registers the newly configured alert slot(s).
    // When re-configuring all the pod alerts for a silence pod toggle, the optional acknowledgeAll can be
    // specified to first acknowledge and clear all possible pending pod alerts and pod alert configurations.
    @discardableResult
    func configureAlerts(_ alerts: [PodAlert], acknowledgeAll: Bool = false, beepBlock: MessageBlock? = nil) throws -> StatusResponse {

        if podState.unacknowledgedCommand != nil {
            try tryToResolvePendingCommand()
        }

        let configurations = alerts.map { $0.configuration }
        let configureAlerts = ConfigureAlertsCommand(nonce: podState.currentNonce, configurations: configurations)
        let blocksToSend: [MessageBlock]
        if acknowledgeAll {
            // Do the acknowledgeAllAlerts command first to clear all previous pod alert configurations.
            let acknowledgeAllAlerts = AcknowledgeAlertCommand(nonce: podState.currentNonce, alerts: AlertSet(rawValue: ~0))
            blocksToSend = [acknowledgeAllAlerts, configureAlerts]
        } else {
            blocksToSend = [configureAlerts]
        }
        let status: StatusResponse = try send(blocksToSend, beepBlock: beepBlock)
        for alert in alerts {
            podState.registerConfiguredAlert(slot: alert.configuration.slot, alert: alert)
        }
        podState.updateFromStatusResponse(status, at: currentDate)
        return status
    }

    // emits the specified beep type and sets the completion beep flags, doesn't throw
    func beepConfig(beepType: BeepType, tempBasalCompletionBeep: Bool, bolusCompletionBeep: Bool) -> Result<StatusResponse, Error> {
        if let fault = self.podState.fault {
            log.info("Skip beep config with faulted pod")
            return .failure(PodCommsError.podFault(fault: fault))
        }

        if podState.unacknowledgedCommand != nil {
            do {
                try tryToResolvePendingCommand()
            } catch let error {
                return .failure(error)
            }
        }

        let beepConfigCommand = BeepConfigCommand(beepType: beepType, tempBasalCompletionBeep: tempBasalCompletionBeep, bolusCompletionBeep: bolusCompletionBeep)
        do {
            let statusResponse: StatusResponse = try send([beepConfigCommand])
            podState.updateFromStatusResponse(statusResponse, at: currentDate)
            return .success(statusResponse)
        } catch let error {
            return .failure(error)
        }
    }

    private func markSetupProgressCompleted(statusResponse: StatusResponse) {
        if (podState.setupProgress != .completed) {
            podState.setupProgress = .completed
            podState.setupUnitsDelivered = statusResponse.insulinDelivered // stash the current insulin delivered value as the baseline
            log.info("Total setup units delivered: %@", String(describing: statusResponse.insulinDelivered))
        }
    }

    func insertCannula(basalSchedule: BasalSchedule? = nil, scheduleOffset: TimeInterval = 0, optionalAlerts: [PodAlert] = [], silent: Bool) throws -> TimeInterval {

        let cannulaInsertionUnits = Pod.cannulaInsertionUnits + Pod.cannulaInsertionUnitsExtra

        guard podState.activatedAt != nil else {
            throw PodCommsError.noPodPaired
        }

        if podState.setupProgress == .startingInsertCannula || podState.setupProgress == .cannulaInserting {
            // We started cannula insertion, but didn't get confirmation somehow, so check status
            let status = try getStatus()
            if status.podProgressStatus == .insertingCannula {
                podState.setupProgress = .cannulaInserting
                // return a non-zero wait time based on the bolus not yet delivered
                return (status.bolusNotDelivered / Pod.primeDeliveryRate) + 1
            }
            if status.podProgressStatus.readyForDelivery {
                markSetupProgressCompleted(statusResponse: status)
                return TimeInterval(0) // Already done; no need to wait
            }
        } else {
            let elapsed: TimeInterval = -(podState.podTimeUpdated?.timeIntervalSinceNow ?? 0)
            let podTime = podState.podTime + elapsed

            // Configure the mandatory Pod Alerts for shutdown imminent alert (79 hours) and pod expiration alert (72 hours) along with any optional alerts
            let shutdownImminentAlarm = PodAlert.shutdownImminent(offset: podTime, absAlertTime: Pod.serviceDuration - Pod.endOfServiceImminentWindow, silent: silent)
            let expirationAdvisoryAlarm = PodAlert.expired(offset: podTime, absAlertTime: Pod.nominalPodLife, duration: Pod.expirationAdvisoryWindow, silent: silent)
            try configureAlerts([expirationAdvisoryAlarm, shutdownImminentAlarm] + optionalAlerts)
        }

        // Mark cannulaInsertionUnits (0.5U) bolus delivery with Pod.secondsPerPrimePulse (1) between pulses for cannula insertion

        let timeBetweenPulses = TimeInterval(seconds: Pod.secondsPerPrimePulse)
        let bolusScheduleCommand = SetInsulinScheduleCommand(nonce: podState.currentNonce, units: cannulaInsertionUnits, timeBetweenPulses: timeBetweenPulses)
        let bolusInfo: BolusInfo?
        if podState.podType.isO5 {
            // O5 uses an extended format including bolusInfo
            bolusInfo = BolusInfo()
        } else {
            // Eros or DASH doesn't use bolusInfo
            bolusInfo = nil
        }

        podState.setupProgress = .startingInsertCannula
        let bolusExtraCommand = BolusExtraCommand(units: cannulaInsertionUnits, timeBetweenPulses: timeBetweenPulses, bolusInfo: bolusInfo)
        let status2: StatusResponse = try send([bolusScheduleCommand, bolusExtraCommand])
        podState.updateFromStatusResponse(status2, at: currentDate)

        podState.setupProgress = .cannulaInserting
        return status2.bolusNotDelivered / Pod.primeDeliveryRate // seconds for the cannula insert bolus to finish
    }

    func checkInsertionCompleted() throws {
        if podState.setupProgress == .cannulaInserting {
            let response = try getStatus()
            if response.podProgressStatus.readyForDelivery {
                markSetupProgressCompleted(statusResponse: response)
            }
        }
    }

    // Throws SetBolusError
    enum DeliveryCommandResult {
        case success(statusResponse: StatusResponse)
        case certainFailure(error: PodCommsError)
        case unacknowledged(error: PodCommsError)
    }

    enum CancelDeliveryResult {
        case success(statusResponse: StatusResponse, canceledDose: UnfinalizedDose?)
        case certainFailure(error: PodCommsError)
        case unacknowledged(error: PodCommsError)
    }

    func bolus(units: Double, automatic: Bool = false, acknowledgementBeep: Bool = false, completionBeep: Bool = false, programReminderInterval: TimeInterval = 0, extendedUnits: Double = 0.0, extendedDuration: TimeInterval = 0) -> DeliveryCommandResult {

        if podState.unacknowledgedCommand != nil {
            do {
                try tryToResolvePendingCommand()
            } catch {
                return DeliveryCommandResult.certainFailure(error: .unacknowledgedCommandPending)
            }
        }

        let timeBetweenPulses = TimeInterval(seconds: Pod.secondsPerBolusPulse)
        let bolusScheduleCommand = SetInsulinScheduleCommand(nonce: podState.currentNonce, units: units, timeBetweenPulses: timeBetweenPulses, extendedUnits: extendedUnits, extendedDuration: extendedDuration)

        // Do a get status here to verify that there isn't an on-going bolus in progress if the last bolus command
        // is still not finalized OR we don't have the last pod delivery status confirming that no bolus is active.
        if podState.unfinalizedBolus != nil || podState.lastDeliveryStatusReceived == nil || podState.lastDeliveryStatusReceived!.bolusing {
            if let statusResponse: StatusResponse = try? send([GetStatusCommand()]) {
                podState.updateFromStatusResponse(statusResponse, at: currentDate)
                guard podState.unfinalizedBolus == nil else {
                    log.default("bolus: pod is still bolusing")
                    return DeliveryCommandResult.certainFailure(error: .unfinalizedBolus)
                }
                // If the pod setup is complete, also confirm that the pod is indeed not suspended
                if podState.setupProgress == .completed && statusResponse.deliveryStatus.suspended {
                    log.default("bolus: pod is suspended")
                    return DeliveryCommandResult.certainFailure(error: .podSuspended)
                }
            } else {
                log.default("bolus: failed to read pod status to verify there is no bolus running")
                return DeliveryCommandResult.certainFailure(error: .noResponse)
            }
        }

        let bolusInfo: BolusInfo?
        if podState.podType.isO5 {
            // O5 uses an extended format including bolusInfo
            bolusInfo = BolusInfo(mealUnits: units)
        } else {
            // Eros or DASH doesn't use bolusInfo
            bolusInfo = nil
        }

        let bolusExtraCommand = BolusExtraCommand(units: units, timeBetweenPulses: timeBetweenPulses, extendedUnits: extendedUnits, extendedDuration: extendedDuration, acknowledgementBeep: acknowledgementBeep, completionBeep: completionBeep, programReminderInterval: programReminderInterval, bolusInfo: bolusInfo)
        do {
            podState.unacknowledgedCommand = PendingCommand.program(.bolus(volume: units, automatic: automatic), transport.messageNumber, currentDate)
            let statusResponse: StatusResponse = try send([bolusScheduleCommand, bolusExtraCommand])
            podState.unacknowledgedCommand = nil
            podState.unfinalizedBolus = UnfinalizedDose(bolusAmount: units, startTime: currentDate, scheduledCertainty: .certain, insulinType: podState.insulinType, automatic: automatic)
            podState.updateFromStatusResponse(statusResponse, at: currentDate)
            return DeliveryCommandResult.success(statusResponse: statusResponse)
        } catch PodCommsError.unacknowledgedMessage(let seq, let error) {
            podState.unacknowledgedCommand = podState.unacknowledgedCommand?.commsFinished
            log.error("Unacknowledged bolus: command seq = %lld, error = %{public}@", seq, String(describing: error))
            return DeliveryCommandResult.unacknowledged(error: .commsError(error: error))
        } catch let error {
            podState.unacknowledgedCommand = nil
            return DeliveryCommandResult.certainFailure(error: .commsError(error: error))
        }
    }

    func setTempBasal(rate: Double, duration: TimeInterval, isHighTemp: Bool, automatic: Bool, acknowledgementBeep: Bool = false, completionBeep: Bool = false, programReminderInterval: TimeInterval = 0) -> DeliveryCommandResult {

        if podState.unacknowledgedCommand != nil {
            do {
                try tryToResolvePendingCommand()
            } catch {
                return DeliveryCommandResult.certainFailure(error: .unacknowledgedCommandPending)
            }
        }

        let tempBasalCommand = SetInsulinScheduleCommand(nonce: podState.currentNonce, tempBasalRate: rate, duration: duration)
        let tempBasalExtraCommand = TempBasalExtraCommand(rate: rate, duration: duration, acknowledgementBeep: acknowledgementBeep, completionBeep: completionBeep, programReminderInterval: programReminderInterval, podType: podState.podType)

        let startTime = currentDate

        do {
            podState.unacknowledgedCommand = PendingCommand.program(.tempBasal(unitsPerHour: rate, duration: duration, isHighTemp: isHighTemp, automatic: automatic), transport.messageNumber, startTime)
            let status: StatusResponse = try send([tempBasalCommand, tempBasalExtraCommand])
            podState.unacknowledgedCommand = nil
            podState.unfinalizedTempBasal = UnfinalizedDose(tempBasalRate: rate, startTime: startTime, duration: duration, isHighTemp: isHighTemp, automatic: automatic, scheduledCertainty: .certain, insulinType: podState.insulinType)
            podState.updateFromStatusResponse(status, at: currentDate)
            return DeliveryCommandResult.success(statusResponse: status)
        } catch PodCommsError.unacknowledgedMessage(let seq, let error) {
            podState.unacknowledgedCommand = podState.unacknowledgedCommand?.commsFinished
            log.error("Unacknowledged temp basal: command seq = %lld, error = %{public}@", seq, String(describing: error))
            return DeliveryCommandResult.unacknowledged(error: .commsError(error: error))
        } catch let error {
            podState.unacknowledgedCommand = nil
            return DeliveryCommandResult.certainFailure(error: .commsError(error: error))
        }
    }

    // Suspends insulin delivery and sets appropriate podSuspendedReminder & suspendTimeExpired alerts.
    // A nil suspendReminder is an untimed suspend with no suspend reminders.
    // A suspendReminder of 0 is an untimed suspend which only uses podSuspendedReminder alert beeps.
    // A suspendReminder of 1-5 minutes will only use suspendTimeExpired alert beeps.
    // A suspendReminder of > 5 min will have periodic podSuspendedReminder beeps followed by suspendTimeExpired alerts.
    // The configured alerts will set up as silent pod alerts if silent is true.
    func suspendDelivery(suspendReminder: TimeInterval? = nil, silent: Bool, beepBlock: MessageBlock? = nil) -> CancelDeliveryResult {

        if podState.unacknowledgedCommand != nil {
            do {
                try tryToResolvePendingCommand()
            } catch {
                return .certainFailure(error: .unacknowledgedCommandPending)
            }
        }

        guard podState.setupProgress == .completed else {
            // A cancel delivery command before pod setup is complete will fault the pod
            return .certainFailure(error: PodCommsError.setupNotComplete)
        }

        do {
            var alertConfigurations: [AlertConfiguration] = []
            var podSuspendedReminderAlert: PodAlert? = nil
            var suspendTimeExpiredAlert: PodAlert? = nil
            let suspendTime: TimeInterval = suspendReminder != nil ? suspendReminder! : 0
            let elapsed: TimeInterval = -(podState.podTimeUpdated?.timeIntervalSinceNow ?? 0)
            let podTime = podState.podTime + elapsed
            log.debug("suspendDelivery: podState.podTime=%@, elapsed=%.2fs, computed timeActive %@", podState.podTime.timeIntervalStr, elapsed, podTime.timeIntervalStr)

            let cancelDeliveryCommand = CancelDeliveryCommand(nonce: podState.currentNonce, deliveryType: .all, beepType: .noBeepCancel)
            var commandsToSend: [MessageBlock] = [cancelDeliveryCommand]

            // podSuspendedReminder provides a periodic pod suspended reminder beep until the specified suspend time.
            if suspendReminder != nil && (suspendTime == 0 || suspendTime > .minutes(5)) {
                // using reminder beeps for an untimed or long enough suspend time requiring pod suspended reminders
                podSuspendedReminderAlert = PodAlert.podSuspendedReminder(active: true, offset: podTime, suspendTime: suspendTime, silent: silent)
                alertConfigurations += [podSuspendedReminderAlert!.configuration]
            }

            // suspendTimeExpired provides suspend time expired alert beeping after the expected suspend time has passed.
            if suspendTime > 0 {
                // a timed suspend using a suspend time expired alert
                suspendTimeExpiredAlert = PodAlert.suspendTimeExpired(offset: podTime, suspendTime: suspendTime, silent: silent)
                alertConfigurations += [suspendTimeExpiredAlert!.configuration]
            }

            // append a ConfigureAlert command if we have any reminder alerts for this suspend
            if alertConfigurations.count != 0 {
                let configureAlerts = ConfigureAlertsCommand(nonce: podState.currentNonce, configurations: alertConfigurations)
                commandsToSend += [configureAlerts]
            }

            podState.unacknowledgedCommand = PendingCommand.stopProgram(.all, transport.messageNumber, currentDate)
            let status: StatusResponse = try send(commandsToSend, beepBlock: beepBlock)
            podState.unacknowledgedCommand = nil
            let canceledDose = podState.handleCancelDosing(deliveryType: .all, bolusNotDelivered: status.bolusNotDelivered, at: currentDate)
            podState.updateFromStatusResponse(status, at: currentDate)

            if let alert = podSuspendedReminderAlert {
                podState.registerConfiguredAlert(slot: alert.configuration.slot, alert: alert)
            }
            if let alert = suspendTimeExpiredAlert {
                podState.registerConfiguredAlert(slot: alert.configuration.slot, alert: alert)
            }

            return CancelDeliveryResult.success(statusResponse: status, canceledDose: canceledDose)

        } catch PodCommsError.unacknowledgedMessage(let seq, let error) {
            podState.unacknowledgedCommand = podState.unacknowledgedCommand?.commsFinished
            log.error("Unacknowledged suspend: command seq = %lld, error = %{public}@", seq, String(describing: error))
            return .unacknowledged(error: .commsError(error: error))
        } catch let error {
            podState.unacknowledgedCommand = nil
            return .certainFailure(error: .commsError(error: error))
        }
    }

    // Cancels any suspend related alerts, called when setting a basal schedule with active suspend alerts
    private func cancelSuspendAlerts() throws -> StatusResponse {

        do {
            let podSuspendedReminder = PodAlert.podSuspendedReminder(active: false, offset: 0, suspendTime: 0)
            let suspendTimeExpired = PodAlert.suspendTimeExpired(offset: 0, suspendTime: 0) // A suspendTime of 0 deactivates this alert

            let status = try configureAlerts([podSuspendedReminder, suspendTimeExpired])
            return status
        } catch let error {
            throw error
        }
    }

    // Cancel beeping can be done implemented using beepType (for a single delivery type) or a separate confirmation beep message block (for cancel all).
    // N.B., Using the built-in cancel delivery command beepType method when cancelling all insulin delivery will emit 3 different sets of cancel beeps!!!
    func cancelDelivery(deliveryType: CancelDeliveryCommand.DeliveryType, beepType: BeepType = .noBeepCancel, beepBlock: MessageBlock? = nil) -> CancelDeliveryResult {

        if podState.unacknowledgedCommand != nil {
            do {
                try tryToResolvePendingCommand()
            } catch {
                return .certainFailure(error: .unacknowledgedCommandPending)
            }
        }

        guard podState.setupProgress == .completed else {
            // A cancel delivery command before pod setup is complete will fault the pod
            return .certainFailure(error: PodCommsError.setupNotComplete)
        }

        do {
            podState.unacknowledgedCommand = PendingCommand.stopProgram(deliveryType, transport.messageNumber, currentDate)
            let cancelDeliveryCommand = CancelDeliveryCommand(nonce: podState.currentNonce, deliveryType: deliveryType, beepType: beepType)
            let status: StatusResponse = try send([cancelDeliveryCommand], beepBlock: beepBlock)
            podState.unacknowledgedCommand = nil

            let canceledDose = podState.handleCancelDosing(deliveryType: deliveryType, bolusNotDelivered: status.bolusNotDelivered, at: currentDate)
            podState.updateFromStatusResponse(status, at: currentDate)

            return CancelDeliveryResult.success(statusResponse: status, canceledDose: canceledDose)
        } catch PodCommsError.unacknowledgedMessage(let seq, let error) {
            podState.unacknowledgedCommand = podState.unacknowledgedCommand?.commsFinished
            log.debug("Unacknowledged stop program: command seq = %lld", seq)
            return .unacknowledged(error: .commsError(error: error))
        } catch let error {
            podState.unacknowledgedCommand = nil
            return .certainFailure(error: .commsError(error: error))
        }
    }

    func setTime(timeZone: TimeZone, basalSchedule: BasalSchedule, date: Date, acknowledgementBeep: Bool = false) throws -> StatusResponse {

        if podState.unacknowledgedCommand != nil {
            try tryToResolvePendingCommand()
        }

        let result = cancelDelivery(deliveryType: .all)
        switch result {
        case .certainFailure(let error):
            throw error
        case .unacknowledged(let error):
            throw error
        case .success:
            let scheduleOffset = timeZone.scheduleOffset(forDate: date)
            let status = try setBasalSchedule(schedule: basalSchedule, scheduleOffset: scheduleOffset, acknowledgementBeep: acknowledgementBeep)
            return status
        }
    }

    func setBasalSchedule(schedule: BasalSchedule, scheduleOffset: TimeInterval, acknowledgementBeep: Bool = false, programReminderInterval: TimeInterval = 0) throws -> StatusResponse {

        if podState.unacknowledgedCommand != nil {
            try tryToResolvePendingCommand()
        }

        let basalScheduleCommand = SetInsulinScheduleCommand(nonce: podState.currentNonce, basalSchedule: schedule, scheduleOffset: scheduleOffset, podType: podState.podType)
        let basalExtraCommand = BasalScheduleExtraCommand.init(schedule: schedule, scheduleOffset: scheduleOffset, acknowledgementBeep: acknowledgementBeep, programReminderInterval: programReminderInterval, podType: podState.podType)

        do {
            if !podState.isSuspended || podState.lastDeliveryStatusReceived == nil || !podState.lastDeliveryStatusReceived!.suspended {
                // The podState or the last pod delivery status return indicates that the pod is not currently suspended.
                // So execute a cancel all command here before setting the basal to prevent a possible 0x31 pod fault,
                // but only when the pod startup is complete as a cancel command during pod setup also fault the pod!
                if podState.setupProgress == .completed  {
                    let _: StatusResponse = try send([CancelDeliveryCommand(nonce: podState.currentNonce, deliveryType: .all, beepType: .noBeepCancel)])
                }
            }
            podState.unacknowledgedCommand = PendingCommand.program(.basalProgram(schedule: schedule), transport.messageNumber, currentDate)
            var status: StatusResponse = try send([basalScheduleCommand, basalExtraCommand])
            podState.unacknowledgedCommand = nil
            let now = currentDate
            podState.suspendState = .resumed(now)
            podState.unfinalizedResume = UnfinalizedDose(resumeStartTime: now, scheduledCertainty: .certain, insulinType: podState.insulinType)
            if hasActiveSuspendAlert(configuredAlerts: podState.configuredAlerts),
               let cancelStatus = try? cancelSuspendAlerts()
            {
                status = cancelStatus // update using the latest status
            }
            podState.updateFromStatusResponse(status, at: currentDate)
            return status
        } catch PodCommsError.unacknowledgedMessage(let seq, let error) {
            podState.unacknowledgedCommand = podState.unacknowledgedCommand?.commsFinished
            log.error("Unacknowledged resume: command seq = %lld, error = %{public}@", seq, String(describing: error))
            throw error
        } catch let error {
            podState.unacknowledgedCommand = nil
            throw error
        }
    }

    func resumeBasal(schedule: BasalSchedule, scheduleOffset: TimeInterval, acknowledgementBeep: Bool = false, programReminderInterval: TimeInterval = 0) throws -> StatusResponse {

        if podState.unacknowledgedCommand != nil {
            try tryToResolvePendingCommand()
        }

        let status = try setBasalSchedule(schedule: schedule, scheduleOffset: scheduleOffset, acknowledgementBeep: acknowledgementBeep, programReminderInterval: programReminderInterval)

        podState.suspendState = .resumed(currentDate)

        return status
    }

    // use cancelDelivery with .none to get status as well as to validate & advance the nonce
    // Throws PodCommsError
    func cancelNone(beepBlock: MessageBlock? = nil) throws -> StatusResponse {
        var statusResponse: StatusResponse

        let cancelResult: CancelDeliveryResult = cancelDelivery(deliveryType: .none, beepBlock: beepBlock)
        switch cancelResult {
        case .certainFailure(let error):
            throw error
        case .unacknowledged(let error):
            throw error
        case .success(let response, _):
            statusResponse = response
        }
        podState.updateFromStatusResponse(statusResponse, at: currentDate)
        return statusResponse
    }

    // Throws PodCommsError
    func getStatus(noSeqGetStatus: Bool = false, beepBlock: MessageBlock? = nil) throws -> StatusResponse {
        // For noSeqSetStatus, use alternative noSeqStatus (type 7) request if not an Eros pod type instead of a normal (type 0) request
        let statusType: PodInfoResponseSubType = (noSeqGetStatus && !podState.podType.isEros) ? .noSeqStatus : .normal
        let statusResponse: StatusResponse = try send([GetStatusCommand(podInfoType: statusType)], beepBlock: beepBlock)

        if podState.unacknowledgedCommand != nil {
            recoverUnacknowledgedCommand(using: statusResponse)
        }
        podState.updateFromStatusResponse(statusResponse, at: currentDate)
        return statusResponse
    }

    func getDetailedStatus(beepBlock: MessageBlock? = nil) throws -> DetailedStatus {
        let infoResponse: PodInfoResponse = try send([GetStatusCommand(podInfoType: .detailedStatus)], beepBlock: beepBlock)

        guard let detailedStatus = infoResponse.podInfo as? DetailedStatus else {
            throw PodCommsError.unexpectedResponse(response: .podInfoResponse)
        }
        if detailedStatus.isFaulted && self.podState.fault == nil {
            // just detected that the pod has faulted, handle setting the fault state but don't throw
            handlePodFault(fault: detailedStatus)
        } else {
            let derivedStatusResponse = StatusResponse(detailedStatus: detailedStatus)
            if podState.unacknowledgedCommand != nil {
                recoverUnacknowledgedCommand(using: derivedStatusResponse)
            }
            podState.updateFromStatusResponse(derivedStatusResponse, at: currentDate)
        }
        return detailedStatus
    }

    func readPodInfo(podInfoResponseSubType: PodInfoResponseSubType, beepBlock: MessageBlock? = nil) throws -> PodInfoResponse {
        let podInfoCommand = GetStatusCommand(podInfoType: podInfoResponseSubType)
        let podInfoResponse: PodInfoResponse = try send([podInfoCommand], beepBlock: beepBlock)
        return podInfoResponse
    }

    // Reconnected to the pod, and we know program was successful based on lastProgrammingMessageSeqNum
    private func unacknowledgedCommandWasReceived(pendingCommand: PendingCommand, podStatus: StatusResponse) {
        switch pendingCommand {
        case .program(let program, _, let commandDate, _):
            if let dose = program.unfinalizedDose(at: commandDate, withCertainty: .certain, insulinType: podState.insulinType) {
                switch dose.doseType {
                case .bolus:
                    podState.unfinalizedBolus = dose
                case .tempBasal:
                    podState.unfinalizedTempBasal = dose
                case .resume:
                    podState.suspendState = .resumed(commandDate)
                default:
                    break
                }
            }
        case .stopProgram(let stopProgram, _, let commandDate, _):
            if stopProgram.contains(.bolus), let bolus = podState.unfinalizedBolus, !bolus.isFinished(at: commandDate) {
                // If the pod is faulted, don't use bolusNotDelivered as this will be handled in handlePodFault()
                let bolusNotDelivered = podState.isFaulted ? 0 : podStatus.bolusNotDelivered
                podState.unfinalizedBolus?.cancel(at: commandDate, withRemaining: bolusNotDelivered)
            }
            if stopProgram.contains(.tempBasal), let tempBasal = podState.unfinalizedTempBasal, !tempBasal.isFinished(at: commandDate) {
                podState.unfinalizedTempBasal?.cancel(at: commandDate)
            }
            if stopProgram.contains(.basal) {
                podState.finalizedDoses.append(UnfinalizedDose(suspendStartTime: commandDate, scheduledCertainty: .certain))
                podState.suspendState = .suspended(commandDate)
            }
        }
    }

    // Reconnected to the pod and we didn't match lastProgrammingMessageSeqNum which indicates
    // that the command was not received. Now verify the pendingCommand against the current pod
    // delivery status to decide whether the delivery related command might have been received or not.
    // Returns true if the command was received based on the pod delivery status and podState was updated.
    private func checkCommandAgainstStatus(pendingCommand: PendingCommand, podStatus: StatusResponse) -> Bool {
        let deliveryStatus = podStatus.deliveryStatus
        var podStatusMatched = false
        switch pendingCommand {
        case .program(let program, _, let commandDate, _):
            if let dose = program.unfinalizedDose(at: commandDate, withCertainty: .certain, insulinType: podState.insulinType) {
                switch dose.doseType {
                case .bolus:
                    if deliveryStatus.bolusing {
                        podState.unfinalizedBolus = dose
                        podStatusMatched = true
                    }
                case .tempBasal:
                    if deliveryStatus.tempBasalRunning {
                        podState.unfinalizedTempBasal = dose
                        podStatusMatched = true
                    }
                case .resume:
                    if !deliveryStatus.suspended {
                        podState.suspendState = .resumed(commandDate)
                        podStatusMatched = true
                    }
                default:
                    break
                }
            }
        case .stopProgram(let stopProgram, _, let commandDate, _):
            if stopProgram.contains(.bolus), let bolus = podState.unfinalizedBolus, !bolus.isFinished(at: commandDate) {
                if !deliveryStatus.bolusing {
                    // If the pod is faulted, don't use bolusNotDelivered as this will be handled in handlePodFault()
                    let bolusNotDelivered = podState.isFaulted ? 0 : podStatus.bolusNotDelivered
                    podState.unfinalizedBolus?.cancel(at: commandDate, withRemaining: bolusNotDelivered)
                    podStatusMatched = true
                }
            }
            if stopProgram.contains(.tempBasal), let tempBasal = podState.unfinalizedTempBasal, !tempBasal.isFinished(at: commandDate) {
                if !deliveryStatus.tempBasalRunning {
                    podState.unfinalizedTempBasal?.cancel(at: commandDate)
                    podStatusMatched = true
                }
            }
            if stopProgram.contains(.basal) {
                if !deliveryStatus.suspended {
                    podState.finalizedDoses.append(UnfinalizedDose(suspendStartTime: commandDate, scheduledCertainty: .certain))
                    podState.suspendState = .suspended(commandDate)
                    podStatusMatched = true
                }
            }
        }
        return podStatusMatched
    }

    func recoverUnacknowledgedCommand(using status: StatusResponse) {
        if let pendingCommand = podState.unacknowledgedCommand {
            self.log.default("Recovering from unacknowledged command %{public}@, status = %{public}@", String(describing: pendingCommand), String(describing: status))

            if status.lastProgrammingMessageSeqNum == pendingCommand.sequence {
                self.log.default("Unacknowledged command was received by pump")
                unacknowledgedCommandWasReceived(pendingCommand: pendingCommand, podStatus: status)
            } else if checkCommandAgainstStatus(pendingCommand: pendingCommand, podStatus: status) {
                self.log.default("Accepted unacknowledged command was received based on pod delivery status of ${public}@", String(describing: status.deliveryStatus))
            } else {
                self.log.default("Unacknowledged command was not received by pump")
            }
            podState.unacknowledgedCommand = nil
        }
    }

    // Can be called a second time to deactivate a given pod
    func deactivatePod() throws {

        // Don't try to cancel if the pod hasn't completed its setup as it will either receive no response
        // (pod progress state <= 2) or creates a $31 pod fault (pod progress states 3 through 7).
        if podState.setupProgress == .completed && podState.fault == nil && !podState.isSuspended {
            let result = cancelDelivery(deliveryType: .all)
            switch result {
            case .certainFailure(let error):
                throw error
            case .unacknowledged(let error):
                throw error
            default:
                break
            }
        }

        // Try to read the most recent pulse log entries for possible later analysis
        _ = try? readPodInfo(podInfoResponseSubType: .pulseLogRecent)
        if podState.fault != nil {
            // Try to read the previous pulse log entries on the faulted pod
            _ = try? readPodInfo(podInfoResponseSubType: .pulseLogPrevious)
        }

        do {
            if podState.unacknowledgedCommand != nil {
                // Try to resolve the unacknowledged command now as DeactivatePodCommand
                // destroys any chance of correctly handling the unacknowledged command.
                try? tryToResolvePendingCommand()
            }
            let deactivatePod = DeactivatePodCommand(nonce: podState.currentNonce)
            let status: StatusResponse = try send([deactivatePod])
            podState.updateFromStatusResponse(status, at: currentDate)
            setDeliverytoppedAt(podTime: status.timeActive)
        } catch let error as PodCommsError {
            /// Don't set DeliveryStopped as we don't know if the pod was deactivated.
            /// Instead, wait until a successful deactivation or the user discards the pod.
            switch error {
            case .podFault, .activationTimeExceeded, .unexpectedResponse:
                break
            default:
                throw error
            }
        }
    }

    func acknowledgeAlerts(alerts: AlertSet, beepBlock: MessageBlock? = nil) throws -> AlertSet {

        if podState.unacknowledgedCommand != nil {
            try tryToResolvePendingCommand()
        }

        let cmd = AcknowledgeAlertCommand(nonce: podState.currentNonce, alerts: alerts)
        let status: StatusResponse = try send([cmd], beepBlock: beepBlock)
        podState.updateFromStatusResponse(status, at: currentDate)
        return podState.activeAlertSlots
    }

    func dosesForStorage(_ storageHandler: ([UnfinalizedDose]) -> Bool) {
        assertOnSessionQueue()

        let dosesToStore = podState.dosesToStore

        if storageHandler(dosesToStore) {
            log.info("Stored doses: %@", String(describing: dosesToStore))
            self.podState.finalizedDoses.removeAll()
        }
    }

    func assertOnSessionQueue() {
        self.transport.assertOnSessionQueue()
    }

    func messageTransport(_ messageTransport: any MessageTransport, didUpdate state: any MessageTransportState) {
        messageTransport.assertOnSessionQueue()

        if let bleMessageTransportState = state as? BleMessageTransportState {
            self.podState.bleMessageTransportState = bleMessageTransportState
        } else if let erosMessageTransportState = state as? ErosMessageTransportState {
            self.podState.erosMessageTransportState = erosMessageTransportState
        } else {
            assertionFailure("Unsupported state update")
        }
    }
}
