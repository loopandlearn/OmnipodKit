//
//  PodLifeStateTests.swift
//  OmniTests
//

import XCTest
@testable import OmnipodKit

class PodLifeStateTests: XCTestCase {

    private func components(_ remaining: TimeInterval, reminderOffset: TimeInterval = .hours(2)) -> [Int?] {
        let lifeState = PodLifeState.timeRemaining(timeUntilExpiration: remaining, timeUntilExpirationReminder: remaining - reminderOffset)
        return [lifeState.daysRemaining, lifeState.hoursRemaining, lifeState.minutesRemaining]
    }

    func testMoreThanADayShowsDaysAndHours() {
        XCTAssertEqual([2, 23, nil], components(.days(3) - .minutes(1)))
    }

    // LoopKit issue #583: two minutes after a 12 hour expiration reminder
    func testShortlyAfterExpirationReminderShowsMinutes() {
        XCTAssertEqual([nil, 11, 58], components(.hours(12) - .minutes(2), reminderOffset: .hours(12)))
    }

    func testFinalDayShowsHoursAndMinutesForAnyReminderSetting() {
        for reminderOffset in [TimeInterval(0), .hours(1), .hours(2), .hours(12), .hours(24)] {
            XCTAssertEqual([nil, 23, 59], components(.days(1) - .seconds(1), reminderOffset: reminderOffset))
            XCTAssertEqual([nil, 11, 58], components(.hours(12) - .minutes(2), reminderOffset: reminderOffset))
            XCTAssertEqual([nil, 2, 0], components(.hours(2), reminderOffset: reminderOffset))
            XCTAssertEqual([nil, 1, 59], components(.hours(2) - .seconds(1), reminderOffset: reminderOffset))
        }
    }

    func testFinalHourShowsOnlyMinutes() {
        XCTAssertEqual([nil, nil, 59], components(.hours(1) - .seconds(1)))
        XCTAssertEqual([nil, nil, 0], components(.seconds(30)))
    }

    func testOneDayBoundary() {
        XCTAssertEqual([1, 0, nil], components(.days(1) + .seconds(1)))
        XCTAssertEqual([1, 0, nil], components(.days(1)))
        XCTAssertEqual([nil, 23, 59], components(.days(1) - .seconds(1)))
    }

    func testTwoHourBoundary() {
        XCTAssertEqual([nil, 2, 0], components(.hours(2) + .seconds(1)))
        XCTAssertEqual([nil, 2, 0], components(.hours(2)))
        XCTAssertEqual([nil, 1, 59], components(.hours(2) - .seconds(1)))
    }

    func testOneHourBoundary() {
        XCTAssertEqual([nil, 1, 0], components(.hours(1) + .seconds(1)))
        XCTAssertEqual([nil, 1, 0], components(.hours(1)))
        XCTAssertEqual([nil, nil, 59], components(.hours(1) - .seconds(1)))
    }

    func testMinutesAreTruncatedNotRounded() {
        XCTAssertEqual([nil, 11, 58], components(.hours(12) - .seconds(61)))
    }

    func testOtherStatesShowNoTime() {
        let states: [PodLifeState] = [.podActivating, .expired, .podDeactivating, .noPod]
        for lifeState in states {
            XCTAssertNil(lifeState.daysRemaining)
            XCTAssertNil(lifeState.hoursRemaining)
            XCTAssertNil(lifeState.minutesRemaining)
        }
    }
}
