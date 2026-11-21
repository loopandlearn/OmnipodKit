//
//  ReservoirEstimateTests.swift
//  OmniTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
@testable import OmnipodKit

class ReservoirEstimateTests: XCTestCase {

    private let aboveThreshold = Pod.reservoirLevelAboveThresholdMagicNumber

    // MARK: - ReservoirEstimate

    func testApproximatesFillAmountMinusInsulinDispensed() {
        let estimate = ReservoirEstimate.approximateUnitsRemaining(fillAmount: 200, reservoirLevel: aboveThreshold, insulinDispensed: 4.95)
        XCTAssertEqual(estimate, 195)
    }

    func testRoundsDownToWholeUnits() {
        let estimate = ReservoirEstimate.approximateUnitsRemaining(fillAmount: 150, reservoirLevel: aboveThreshold, insulinDispensed: 20.05)
        XCTAssertEqual(estimate, 129)
    }

    func testFloatingPointErrorDoesNotDropAUnit() {
        // 30.000000000000004 would otherwise leave 69.999... and round down to 69
        let estimate = ReservoirEstimate.approximateUnitsRemaining(fillAmount: 100, reservoirLevel: aboveThreshold, insulinDispensed: 30.0.nextUp)
        XCTAssertEqual(estimate, 70)
    }

    func testNoApproximationWithoutFillAmount() {
        XCTAssertNil(ReservoirEstimate.approximateUnitsRemaining(fillAmount: nil, reservoirLevel: aboveThreshold, insulinDispensed: 10))
    }

    func testNoApproximationBeforeDeliveryIsReported() {
        XCTAssertNil(ReservoirEstimate.approximateUnitsRemaining(fillAmount: 200, reservoirLevel: nil, insulinDispensed: nil))
    }

    func testPodMeasurementWinsAtOrBelowFiftyUnits() {
        for level in [50.0, 49.95, 12.3, 0] {
            XCTAssertNil(ReservoirEstimate.approximateUnitsRemaining(fillAmount: 200, reservoirLevel: level, insulinDispensed: 10), "level \(level)")
        }
    }

    func testFallsBackWhenApproximationContradictsPod() {
        // filled 200 U, so these leave 50 U or less, yet the pod still reads 50+ U
        for dispensed in [150.0, 160.0, 199.0] {
            XCTAssertNil(ReservoirEstimate.approximateUnitsRemaining(fillAmount: 200, reservoirLevel: aboveThreshold, insulinDispensed: dispensed), "dispensed \(dispensed)")
        }
    }

    func testLowestApproximationIsFiftyOneUnits() {
        let estimate = ReservoirEstimate.approximateUnitsRemaining(fillAmount: 200, reservoirLevel: aboveThreshold, insulinDispensed: 149)
        XCTAssertEqual(estimate, 51)
    }

    func testAllowedFillAmounts() {
        XCTAssertEqual(ReservoirEstimate.allowedFillAmounts.first, 85)
        XCTAssertEqual(ReservoirEstimate.allowedFillAmounts.last, 200)
        XCTAssertEqual(ReservoirEstimate.allowedFillAmounts.count, 24)
    }

    // MARK: - PodState

    func testTotalInsulinDispensedIsNilBeforeFirstStatus() {
        XCTAssertNil(makePodState().totalInsulinDispensed)
    }

    func testTotalInsulinDispensedIncludesSetupUnits() {
        var podState = makePodState()
        podState.updateFromStatusResponse(statusResponse(insulinDelivered: 42.5))

        // delivered excludes the setup units, the total dispensed counts them
        XCTAssertEqual(42.5 - 3.15, podState.lastInsulinMeasurements!.delivered, accuracy: 0.001)
        XCTAssertEqual(42.5, podState.totalInsulinDispensed!, accuracy: 0.001)
    }

    // MARK: - OmniPumpManagerState

    func testStateApproximatesFromCurrentPodFillAmount() {
        var podState = makePodState()
        podState.setupProgress = .completed
        podState.updateFromStatusResponse(statusResponse(insulinDelivered: 54.95))

        var state = makeState(podState: podState)
        XCTAssertNil(state.approximateReservoirLevel)

        state.reservoirFillAmount = 180
        XCTAssertEqual(state.approximateReservoirLevel, 125)

        // the default only applies to the next pod
        state.reservoirFillAmount = nil
        state.defaultReservoirFillAmount = 200
        XCTAssertNil(state.approximateReservoirLevel)
    }

    func testStateDoesNotApproximateDuringPodSetup() {
        var podState = makePodState()
        podState.updateFromStatusResponse(statusResponse(insulinDelivered: 2.6))

        var state = makeState(podState: podState)
        state.reservoirFillAmount = 200
        XCTAssertNil(state.approximateReservoirLevel)
    }

    func testStateDoesNotApproximateForFaultedPod() throws {
        var podState = makePodState()
        podState.setupProgress = .completed
        podState.updateFromStatusResponse(statusResponse(insulinDelivered: 54.95))
        podState.fault = try DetailedStatus(encodedData: Data(hexadecimalString: "020f0000000900345c000103ff0001000005ae056029")!)

        var state = makeState(podState: podState)
        state.reservoirFillAmount = 180
        XCTAssertNil(state.approximateReservoirLevel)
    }

    func testFillAmountsArePersisted() {
        var state = makeState(podState: nil)
        state.reservoirFillAmount = 150
        state.defaultReservoirFillAmount = 180

        let restored = OmniPumpManagerState(rawValue: state.rawValue)
        XCTAssertEqual(restored?.reservoirFillAmount, 150)
        XCTAssertEqual(restored?.defaultReservoirFillAmount, 180)

        let restoredUnset = OmniPumpManagerState(rawValue: makeState(podState: nil).rawValue)
        XCTAssertNotNil(restoredUnset)
        XCTAssertNil(restoredUnset?.reservoirFillAmount)
        XCTAssertNil(restoredUnset?.defaultReservoirFillAmount)
    }

    // MARK: - Helpers

    private func makePodState() -> PodState {
        return PodState(address: 0x17f4f6, firmwareVersion: "4.10.0", iFirmwareVersion: "1.4.0", lotNo: 43620, lotSeq: 560313, insulinType: .novolog, podType: dashType, setupUnitsDelivered: 3.15)
    }

    private func statusResponse(insulinDelivered: Double) -> StatusResponse {
        return StatusResponse(
            deliveryStatus: .scheduledBasal,
            podProgressStatus: .aboveFiftyUnits,
            timeActive: .hours(20),
            reservoirLevel: aboveThreshold,
            insulinDelivered: insulinDelivered,
            bolusNotDelivered: 0,
            lastProgrammingMessageSeqNum: 5,
            alerts: AlertSet(slots: []))
    }

    private func makeState(podState: PodState?) -> OmniPumpManagerState {
        let basalSchedule = BasalSchedule(entries: [BasalScheduleEntry(rate: 1.0, startTime: 0, podType: dashType)])
        return OmniPumpManagerState(
            isOnboarded: true,
            podState: podState,
            timeZone: TimeZone(identifier: "America/Los_Angeles")!,
            basalSchedule: basalSchedule,
            maxBasalRateUnitsPerHour: 5,
            maxBolusUnits: 10,
            insulinType: .novolog,
            podType: dashType,
            podKeepAlive: .disabled
        )
    }
}
