//
//  PeripheralManagerErrors.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/PeripheralManagerErrors.swift
//  Created by Randall Knutson on 8/18/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import Foundation

enum PeripheralManagerError: Error {
    case cbPeripheralError(Error)
    case notReady
    case incorrectResponse
    case timeout([PeripheralManager.CommandCondition])
    case emptyValue
    case unknownCharacteristic
    case nack
    case unknownPodType
}

extension PeripheralManagerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .cbPeripheralError:
            return LocalizedString("Bluetooth error", comment: "Error message description for PeripheralManagerError.cbPeripheralError")
        case .notReady:
            return LocalizedString("Peripheral Not Ready", comment: "Error message description for PeripheralManagerError.notReady")
        case .incorrectResponse:
            return LocalizedString("Incorrect Response", comment: "Error message description for PeripheralManagerError.incorrectResponse")
        case .timeout:
            return LocalizedString("Timeout", comment: "Error message description for PeripheralManagerError.timeout")
        case .emptyValue:
            return LocalizedString("Empty Value", comment: "Error message description for PeripheralManagerError.emptyValue")
        case .unknownCharacteristic:
            return LocalizedString("Unknown Characteristic", comment: "Error message description for PeripheralManagerError.unknownCharacteristic")
        case .nack:
            return LocalizedString("Nack", comment: "Error message description for PeripheralManagerError.nack")
        case .unknownPodType:
            return LocalizedString("Unknown Pod Type", comment: "Error message description for PeripheralManagerError.unknownPodType")
        }
    }

    var failureReason: String? {
        if case .cbPeripheralError(let error) = self {
            return error.localizedDescription
        }
        return nil
    }

    var recoverySuggestion: String? {
        switch self {
        case .cbPeripheralError, .timeout, .notReady:
            return LocalizedString("Try adjusting pod position or toggle Bluetooth off and then on in iPhone Settings", comment: "Recovery suggestion for possible bluetooth issue")
        default:
            return nil
        }
    }
}
