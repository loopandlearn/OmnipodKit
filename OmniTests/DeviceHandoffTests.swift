//
//  DeviceHandoffTests.swift
//  OmniTests
//
//  The hand-off contract as OmnipodKit keeps it: what an export leaves out, what an adopter
//  inherits, what a released controller drops when it takes control back, and that delivery
//  this manager did not command is never booked under a new identity.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
import LoopKit
@testable import OmnipodKit

final class DeviceHandoffTests: XCTestCase {

    let address: UInt32 = 0x17A6219A
    let ltk = Data(hexadecimalString: "fedcba98765432100123456789abcdef")!
    let bolusStart = Date(timeIntervalSinceNow: -30)
    let measuredAt = Date(timeIntervalSinceNow: -60)
    let watchHandle = "0B1D2C3E-0000-4000-8000-00000000B002"

    /// What an adopter that met this pod before saved: its own handle for it.
    var watchLocalState: [String: Any] { ["podAddress": address, "bleIdentifier": watchHandle] }

    /// A DASH pod mid-session: a handle, live session keys, a pending command and a bolus running.
    func makePodState() -> PodState {
        var pod = PodState(address: address, firmwareVersion: "4.10.0", iFirmwareVersion: "1.1.0",
                           lotNo: 43620, lotSeq: 560313, insulinType: .novolog, podType: dashType,
                           bleMessageTransportState: BleMessageTransportState(
                               ck: Data(repeating: 0xAB, count: 16), noncePrefix: Data(repeating: 0xCD, count: 8),
                               eapSeq: 41, msgSeq: 7, nonceSeq: 9, messageNumber: 3),
                           ltk: ltk, bleIdentifier: "0B1D2C3E-0000-4000-8000-00000000A001")
        pod.setupProgress = .completed
        pod.unfinalizedBolus = UnfinalizedDose(decisionId: nil, bolusAmount: 2.0, startTime: bolusStart,
                                               scheduledCertainty: .certain, insulinType: .novolog)
        pod.unacknowledgedCommand = .stopProgram(.tempBasal, 3, Date(), false)
        pod.lastInsulinMeasurements = PodInsulinMeasurements(insulinDelivered: 12.35, reservoirLevel: nil,
                                                             validTime: measuredAt)
        return pod
    }

    /// The manager's state. A manager itself cannot be built here: its BLE central needs a host
    /// app with the bluetooth-central background mode.
    func makeState(released: Bool = false, pod: PodState? = nil) -> OmniPumpManagerState {
        var state = OmniPumpManagerState(isOnboarded: true, podState: pod ?? makePodState(), timeZone: .current,
                                         basalSchedule: BasalSchedule(entries: [BasalScheduleEntry(rate: 1.0, startTime: 0, podType: dashType)]),
                                         maxBasalRateUnitsPerHour: 3, maxBolusUnits: 5, insulinType: .novolog,
                                         podType: dashType, podKeepAlive: .disabled,
                                         controllerId: 0x1234_5678, podId: 0x1234_5679)
        state.podConnectionReleased = released
        return state
    }

    func export(_ state: OmniPumpManagerState) -> SharedDeviceConfiguration {
        state.sharedConfiguration(managerIdentifier: "Omni")
    }

    func adopt(_ configuration: SharedDeviceConfiguration, localState: [String: Any]? = nil) throws -> OmniPumpManagerState {
        let raw = try XCTUnwrap(OmniPumpManager.adoptedRawState(from: configuration, localState: localState))
        return try XCTUnwrap(OmniPumpManagerState(rawValue: raw))
    }

    func exportedPod(_ configuration: SharedDeviceConfiguration) -> [String: Any]? {
        configuration.state["podState"] as? [String: Any]
    }

    // MARK: - Export

    func testExportLeavesOutLocalStateSessionMaterialAndThePendingCommand() {
        var state = makeState(released: true)
        state.configuredByAnotherController = true
        let configuration = export(state)
        let pod = exportedPod(configuration)
        let transport = pod?["bleMessageTransportState"] as? [String: Any]

        XCTAssertNil(pod?["bleIdentifier"], "the handle is this controller's")
        XCTAssertNotNil(state.localState, "it stays behind in this controller's local state")
        XCTAssertEqual(configuration.state["podConnectionReleased"] as? Bool, false, "the released flag is this controller's")
        XCTAssertEqual(configuration.state["configuredByAnotherController"] as? Bool, false)
        XCTAssertNil(pod?["unacknowledgedCommand"], "no pending command travels")
        XCTAssertEqual(transport?["ck"] as? String, "", "no session key travels")
        XCTAssertEqual(transport?["noncePrefix"] as? String, "", "no nonce prefix travels")
        XCTAssertEqual(transport?["nonceSeq"] as? Int, 0)
        XCTAssertEqual(transport?["msgSeq"] as? Int, 0)
    }

