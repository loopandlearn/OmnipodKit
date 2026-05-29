//
//  SessionEstablisher.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/Session/SessionEstablisher.swift
//  Created by Randall Knutson on 11/8/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import Foundation
import OSLog

/// Determines the EAP-AKA role during session key negotiation.
///
/// - `PRIMARY`: Controller initiates the EAP-AKA challenge (sends RAND+AUTN first,
///   pod responds with RES). This is the standard DASH behavior.
/// - `SECONDARY`: Pod initiates the EAP-AKA challenge (pod sends RAND+AUTN first,
///   controller responds with RES). This is what O5 pods expect for post-pairing sessions,
///   matching the Android app's use of `TwiEapAkaSlave`.
enum SessionKeyMode {
    case PRIMARY    // Controller initiates challenge (DASH default)
    case SECONDARY  // Pod initiates challenge, controller responds (O5 post-pairing)
}

enum SessionResult {
    case SessionKeys(SessionKeys)
    case SessionNegotiationResynchronization(SessionNegotiationResynchronization)
}

enum SessionEstablishmentException: Error {
    case InvalidParameter(String)
    case CommunicationError(String)
}

class SessionEstablisher {
    private static let IV_SIZE = 4

    private let manager: PeripheralManager
    private let ltk: Data
    private let eapSqn: Data
    private let myId: UInt32
    private let podId: UInt32
    private var msgSeq: Int
    private let podType: PodType
    private let mode: SessionKeyMode

    private var controllerIV: Data
    private var nodeIV: Data = Data()
    private var identifier: UInt8 = 0
    private let milenage: Milenage
    private let log = OSLog(category: "SessionEstablisher")

    init(manager: PeripheralManager, ltk: Data, eapSqn: Int, myId: UInt32, podId: UInt32, msgSeq: Int, podType: PodType = dashType, mode: SessionKeyMode = .PRIMARY) throws {
//        guard eapSqn.count == 6 else { throw SessionEstablishmentException.InvalidParameter("EAP-SQN has to be 6 bytes long") }
        guard ltk.count == 16 else { throw SessionEstablishmentException.InvalidParameter("LTK has to be 16 bytes long") }

        let random = OmniRandomByteGenerator()
        controllerIV = random.nextBytes(length: SessionEstablisher.IV_SIZE)

        self.manager = manager
        self.ltk = ltk
        self.eapSqn = Data(bigEndian: eapSqn).subdata(in: 2..<8)
        self.myId = myId
        self.podId = podId
        self.msgSeq = msgSeq
        self.podType = podType
        self.mode = mode
        self.milenage = try Milenage(k: ltk, sqn: self.eapSqn)
    }
    
    func negotiateSessionKeys() throws -> SessionResult {
        log.default("negotiateSessionKeys: podType=%{public}@, mode=%{public}@", podType.briefName, String(describing: mode))

        switch mode {
        case .PRIMARY:
            return try negotiateSessionKeysPrimary()
        case .SECONDARY:
            return try negotiateSessionKeysSecondary()
        }
    }

    // MARK: - PRIMARY Mode (Controller initiates challenge -- current DASH behavior)

    private func negotiateSessionKeysPrimary() throws -> SessionResult {
        msgSeq += 1
        let challenge = try eapAkaChallenge()
        let sendResult = manager.sendMessagePacket(challenge)
        guard case .sentWithAcknowledgment = sendResult else {
            throw SessionEstablishmentException.CommunicationError("Could not send the EAP AKA challenge: $sendResult")
        }
        guard let challengeResponse = try manager.readMessagePacket() else {
            throw SessionEstablishmentException.CommunicationError("Could not establish session")
        }

        let newSqn = try processChallengeResponse(challengeResponse: challengeResponse)
        if (newSqn != nil) {
            return .SessionNegotiationResynchronization(SessionNegotiationResynchronization(
                synchronizedEapSqn: newSqn!,
                msgSequenceNumber: UInt8(msgSeq)
            ))
        }

        msgSeq += 1
        let success = eapSuccess()
        let _ = manager.sendMessagePacket(success)

        return .SessionKeys(SessionKeys(
            ck: milenage.ck,
            nonce:  Nonce(prefix: controllerIV + nodeIV),
            msgSequenceNumber: msgSeq
        ))
    }

