//
//  PodCommsSession+O5Activation.swift
//  OmnipodKit
//
//  O5-specific activation command sequence.
//  Based on POST_PAIR_COMMANDS.md from Omnipod 5 APK analysis and btsnoop captures.
//
//  The O5 activation differs from DASH in command ordering:
//    Phase 1: Alerts → Prime 1 (tubing fill)
//    Phase 2: Basal → Alerts (clear/reprogram) → Prime 2 (cannula insertion) → Final status
//
//  All O5 programming commands (ConfigureAlerts, ProgramBolus, ProgramBasal) are sent as
//  Type 4 (encrypted + ECDSA signed) messages via o5Send() / o5ConfigureAlerts().
//
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//

import Foundation
import os.log

extension PodCommsSession {

    // MARK: - O5 Activation Phase 1 (priming)

    /// O5 activation Phase 1: configure alerts, prime tubing.
    ///
    /// From Frida log of real O5 app, after EAP-AKA session establishment:
    ///   1. ProgramAlert: low reservoir (slot #4, volume-based)
    ///   2. ProgramAlert: lump-of-coal / finish setup reminder (slot #7, time-based)
    ///   3. ProgramAlert: user-set pod expiration (slot #3, time-based)
    ///   4. ProgramBolus: prime 1 (engage clutch drive, fill tubing, 2.6U)
    ///   5. Wait for prime completion
    ///
    /// Note: NO basal schedule is programmed before priming. Basal is programmed
    /// during Phase 2 (cannula insertion), matching the real O5 app behavior.
    ///
    /// All commands are sent as Type 4 signed messages via o5Send() / o5ConfigureAlerts().
    ///
    /// - Returns: Time interval until prime is expected to complete
    func o5Prime() throws -> TimeInterval {
        let primeDuration: TimeInterval = .seconds(Pod.primeUnits / Pod.primeDeliveryRate) + 3

        // Check if priming was already started (resuming from interrupted activation)
        // O5 app uses GetStatus page 7 (noSeqStatus) for prime polling
        if !podState.setupProgress.primingNeverAttempted {
            let status = try getStatus(noSeqGetStatus: true)
            if status.podProgressStatus == .priming || status.podProgressStatus == .primingCompleted {
                podState.setupProgress = .priming
                return podState.primeFinishTime?.timeIntervalSinceNow ?? primeDuration
            }
        }

        // Step 1: Configure low reservoir alert (slot #4)
        // From Frida: slot=4, 100 micro-liters = 5U threshold
        log.info("O5 Phase 1: Configuring low reservoir alert (slot #4)")
        let lowReservoirAlert = PodAlert.lowReservoir(units: 5)
        try o5ConfigureAlerts([lowReservoirAlert])

        // Step 2: Configure lump-of-coal / finish setup reminder (slot #7)
        // From POST_PAIR_COMMANDS.md: slot=7, beepReps=2, beepType=8, autoOff=true,
        //   duration=55min, type=time, threshold=5min activation delay
        log.info("O5 Phase 1: Configuring finish setup reminder (slot #7)")
        let finishSetupReminder = PodAlert.finishSetupReminder
        try o5ConfigureAlerts([finishSetupReminder])

        // Step 3: Configure user-set pod expiration alert (slot #3)
        // O5 app uses 68h from activation (4h before 72h nominal life)
        log.info("O5 Phase 1: Configuring user expiration reminder (slot #3)")
        let elapsed: TimeInterval = -(podState.podTimeUpdated?.timeIntervalSinceNow ?? 0)
        let podTime = podState.podTime + elapsed
        let expirationReminder = PodAlert.expirationReminder(
            offset: podTime,
            absAlertTime: Pod.nominalPodLife - TimeInterval(hours: 4)
        )
        try o5ConfigureAlerts([expirationReminder])

        // Step 4: Prime bolus 1 (engage clutch drive, fill tubing)
        // From POST_PAIR_COMMANDS.md: ProgramBolus 0x17, prime 1 volume, prime pulse rate
        log.info("O5 Phase 1: Starting prime bolus 1 (%.1fU)", Pod.primeUnits)
        let primeFinishTime = currentDate + primeDuration
        podState.primeFinishTime = primeFinishTime
        podState.setupProgress = .startingPrime

        let timeBetweenPulses = TimeInterval(seconds: Pod.secondsPerPrimePulse)
        let scheduleCommand = SetInsulinScheduleCommand(
            nonce: podState.currentNonce,
            units: Pod.primeUnits,
            timeBetweenPulses: timeBetweenPulses
        )
        let bolusExtraCommand = BolusExtraCommand(
            units: Pod.primeUnits,
            timeBetweenPulses: timeBetweenPulses,
            completionBeep: true,
            programReminderInterval: TimeInterval(minutes: 60)
        )
        let primeStatus: StatusResponse = try o5Send([scheduleCommand, bolusExtraCommand])
        podState.updateFromStatusResponse(primeStatus, at: currentDate)
        podState.setupProgress = .priming
        log.info("O5 Phase 1: Prime 1 started, expected completion in %.0f seconds",
                 primeFinishTime.timeIntervalSinceNow)

        return primeFinishTime.timeIntervalSinceNow
    }