    func testExportKeepsTheFactsAboutThePod() {
        let configuration = export(makeState())
        let pod = exportedPod(configuration)
        let transport = pod?["bleMessageTransportState"] as? [String: Any]

        XCTAssertEqual(configuration.managerIdentifier, "Omni")
        XCTAssertEqual(pod?["address"] as? UInt32, address)
        XCTAssertEqual(pod?["ltk"] as? String, ltk.hexadecimalString)
        XCTAssertEqual(transport?["eapSeq"] as? Int, 41, "the pod resyncs the EAP sequence; it still travels")
        XCTAssertEqual(transport?["messageNumber"] as? Int, 3)
        XCTAssertNotNil(pod?["unfinalizedBolus"], "in-flight doses travel with the export")
        XCTAssertEqual(configuration.deliveredUnits, 12.35)
        XCTAssertEqual(configuration.asOf, measuredAt, "the total is as of its reading")
    }

    // MARK: - Adopt

    func testAdoptRoundTripsIdentityKeysAndInFlightDoses() throws {
        let exporter = makeState()
        let configuration = try XCTUnwrap(SharedDeviceConfiguration(rawValue: export(exporter).rawValue))

        let adopter = try adopt(configuration)
        let pod = try XCTUnwrap(adopter.podState)

        XCTAssertTrue(adopter.configuredByAnotherController)
        XCTAssertFalse(adopter.podConnectionReleased)
        XCTAssertEqual(pod.address, address)
        XCTAssertEqual(pod.ltk, ltk)
        XCTAssertEqual(adopter.controllerId, exporter.controllerId)
        XCTAssertEqual(adopter.podId, exporter.podId)
        XCTAssertNil(pod.unacknowledgedCommand)
        XCTAssertNil(pod.bleMessageTransportState.ck.flatMap { $0.isEmpty ? nil : $0 }, "no session falls through from the exporter")

        // The same dose reported under the same identity, from either manager.
        let theirs = NewPumpEvent(try XCTUnwrap(exporter.podState?.unfinalizedBolus))
        let ours = NewPumpEvent(try XCTUnwrap(pod.unfinalizedBolus))
        XCTAssertEqual(ours.raw, theirs.raw)
        XCTAssertEqual(ours.dose?.syncIdentifier, theirs.dose?.syncIdentifier)
    }

    func testAnAdopterThatNeverMetThePodSearches() throws {
        let adopter = try adopt(export(makeState()))
        XCTAssertNil(adopter.podState?.bleIdentifier, "the exporter's handle means nothing here")
    }

    func testAnAdopterThatMetThePodUsesItsOwnHandle() throws {
        let adopter = try adopt(export(makeState()), localState: watchLocalState)
        XCTAssertEqual(adopter.podState?.bleIdentifier, watchHandle)
        XCTAssertEqual(adopter.localState?["bleIdentifier"] as? String, watchHandle, "and hands it back to the host")
    }

    func testAHandleForAnotherPodIsIgnored() throws {
        let otherPod: [String: Any] = ["podAddress": address &+ 1, "bleIdentifier": watchHandle]
        XCTAssertNil(try adopt(export(makeState()), localState: otherPod).podState?.bleIdentifier)
        XCTAssertTrue(OmniPumpManager.takeControlNeedsSearch(adopting: export(makeState()), localState: otherPod))
    }

