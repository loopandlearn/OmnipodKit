//
//  PodProtocolError.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/PodProtocolError.swift
//  Created by Randall Knutson on 8/3/21.
//

import Foundation
import CoreBluetooth

enum PodProtocolError: Error {
    case invalidLTKKey(_ message: String)
    case pairingException(_ message: String)
    case messageIOException(_ message: String)
    case couldNotParseMessageException(_ message: String)
    case incorrectPacketException(_ payload: Data, _ location: Int)
    case invalidCrc(payloadCrc: Data, computedCrc: Data)
}

extension PodProtocolError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidLTKKey(let message):
            return String(format: "Invalid LTK Key: %1$@", message)
        case .pairingException(let message):
            return String(format: "Pairing Exception: %1$@", message)
        case .messageIOException(let message):
            return String(format: "Message IO Exception: %1$@", message)
        case .couldNotParseMessageException(let message):
            return String(format: "Could not parse message: %1$@", message)
        case .incorrectPacketException(let payload, let location):
            let payloadStr = payload.hexadecimalString
            return String(format: "Incorrect Packet Exception: %1$@ (location=%2$lld)", payloadStr, location)
        case .invalidCrc(let payloadCrc, let computedCrc):
            return String(format: "Payload crc32 %1$@ does not match computed crc32 %2$@", payloadCrc.hexadecimalString, computedCrc.hexadecimalString)
        }
    }

    var failureReason: String? {
        return nil
    }

    var recoverySuggestion: String? {
        return nil
    }
}