    // MARK: - O5 Activation Phase 2 (cannula insertion)

    /// O5 activation Phase 2: clear/reprogram alerts, insert cannula.
    ///
    /// From POST_PAIR_COMMANDS.md btsnoop, after prime 1 completion:
    ///   1. ProgramAlert: clear LOC (#7), program system expiration (#2), imminent expiration (#0)
    ///   2. ProgramBolus: prime 2 (fill cannula, insert needle, 0.5U)
    ///   3. CGM activation (skipped — not implemented yet)
    ///   4. Final status verification
    ///
    /// All commands are sent as Type 4 signed messages via o5Send() / o5ConfigureAlerts().
    ///
    /// - Parameter optionalAlerts: Additional alerts to configure (e.g., low reservoir)
    /// - Parameter silent: Whether to silence beep alerts
    /// - Returns: Time interval until cannula insertion is expected to complete
    func o5InsertCannula(optionalAlerts: [PodAlert] = [], silent: Bool) throws -> TimeInterval {
        let cannulaInsertionUnits = Pod.cannulaInsertionUnits + Pod.cannulaInsertionUnitsExtra

        guard podState.activatedAt != nil else {
            throw PodCommsError.noPodPaired
        }

        // Check if cannula insertion was already started (resuming from interrupted activation)
        if podState.setupProgress == .startingInsertCannula || podState.setupProgress == .cannulaInserting {
            let status = try getStatus()
            if status.podProgressStatus == .insertingCannula {
                podState.setupProgress = .cannulaInserting
                return (status.bolusNotDelivered / Pod.primeDeliveryRate) + 1
            }
            if status.podProgressStatus.readyForDelivery {
                markSetupProgressCompleted(statusResponse: status)
                return TimeInterval(0)
            }
        }

        let elapsed: TimeInterval = -(podState.podTimeUpdated?.timeIntervalSinceNow ?? 0)
        let podTime = podState.podTime + elapsed

        // Step 1: Clear LOC and program expiration alerts
        // From POST_PAIR_COMMANDS.md:
        //   - Clear lump-of-coal (slot #7) by reprogramming as expired/inactive
        //   - Program system expiration (slot #2): shutdown imminent at 79 hours
        //   - Program imminent expiration (slot #0): 15 min duration, autoOff
        log.info("O5 Phase 2: Configuring expiration alerts and clearing LOC")
        let shutdownImminentAlarm = PodAlert.shutdownImminent(
            offset: podTime,
            absAlertTime: Pod.serviceDuration - Pod.endOfServiceImminentWindow,
            silent: silent
        )
        let expirationAdvisoryAlarm = PodAlert.expired(
            offset: podTime,
            absAlertTime: Pod.nominalPodLife,
            duration: Pod.expirationAdvisoryWindow,
            silent: silent
        )
        try o5ConfigureAlerts([expirationAdvisoryAlarm, shutdownImminentAlarm] + optionalAlerts)

        // Step 2: Prime bolus 2 (fill cannula, insert needle)
        // From POST_PAIR_COMMANDS.md: ProgramBolus 0x17, prime 2 volume (0.5U), prime pulse rate
        log.info("O5 Phase 2: Starting prime bolus 2 / cannula insertion (%.1fU)", cannulaInsertionUnits)
        let timeBetweenPulses = TimeInterval(seconds: Pod.secondsPerPrimePulse)
        let bolusScheduleCommand = SetInsulinScheduleCommand(
            nonce: podState.currentNonce,
            units: cannulaInsertionUnits,
            timeBetweenPulses: timeBetweenPulses
        )
        podState.setupProgress = .startingInsertCannula
        let bolusExtraCommand = BolusExtraCommand(
            units: cannulaInsertionUnits,
            timeBetweenPulses: timeBetweenPulses
        )
        let status: StatusResponse = try o5Send([bolusScheduleCommand, bolusExtraCommand])
        podState.updateFromStatusResponse(status, at: currentDate)

        podState.setupProgress = .cannulaInserting
        log.info("O5 Phase 2: Cannula insertion started, pod progress=%{public}@",
                 String(describing: status.podProgressStatus))

        // Step 3: CGM activation (skipped for now)
        // From POST_PAIR_COMMANDS.md: activateDexcomG6Cgm() / activateLibre2Cgm() / activateNoCgm()

        return status.bolusNotDelivered / Pod.primeDeliveryRate
    }
}
