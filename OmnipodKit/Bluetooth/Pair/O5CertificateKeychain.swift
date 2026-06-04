//
//  O5CertificateKeychain.swift
//  OmnipodKit
//
//  Persists O5RegistrationData entries in the iOS Keychain so the user does
//  not have to redo the O5 key download on every cold start.
//
//  Note: the "forget pod" flow intentionally does NOT call into this module —
//  these credentials are tied to the controller identity, not to any pod
//  session, and must outlive pod un-pair. Removal happens only via the
//  explicit "Forget Saved Certificate" UI in CertificateDetailsView.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import Security
import os.log

enum O5CertificateKeychain {

    private static let log = OSLog(subsystem: "com.loopkit.OmnipodKit", category: "O5CertificateKeychain")

    private static let service = "org.nightscout.o5certificates"
    private static let schemaVersion = 1

    private static var restored = false
    private static let restoreLock = NSLock()

    enum Error: Swift.Error {
        case encodingFailed
        case unhandled(OSStatus)
    }

    /// One persisted entry: registration data plus the source that originally produced it.
    struct Entry {
        let data: O5RegistrationData
        let source: O5RegistrationSource
    }

    // MARK: - Public API

    static func save(_ data: O5RegistrationData, source: O5RegistrationSource) throws {
        let payload = try encode(data, source: source)
        let account = String(data.controllerId)

        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: payload,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]

        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw Error.unhandled(updateStatus)
        }

        var addQuery = updateQuery
        addQuery[kSecValueData as String] = payload
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecAttrSynchronizable as String] = false

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw Error.unhandled(addStatus)
        }
    }

    static func delete(controllerId: UInt32) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: String(controllerId),
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw Error.unhandled(status)
        }
    }

    static func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw Error.unhandled(status)
        }
    }

    static func loadAll() -> [Entry] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return [] }
        guard let items = result as? [[String: Any]] else { return [] }

        return items.compactMap { item -> Entry? in
            guard let data = item[kSecValueData as String] as? Data else { return nil }
            return decode(data)
        }
    }

    static func contains(controllerId: UInt32) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: String(controllerId),
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Loads every persisted certificate into the in-memory `O5RegistrationData` registry.
    /// Idempotent and cheap to call — the actual Keychain read happens at most once per process.
    static func restoreIntoRegistry() {
        restoreLock.lock()
        defer { restoreLock.unlock() }
        if restored { return }
        restored = true
        for entry in loadAll() {
            O5RegistrationData.install(entry.data, source: entry.source)
        }
    }

    // MARK: - Codec

    private static func encode(_ data: O5RegistrationData, source: O5RegistrationSource) throws -> Data {
        var json = data.toJSON()
        json["v"] = schemaVersion
        json["source"] = source.rawValue
        do {
            return try JSONSerialization.data(withJSONObject: json, options: [])
        } catch {
            throw Error.encodingFailed
        }
    }

    private static func decode(_ blob: Data) -> Entry? {
        guard let obj = try? JSONSerialization.jsonObject(with: blob),
              let json = obj as? [String: Any],
              let data = O5RegistrationData.fromJSON(json)
        else { return nil }
        let source: O5RegistrationSource = {
            if let raw = json["source"] as? String, let s = O5RegistrationSource(rawValue: raw) {
                return s
            }
            return .imported
        }()
        return Entry(data: data, source: source)
    }
}
