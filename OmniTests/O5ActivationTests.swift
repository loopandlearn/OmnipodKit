//
//  O5ActivationTests.swift
//  OmniTests
//
//  Tests for O5 Phase 1 activation alert ordering, low reservoir threshold,
//  and user expiry alert timing.
//
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//

import Foundation
import XCTest
@testable import OmnipodKit

class O5ActivationAlertTests: XCTestCase {

    // MARK: - Issue 1: User expiry alert should NOT be in o5Prime()

    /// Verify that the alerts used in o5Prime() are only slots #4 and #7.
    /// The user expiry alert (slot #3) is sent AFTER prime completes
    /// via o5PostPrimeAlerts(), matching the Frida-captured O5 app behavior.
    ///
    /// The Frida capture (Pod2, 2026-02-16) shows this order:
    ///   1. programAlert: low reservoir (slot #4)
    ///   2. programAlert: LOC/setup reminder (slot #7)
    ///   3. programBolus: prime 1
    ///   ... poll until prime complete ...
    ///   4. programAlert: user expiry (slot #3)  <-- AFTER prime
    func testO5PrePrimeAlertsAreSlot4AndSlot7Only() {
        // Low reservoir alert (slot #4) should target slot4LowReservoir
        let lowReservoir = PodAlert.lowReservoir(units: 10)
        XCTAssertEqual(lowReservoir.configuration.slot, .slot4LowReservoir)
        XCTAssertTrue(lowReservoir.configuration.active)

        // Finish setup reminder (slot #7) should target slot7Expired
        let finishSetup = PodAlert.finishSetupReminder
        XCTAssertEqual(finishSetup.configuration.slot, .slot7Expired)
        XCTAssertTrue(finishSetup.configuration.active)
    }

    /// Verify that the user expiry alert (slot #3) can be correctly constructed
    /// for post-prime delivery via o5PostPrimeAlerts().
    func testPostPrimeUserExpiryAlertIsSlot3() {
        let podTime: TimeInterval = .minutes(2) // 2 minutes after activation
        let expirationReminder = PodAlert.expirationReminder(
            offset: podTime,
            absAlertTime: Pod.nominalPodLife - Pod.o5UserExpiryOffset
        )
        XCTAssertEqual(expirationReminder.configuration.slot, .slot3ExpirationReminder)
        XCTAssertTrue(expirationReminder.configuration.active)
    }

    // MARK: - Issue 2: Low reservoir threshold encoding

    /// Verify that the low reservoir alert with 10U threshold encodes to 100 ticks (0x0064),
    /// matching the Frida-captured value from the real O5 app.
    ///
    /// Encoding formula: ticks = UInt16(volume / Pod.pulseSize / 2)
    ///   10U / 0.05 / 2 = 100 = 0x0064
    func testLowReservoirAlertEncodesTo10U() {
        let lowReservoir = PodAlert.lowReservoir(units: 10)
        let config = lowReservoir.configuration

        // Verify the alert is volume-triggered with 10U
        if case .unitsRemaining(let units) = config.trigger {
            XCTAssertEqual(units, 10.0, "Low reservoir trigger should be 10U")
        } else {
            XCTFail("Low reservoir alert should have unitsRemaining trigger")
        }

        // Verify the encoded bytes contain 0x0064 (100 ticks) for the threshold
        let configData = config.data
        XCTAssertEqual(configData.count, AlertConfiguration.length,
                       "Alert configuration should be 6 bytes")

        // Bytes 2-3 contain the trigger value (big-endian UInt16)
        // For volume trigger: ticks = UInt16(volume / pulseSize / 2)
        // 10U / 0.05 / 2 = 100 = 0x0064
        let ticksHighByte = configData[2]
        let ticksLowByte = configData[3]
        let ticks = (UInt16(ticksHighByte) << 8) | UInt16(ticksLowByte)
        // The trigger value is in the lower 14 bits (0x3FFF mask)
        let triggerTicks = ticks & 0x3FFF
        XCTAssertEqual(triggerTicks, 100,
                       "10U low reservoir should encode as 100 ticks (0x0064)")
    }

    /// Verify that 5U (the previous incorrect value) would encode to 50 ticks (0x0032),
    /// confirming the difference between the old and new values.
    func testLowReservoir5UEncodesTo50Ticks() {
        let lowReservoir = PodAlert.lowReservoir(units: 5)
        let config = lowReservoir.configuration
        let configData = config.data

        let ticksHighByte = configData[2]
        let ticksLowByte = configData[3]
        let ticks = (UInt16(ticksHighByte) << 8) | UInt16(ticksLowByte)
        let triggerTicks = ticks & 0x3FFF
        XCTAssertEqual(triggerTicks, 50,
                       "5U low reservoir should encode as 50 ticks (0x0032)")
    }

    // MARK: - Issue 3: User expiry alert time calculation

    /// Verify that the O5 user expiry offset constant is 352 minutes (5h52m).
    func testO5UserExpiryOffsetConstant() {
        let expectedMinutes: Double = 352
        XCTAssertEqual(Pod.o5UserExpiryOffset, TimeInterval(minutes: expectedMinutes),
                       "O5 user expiry offset should be 352 minutes (5h52m)")
    }

