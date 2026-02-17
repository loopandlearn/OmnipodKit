//
//  PodCommsSession+O5Activation.swift
//  OmnipodKit
//
//  O5-specific activation command sequence.
//  Based on POST_PAIR_COMMANDS.md from Omnipod 5 APK analysis and btsnoop captures.
//
//  The O5 activation differs from DASH in command ordering:
//    Phase 1: Alerts (slots #4, #7) -> Prime 1 (tubing fill) -> [wait] -> Alert (slot #3)
//    Phase 2: Basal -> Alerts (clear/reprogram) -> Prime 2 (cannula insertion) -> Final status
//
//  Only ProgramBolus (prime/delivery) uses Type 4 (encrypted + ECDSA signed) via o5Send().
//  All other commands (ConfigureAlerts, ProgramBasal, etc.) use Type 1 (encrypted only).
//
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//

import Foundation
import os.log

extension PodCommsSession {

    // MARK: - O5 Activation Phase 1 (priming)

    /// O5 activation Phase 1: configure pre-prime alerts, prime tubing.
    ///
    /// From Frida log of real O5 app, after EAP-AKA session establishment:
    ///   1. ProgramAlert: low reservoir (slot #4, volume-based)
    ///   2. ProgramAlert: lump-of-coal / finish setup reminder (slot #7, time-based)
    ///   3. ProgramBolus: prime 1 (engage clutch drive, fill tubing, 2.6U)
    ///   4. Wait for prime completion
    ///   5. ProgramAlert: user-set pod expiration (slot #3, time-based) -- sent by o5PostPrimeAlerts()
    ///
    /// Note: NO basal schedule is programmed before priming. Basal is programmed
    /// during Phase 2 (cannula insertion), matching the real O5 app behavior.
    /// The user expiry alert (slot #3) is sent AFTER prime completes, not before.
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
        // From Frida: slot=4, 0x0064 = 100 ticks = 10U threshold
        log.info("O5 Phase 1: Configuring low reservoir alert (slot #4)")
        let lowReservoirAlert = PodAlert.lowReservoir(units: 10)
        try o5ConfigureAlerts([lowReservoirAlert])

        // Step 2: Configure lump-of-coal / finish setup reminder (slot #7)
        // From POST_PAIR_COMMANDS.md: slot=7, beepReps=2, beepType=8, autoOff=true,
        //   duration=55min, type=time, threshold=5min activation delay
        log.info("O5 Phase 1: Configuring finish setup reminder (slot #7)")
        let finishSetupReminder = PodAlert.finishSetupReminder
        try o5ConfigureAlerts([finishSetupReminder])

