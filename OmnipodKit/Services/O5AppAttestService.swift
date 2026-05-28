//
//  O5AppAttestService.swift
//  OmnipodKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import CryptoKit
import DeviceCheck
import Network

let o5KeyManagerBaseURL = "https://api.osaid-keymanager.org"
private let omnipodkitApiVersion = "1.0.0"

struct O5AuthError: Error {
    let message: String
    let recoverySuggestion: String?
    let httpStatusCode: Int?
    let underlyingError: Error?

    init(message: String, recoverySuggestion: String? = nil, httpStatusCode: Int? = nil, underlyingError: Error? = nil) {
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.httpStatusCode = httpStatusCode
        self.underlyingError = underlyingError
    }
}

/// Ordered phases of the keypair fetch flow. UI consumers can use `index` /
/// `totalSteps` to drive a determinate progress bar.
enum O5KeyFetchProgress: Int, CaseIterable {
    case checkingInternetConnection
    case checkingKeymanagerServiceStatus
    case checkingDeviceSupport
    case resolvingAppIdentity
    case generatingAttestKey
    case requestingChallenge
    case attestingWithApple
    case downloadingCertificate

    var index: Int { rawValue + 1 }
    static var totalSteps: Int { Self.allCases.count }

    var localizedDescription: String {
        switch self {
        case .checkingInternetConnection:
            return LocalizedString("Checking Internet connection…", comment: "O5 fetch progress: internet pre-check")
        case .checkingKeymanagerServiceStatus:
            return LocalizedString("Checking server status…", comment: "O5 fetch progress: server status")
        case .checkingDeviceSupport:
            return LocalizedString("Checking device support…", comment: "O5 fetch progress: device support")
        case .resolvingAppIdentity:
            return LocalizedString("Resolving app identity…", comment: "O5 fetch progress: team id / bundle id")
        case .generatingAttestKey:
            return LocalizedString("Generating App Attest key…", comment: "O5 fetch progress: generate key")
        case .requestingChallenge:
            return LocalizedString("Requesting server challenge…", comment: "O5 fetch progress: challenge")
        case .attestingWithApple:
            return LocalizedString("Attesting with Apple…", comment: "O5 fetch progress: attestation")
        case .downloadingCertificate:
            return LocalizedString("Downloading certificate…", comment: "O5 fetch progress: download")
        }
    }
}

