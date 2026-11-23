//
//  PodStateTests.swift
//  OmniTests
//
//  From OmniBLE/OmniBLETests/PodStateTests.swift
//  Created by Pete Schwamb on 10/13/17.
//  Copyright © 2017 Pete Schwamb. All rights reserved.
//

import XCTest
@testable import OmnipodKit

class PodStateTests: XCTestCase {
    
    func testErrorResponse() {
        do {
            let errorResponse = try ErrorResponse(encodedData: Data(hexadecimalString: "0603070008019a")!)

            switch errorResponse.errorResponseType {
            case .nonretryableError(let errorCode, let faultEventCode, let podProgress):
                XCTAssertEqual(7, errorCode)
                XCTAssertEqual(.noFaults, faultEventCode.faultType)
                XCTAssertEqual(.aboveFiftyUnits, podProgress)
                break
            default:
                XCTFail("Unexpected bad nonce response")
                break
            }
        } catch (let error) {
            XCTFail("message decoding threw error: \(error)")
        }
    }

    private func pod(lotSeq: UInt32, activatedAt: Date) -> PodState {
        var pod = PodState(address: 0x17A6219A, firmwareVersion: "4.10.0", iFirmwareVersion: "1.1.0",
                           lotNo: 139173265, lotSeq: lotSeq, insulinType: .novolog, podType: dashType)
        pod.setupProgress = .completed
        pod.activatedAt = activatedAt
        pod.expiresAt = activatedAt + Pod.nominalPodLife
        return pod
    }

    func testComponentReplacementAfterAnOcclusion() throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var previous = pod(lotSeq: 1, activatedAt: start)
        previous.deliveryStoppedAt = start + .hours(40)
        previous.fault = try DetailedStatus(encodedData: Data(hexadecimalString: "020d0000000407eb140e0c03ff0e1400002817080000")!)
        previous.lastInsulinMeasurements = PodInsulinMeasurements(insulinDelivered: 100, reservoirLevel: 23.5, validTime: start + .hours(40))
        let new = pod(lotSeq: 2, activatedAt: start + .hours(41))

        let replacement = OmniPumpManager.componentReplacement(newPod: new, previousPod: previous)