    // MARK: - SECONDARY Mode (Pod initiates challenge -- O5 post-pairing behavior)

    private func negotiateSessionKeysSecondary() throws -> SessionResult {
        // Step 1: Wait for pod's EAP-Request/AKA-Challenge
        log.default("SECONDARY: Waiting for pod's EAP-AKA challenge...")
        guard let challengePacket = try manager.readMessagePacket() else {
            throw SessionEstablishmentException.CommunicationError(
                "SECONDARY: Did not receive EAP-AKA challenge from pod"
            )
        }

        let challengeMsg = try EapMessage.parse(payload: challengePacket.payload)

        // Validate it's an EAP-Request (code=0x01) with AKA-Challenge subtype
        guard challengeMsg.code == .REQUEST else {
            throw SessionEstablishmentException.CommunicationError(
                "SECONDARY: Expected EAP-Request from pod, got code: \(challengeMsg.code)"
            )
        }

        // Store the identifier from the pod's message (we must echo it back)
        identifier = challengeMsg.identifier
        log.default("SECONDARY: Received pod challenge with identifier=%{public}lld, %{public}lld attributes",
                     identifier, challengeMsg.attributes.count)

        // Step 2: Extract RAND, AUTN, and pod's IV from the challenge
        var podRand: Data?
        var podAutn: Data?
        var podIV: Data?

        for attr in challengeMsg.attributes {
            switch attr {
            case is EapAkaAttributeRand:
                podRand = attr.payload
            case is EapAkaAttributeAutn:
                podAutn = attr.payload
            case is EapAkaAttributeCustomIV:
                podIV = attr.payload.subdata(in: 0..<SessionEstablisher.IV_SIZE)
            default:
                throw SessionEstablishmentException.CommunicationError(
                    "SECONDARY: Unexpected attribute in pod challenge: \(type(of: attr))"
                )
            }
        }

        guard let rand = podRand, let autn = podAutn, let nodeIVData = podIV else {
            throw SessionEstablishmentException.CommunicationError(
                "SECONDARY: Pod challenge missing required attributes " +
                "(RAND=\(podRand != nil), AUTN=\(podAutn != nil), IV=\(podIV != nil))"
            )
        }

        self.nodeIV = nodeIVData
        log.default("SECONDARY: Pod RAND=%{public}@, AUTN=%{public}@, IV=%{public}@",
                     rand.hexadecimalString, autn.hexadecimalString, nodeIVData.hexadecimalString)

        // Step 3: Compute Milenage using pod's RAND and shared K
        let secondaryMilenage = try Milenage(k: ltk, sqn: eapSqn, randParam: rand)

        // Step 4: Validate pod's AUTN
        // AUTN = (AK ^ SQN) || AMF || MAC-A  (16 bytes total)
        // If our SQN matches the pod's SQN, our computed AUTN will match exactly.
        // If SQN is out of sync, the AUTN will differ (both AK^SQN and MAC-A portions).
        log.default("SECONDARY: Computed AUTN=%{public}@, received AUTN=%{public}@",
                     secondaryMilenage.autn.hexadecimalString, autn.hexadecimalString)

        if autn != secondaryMilenage.autn {
            // AUTN mismatch. Extract the pod's SQN and try recomputing with it.
            // Pod's SQN can be recovered from: SQN_pod = AUTN[0:6] ^ AK
            // (AK depends only on K and RAND, which we both know)
            let podSqn = autn.subdata(in: 0..<6) ^ secondaryMilenage.ak
            log.default("SECONDARY: AUTN mismatch. Extracted pod SQN=%{public}@, our SQN=%{public}@",
                         podSqn.hexadecimalString, eapSqn.hexadecimalString)

            // Recompute Milenage with the pod's SQN to verify MAC-A
            let recomputedMilenage = try Milenage(k: ltk, sqn: podSqn, randParam: rand)
            if autn != recomputedMilenage.autn {
                // Even with the pod's SQN, AUTN doesn't match -- K mismatch or corruption
                throw SessionEstablishmentException.CommunicationError(
                    "SECONDARY: AUTN validation failed even with pod's extracted SQN. " +
                    "Received: \(autn.hexadecimalString), " +
                    "Recomputed: \(recomputedMilenage.autn.hexadecimalString). " +
                    "Possible LTK mismatch."
                )
            }

            // AUTN is valid with the pod's SQN -- our SQN is stale.
            // Return resynchronization so the caller can update the stored EAP SQN.
            log.default("SECONDARY: AUTN valid with pod SQN. Returning resynchronization.")
            let newSqn = try EapSqn(data: podSqn)
            return .SessionNegotiationResynchronization(SessionNegotiationResynchronization(
                synchronizedEapSqn: newSqn,
                msgSequenceNumber: UInt8(msgSeq)
            ))
        }

        log.default("SECONDARY: AUTN validated successfully. Computing RES.")

        // Step 5: Build and send EAP-Response with RES and controller IV
        msgSeq += 1
        let responsePacket = try buildSecondaryResponse(
            res: secondaryMilenage.res,
            identifier: identifier
        )

        let sendResult = manager.sendMessagePacket(responsePacket)
        guard case .sentWithAcknowledgment = sendResult else {
            throw SessionEstablishmentException.CommunicationError(
                "SECONDARY: Could not send EAP-AKA response: \(sendResult)"
            )
        }
        log.default("SECONDARY: Sent EAP-Response with RES=%{public}@, controllerIV=%{public}@",
                     secondaryMilenage.res.hexadecimalString, controllerIV.hexadecimalString)

        // Step 6: Wait for EAP-Success from pod
        guard let successPacket = try manager.readMessagePacket() else {
            throw SessionEstablishmentException.CommunicationError(
                "SECONDARY: Did not receive EAP-Success from pod"
            )
        }

        let successMsg = try EapMessage.parse(payload: successPacket.payload)
        if successMsg.code == .FAILURE {
            throw SessionEstablishmentException.CommunicationError(
                "SECONDARY: Pod rejected EAP-AKA response (EAP-Failure received)"
            )
        }
        guard successMsg.code == .SUCCESS else {
            throw SessionEstablishmentException.CommunicationError(
                "SECONDARY: Expected EAP-Success from pod, got code: \(successMsg.code)"
            )
        }
        log.default("SECONDARY: Received EAP-Success from pod")

        msgSeq += 1

        // Step 7: Return session keys
        // In SECONDARY mode, the pod sends first (with its IV), so the nonce prefix
        // uses nodeIV + controllerIV (reversed from PRIMARY mode's controllerIV + nodeIV).
        return .SessionKeys(SessionKeys(
            ck: secondaryMilenage.ck,
            nonce: Nonce(prefix: nodeIV + controllerIV),
            msgSequenceNumber: msgSeq
        ))
    }

