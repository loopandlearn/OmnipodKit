//
//  O5PairingConfiguration.swift
//  OmnipodKit
//
//  Created for O5 pairing troubleshooting.
//  Automatically cycles through different configuration combinations on successive pairing attempts.
//

import Foundation
import os.log

/// Represents a pairing configuration as a bitmask. Each bit enables/disables one setting.
/// The configuration cycles through all 2^N combinations on successive pairing attempts,
/// starting from 0 (all defaults / current behavior).
///
/// Bit assignments (0 = default/current behavior, 1 = alternate):
///   Bit 0: keysNonceFirst         — 0: keys-grouped (default), 1: nonces-first
///   Bit 1: bytesAsControllerId    — 0: true/use controllerID (default), 1: false/use zeros
///   Bit 2: useUInt32LengthPrefixes — 0: UInt64 BE (default), 1: UInt32 BE
///   Bit 3: kdfZeroControllerID    — 0: real controllerID (default), 1: zero controllerID in KDF
///   Bit 4: swapCertIndexes        — 0: INS02PG1 in SPS2.1 (default), 1: TLS in SPS2.1
///   Bit 5: nonceLastBytes         — 0: first 6 bytes (default), 1: last 6 bytes
///   Bit 6: swapNonceDirection     — 0: write=0x01/read=0x02 (default), 1: swapped
///   Bit 7: useWithResponseForCmds — 0: .withoutResponse for O5 (default), 1: .withResponse
struct O5PairingConfiguration {

    private static let log = OSLog(category: "O5PairingConfig")

    /// UserDefaults key for persisting the combination counter across app launches.
    private static let counterKey = "O5PairingConfiguration.combinationCounter"

    /// Total number of toggleable settings (bits).
    static let bitCount = 8

    /// Total number of combinations: 2^bitCount.
    static let totalCombinations = 1 << bitCount  // 256

    /// The raw bitmask for this configuration (0 ..< totalCombinations).
    let mask: UInt32

    // MARK: - Derived settings from the bitmask

    var keysNonceFirst: Bool         { return (mask & (1 << 0)) != 0 }
    var bytesAsControllerId: Bool    { return (mask & (1 << 1)) == 0 }  // inverted: bit=0 means true (default)
    var useUInt32LengthPrefixes: Bool { return (mask & (1 << 2)) != 0 }
    var kdfZeroControllerID: Bool    { return (mask & (1 << 3)) != 0 }
    var swapCertIndexes: Bool        { return (mask & (1 << 4)) != 0 }
    var nonceLastBytes: Bool         { return (mask & (1 << 5)) != 0 }
    var swapNonceDirection: Bool     { return (mask & (1 << 6)) != 0 }
    var useWithResponseForCommands: Bool { return (mask & (1 << 7)) != 0 }

    // MARK: - Shared state

    /// The current configuration for the active pairing attempt.
    /// Set at the start of each pairing attempt by `nextConfiguration()`.
    static var current: O5PairingConfiguration = O5PairingConfiguration(mask: 0)

    // MARK: - Initialization

    init(mask: UInt32) {
        self.mask = mask % UInt32(O5PairingConfiguration.totalCombinations)
    }

    // MARK: - Cycling

    /// Returns the current configuration for pairing.
    ///
    /// Bitmask cycling disabled — Config#10 confirmed correct (2026-02-16).
    /// Defaults locked in O5KeyExchange.swift. Always returns mask 0 so that
    /// O5KeyExchange's own default values (the confirmed-correct ones) are used.
    static func nextConfiguration() -> O5PairingConfiguration {
        // Bitmask cycling disabled — Config#10 confirmed correct (2026-02-16).
        // Mask 0x0A = bits 1+3 set: bytesAsControllerId=false, kdfZeroControllerID=true.
        let config = O5PairingConfiguration(mask: 0x0A)

        // --- Counter increment disabled: no longer cycling through combinations ---
        // let counter = UserDefaults.standard.integer(forKey: counterKey)
        // let config = O5PairingConfiguration(mask: UInt32(counter))
        // let next = (counter + 1) % totalCombinations
        // UserDefaults.standard.set(next, forKey: counterKey)

        // Store as the current active configuration
        current = config
        return config
    }

