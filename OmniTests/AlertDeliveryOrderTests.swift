//
//  AlertDeliveryOrderTests.swift
//  OmniTests
//

import XCTest
import LoopKit
import RileyLinkBLEKit
@testable import OmnipodKit

class AlertDeliveryOrderTests: XCTestCase {
    @MainActor
    func testIssueAndRetractReachDelegateInCallOrder() async throws {
        let state = OmniPumpManagerState(
            isOnboarded: true,
            podState: nil,
            timeZone: .currentFixed,
            basalSchedule: BasalSchedule(entries: [BasalScheduleEntry(rate: 1.0, startTime: 0, podType: erosType)]),
            maxBasalRateUnitsPerHour: 3,
            maxBolusUnits: 10,
            insulinType: .novolog,
            podType: erosType,
            podKeepAlive: .disabled
        )
        let manager = OmniPumpManager(state: state, rileyLinkDeviceProvider: StubRileyLinkDeviceProvider())
        let delegate = RecordingPumpManagerDelegate()
        manager.pumpManagerDelegate = delegate

        let expected = await Task.detached { () -> [String] in
            let alerts: [PumpManagerAlert] = [.suspendEnded(triggeringSlot: nil), .podExpiring(triggeringSlot: nil), .timeOffsetChangeDetected]
            var expected: [String] = []
            for i in 0..<300 {
                let alert = alerts[i % alerts.count]
                let identifiers = alert.isRepeating ? [alert.alertIdentifier, alert.repeatingAlertIdentifier] : [alert.alertIdentifier]
                if i % 2 == 0 {
                    manager.issueAlert(alert: alert)
                    expected += identifiers.map { "issue \($0)" }
                } else {
                    manager.retractAlert(alert: alert)
                    expected += identifiers.map { "retract \($0)" }
                }
            }
            return expected
        }.value

        let deadline = Date().addingTimeInterval(10)
        while delegate.recorded.count < expected.count, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(delegate.recorded, expected)
    }
}

private class RecordingPumpManagerDelegate: PumpManagerDelegate {
    private(set) var recorded: [String] = []

    func issueAlert(_ alert: Alert) async {
        recorded.append("issue \(alert.identifier.alertIdentifier)")
    }

    func retractAlert(identifier: Alert.Identifier) async {
        recorded.append("retract \(identifier.alertIdentifier)")
    }

    func doesIssuedAlertExist(identifier: Alert.Identifier) async throws -> Bool { false }
    func lookupAllUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
    func recordRetractedAlert(_ alert: Alert, at date: Date) async throws {}

    func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {}

    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {}
    func pumpManagerBLEHeartbeatDidFire(_ pumpManager: PumpManager) {}
    func pumpManagerMustProvideBLEHeartbeat(_ pumpManager: PumpManager) -> Bool { false }
    func pumpManagerWillDeactivate(_ pumpManager: PumpManager) {}
    func pumpManagerPumpWasReplaced(_ pumpManager: PumpManager) {}
    func pumpManager(_ pumpManager: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents pumpRecordsBasalProfileStartEvents: Bool) {}
    func pumpManager(_ pumpManager: PumpManager, didError error: PumpManagerError) {}
    func pumpManager(_ pumpManager: PumpManager, hasNewPumpEvents events: [NewPumpEvent], lastReconciliation: Date?, replacePendingEvents: Bool, completion: @escaping (_ error: Error?) -> Void) { completion(nil) }
    func pumpManager(_ pumpManager: PumpManager, didReadReservoirValue units: Double, at date: Date, completion: @escaping (_ result: Result<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool), Error>) -> Void) {}
    func pumpManager(_ pumpManager: PumpManager, didAdjustPumpClockBy adjustment: TimeInterval) {}
    func pumpManagerDidUpdateState(_ pumpManager: PumpManager) {}
    func pumpManager(_ pumpManager: PumpManager, didRequestBasalRateScheduleChange basalRateSchedule: BasalRateSchedule, completion: @escaping (Error?) -> Void) { completion(nil) }
    func startDateToFilterNewPumpEvents(for manager: PumpManager) -> Date { .distantPast }
    var detectedSystemTimeOffset: TimeInterval { 0 }
    var automaticDosingEnabled: Bool { false }
    var automatedTreatmentState: AutomatedTreatmentState? { nil }
}

private class StubRileyLinkDeviceProvider: RileyLinkDeviceProvider {
    weak var delegate: RileyLinkDeviceProviderDelegate?
    var idleListeningState: RileyLinkBluetoothDevice.IdleListeningState = .disabled
    var idleListeningEnabled: Bool { false }
    var timerTickEnabled = false
    var connectingCount: Int { 0 }

    func deprioritize(_ device: RileyLinkDevice, completion: (() -> Void)?) { completion?() }
    func assertIdleListening(forcingRestart: Bool) {}
    func getDevices(_ completion: @escaping (_ devices: [RileyLinkDevice]) -> Void) { completion([]) }
    func connect(_ device: RileyLinkDevice) {}
    func disconnect(_ device: RileyLinkDevice) {}
    func setScanningEnabled(_ enabled: Bool) {}
    func shouldConnect(to deviceID: String) -> Bool { false }

    var debugDescription: String { "StubRileyLinkDeviceProvider" }
}
