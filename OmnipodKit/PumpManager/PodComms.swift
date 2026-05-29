//
//  PodComms.swift
//  OmnipodKit
//
//  Based on Omni{BLE,Kit}/PumpManager/PodComms.swift
//  Created by Joe Moran on 1/9/25.
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import os.log

protocol PodCommsDelegate: OmniConnectionDelegate {
    func podComms(_ podComms: PodComms, didChange podState: PodState?)
    func podCommsDidEstablishSession(_ podComms: PodComms) // non-RL only
}

class PodComms: CustomDebugStringConvertible {

    var myId: UInt32 = 0
    var podId: UInt32 = 0

    weak var delegate: PodCommsDelegate?

    weak var messageLogger: MessageLogger?

    let log = OSLog(category: "PodComms")

    var podStateLock = NSLock()

    var podState: PodState? {
        didSet {
            if podState != oldValue {
                delegate?.podComms(self, didChange: podState)
            }
        }
    }

    let podType: PodType

    init(podState: PodState?, podType: PodType, myId: UInt32 = 0, podId: UInt32 = 0) {
        self.podState = podState
        self.delegate = nil
        self.messageLogger = nil
        self.myId = myId
        self.podId = podId
        self.podType = podType
    }

    func updateInsulinType(_ insulinType: InsulinType) {
        podStateLock.lock()
        podState?.insulinType = insulinType
        podStateLock.unlock()
    }

    /// Handle any dosing and pump event cleanup when discarding a pod without going thru normal pod deactivation
    func handleDiscardedPodDosing(podTime: TimeInterval, reservoirLevel: Double?) {
        guard podState != nil else {
            return
        }

        /// Any suspended pod either already went through normal pod deactivation that does a cancelDelivery,
        /// pod fault handling for the faulted and suspended pod &/or was already suspended by the user.
        guard !podState!.isSuspended else {
            return
        }

        /// If the initial basal still needs to be programmed,
        /// then don't create suspend pump event without the resume.
        guard !podState!.setupProgress.needsInitialBasalSchedule else {
            return
        }

        podStateLock.lock()
        let now = Date()

        /// Compute the bolusNotDelivered if there was a bolus in progress when the pod was discarded.
        var bolusNotDelivered = 0.0
        if let bolus = podState!.unfinalizedBolus {
            let bolusDelivered = (((bolus.units * bolus.progress(at: now)) / Pod.pulseSize).rounded()) * Pod.pulseSize
            log.info("Cancelling unfinished bolus with calculated bolus delivered of %@", bolusDelivered.twoDecimals)
            bolusNotDelivered = bolus.units - bolusDelivered
        }

        /// Use handleCancelDosing() to update the dosing for a cancel all command (assuming the user removes the pod as directed).
        /// This includes suspending the pod and handle cancelling any in-progress tempBasal and bolus doses based on the current time.
        podState!.handleCancelDosing(deliveryType: .all, bolusNotDelivered: bolusNotDelivered, at: now)

        /// Now create a fake cancel all response and use it to update the podState.
        /// This has the side effects of updating lastSync as well as finalizing the
        /// unfinalizedSuspend and any unfinalized bolus or tempBasal doses.
        let fakeSuspendedResponse = StatusResponse(
            deliveryStatus: .suspended, // faking a suspended pod response
            podProgressStatus: .aboveFiftyUnits, // any nominal value should be fine
            timeActive: podTime, // current adjusted pod time as of now
            reservoirLevel: reservoirLevel ?? Pod.reservoirLevelAboveThresholdMagicNumber, // re-use last response
            insulinDelivered: 0.0, // this value will be ignored when it's less than previous value
            bolusNotDelivered: bolusNotDelivered, // might be non-zero for an in-progress bolus
            lastProgrammingMessageSeqNum: 0, // not important
            alerts: .none
        )
        podState!.updateFromStatusResponse(fakeSuspendedResponse, at: now)

        podStateLock.unlock()
    }

    func forgetPod() {
        podStateLock.lock()
        podState?.resolveAnyPendingCommandWithUncertainty()
        podState?.finalizeAllDoses()
        podStateLock.unlock()
    }

    func prepForNewPod(myId: UInt32 = 0, podId: UInt32 = 0) {
        self.myId = myId
        self.podId = podId

        podStateLock.lock()
        self.podState = nil
        podStateLock.unlock()
    }

    // runSession() result enum
    enum SessionRunResult {
        case success(session: PodCommsSession)
        case failure(PodCommsError)
    }

    // MARK: - CustomDebugStringConvertible

    var debugDescription: String {
        var ret = "## PodComms\n"
        if myId != 0 || podId != 0 {
            ret += "* myId: \(String(format: "%08llX", myId))\n* podId: \(String(format: "%08llX", podId))\n"
        }
        ret += "* delegate: \(String(describing: delegate != nil))\n"
        return ret
    }
}
