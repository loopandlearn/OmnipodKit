//
//  O5Type4MessageSigningTests.swift
//  OmniTests
//

import XCTest
import CryptoKit
@testable import OmnipodKit

final class O5Type4MessageSigningTests: XCTestCase {

    private let signedBlockTypes: Set<MessageBlockType> = [
        .setInsulinSchedule,
        .deactivatePod,
        .cancelDelivery,
    ]

    func testInsulinDeliveryCommands_requireType4BlockTypes() {
        let bolus = SetInsulinScheduleCommand(nonce: 0x12345678, units: 1.0, timeBetweenPulses: 2.0)
        XCTAssertTrue(signedBlockTypes.contains(bolus.blockType))

        let tempBasal = SetInsulinScheduleCommand(nonce: 0x12345678, tempBasalRate: 0.5, duration: .hours(1))
        XCTAssertTrue(signedBlockTypes.contains(tempBasal.blockType))
    }

    func testCancelAndDeactivate_requireType4BlockTypes() {
        let cancel = CancelDeliveryCommand(nonce: 0x12345678, deliveryType: .bolus, beepType: .noBeepCancel)
        XCTAssertTrue(signedBlockTypes.contains(cancel.blockType))

        let deactivate = DeactivatePodCommand(nonce: 0x12345678)
        XCTAssertTrue(signedBlockTypes.contains(deactivate.blockType))
    }

    func testNonSignedCommand_notInType4Set() {
        let status = GetStatusCommand()
        XCTAssertFalse(signedBlockTypes.contains(status.blockType))
    }

    func testEncryptedSignedPacket_usesType4Header() {
        let packet = MessagePacket(
            type: .ENCRYPTED_SIGNED,
            source: 0x002A1C6C,
            destination: 0x002A1C6E,
            payload: Data(repeating: 0x42, count: 32),
            sequenceNumber: 1,
            eqos: 1
        )
        XCTAssertEqual(packet.type, .ENCRYPTED_SIGNED)
        XCTAssertEqual(packet.type.rawValue, MessageType.ENCRYPTED_SIGNED.rawValue)
    }

    func testEncryptedSignedPacket_appends64ByteSignature() throws {
        let privateKey = P256.Signing.PrivateKey()
        var packet = MessagePacket(
            type: .ENCRYPTED_SIGNED,
            source: 0x002A1C6C,
            destination: 0x002A1C6E,
            payload: Data(repeating: 0x42, count: 32),
            sequenceNumber: 1,
            eqos: 1
        )
        let signingInput = packet.asData(forEncryption: false).prefix(16) + packet.payload
        let signature = try privateKey.signature(for: signingInput)
        packet.signatureData = Data(signature.rawRepresentation)

        XCTAssertEqual(packet.signatureData?.count, 64)
        XCTAssertEqual(packet.asData().suffix(64), packet.signatureData)
    }

    func testEncryptedSignedSignature_verifiesWithSigningKey() throws {
        let privateKey = P256.Signing.PrivateKey()
        var packet = MessagePacket(
            type: .ENCRYPTED_SIGNED,
            source: 0x002A1C6C,
            destination: 0x002A1C6E,
            payload: Data("G0.0".utf8) + Data(repeating: 0x11, count: 40),
            sequenceNumber: 3,
            eqos: 1
        )
        let signingInput = packet.asData(forEncryption: false).prefix(16) + packet.payload
        let signature = try privateKey.signature(for: signingInput)
        packet.signatureData = Data(signature.rawRepresentation)

        let publicKey = privateKey.publicKey
        XCTAssertTrue(publicKey.isValidSignature(signature, for: signingInput))
    }
}