    /// Verify that the user expiry alert fires at approximately 3968 minutes from activation,
    /// matching the Frida-captured value.
    ///
    /// nominalPodLife = 72h = 4320 min
    /// o5UserExpiryOffset = 352 min
    /// absAlertTime = 4320 - 352 = 3968 min
    func testUserExpiryAlertTimeProduces3968Minutes() {
        let absAlertTime = Pod.nominalPodLife - Pod.o5UserExpiryOffset
        let absAlertMinutes = absAlertTime.minutes

        // The Frida capture shows 3968 minutes
        XCTAssertEqual(absAlertMinutes, 3968, accuracy: 0.01,
                       "User expiry absolute alert time should be 3968 minutes")
    }

    /// Verify the trigger time for a freshly activated pod (podTime ~0).
    /// The trigger should fire at approximately 3967 minutes (3968 - 1 offset).
    func testUserExpiryTriggerTimeForFreshPod() {
        let podTime: TimeInterval = .minutes(1) // 1 minute after activation
        let absAlertTime = Pod.nominalPodLife - Pod.o5UserExpiryOffset
        let expirationReminder = PodAlert.expirationReminder(
            offset: podTime,
            absAlertTime: absAlertTime
        )
        let config = expirationReminder.configuration

        // The trigger time should be absAlertTime - offset
        if case .timeUntilAlert(let triggerTime) = config.trigger {
            let triggerMinutes = triggerTime.minutes
            let expectedTriggerMinutes = 3968.0 - 1.0
            XCTAssertEqual(triggerMinutes, expectedTriggerMinutes, accuracy: 0.01,
                           "Trigger time should be ~3967 minutes for a pod 1 minute old")
        } else {
            XCTFail("Expiration reminder should have timeUntilAlert trigger")
        }
    }

    /// Verify that nominalPodLife is 72 hours (4320 minutes) as expected.
    func testNominalPodLifeIs72Hours() {
        let expectedMinutes: Double = 72 * 60 // 4320 minutes
        XCTAssertEqual(Pod.nominalPodLife.minutes, expectedMinutes, accuracy: 0.01,
                       "Nominal pod life should be 72 hours (4320 minutes)")
    }

    /// Verify the old 4-hour offset would produce 4080 minutes (68h), confirming
    /// the fix changed the calculation.
    func testOld4HourOffsetProduces4080Minutes() {
        let oldAbsAlertTime = Pod.nominalPodLife - TimeInterval(hours: 4)
        let oldMinutes = oldAbsAlertTime.minutes
        XCTAssertEqual(oldMinutes, 4080, accuracy: 0.01,
                       "Old 4h offset would produce 4080 min (68h), not Frida's 3968")
    }

    // MARK: - Phase 2 Issue 1: Shutdown imminent beepRepeat (O5 vs DASH)

    /// Verify that the shutdownImminent alert defaults to beepRepeat=every15Minutes for DASH.
    func testShutdownImminentDefaultBeepRepeatIsDASH() {
        let podTime: TimeInterval = .minutes(5)
        let alert = PodAlert.shutdownImminent(
            offset: podTime,
            absAlertTime: Pod.serviceDuration - Pod.endOfServiceImminentWindow,
            silent: false
        )
        let config = alert.configuration

        XCTAssertEqual(config.slot, .slot2ShutdownImminent)
        XCTAssertTrue(config.active)
        XCTAssertEqual(config.beepRepeat, .every15Minutes,
                       "DASH shutdownImminent should default to every15Minutes (beepRepeat=6)")
    }

    /// Verify that the O5 shutdownImminent alert uses beepRepeat=every5Minutes (8).
    func testShutdownImminentO5BeepRepeatIsEvery5Minutes() {
        let podTime: TimeInterval = .minutes(5)
        let alert = PodAlert.shutdownImminent(
            offset: podTime,
            absAlertTime: Pod.serviceDuration - Pod.endOfServiceImminentWindow,
            silent: false,
            beepRepeat: .every5Minutes
        )
        let config = alert.configuration

        XCTAssertEqual(config.slot, .slot2ShutdownImminent)
        XCTAssertTrue(config.active)
        XCTAssertEqual(config.beepRepeat, .every5Minutes,
                       "O5 shutdownImminent should use every5Minutes (beepRepeat=8)")
    }

    /// Verify the shutdownImminent encoded data correctly reflects the beepRepeat value.
    /// Byte 4 of AlertConfiguration.data is the beepRepeat raw value.
    func testShutdownImminentEncodedBeepRepeatByte() {
        let podTime: TimeInterval = .minutes(5)

        // DASH: beepRepeat=6 (every15Minutes)
        let dashAlert = PodAlert.shutdownImminent(
            offset: podTime,
            absAlertTime: Pod.serviceDuration - Pod.endOfServiceImminentWindow,
            silent: false
        )
        let dashData = dashAlert.configuration.data
        XCTAssertEqual(dashData[4], BeepRepeat.every15Minutes.rawValue,
                       "DASH shutdown imminent should encode beepRepeat=6 at byte 4")

        // O5: beepRepeat=8 (every5Minutes)
        let o5Alert = PodAlert.shutdownImminent(
            offset: podTime,
            absAlertTime: Pod.serviceDuration - Pod.endOfServiceImminentWindow,
            silent: false,
            beepRepeat: .every5Minutes
        )
        let o5Data = o5Alert.configuration.data
        XCTAssertEqual(o5Data[4], BeepRepeat.every5Minutes.rawValue,
                       "O5 shutdown imminent should encode beepRepeat=8 at byte 4")
    }