        // Step 3: Prime bolus 1 (engage clutch drive, fill tubing)
        // User expiry alert (slot #3) is sent AFTER prime completes -- see o5PostPrimeAlerts()
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
            programReminderInterval: TimeInterval(minutes: 60),
            withPdmValue: true // O5 requires 0x12 (WITH_PDM_VALUE) with bolus source fields
        )
        let primeStatus: StatusResponse = try o5Send([scheduleCommand, bolusExtraCommand])
        podState.updateFromStatusResponse(primeStatus, at: currentDate)
        podState.setupProgress = .priming
        log.info("O5 Phase 1: Prime 1 started, expected completion in %.0f seconds",
                 primeFinishTime.timeIntervalSinceNow)

        return primeFinishTime.timeIntervalSinceNow
    }

    // MARK: - O5 Post-Prime Alerts

    /// Sends the user expiry alert (slot #3) after prime 1 completes.
    ///
    /// From Frida capture of real O5 app (Pod2, 2026-02-16), the user expiry alert is
    /// sent AFTER prime completes but before Phase 1 is considered done:
    ///   ... prime 1 complete (poll getPodStatus page 7 until done) ...
    ///   programAlert slot #3: user expiry at 3968 min (~66h8m from activation)
    ///   --- ACTIVATION_COMPLETED_PHASE_1 ---
    ///
    /// This function should be called after prime completion is confirmed,
    /// before proceeding to Phase 2 (cannula insertion).
    func o5PostPrimeAlerts() throws {
        log.info("O5 Phase 1 post-prime: Configuring user expiration reminder (slot #3)")
        let elapsed: TimeInterval = -(podState.podTimeUpdated?.timeIntervalSinceNow ?? 0)
        let podTime = podState.podTime + elapsed
        let expirationReminder = PodAlert.expirationReminder(
            offset: podTime,
            absAlertTime: Pod.nominalPodLife - Pod.o5UserExpiryOffset
        )
        try o5ConfigureAlerts([expirationReminder])
        log.info("O5 Phase 1 post-prime: User expiry alert configured (slot #3)")
    }

    // MARK: - O5 Activation Phase 2 (cannula insertion)

    /// O5 activation Phase 2: program basal, clear/reprogram alerts, insert cannula.
    ///
    /// From the O5 Java activation state machine, after prime 1 completion:
    ///   1. ProgramBasal: full 24-hour basal schedule (ACTIVATION_PROGRAMMED_BASAL state 9)
    ///   2. ProgramAlert: clear LOC (#7), program system expiration (#2),
    ///      imminent expiration/auto-off (#0) (ACTIVATION_PROGRAMMED_CANCEL_LOC_ETC_ALERT state 10)
    ///   3. ProgramBolus: prime 2 (fill cannula, insert needle, 0.5U) (ACTIVATION_INSERTED_CANNULA state 11)
    ///   4. CGM activation (skipped -- not implemented yet)
    ///   5. Final status verification
    ///
    /// All alerts use Type 1 (encrypted, unsigned) via o5ConfigureAlerts().
    /// ProgramBolus (prime 2) uses Type 4 (encrypted + ECDSA signed) via o5Send().
    ///
    /// - Parameter basalSchedule: The basal schedule to program (from OmniPumpManagerState)
    /// - Parameter scheduleOffset: Current time offset into the basal schedule
    /// - Parameter optionalAlerts: Additional alerts to configure (e.g., low reservoir)
    /// - Parameter silent: Whether to silence beep alerts
    /// - Returns: Time interval until cannula insertion is expected to complete
    func o5InsertCannula(basalSchedule: BasalSchedule, scheduleOffset: TimeInterval, optionalAlerts: [PodAlert] = [], silent: Bool) throws -> TimeInterval {
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

        // Send the post-prime user expiry alert (slot #3) if not already sent.
        // This completes Phase 1 per the Frida-validated activation sequence:
        // the user expiry alert is sent AFTER prime completes, before Phase 2 begins.
        if podState.configuredAlerts[.slot3ExpirationReminder] == nil {
            try o5PostPrimeAlerts()
        }

        // Step 1: Program initial basal schedule (FIRST command in Phase 2)
        // O5 Java state machine: ACTIVATION_COMPLETED_PHASE_1 -> ACTIVATION_PROGRAMMED_BASAL
        // Basal is NOT programmed before priming (Phase 1). It must be the first Phase 2 command.
        if podState.setupProgress.needsInitialBasalSchedule {
            log.info("O5 Phase 2: Programming initial basal schedule")
            try programInitialBasalSchedule(basalSchedule, scheduleOffset: scheduleOffset)
        }

        let elapsed: TimeInterval = -(podState.podTimeUpdated?.timeIntervalSinceNow ?? 0)
        let podTime = podState.podTime + elapsed

        // Step 2: Clear LOC and program expiration alerts
        // O5 Java state machine: ACTIVATION_PROGRAMMED_BASAL -> ACTIVATION_PROGRAMMED_CANCEL_LOC_ETC_ALERT
        // From O5 Java source:
        //   - Program system expiration (slot #2): shutdown imminent, beepRepeat=8 (every5Minutes)
        //   - Program pod expiration advisory (slot #7): clear LOC, reprogram as expiration
        //   - Program imminent expiration / auto-off (slot #0): 15 min duration, autoOff=true
        log.info("O5 Phase 2: Configuring expiration alerts and clearing LOC")
        let shutdownImminentAlarm = PodAlert.shutdownImminent(
            offset: podTime,
            absAlertTime: Pod.serviceDuration - Pod.endOfServiceImminentWindow,
            silent: silent,
            beepRepeat: .every5Minutes  // O5 uses every5Minutes (8), not every15Minutes (6) like DASH
        )
        let expirationAdvisoryAlarm = PodAlert.expired(
            offset: podTime,
            absAlertTime: Pod.nominalPodLife,
            duration: Pod.expirationAdvisoryWindow,
            silent: silent
        )
        // Slot #0: imminent expiration / auto-off alert
        // From O5 Java source: slot=0, beepType=2 (bipBeepBipBeepBipBeepBipBeep),
        //   beepRepeat=2 (every1MinuteFor15Minutes), duration=15min, autoOff=true, type=time
        // Initially disabled -- requires POD_AUTO_OFF_REMINDER configuration to enable
        let autoOffAlert = PodAlert.autoOff(
            active: false,
            offset: podTime,
            countdownDuration: .minutes(15),
            silent: silent
        )
        try o5ConfigureAlerts([expirationAdvisoryAlarm, shutdownImminentAlarm, autoOffAlert] + optionalAlerts)

        // Step 3: Prime bolus 2 (fill cannula, insert needle)
        // O5 Java state machine: ACTIVATION_PROGRAMMED_CANCEL_LOC_ETC_ALERT -> ACTIVATION_INSERTED_CANNULA
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
            timeBetweenPulses: timeBetweenPulses,
            withPdmValue: true // O5 requires 0x12 (WITH_PDM_VALUE) with bolus source fields
        )
        let status: StatusResponse = try o5Send([bolusScheduleCommand, bolusExtraCommand])
        podState.updateFromStatusResponse(status, at: currentDate)

        podState.setupProgress = .cannulaInserting
        log.info("O5 Phase 2: Cannula insertion started, pod progress=%{public}@",
                 String(describing: status.podProgressStatus))

        // Step 4: CGM activation (skipped for now)
        // From POST_PAIR_COMMANDS.md: activateDexcomG6Cgm() / activateLibre2Cgm() / activateNoCgm()

        return status.bolusNotDelivered / Pod.primeDeliveryRate
    }
}