    func testTheLocalStateSurvivesAPropertyListRoundTrip() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: watchLocalState, format: .binary, options: 0)
        let saved = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(try adopt(export(makeState()), localState: saved).podState?.bleIdentifier, watchHandle)
    }

    /// Asked of a standing copy before Start: only a pod this controller holds no handle for.
    func testAnExportSaysWhetherAdoptingItWillSearch() {
        XCTAssertTrue(OmniPumpManager.takeControlNeedsSearch(adopting: export(makeState()), localState: nil))
        XCTAssertFalse(OmniPumpManager.takeControlNeedsSearch(adopting: export(makeState()), localState: watchLocalState))
        XCTAssertFalse(OmniPumpManager.takeControlNeedsSearch(
            adopting: SharedDeviceConfiguration(managerIdentifier: "Omni", asOf: Date(), state: [:]), localState: nil))
    }

    /// What `releaseControl()` does with an unproven handle, through the pod comms as it does it.
    func testAHandleThatNeverConnectedIsDroppedAtRelease() throws {
        var adopter = try adopt(export(makeState()), localState: watchLocalState)
        let podComms = PodComms(podState: adopter.podState, podType: dashType)
        XCTAssertEqual(ConnectClock.adoptedHandleThatNeverConnected(), watchHandle)
        podComms.forgetHandle()
        adopter.updatePodStateFromPodComms(podComms.podState)
        XCTAssertNil(adopter.localState, "the host saves nil, so the next adopt searches")
        XCTAssertTrue(OmniPumpManager.takeControlNeedsSearch(adopting: export(makeState()), localState: adopter.localState))
    }

    func testAHandleThatConnectedIsKept() throws {
        _ = try adopt(export(makeState()), localState: watchLocalState)
        ConnectClock.noteConnect(appState: "fg")
        XCTAssertNil(ConnectClock.adoptedHandleThatNeverConnected())
    }

    func testAHandleFoundBySearchingIsNotDroppedAtRelease() throws {
        _ = try adopt(export(makeState()))
        XCTAssertNil(ConnectClock.adoptedHandleThatNeverConnected(), "only a handle the adopt attached is on trial")
    }

    func testAnAdopterBooksNoUntrackedBolusAsItsOwn() throws {
        var pod = makePodState()
        pod.unfinalizedBolus = nil
        var adopted = try XCTUnwrap(try adopt(export(makeState(pod: pod))).podState)

        adopted.updateFromStatusResponse(status(.bolusInProgress, bolusNotDelivered: 1.5))

        XCTAssertNil(adopted.unfinalizedBolus, "a bolus the adopter did not command gets no identity of its own")
    }

    // MARK: - Release and take

    func testReleaseHandsInFlightDosesToTheOtherController() {
        var state = makeState()
        state.releaseControl()

        XCTAssertTrue(state.podConnectionReleased)
        XCTAssertTrue(state.inFlightDosesInheritedAway)
        XCTAssertNotNil(state.podState?.unfinalizedBolus, "kept until take: nothing reports while released")
    }

    func testTakeDropsInFlightCopiesAndResolvesFromThePodsStatus() throws {
        var state = makeState()
        state.releaseControl()
        var pod = try XCTUnwrap(state.podState)
        pod.resolveAfterForeignControl(dropInFlight: state.inFlightDosesInheritedAway)

        XCTAssertNil(pod.unfinalizedBolus, "the frozen copy is dead")
        XCTAssertNil(pod.lastDeliveryStatusReceived, "read before writing")
        XCTAssertTrue(pod.untrackedDeliveryIsForeign)

        // The pod still bolusing (the other controller's bolus) books nothing here.
        pod.updateFromStatusResponse(status(.bolusInProgress, bolusNotDelivered: 0.8))
        XCTAssertNil(pod.unfinalizedBolus)
        XCTAssertTrue(pod.finalizedDoses.isEmpty, "nor is the dropped copy finalized from the frozen view")

        // Once the pod shows no bolus, this controller books its own again.
        pod.updateFromStatusResponse(status(.scheduledBasal))
        XCTAssertFalse(pod.untrackedDeliveryIsForeign)
    }

    func testAReleaseWithNothingInFlightKeepsTheFinishedRecords() throws {
        var pod = makePodState()
        pod.unfinalizedBolus = nil
        pod.finalizedDoses = [UnfinalizedDose(decisionId: nil, bolusAmount: 1.0, startTime: Date(timeIntervalSinceNow: -3600),
                                              scheduledCertainty: .certain, insulinType: .novolog)]
        var state = makeState(pod: pod)
        state.releaseControl()
        XCTAssertFalse(state.inFlightDosesInheritedAway)

        pod.resolveAfterForeignControl(dropInFlight: state.inFlightDosesInheritedAway)
        XCTAssertEqual(pod.finalizedDoses.count, 1, "finished doses are still this controller's to report")
    }

    func testTheHandOffFlagsSurviveARelaunch() throws {
        var state = makeState()
        state.releaseControl()
        state.configuredByAnotherController = true
        var pod = try XCTUnwrap(state.podState)
        pod.untrackedDeliveryIsForeign = true
        state.updatePodStateFromPodComms(pod)

        let relaunched = try XCTUnwrap(OmniPumpManagerState(rawValue: state.rawValue))
        XCTAssertTrue(relaunched.podConnectionReleased)
        XCTAssertTrue(relaunched.inFlightDosesInheritedAway)
        XCTAssertTrue(relaunched.configuredByAnotherController)
        XCTAssertEqual(relaunched.podState?.untrackedDeliveryIsForeign, true)
    }

    // MARK: - Untracked delivery (stock behaviour unchanged)

    func testAnUntrackedBolusIsStillBookedWhenNoOtherControllerIsInPlay() {
        var pod = makePodState()
        pod.unfinalizedBolus = nil
        pod.updateFromStatusResponse(status(.bolusInProgress, bolusNotDelivered: 1.5))
        XCTAssertEqual(pod.unfinalizedBolus?.units, 1.5)
    }

    // MARK: - Key and handle

    func testTheKeyDecodesWithoutAHandle() throws {
        var raw = makePodState().rawValue
        raw.removeValue(forKey: "bleIdentifier")
        let pod = try XCTUnwrap(PodState(rawValue: raw))
        XCTAssertEqual(pod.ltk, ltk, "dropping the per-device handle must not drop the pod's key")
        XCTAssertNil(pod.bleIdentifier)
    }

    func testTheAdoptersKeyComesThroughAnExportWithNoHandle() throws {
        XCTAssertEqual(try adopt(export(makeState())).podState?.ltk, ltk)
    }

    // MARK: - Wedge signature

    func testWedgeIsACode11DuringTheAttempt() {
        let start = Date()
        XCTAssertTrue(ConnectClock.isWedge(lastCode11At: start.addingTimeInterval(5),
                                           lastConnectAt: start.addingTimeInterval(2), since: start))
        XCTAssertFalse(ConnectClock.isWedge(lastCode11At: start.addingTimeInterval(-60),
                                            lastConnectAt: start.addingTimeInterval(2), since: start))
    }

    func testWedgeIsNoConnectAtAllDuringTheAttempt() {
        let start = Date()
        XCTAssertTrue(ConnectClock.isWedge(lastCode11At: nil, lastConnectAt: nil, since: start))
        XCTAssertTrue(ConnectClock.isWedge(lastCode11At: nil, lastConnectAt: start.addingTimeInterval(-1), since: start))
        XCTAssertFalse(ConnectClock.isWedge(lastCode11At: nil, lastConnectAt: start.addingTimeInterval(3), since: start))
    }

    // MARK: - Fault text for the host

    func faulted(code: UInt8) throws -> PodState {
        var pod = makePodState()
        let hex = String(format: "020d000000060000%02x000003ff0000000003a20386a0", code)
        pod.fault = try DetailedStatus(encodedData: Data(hexadecimalString: hex)!)
        return pod
    }

    func testTheFaultTextIsTheFaultAlarmsTitle() throws {
        XCTAssertNil(makePodState().localizedFaultDescription, "a working pod has no fault text")
        XCTAssertEqual(try faulted(code: 0x14).localizedFaultDescription, "Occlusion Detected")
        XCTAssertEqual(try faulted(code: 0x18).localizedFaultDescription, "Empty Reservoir")
        XCTAssertEqual(try faulted(code: 0x1C).localizedFaultDescription, "Pod Expired")
        XCTAssertEqual(try faulted(code: 0x8F).localizedFaultDescription, "Critical Pod Fault 143",
                       "the fault code the pod reported")
    }

    func testAFaultWithNoCodeStillHasText() {
        var pod = makePodState()
        pod.setupProgress = .activationTimeout
        XCTAssertEqual(pod.localizedFaultDescription, "Pod Error")
    }

    // MARK: -

    func status(_ deliveryStatus: DeliveryStatus, bolusNotDelivered: Double = 0) -> StatusResponse {
        StatusResponse(deliveryStatus: deliveryStatus, podProgressStatus: .aboveFiftyUnits, timeActive: .hours(10),
                       reservoirLevel: Pod.reservoirLevelAboveThresholdMagicNumber, insulinDelivered: 13,
                       bolusNotDelivered: bolusNotDelivered, lastProgrammingMessageSeqNum: 5, alerts: AlertSet(slots: []))
    }
}
