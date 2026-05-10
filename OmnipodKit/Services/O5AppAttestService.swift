//
//  O5AppAttestService.swift
//  OmnipodKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import CryptoKit
import DeviceCheck

let o5KeyManagerBaseURL = "https://api.osaid-keymanager.org"

struct O5AuthError: Error {
    let message: String
    let httpStatusCode: Int?
    let underlyingError: Error?

    init(message: String, httpStatusCode: Int? = nil, underlyingError: Error? = nil) {
        self.message = message
        self.httpStatusCode = httpStatusCode
        self.underlyingError = underlyingError
    }
}

class O5AppAttestService {

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// Runs the full App Attest + keypair fetch flow.
    /// Calls completion on the main queue.
    func fetchKeypair(completion: @escaping (Result<O5RegistrationData, O5AuthError>) -> Void) {
        Task {
            do {
                let result = try await performFetchFlow()
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

    private func performFetchFlow() async throws -> O5RegistrationData {
        let attestService = DCAppAttestService.shared

        guard attestService.isSupported else {
            throw O5AuthError(message: "App Attest is not supported on this device.")
        }

        // Step 1: Generate a fresh App Attest key
        let keyId = try await generateKey(attestService)

        // Step 2: Get challenge from server
        let challenge = try await getChallenge()

        // Step 3: Attest the key with Apple
        let challengeHash = Data(SHA256.hash(data: Data(challenge.utf8)))
        let attestation = try await attestKey(attestService, keyId: keyId, clientDataHash: challengeHash)

        // Step 4: Exchange attestation for a keypair in a single request.
        let appId = try getAppId()
        return try await claimKeypair(
            attestation: attestation,
            keyId: keyId,
            challenge: challenge,
            appId: appId
        )
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

    private func getTeamId() -> String? {
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