class O5AppAttestService {

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// Runs the full App Attest + keypair fetch flow.
    /// Calls `progress` on the main queue before starting each phase, then `completion`
    /// on the main queue with the final result.
    func fetchKeypair(
        progress: @escaping (O5KeyFetchProgress) -> Void = { _ in },
        completion: @escaping (Result<O5RegistrationData, O5AuthError>) -> Void
    ) {
        let report: (O5KeyFetchProgress) -> Void = { step in
            DispatchQueue.main.async { progress(step) }
        }
        Task {
            do {
                let result = try await performFetchFlow(progress: report)
                DispatchQueue.main.async { completion(.success(result)) }
            } catch let error as O5AuthError {
                DispatchQueue.main.async { completion(.failure(error)) }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(O5AuthError(message: error.localizedDescription, underlyingError: error)))
                }
            }
        }
    }

    // MARK: - Async flow

    private func performFetchFlow(progress: (O5KeyFetchProgress) -> Void) async throws -> O5RegistrationData {
        progress(.checkingInternetConnection)
        try await checkInternetConnection()

        progress(.checkingKeymanagerServiceStatus)
        try await checkServerStatus()

        progress(.checkingDeviceSupport)
        let attestService = DCAppAttestService.shared
        guard attestService.isSupported else {
            throw O5AuthError(message: "App Attest is not supported on this device.")
        }

        // Resolve app identity early so failures (e.g. missing team ID) surface before
        // we burn an App Attest key generation, and so the user sees which step failed.
        progress(.resolvingAppIdentity)
        let appId = try getAppId()

        progress(.generatingAttestKey)
        let keyId = try await generateKey(attestService)

        progress(.requestingChallenge)
        let challenge = try await getChallenge()

        progress(.attestingWithApple)
        let challengeHash = Data(SHA256.hash(data: Data(challenge.utf8)))
        let attestation = try await attestKey(attestService, keyId: keyId, clientDataHash: challengeHash)

        progress(.downloadingCertificate)
        return try await claimKeypair(
            attestation: attestation,
            keyId: keyId,
            challenge: challenge,
            appId: appId
        )
    }

    // MARK: - Pre-flight checks

    /// One-shot link-layer reachability check. Throws an offline-flavored
    /// `O5AuthError` when the device has no usable path within `timeout`.
    /// Cheap optimistic check — cannot detect captive portals or DNS
    /// failures; those still surface as URLErrors from later HTTP requests.
    private func checkInternetConnection(timeout: TimeInterval = 2.0) async throws {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }

        let satisfied: Bool = await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "org.nightscout.o5-reachability")
            var resumed = false
            let resume: (Bool) -> Void = { value in
                queue.async {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: value)
                }
            }
            monitor.pathUpdateHandler = { path in
                resume(path.status == .satisfied)
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                resume(false)
            }
        }

        if !satisfied {
            throw O5AuthError(
                message: LocalizedString(
                    "Could not connect to the Internet to fetch an Omnipod 5 Pod Certificate.",
                    comment: "O5 fetch failure: offline at pre-flight, primary line"),
                recoverySuggestion: LocalizedString(
                    "Please connect to Wi-Fi or Cellular Data and try again.",
                    comment: "O5 fetch failure: offline at pre-flight, recovery suggestion"))
        }
    }

    /// Calls the OSAID Keymanager service-status endpoint. If the server
    /// reports `available: false`, the user-facing `message` is surfaced
    /// verbatim and the flow aborts. Non-2xx HTTP and transport failures
    /// flow through the existing `performRequest` → `authError` path.
    /// Unparseable 2xx responses are treated as failures (fail-closed),
    /// not as implicit availability.
    private func checkServerStatus() async throws {
        var request = URLRequest(url: URL(string: "\(o5KeyManagerBaseURL)/api/status/ios")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "omnipodkit_api_version": omnipodkitApiVersion,
        ])

        let (data, response) = try await performRequest(request)

        let malformedMessage = LocalizedString(
            "The key-management server is temporarily unavailable: received unexpected response.",
            comment: "O5 fetch: malformed status response, primary line")
        let malformedRecovery = LocalizedString(
            "Please try again later.",
            comment: "O5 fetch: malformed status response, recovery suggestion")

        guard let json = parseJSON(data) else {
            throw O5AuthError(
                message: malformedMessage,
                recoverySuggestion: malformedRecovery,
                httpStatusCode: response.statusCode)
        }
        guard let available = json["available"] as? Bool else {
            throw O5AuthError(
                message: malformedMessage,
                recoverySuggestion: malformedRecovery,
                httpStatusCode: response.statusCode)
        }

        if available { return }

        let trimmed = (json["message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let unavailable = LocalizedString(
            "The key-management server is temporarily unavailable.",
            comment: "O5 fetch: keymanager-reported unavailable, no message")
        let displayed = (trimmed?.isEmpty == false) ? trimmed! : unavailable
        throw O5AuthError(message: displayed, httpStatusCode: response.statusCode)
    }

    // MARK: - App Attest

    private func generateKey(_ service: DCAppAttestService) async throws -> String {
        do {
            return try await service.generateKey()
        } catch {
            throw O5AuthError(message: "Failed to generate App Attest key: \(error.localizedDescription)", underlyingError: error)
        }
    }

    private func attestKey(_ service: DCAppAttestService, keyId: String, clientDataHash: Data) async throws -> Data {
        do {
            return try await service.attestKey(keyId, clientDataHash: clientDataHash)
        } catch {
            throw O5AuthError(message: "App Attest attestation failed: \(error.localizedDescription)", underlyingError: error)
        }
    }

    // MARK: - App Identity

    private func getAppId() throws -> String {
        guard let bundleId = Bundle.main.bundleIdentifier else {
            throw O5AuthError(message: "Could not determine bundle identifier.")
        }
        guard let teamId = getTeamId() else {
            throw O5AuthError(message: "Could not determine Team ID from provisioning profile.")
        }
        return "\(teamId).\(bundleId)"
    }

    /// Resolves the Apple Team ID across environments. Tries, in order:
    ///   1. The signed `embedded.mobileprovision` (real-device / TestFlight / App Store builds)
    ///   2. The Keychain access-group prefix (works in simulator and on device whenever
    ///      the process has a code-signing identity — does not require a provisioning profile)
    ///   3. An `OmnipodKitTeamIdentifier` key in OmnipodKit's Info.plist, populated from the
    ///      `$(DEVELOPMENT_TEAM)` build setting (last-ditch override for environments
    ///      where neither runtime source is available, e.g. unsigned test harnesses).
    private func getTeamId() -> String? {
        if let id = teamIdFromMobileProvision(), !id.isEmpty { return id }
        if let id = teamIdFromKeychainAccessGroup(), !id.isEmpty { return id }
        if let id = teamIdFromInfoPlist(), !id.isEmpty, !id.contains("$(") { return id }
        return nil
    }

    private func teamIdFromMobileProvision() -> String? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }

        // The mobileprovision file is a CMS signed plist. Find the plist XML within it.
        guard let plistString = String(data: data, encoding: .ascii),
              let plistStart = plistString.range(of: "<?xml"),
              let plistEnd = plistString.range(of: "</plist>") else {
            return nil
        }

        let xml = String(plistString[plistStart.lowerBound...plistEnd.upperBound])
        guard let plistData = xml.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let teamIds = plist["TeamIdentifier"] as? [String],
              let teamId = teamIds.first else {
            return nil
        }
        return teamId
    }

    /// Adds (or finds) a probe Keychain item and reads its `kSecAttrAccessGroup`,
    /// which iOS prefixes with the team ID: `<TEAMID>.<bundleId>`.
    private func teamIdFromKeychainAccessGroup() -> String? {
        let probeAccount = "org.nightscout.o5.teamid-probe"
        let probeService = "org.nightscout.o5.teamid-probe"

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: probeAccount,
            kSecAttrService as String: probeService,
        ]

        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = Data()
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            addQuery[kSecReturnAttributes as String] = true
            status = SecItemAdd(addQuery as CFDictionary, &result)
        }

        guard status == errSecSuccess,
              let attrs = result as? [String: Any],
              let accessGroup = attrs[kSecAttrAccessGroup as String] as? String,
              let prefix = accessGroup.split(separator: ".").first
        else { return nil }

        return String(prefix)
    }

    /// Reads `OmnipodKitTeamIdentifier` from OmnipodKit's Info.plist. The xcconfig
    /// substitutes `$(DEVELOPMENT_TEAM)` at build time. We read from the framework's
    /// bundle (not `Bundle.main`) because the substitution happens in OmnipodKit's plist.
    private func teamIdFromInfoPlist() -> String? {
        let frameworkBundle = Bundle(for: O5AppAttestService.self)
        return frameworkBundle.object(forInfoDictionaryKey: "OmnipodKitTeamIdentifier") as? String
    }

    // MARK: - Server API

    private func getChallenge() async throws -> String {
        var request = URLRequest(url: URL(string: "\(o5KeyManagerBaseURL)/api/auth/ios/challenge")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await performRequest(request)

        guard let json = parseJSON(data),
              let challenge = json["challenge"] as? String
        else {
            throw authError(data: data, response: response, fallback: "Failed to get challenge.")
        }
        return challenge
    }

    private func claimKeypair(attestation: Data, keyId: String, challenge: String, appId: String) async throws -> O5RegistrationData {
        var request = URLRequest(url: URL(string: "\(o5KeyManagerBaseURL)/api/o5/keypair")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "attestation": attestation.base64EncodedString(),
            "key_id": keyId,
            "challenge": challenge,
            "app_id": appId,
        ])

        let (data, response) = try await performRequest(request)

        guard let json = parseJSON(data),
              let registrationData = O5RegistrationData.fromJSON(json)
        else {
            throw authError(data: data, response: response, fallback: "Failed to claim keypair.")
        }
        return registrationData
    }

    // MARK: - Helpers

    private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw O5AuthError(message: error.localizedDescription, underlyingError: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw O5AuthError(message: "Invalid response from server.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw authError(data: data, response: httpResponse, fallback: "HTTP \(httpResponse.statusCode)")
        }

        return (data, httpResponse)
    }

    private func parseJSON(_ data: Data?) -> [String: Any]? {
        guard let data = data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func authError(data: Data?, response: URLResponse?, fallback: String) -> O5AuthError {
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        let message: String
        if let json = parseJSON(data) {
            message = (json["message"] as? String) ?? (json["error"] as? String) ?? fallback
        } else {
            message = fallback
        }
        return O5AuthError(message: message, httpStatusCode: statusCode)
    }
}
