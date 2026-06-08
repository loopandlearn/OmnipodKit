//
//  BolusExtraCommandO5Tests.swift
//  OmniTests
//

import XCTest
@testable import OmnipodKit

class BolusExtraCommandO5Tests: XCTestCase {

    private func hex(_ string: String) -> Data {
        Data(hexadecimalString: string)!
    }

    func testO5SubtypeFlag() {
        let o5 = BolusExtraCommand(units: 1.0, bolusInfo: BolusInfo(mealUnits: 1.0))
        XCTAssertEqual(o5.data[1], 0x12)

        let dash = BolusExtraCommand(units: 1.0, bolusInfo: nil)
        XCTAssertEqual(dash.data[1], 0x0d)
    }

    func testErosStyleDecode_noBolusInfo() throws {
        let cmd = try BolusExtraCommand(encodedData: hex("170d7c177000030d40000000000000"))
        XCTAssertNil(cmd.bolusInfo)
        XCTAssertEqual(cmd.data[1], 0x0d)
    }

    func testO5OneUnitBolusEncoding() throws {
        let cmd = BolusExtraCommand(
            units: 1.0,
            timeBetweenPulses: TimeInterval(seconds: Pod.secondsPerBolusPulse),
            bolusInfo: BolusInfo(mealUnits: 1.0)
        )
        XCTAssertEqual(cmd.data, O5CommLogFixtures.oneUnitBolusExtra)

        let decoded = try BolusExtraCommand(encodedData: O5CommLogFixtures.oneUnitBolusExtra)
        XCTAssertEqual(decoded.units, 1.0)
        XCTAssertEqual(decoded.bolusInfo?.mealUnits, 1.0)
        XCTAssertEqual(decoded.bolusInfo?.correctionUnits, 0.0)
        XCTAssertEqual(decoded.bolusInfo?.bolusSource, 1)
        XCTAssertFalse(decoded.acknowledgementBeep)
        XCTAssertFalse(decoded.completionBeep)
    }

    func testO5PrimeBolusEncoding() throws {
        let timeBetweenPulses = TimeInterval(seconds: Pod.secondsPerPrimePulse)
        let cmd = BolusExtraCommand(
            units: Pod.primeUnits,
            timeBetweenPulses: timeBetweenPulses,
            bolusInfo: BolusInfo()
        )
        XCTAssertEqual(cmd.data, O5CommLogFixtures.primeBolusExtra)

        let decoded = try BolusExtraCommand(encodedData: O5CommLogFixtures.primeBolusExtra)
        XCTAssertEqual(decoded.units, Pod.primeUnits)
        XCTAssertEqual(decoded.timeBetweenPulses, timeBetweenPulses)
    }

    func testO5CannulaBolusEncoding() throws {
        let timeBetweenPulses = TimeInterval(seconds: Pod.secondsPerPrimePulse)
        let cmd = BolusExtraCommand(
            units: Pod.cannulaInsertionUnits,
            timeBetweenPulses: timeBetweenPulses,
            bolusInfo: BolusInfo()
        )
        XCTAssertEqual(cmd.data, O5CommLogFixtures.cannulaBolusExtra)

        let decoded = try BolusExtraCommand(encodedData: O5CommLogFixtures.cannulaBolusExtra)
        XCTAssertEqual(decoded.units, Pod.cannulaInsertionUnits)
    }

    func testO5RoundTripDecode_withBolusInfo() throws {
        let original = BolusExtraCommand(
            units: 2.5,
            timeBetweenPulses: TimeInterval(seconds: Pod.secondsPerBolusPulse),
            extendedUnits: 0.5,
            extendedDuration: TimeInterval(hours: 1),
            acknowledgementBeep: true,
            completionBeep: false,
            programReminderInterval: TimeInterval(minutes: 30),
            bolusInfo: BolusInfo(bolusSource: 1, mealUnits: 1.0, correctionUnits: 1.5)
        )
        let decoded = try BolusExtraCommand(encodedData: original.data)
        XCTAssertEqual(decoded.units, original.units, accuracy: 0.001)
        XCTAssertEqual(decoded.extendedUnits, original.extendedUnits, accuracy: 0.001)
        XCTAssertEqual(decoded.bolusInfo?.mealUnits, 1.0)
        XCTAssertEqual(decoded.bolusInfo?.correctionUnits, 1.5)
        XCTAssertTrue(decoded.acknowledgementBeep)
    }
}
