//
//  ErrorResponse.swift
//  OmnipodKit
//
//  From OmniBLE/OmnipodCommon/MessageBlocks/ErrorResponse.swift
//  Created by Pete Schwamb on 2/25/18.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import Foundation

fileprivate let eros_badNonce: UInt8 = 0x14 // only returned on Eros


// Known error response codes returned by the pod when rejecting a command.
// These are distinct from FaultEventCode values which represent pod hardware faults.
enum ErrorResponseCode: UInt8, CustomStringConvertible {
    case badNonce           = 0x14 // Eros only: nonce mismatch
    case o5InvalidCommand   = 0x2A // Omnipod 5 invalid command (e.g., an unsigned bolus command)

    var description: String {
        switch self {
        case .badNonce:
            return "Bad nonce"
        case .o5InvalidCommand:
            return "Omnipod 5 invalid command"
        }
    }

    // Return a description for any error code, including unknown ones
    static func descriptionFor(code: UInt8) -> String {
        if let known = ErrorResponseCode(rawValue: code) {
            return known.description
        }
        return String(format: "Unknown error code %llu (0x%02llX)", code, code)
    }
}

enum ErrorResponseType {
    case badNonce(nonceResyncKey: UInt16) // only returned on Eros
    case nonretryableError(code: UInt8, faultEventCode: FaultEventCode, podProgress: PodProgressStatus)
}

// 06 14 WWWW, WWWW is the encoded nonce resync key
// 06 EE FF0P, EE != 0x14, FF = fault code (if any), 0P = pod progress status (1..15)

// Known error response codes returned by the pod when rejecting a command.
// These are distinct from FaultEventCode values which represent pod hardware faults.
struct ErrorResponse: MessageBlock {
    let blockType: MessageBlockType = .errorResponse
    let errorResponseType: ErrorResponseType
    let data: Data

    init(encodedData: Data) throws {
        let errorCode = encodedData[2]
        switch (errorCode) {
        case eros_badNonce:
            // For this error code only the 2 next bytes are the encoded nonce resync key (only returned on Eros)
            let nonceResyncKey: UInt16 = encodedData[3...].toBigEndian(UInt16.self)
            errorResponseType = .badNonce(nonceResyncKey: nonceResyncKey)
            break
        default:
            // All other error codes are some non-retryable command error. In this case,
            // the next 2 bytes are any saved fault code (typically 0) and the pod progress value.
            let faultEventCode = FaultEventCode(rawValue: encodedData[3])
            guard let podProgress = PodProgressStatus(rawValue: encodedData[4]) else {
                throw MessageError.unknownValue(value: encodedData[4], typeDescription: "ErrorResponse PodProgressStatus")
            }
            errorResponseType = .nonretryableError(code: errorCode, faultEventCode: faultEventCode, podProgress: podProgress)
            break
        }
        self.data = encodedData
    }
}