    /// Builds an EAP-Response message containing RES and controller IV for SECONDARY mode.
    private func buildSecondaryResponse(res: Data, identifier: UInt8) throws -> MessagePacket {
        let attributes = [
            try EapAkaAttributeRes(payload: res),
            try EapAkaAttributeCustomIV(payload: controllerIV)
        ]

        let eapMsg = EapMessage(
            code: EapCode.RESPONSE,  // 0x02 -- we are responding to the pod's challenge
            identifier: identifier,
            attributes: attributes
        )

        return MessagePacket(
            type: MessageType.SESSION_ESTABLISHMENT,
            source: myId,
            destination: podId,
            payload: eapMsg.toData(),
            sequenceNumber: UInt8(msgSeq)
        )
    }

    private func eapAkaChallenge() throws -> MessagePacket {
        let attributes = [
            try EapAkaAttributeAutn(payload: milenage.autn),
            try EapAkaAttributeRand(payload: milenage.rand),
            try EapAkaAttributeCustomIV(payload: controllerIV)
        ]

        let eapMsg = EapMessage(
            code: EapCode.REQUEST,
            identifier: identifier,
            attributes: attributes
        )
        return MessagePacket(
            type: MessageType.SESSION_ESTABLISHMENT,
            source: myId,
            destination: podId,
            payload: eapMsg.toData(),
            sequenceNumber: UInt8(msgSeq)
        )
    }

