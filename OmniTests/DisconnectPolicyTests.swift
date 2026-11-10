//
//  DisconnectPolicyTests.swift
//  OmniTests
//

import XCTest
@testable import OmnipodKit

class DisconnectPolicyTests: XCTestCase {

    private typealias Situation = DisconnectPolicy.Situation

    private func decide(_ situation: Situation, inFlight: Bool) -> DisconnectPolicy.Decision {
        return DisconnectPolicy.didDisconnect(situation, commandConnectInFlight: inFlight)
    }

    private let backgroundHeartbeat = Situation(probeActive: true, autoConnect: true)
    private let foreground = Situation(held: true, foreground: true, autoConnect: true)
    private let backgroundKeepAlive = Situation(held: true, autoConnect: true)

    func testPodHangUpDuringACommandInTheBackgroundRearmsTheProbeWhenTheSessionEnds() {
        var duringSession = backgroundHeartbeat
        duringSession.sessionActive = true
        let drop = decide(duringSession, inFlight: true)
        XCTAssertEqual(drop, .init(action: .idle(armProbe: false), commandConnectInFlight: true))

        let ended = DisconnectPolicy.sessionsEnded(backgroundHeartbeat, linkDown: true, commandConnectInFlight: drop.commandConnectInFlight)
        XCTAssertEqual(ended, .init(action: .idle(armProbe: true), commandConnectInFlight: false))
    }

    func testCancelledProbesDisconnectDuringACommandConnectKeepsTheCommandInFlight() {
        var situation = backgroundHeartbeat
        situation.sessionActive = true
        XCTAssertEqual(decide(situation, inFlight: true).commandConnectInFlight, true)
    }

    func testDropOutsideASessionInTheBackgroundRearmsTheProbe() {
        let decision = decide(backgroundHeartbeat, inFlight: true)
        XCTAssertEqual(decision, .init(action: .idle(armProbe: true), commandConnectInFlight: false))
    }

    func testSessionsEndingWithTheLinkUpLeaveItToTheIdleDisconnect() {
        XCTAssertNil(DisconnectPolicy.sessionsEnded(backgroundHeartbeat, linkDown: false, commandConnectInFlight: true))
    }

    func testSessionsEndingOnAHeldLinkChangeNothing() {
        XCTAssertNil(DisconnectPolicy.sessionsEnded(backgroundKeepAlive, linkDown: true, commandConnectInFlight: true))
    }

    func testIdleDisconnectInTheBackgroundRearmsTheProbe() {
        let decision = decide(backgroundHeartbeat, inFlight: false)
        XCTAssertEqual(decision, .init(action: .idle(armProbe: true), commandConnectInFlight: false))
    }

    func testDropInTheBackgroundWithoutHeartbeatGoesIdleWithoutAProbe() {
        let decision = decide(Situation(autoConnect: true), inFlight: true)
        XCTAssertEqual(decision, .init(action: .idle(armProbe: false), commandConnectInFlight: false))
    }

    func testDropOfAPodNoLongerAutoConnectedArmsNoProbe() {
        let decision = decide(Situation(probeActive: true), inFlight: true)
        XCTAssertEqual(decision, .init(action: .idle(armProbe: false), commandConnectInFlight: false))
    }

    func testDropOfAHeldLinkDuringACommandReconnects() {
        XCTAssertEqual(decide(foreground, inFlight: true), .init(action: .keepAliveReconnect, commandConnectInFlight: true))
        XCTAssertEqual(decide(backgroundKeepAlive, inFlight: true), .init(action: .keepAliveReconnect, commandConnectInFlight: true))
    }

    func testDeliberateDisconnectOfAHeldLinkDoesNotReconnect() {
        // disconnectOnDemand clears the flag before cancelling.
        XCTAssertEqual(decide(foreground, inFlight: false), .init(action: .idle(armProbe: false), commandConnectInFlight: false))
    }

    func testSystemReconnectAndWatchdogKeepTheCommandInFlight() {
        var situation = backgroundHeartbeat
        situation.systemReconnecting = true
        XCTAssertEqual(decide(situation, inFlight: true), .init(action: .deferToSystemReconnect, commandConnectInFlight: true))

        situation = backgroundHeartbeat
        situation.watchdogActive = true
        XCTAssertEqual(decide(situation, inFlight: true), .init(action: .deferToWatchdog, commandConnectInFlight: true))
    }

    func testEagerPodHeldConnected() {
        var situation = foreground
        situation.eager = true
        XCTAssertEqual(decide(situation, inFlight: true).action, .eagerReconnect)

        situation = backgroundKeepAlive
        situation.eager = true
        XCTAssertEqual(decide(situation, inFlight: true).action, .standingConnect)

        situation.eagerHeartbeatMode = true
        XCTAssertEqual(decide(situation, inFlight: true).action, .eagerHeartbeatReconnect)
    }

    func testEagerPodInTheBackgroundWithoutKeepAliveIsConnectOnDemand() {
        var situation = backgroundHeartbeat
        situation.eager = true
        XCTAssertEqual(decide(situation, inFlight: true), .init(action: .idle(armProbe: true), commandConnectInFlight: false))
    }
}