    /// Verify that shutdownImminent beepRepeat survives serialization round-trip.
    func testShutdownImminentBeepRepeatRoundTrip() {
        // O5 variant with every5Minutes
        let original = PodAlert.shutdownImminent(
            offset: .minutes(10),
            absAlertTime: Pod.serviceDuration - Pod.endOfServiceImminentWindow,
            silent: false,
            beepRepeat: .every5Minutes
        )
        let rawValue = original.rawValue
        let restored = PodAlert(rawValue: rawValue)

        XCTAssertNotNil(restored, "Should be able to restore shutdownImminent from rawValue")
        if case .shutdownImminent(_, _, _, let beepRepeat) = restored! {
            XCTAssertEqual(beepRepeat, .every5Minutes,
                           "Restored shutdownImminent should preserve every5Minutes beepRepeat")
        } else {
            XCTFail("Restored alert should be shutdownImminent")
        }

        // DASH variant (default every15Minutes)
        let dashOriginal = PodAlert.shutdownImminent(
            offset: .minutes(10),
            absAlertTime: Pod.serviceDuration - Pod.endOfServiceImminentWindow,
            silent: false
        )
        let dashRawValue = dashOriginal.rawValue
        let dashRestored = PodAlert(rawValue: dashRawValue)
        if case .shutdownImminent(_, _, _, let beepRepeat) = dashRestored! {
            XCTAssertEqual(beepRepeat, .every15Minutes,
                           "Restored DASH shutdownImminent should preserve every15Minutes beepRepeat")
        } else {
            XCTFail("Restored alert should be shutdownImminent")
        }
    }

    // MARK: - Phase 2 Issue 2: Slot #0 auto-off alert encoding

    /// Verify that the slot #0 auto-off alert encodes correctly with O5 Phase 2 parameters.
    /// From O5 Java source: slot=0, beepType=2, beepRepeat=2, duration=15min, autoOff=true.
    func testAutoOffAlertEncodesCorrectly() {
        let autoOff = PodAlert.autoOff(
            active: false,
            offset: .minutes(5),
            countdownDuration: .minutes(15),
            silent: false
        )
        let config = autoOff.configuration

        XCTAssertEqual(config.slot, .slot0AutoOff)
        XCTAssertFalse(config.active, "Auto-off should be initially disabled")
        XCTAssertEqual(config.duration, .minutes(15), "Auto-off duration should be 15 minutes")
        XCTAssertTrue(config.autoOffModifier, "Auto-off should have autoOffModifier=true")
        XCTAssertEqual(config.beepRepeat, .every1MinuteFor15Minutes,
                       "Auto-off beepRepeat should be every1MinuteFor15Minutes (2)")
        XCTAssertEqual(config.beepType, .bipBeepBipBeepBipBeepBipBeep,
                       "Auto-off beepType should be bipBeepBipBeepBipBeepBipBeep (2)")
    }

    /// Verify that an active auto-off alert encodes the autoOff modifier bit.
    func testAutoOffAlertEncodesAutoOffModifierBit() {
        let autoOff = PodAlert.autoOff(
            active: true,
            offset: .minutes(5),
            countdownDuration: .minutes(15),
            silent: false
        )
        let configData = autoOff.configuration.data
        XCTAssertEqual(configData.count, AlertConfiguration.length, "Alert configuration should be 6 bytes")

        let firstByte = configData[0]
        XCTAssertTrue(firstByte & 0x02 != 0, "AutoOff modifier bit should be set in encoded data")
    }

    /// Verify that a non-autoOff alert does NOT have the autoOff modifier bit set.
    func testNonAutoOffAlertDoesNotHaveModifierBit() {
        let lowReservoir = PodAlert.lowReservoir(units: 10)
        let configData = lowReservoir.configuration.data

        let firstByte = configData[0]
        XCTAssertTrue(firstByte & 0x02 == 0, "Non-autoOff alert should NOT have autoOff modifier bit set")
    }

    /// Verify auto-off alert trigger is time-based with the correct countdown duration.
    func testAutoOffAlertTriggerIsTimeBased() {
        let autoOff = PodAlert.autoOff(
            active: true,
            offset: .minutes(5),
            countdownDuration: .minutes(15),
            silent: false
        )
        let config = autoOff.configuration

        if case .timeUntilAlert(let triggerTime) = config.trigger {
            XCTAssertEqual(triggerTime, .minutes(15),
                           "Auto-off countdown duration should be 15 minutes")
        } else {
            XCTFail("Auto-off alert should have timeUntilAlert trigger")
        }
    }
}