    private func assertIdentifier(msg: EapMessage) throws {
        if (msg.identifier != identifier) {
            log.debug("EAP-AKA: got incorrect identifier ${msg.identifier} expected: $identifier")
            throw SessionEstablishmentException.CommunicationError("Received incorrect EAP identifier: ${msg.identifier}")
        }
    }

    private func processChallengeResponse(challengeResponse: MessagePacket) throws -> EapSqn? {
        let eapMsg = try EapMessage.parse(payload: challengeResponse.payload)

        try assertIdentifier(msg: eapMsg)

        let eapSqn = try isResynchronization(eapMsg: eapMsg)
        if (eapSqn != nil) {
            return eapSqn
        }

        try assertValidAkaMessage(eapMsg: eapMsg)

        for attr in eapMsg.attributes {
            switch attr {
            case is EapAkaAttributeRes:
                if (milenage.res != attr.payload) {
                    throw SessionEstablishmentException.CommunicationError(
                        "RES mismatch." +
                            "Expected: ${milenage.res.toHex()}." +
                            "Actual: ${attr.payload.toHex()}."
                    )
                }
            case is EapAkaAttributeCustomIV:
                nodeIV = attr.payload.subdata(in: 0..<SessionEstablisher.IV_SIZE)
            default:
                throw SessionEstablishmentException.CommunicationError("Unknown attribute received: $attr")
            }
        }
        return nil
    }

    private func assertValidAkaMessage(eapMsg: EapMessage) throws {
        if (eapMsg.attributes.count != 2) {
            log.debug("EAP-AKA: got incorrect: $eapMsg")
            if (eapMsg.attributes.count == 1 && eapMsg.attributes[0] is EapAkaAttributeClientErrorCode) {
                throw SessionEstablishmentException.CommunicationError(
                    "Received CLIENT_ERROR_CODE for EAP-AKA challenge: ${eapMsg.attributes[0].toByteArray().toHex()}"
                )
            }
        throw SessionEstablishmentException.CommunicationError("Expecting two attributes, got: ${eapMsg.attributes.count}")
        }
    }

    private func isResynchronization(eapMsg: EapMessage) throws -> EapSqn? {
        if (eapMsg.subType != EapMessage.SUBTYPE_SYNCRONIZATION_FAILURE ||
            eapMsg.attributes.count != 1 ||
            eapMsg.attributes[0] as? EapAkaAttributeAuts == nil
        ) {
            return nil
        }

        let auts = eapMsg.attributes[0] as! EapAkaAttributeAuts
        let autsMilenage = try Milenage(
            k: ltk,
            sqn: eapSqn,
            randParam: milenage.rand,
            auts: auts.payload
        )

        let newSqnMilenage = try Milenage(
            k: ltk,
            sqn: autsMilenage.synchronizationSqn,
            randParam: milenage.rand,
            auts: auts.payload,
            amf: Milenage.RESYNC_AMF
        )

        if (newSqnMilenage.macS != newSqnMilenage.receivedMacS) {
            throw SessionEstablishmentException.CommunicationError(
                "MacS mismatch. " +
                    "Expected: ${newSqnMilenage.macS.toHex()}. " +
                    "Received: ${newSqnMilenage.receivedMacS.toHex()}"
            )
        }
        return try EapSqn(data: autsMilenage.synchronizationSqn)
    }

    private func eapSuccess() ->  MessagePacket {
        let eapMsg = EapMessage(
            code: EapCode.SUCCESS,
            identifier: UInt8(identifier),
            attributes: Array()
        )

        return MessagePacket(
            type: MessageType.SESSION_ESTABLISHMENT,
            source: myId,
            destination: podId,
            payload: eapMsg.toData(),
            sequenceNumber: UInt8(msgSeq)
        )
    }
}
