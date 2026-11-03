//
//  PodCommsSessionTests.swift
//  OmniTests
//
//  From OmniBLE/OmniBLETests/PodCommsSessionTests.swift
//  Created by Pete Schwamb on 3/25/19.
//  Copyright © 2019 Pete Schwamb. All rights reserved.
//

import Foundation

import XCTest
@testable import OmnipodKit

class MockMessageTransport: MessageTransport {
    var delegate: MessageTransportDelegate?

    var messageNumber: Int

    var responseMessageBlocks = [MessageBlock]()
    var sentMessages = [Message]()

    var address: UInt32

    var sentMessageHandler: ((Message) -> Void)?

    init(address: UInt32, messageNumber: Int) {
        self.address = address
        self.messageNumber = messageNumber
    }

    func sendMessage(_ message: Message) throws -> Message {
        sentMessages.append(message)
        if responseMessageBlocks.isEmpty {
            throw PodCommsError.noResponse
        }
        return Message(address: address, messageBlocks: [responseMessageBlocks.removeFirst()], sequenceNum: messageNumber)
    }

    func addResponse(_ messageBlock: MessageBlock) {
        responseMessageBlocks.append(messageBlock)
    }

    func assertOnSessionQueue() {
        // Do nothing in tests
    }
}

class PodCommsSessionTests: XCTestCase, PodCommsSessionDelegate {

    var lastPodStateUpdate: PodState?

    let address: UInt32 = 521580830
    let fakeLtk = Data(hexadecimalString: "fedcba98765432100123456789abcdef")!
    var mockTransport: MockMessageTransport! = nil
    var podState: PodState! = nil

    override func setUp() {
        mockTransport = MockMessageTransport(address: address, messageNumber: 1)
        podState = PodState(address: address, firmwareVersion: "2.7.0", iFirmwareVersion: "2.7.0", lotNo: 43620, lotSeq: 560313, insulinType: .novolog, podType: dashType, ltk: fakeLtk, bleIdentifier: "0000-0000")
    }

    func podCommsSession(_ podCommsSession: PodCommsSession, didChange state: PodState) {
        lastPodStateUpdate = state
    }

    func testBolusFinishedEarlyOnPodIsMarkedNonMutable() {
         let mockStart = Date()
         podState.unfinalizedBolus = UnfinalizedDose(bolusAmount: 4.45, startTime: mockStart, scheduledCertainty: .certain, insulinType: .novolog)
         let session = PodCommsSession(podState: podState, transport: mockTransport, delegate: self)

         // Simulate a status request a bit before the bolus is expected to finish
         let statusRequestTime = podState.unfinalizedBolus!.finishTime!.addingTimeInterval(-5)
         session.mockCurrentDate = statusRequestTime

         let statusResponse = StatusResponse(
             deliveryStatus: .scheduledBasal,
             podProgressStatus: .aboveFiftyUnits,
             timeActive: .minutes(10),
             reservoirLevel: Pod.reservoirLevelAboveThresholdMagicNumber,
             insulinDelivered: 25,
             bolusNotDelivered: 0,
             lastProgrammingMessageSeqNum: 5,
             alerts: AlertSet(slots: []))

         mockTransport.addResponse(statusResponse)

         let _ = try! session.getStatus()

         XCTAssertEqual(1, lastPodStateUpdate!.finalizedDoses.count)

         let finalizedBolus = lastPodStateUpdate!.finalizedDoses[0]

         XCTAssertTrue(finalizedBolus.isFinished(at: statusRequestTime))
         XCTAssertFalse(finalizedBolus.isMutable(at: statusRequestTime))
     }

    func testFaultSeenAfterScheduledBolusEndRecordsUndeliveredBolus() {
        let activatedAt = Date().addingTimeInterval(.hours(-3))
        podState.expiresAt = activatedAt + Pod.nominalPodLife
        let bolusStart = activatedAt + .minutes(99.5)
        podState.unfinalizedBolus = UnfinalizedDose(bolusAmount: 4, startTime: bolusStart, scheduledCertainty: .certain, insulinType: .novolog)
        let session = PodCommsSession(podState: podState, transport: mockTransport, delegate: self)
        session.mockCurrentDate = activatedAt + .minutes(105)

        // 0x18 empty reservoir fault at 100 minutes with 1.8 U (36 pulses) of the bolus not delivered
        let fault = try! PodInfoResponse(encodedData: Data(hexadecimalString: "0216020d0000240508001800640000006900001900000000")!)
        mockTransport.addResponse(fault)

        XCTAssertThrowsError(try session.getStatus())

        let bolus = lastPodStateUpdate!.finalizedDoses.first { $0.doseType == .bolus }!
        XCTAssertEqual(2.2, bolus.units, accuracy: 0.01)
        XCTAssertEqual(activatedAt + .minutes(100), bolus.finishTime)
    }

}