        XCTAssertEqual(replacement.previous, .init(stopDate: start + .hours(40), remainingUnits: 23.5, reason: .occlusion(code: "0x14")))
        XCTAssertEqual(replacement.expirationDate, start + .hours(41) + Pod.nominalPodLife)
        XCTAssertEqual(replacement.componentIdentifier, "139173265-2")
        XCTAssertEqual(replacement.primes, [.init(target: .tubing, volume: Pod.primeUnits),
                                           .init(target: .cannula, volume: Pod.cannulaInsertionUnits + Pod.cannulaInsertionUnitsExtra)])
    }

    func testComponentReplacementPrimeFromTheSetupUnitsDelivered() {
        var new = pod(lotSeq: 2, activatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        new.setupUnitsDelivered = 2.95
        let cannulaUnits = Pod.cannulaInsertionUnits + Pod.cannulaInsertionUnitsExtra
        let primes = OmniPumpManager.componentReplacement(newPod: new, previousPod: nil).primes
        XCTAssertEqual(primes[0].target, .tubing)
        XCTAssertEqual(primes[0].volume, 2.95 - cannulaUnits, accuracy: 0.001)
        XCTAssertEqual(primes[1], .init(target: .cannula, volume: cannulaUnits))
    }

    func testPreviousComponentAfterAFault() throws {
        var previous = pod(lotSeq: 1, activatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        previous.fault = try DetailedStatus(encodedData: Data(hexadecimalString: "020f0000000900345c000103ff0001000005ae056029")!)
        XCTAssertEqual(OmniPumpManager.previousComponent(for: previous).reason, .fault(code: "0x5C"))
    }

    func testPreviousComponentAfterTheMaximumPodLife() throws {
        var previous = pod(lotSeq: 1, activatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        previous.fault = try DetailedStatus(encodedData: Data(hexadecimalString: "020f0000000900341c000103ff0001000005ae056029")!)
        XCTAssertEqual(previous.fault?.faultEventCode.faultType, .exceededMaximumPodLife80Hrs)
        XCTAssertEqual(OmniPumpManager.previousComponent(for: previous).reason, .expired)
    }

    func testPreviousComponentReasonFromTheStopTime() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var early = pod(lotSeq: 1, activatedAt: start)
        early.deliveryStoppedAt = start + .hours(50)
        var late = pod(lotSeq: 1, activatedAt: start)
        late.deliveryStoppedAt = start + Pod.nominalPodLife + .hours(2)

        XCTAssertEqual(OmniPumpManager.previousComponent(for: early).reason, .userInitiated)
        XCTAssertEqual(OmniPumpManager.previousComponent(for: late).reason, .expired)
    }

    func testPreviousPodAbandonedDuringSetupIsNotReported() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var abandoned = PodState(address: 0x17A6219A, firmwareVersion: "4.10.0", iFirmwareVersion: "1.1.0",
                                 lotNo: 139173265, lotSeq: 2, insulinType: .novolog, podType: dashType)
        abandoned.setupProgress = .priming
        abandoned.deliveryStoppedAt = start + .hours(42)
        let new = pod(lotSeq: 3, activatedAt: start + .hours(43))

        XCTAssertNil(OmniPumpManager.componentReplacement(newPod: new, previousPod: abandoned).previous)
    }

    private func podInSetup(lotSeq: UInt32) -> PodState {
        var pod = PodState(address: 0x17A6219A, firmwareVersion: "4.10.0", iFirmwareVersion: "1.1.0",
                           lotNo: 139173265, lotSeq: lotSeq, insulinType: .novolog, podType: dashType)
        pod.setupProgress = .priming
        return pod
    }

    func testPodAbandonedDuringSetupKeepsThePreviousPod() throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var a = pod(lotSeq: 1, activatedAt: start)
        a.deliveryStoppedAt = start + .hours(40)
        a.fault = try DetailedStatus(encodedData: Data(hexadecimalString: "020d0000000407eb140e0c03ff0e1400002817080000")!)
        let b = podInSetup(lotSeq: 2)
        let c = pod(lotSeq: 3, activatedAt: start + .hours(41))

        let previous = OmniPumpManager.previousPod(retiring: b, current: a)
        XCTAssertEqual(previous, a)
        XCTAssertEqual(OmniPumpManager.componentReplacement(newPod: c, previousPod: previous).previous?.reason, .occlusion(code: "0x14"))
    }

    func testPodFaultedDuringSetupIsReported() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var a = pod(lotSeq: 1, activatedAt: start)
        a.deliveryStoppedAt = start + .hours(40)
        var b = podInSetup(lotSeq: 2)
        b.setupProgress = .activationTimeout
        let c = pod(lotSeq: 3, activatedAt: start + .hours(41))

        XCTAssertTrue(OmniPumpManager.isPodChange(from: podInSetup(lotSeq: 2), to: b))
        let replacementForB = OmniPumpManager.componentReplacement(newPod: b, previousPod: a)
        XCTAssertEqual(replacementForB.previous?.stopDate, start + .hours(40))
        XCTAssertEqual(replacementForB.primes, [])

        let previous = OmniPumpManager.previousPod(retiring: b, current: a)
        XCTAssertEqual(previous?.lotSeq, 2)
        XCTAssertNotNil(previous?.deliveryStoppedAt)
        XCTAssertEqual(OmniPumpManager.componentReplacement(newPod: c, previousPod: previous).previous?.reason, .fault(code: nil))
    }

    func testPreviousPodIsKeptWhenSwitchingPodTypes() {
        let a = pod(lotSeq: 1, activatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        XCTAssertEqual(OmniPumpManager.previousPod(retiring: nil, current: a), a)
    }

    func testIsPodChange() throws {
        let inSetup = podInSetup(lotSeq: 2)
        let completed = pod(lotSeq: 2, activatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        var faultedInSetup = inSetup
        faultedInSetup.fault = try DetailedStatus(encodedData: Data(hexadecimalString: "020f0000000900345c000103ff0001000005ae056029")!)
        var faultedAfterSetup = completed
        faultedAfterSetup.fault = faultedInSetup.fault

        XCTAssertTrue(OmniPumpManager.isPodChange(from: inSetup, to: completed))
        XCTAssertTrue(OmniPumpManager.isPodChange(from: inSetup, to: faultedInSetup))
        XCTAssertFalse(OmniPumpManager.isPodChange(from: completed, to: completed))
        XCTAssertFalse(OmniPumpManager.isPodChange(from: completed, to: faultedAfterSetup))
        XCTAssertFalse(OmniPumpManager.isPodChange(from: faultedInSetup, to: faultedInSetup))
        XCTAssertFalse(OmniPumpManager.isPodChange(from: inSetup, to: inSetup))
        XCTAssertFalse(OmniPumpManager.isPodChange(from: completed, to: nil))
    }

    func testLTKAndBLEIdentifierDecodeIndependently() throws {
        let ltk = Data(hexadecimalString: "fedcba98765432100123456789abcdef")!
        let handle = "0B1D2C3E-0000-4000-8000-00000000A001"
        let pod = PodState(address: 0x17A6219A, firmwareVersion: "4.10.0", iFirmwareVersion: "1.1.0",
                           lotNo: 139173265, lotSeq: 560313, insulinType: .novolog, podType: dashType,
                           ltk: ltk, bleIdentifier: handle)

        var withoutHandle = pod.rawValue
        withoutHandle.removeValue(forKey: "bleIdentifier")
        let decodedWithoutHandle = try XCTUnwrap(PodState(rawValue: withoutHandle))
        XCTAssertEqual(decodedWithoutHandle.ltk, ltk)
        XCTAssertNil(decodedWithoutHandle.bleIdentifier)

        var withoutKey = pod.rawValue
        withoutKey.removeValue(forKey: "ltk")
        let decodedWithoutKey = try XCTUnwrap(PodState(rawValue: withoutKey))
        XCTAssertNil(decodedWithoutKey.ltk)
        XCTAssertEqual(decodedWithoutKey.bleIdentifier, handle)
    }

    func testCancelAfterScheduledEndAppliesBolusNotDelivered() {
        var podState = PodState(address: 521580830, firmwareVersion: "2.7.0", iFirmwareVersion: "2.7.0", lotNo: 139173265, lotSeq: 560313, insulinType: .novolog, podType: dashType, ltk: Data(hexadecimalString: "fedcba98765432100123456789abcdef")!, bleIdentifier: "0000-0000")
        let start = Date().addingTimeInterval(.hours(-1))
        podState.unfinalizedBolus = UnfinalizedDose(doseId: nil, bolusAmount: 4, startTime: start, scheduledCertainty: .certain, insulinType: .novolog)
        let rate = podState.unfinalizedBolus!.rate

        _ = podState.handleCancelDosing(deliveryType: .all, bolusNotDelivered: 1.8, at: Date())

        XCTAssertEqual(2.2, podState.unfinalizedBolus!.units, accuracy: 0.01)
        XCTAssertEqual(start.addingTimeInterval(.hours(2.2 / rate)).timeIntervalSince1970, podState.unfinalizedBolus!.finishTime!.timeIntervalSince1970, accuracy: 1)
    }

    func testCancelDoesNotSubtractBolusNotDeliveredTwice() {
        var podState = PodState(address: 521580830, firmwareVersion: "2.7.0", iFirmwareVersion: "2.7.0", lotNo: 139173265, lotSeq: 560313, insulinType: .novolog, podType: dashType, ltk: Data(hexadecimalString: "fedcba98765432100123456789abcdef")!, bleIdentifier: "0000-0000")
        let start = Date().addingTimeInterval(.hours(-1))
        podState.unfinalizedBolus = UnfinalizedDose(doseId: nil, bolusAmount: 4, startTime: start, scheduledCertainty: .certain, insulinType: .novolog)
        let canceledAt = start.addingTimeInterval(.seconds(30))
        // A recovered unacknowledged cancel has already applied the remaining 1 U
        podState.unfinalizedBolus!.cancel(at: canceledAt, withRemaining: 1)

        for faultTime in [start.addingTimeInterval(.seconds(20)), start.addingTimeInterval(.seconds(40))] {
            var state = podState
            _ = state.handleCancelDosing(deliveryType: .all, bolusNotDelivered: 1, at: faultTime)
            XCTAssertEqual(3, state.unfinalizedBolus!.units, accuracy: 0.01)
        }
    }
}

