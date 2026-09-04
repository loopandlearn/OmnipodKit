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
    /// User-facing. These reach alert dialogs verbatim (e.g. Loop's "Unable To Clear Alert"), so they
    /// must read as plain English -- the protocol detail belongs in `failureReason` and the device
    /// communication log, not in front of someone holding a beeping pod.
    var errorDescription: String? {
        switch self {
        case .invalidLTKKey:
            return LocalizedString("Could not establish a secure connection to the pod.", comment: "Error description for invalidLTKKey")
        case .pairingException:
            return LocalizedString("Could not pair with the pod.", comment: "Error description for pairingException")
        case .messageIOException:
            return LocalizedString("Communication with the pod was interrupted.", comment: "Error description for messageIOException")
        case .couldNotParseMessageException, .incorrectPacketException, .invalidCrc:
            return LocalizedString("Received an unexpected response from the pod.", comment: "Error description for a malformed or unparseable pod response")
        }
    }

    /// Diagnostic detail. Not shown by Loop's acknowledgement-failure dialog (which renders
    /// `errorDescription` + `recoverySuggestion`), but preserved for logs and issue reports.
    var failureReason: String? {
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
            return String(format: "Incorrect Packet Exception: %1$@ (location=%2$d)", payload.hexadecimalString, location)
        case .invalidCrc(let payloadCrc, let computedCrc):
            return String(format: "Payload crc32 %1$@ does not match computed crc32 %2$@", payloadCrc.hexadecimalString, computedCrc.hexadecimalString)
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .messageIOException, .couldNotParseMessageException, .incorrectPacketException, .invalidCrc:
            // These are usually a dropped link rather than a pod problem, and the command is retried
            // automatically -- so lead with "no action needed" rather than alarming the user.
            return LocalizedString("This usually resolves on its own. If it keeps happening, move your iPhone closer to the pod.", comment: "Recovery suggestion for a transient pod communication error")
        case .invalidLTKKey, .pairingException:
            return LocalizedString("Move your iPhone closer to the pod and try again.", comment: "Recovery suggestion for a pod pairing error")
        }
    }
}


