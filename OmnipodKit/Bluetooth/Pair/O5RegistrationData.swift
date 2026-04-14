//
//  O5RegistrationData.swift
//  OmnipodKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import CryptoSwift


struct O5RegistrationData {
    private static var _registry: [UInt32: O5RegistrationData] = [:]
    private static let lock = NSLock()

    static func install(_ value: O5RegistrationData) {
        lock.lock()
        defer { lock.unlock() }
        _registry[value.controllerId] = value
    }

    static func get(_ controllerId: UInt32) -> O5RegistrationData? {
        lock.lock()
        defer { lock.unlock() }
        return _registry[controllerId]
    }

    static func getRandom() -> O5RegistrationData? {
        lock.lock()
        defer { lock.unlock() }
        switch _registry.count {
        case 0:
            return nil
        case 1:
            return _registry.values.first!
        default:
            let randomIndex = Int.random(in: 0..<_registry.count)
            return Array(_registry.values)[randomIndex]
        }
    }

    static var allValues: [O5RegistrationData] {
        lock.lock()
        defer { lock.unlock() }
        return Array(_registry.values)
    }

    static var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _registry.isEmpty
    }

    /// Parse an O5RegistrationData from a JSON dictionary (e.g. from an .o5keypair file or API response).
    static func fromJSON(_ json: [String: Any]) -> O5RegistrationData? {
        guard let controllerId = (json["controllerId"] as? NSNumber)?.uint32Value,
              let privateKeyHex = json["privateKey"] as? String,
              let publicKeyHex = json["publicKey"] as? String,
              let intermediateCABase64 = json["intermediateCA"] as? String,
              let tlsCertificateBase64 = json["tlsCertificate"] as? String
        else { return nil }
        return O5RegistrationData(
            controllerId: controllerId,
            privateKeyHex: privateKeyHex,
            publicKeyHex: publicKeyHex,
            intermediateCABase64: intermediateCABase64,
            tlsCertificateBase64: tlsCertificateBase64
        )
    }

    // MARK: - Identity

    /// Becomes the 4-byte controller ID.
    let controllerId: UInt32

    // MARK: - Keypair (main signing key private + public)

    let privateKeyHex: String
    let publicKeyHex: String

    // MARK: - Certificate Chain

    let intermediateCABase64: String
    let tlsCertificateBase64: String


    // MARK: - Convenience

    var privateKey: Data { Data(hex: privateKeyHex) }
    var publicKey: Data { Data(hex: publicKeyHex) }

    var intermediateCA: Data? { Data(base64Encoded: intermediateCABase64) }
    var tlsCertificate: Data? { Data(base64Encoded: tlsCertificateBase64) }

    var controllerIdData: Data {
        var value = controllerId.bigEndian
        return Data(bytes: &value, count: 4)
    }
}