    /// Resets the counter back to 0 (e.g., after a successful pairing).
    static func resetCounter() {
        UserDefaults.standard.set(0, forKey: counterKey)
        log.default("O5PairingConfiguration: counter reset to 0")
    }

    /// Returns the current counter value without advancing it.
    static func currentCounter() -> Int {
        return UserDefaults.standard.integer(forKey: counterKey)
    }

    // MARK: - Apply to O5KeyExchange

    /// Applies this configuration's settings to an O5KeyExchange instance.
    func apply(to keyExchange: O5KeyExchange) {
        keyExchange.keysNonceFirst = keysNonceFirst
        keyExchange.bytesAsControllerId = bytesAsControllerId
        keyExchange.useUInt32LengthPrefixes = useUInt32LengthPrefixes
        keyExchange.kdfZeroControllerID = kdfZeroControllerID
        keyExchange.swapCertIndexes = swapCertIndexes
        keyExchange.nonceLastBytes = nonceLastBytes
        keyExchange.swapNonceDirection = swapNonceDirection
    }

    // MARK: - Logging

    /// Logs the full configuration prominently for correlation with pairing results.
    func logConfiguration() {
        let header = """
        ============================================================
        O5 PAIRING CONFIGURATION - Combination #\(mask) of \(O5PairingConfiguration.totalCombinations - 1)
        Bitmask: \(String(mask, radix: 2).leftPadded(toLength: O5PairingConfiguration.bitCount, with: "0"))  (0x\(String(format: "%02x", mask)))
        ============================================================
        """
        O5PairingConfiguration.log.default("%{public}@", header)

        let settings = """
          Bit 0 - keysNonceFirst:          \(keysNonceFirst)  \(keysNonceFirst ? "[ALT: nonces-first layout]" : "[DEFAULT: keys-grouped layout]")
          Bit 1 - bytesAsControllerId:      \(bytesAsControllerId)  \(bytesAsControllerId ? "[DEFAULT: use controllerID]" : "[ALT: use zeros]")
          Bit 2 - useUInt32LengthPrefixes:  \(useUInt32LengthPrefixes)  \(useUInt32LengthPrefixes ? "[ALT: UInt32 BE prefixes]" : "[DEFAULT: UInt64 BE prefixes]")
          Bit 3 - kdfZeroControllerID:      \(kdfZeroControllerID)  \(kdfZeroControllerID ? "[ALT: zero controllerID in KDF]" : "[DEFAULT: real controllerID in KDF]")
          Bit 4 - swapCertIndexes:          \(swapCertIndexes)  \(swapCertIndexes ? "[ALT: TLS in SPS2.1, INS02PG1 in SPS2]" : "[DEFAULT: INS02PG1 in SPS2.1, TLS in SPS2]")
          Bit 5 - nonceLastBytes:           \(nonceLastBytes)  \(nonceLastBytes ? "[ALT: last 6 bytes of nonce]" : "[DEFAULT: first 6 bytes of nonce]")
          Bit 6 - swapNonceDirection:       \(swapNonceDirection)  \(swapNonceDirection ? "[ALT: write=0x00/read=0x01]" : "[DEFAULT: write=0x01/read=0x02]")
          Bit 7 - useWithResponseForCmds:   \(useWithResponseForCommands)  \(useWithResponseForCommands ? "[ALT: .withResponse on cmd char]" : "[DEFAULT: .withoutResponse on cmd char]")
        ============================================================
        """
        O5PairingConfiguration.log.default("%{public}@", settings)
    }

    /// Short one-line summary for inline logging.
    var shortDescription: String {
        let bits = String(mask, radix: 2).leftPadded(toLength: O5PairingConfiguration.bitCount, with: "0")
        return "Config#\(mask) [\(bits)]"
    }
}

// MARK: - String padding helper

private extension String {
    func leftPadded(toLength length: Int, with character: Character) -> String {
        let padding = String(repeating: character, count: max(0, length - count))
        return padding + self
    }
}
