//
//  O5AidCommands.swift
//  OmnipodKit
//
//  Created for O5 AID setup commands sent between AssignAddress and SetupPod.
//  These use an ASCII key-value protocol different from legacy Omnipod commands.
//
//  Command formats:
//    SET+GET: S[feature].[attr]=[data],G[feature].[attr]
//    GET only: G[feature].[attr]
//    Extended SET: SE[feature].[attr]=[data]
//
//  Response formats:
//    SET+GET response: [feature].[attr]=[data]
//    GET response: [feature].[attr]=[data]
//    Extended SET response: ES[feature].[attr]=[data]
//

import Foundation

/// Constructs O5 AID command payloads for the pre-SetupPod activation sequence.
///
/// These commands use SLPE (StringLengthPrefixEncoding) wrapping with ASCII key-value
/// pairs instead of binary Omnipod message blocks. The data values can be ASCII text
/// (e.g., "8" for DIA) or hex-encoded binary (e.g., "0003000E00" for TDI).
struct O5AidCommands {

    // MARK: - SLPE Payload Construction

    /// Constructs a SET+GET command payload in SLPE format.
    ///
    /// Wire format: `S[f].[a]=` + [2-byte BE length] + data + `,G[f].[a]`
    ///
    /// - Parameters:
    ///   - feature: The feature number (e.g., "3", "255")
    ///   - attribute: The attribute number (e.g., "2", "1")
    ///   - data: The ASCII data string to SET (e.g., "0003000E00", "8")
    /// - Returns: SLPE-encoded Data ready for the encrypted transport
    static func setGetPayload(feature: String, attribute: String, data: String) -> Data {
        let setKey = "S\(feature).\(attribute)="
        let getKey = ",G\(feature).\(attribute)"
        return StringLengthPrefixEncoding.formatKeys(
            keys: [setKey, getKey],
            payloads: [Data(data.utf8), Data()]
        )
    }

    /// Constructs a GET-only command payload in SLPE format.
    ///
    /// Wire format: `G[f].[a]` (just the key string, no length prefix or data)
    ///
    /// - Parameters:
    ///   - feature: The feature number (e.g., "3")
    ///   - attribute: The attribute number (e.g., "12")
    /// - Returns: SLPE-encoded Data ready for the encrypted transport
    static func getPayload(feature: String, attribute: String) -> Data {
        let getKey = "G\(feature).\(attribute)"
        return StringLengthPrefixEncoding.formatKeys(
            keys: [getKey],
            payloads: [Data()]
        )
    }

    /// Constructs an Extended SET command payload in SLPE format.
    ///
    /// Wire format: `SE[f].[a]=` + [2-byte BE length] + data
    ///
    /// - Parameters:
    ///   - feature: The feature number (e.g., "255", "2")
    ///   - attribute: The attribute number (e.g., "2", "1")
    ///   - data: The ASCII data string to SET
    /// - Returns: SLPE-encoded Data ready for the encrypted transport
    static func extendedSetPayload(feature: String, attribute: String, data: String) -> Data {
        let setKey = "SE\(feature).\(attribute)="
        return StringLengthPrefixEncoding.formatKeys(
            keys: [setKey],
            payloads: [Data(data.utf8)]
        )
    }

    /// Returns the expected response prefix for a SET+GET or GET-only command.
    /// Response format: `[feature].[attribute]=`
    static func responsePrefix(feature: String, attribute: String) -> String {
        return "\(feature).\(attribute)="
    }

    /// Returns the expected response prefix for an Extended SET command.
    /// Response format: `ES[feature].[attribute]=`
    static func extendedSetResponsePrefix(feature: String, attribute: String) -> String {
        return "ES\(feature).\(attribute)="
    }

    // MARK: - AID Command Definitions

    /// Command 1: UTC time setting.
    /// Sends: `SE255.2=[unix_timestamp]`
    /// Response: `ES255.2=0`
    struct UtcCommand {
        static let feature = "255"
        static let attribute = "2"

        /// Creates the SLPE-wrapped payload for the UTC command.
        /// - Parameter timestamp: Unix timestamp (defaults to current time)
        /// - Returns: Tuple of (payload, responsePrefix)
        static func payload(timestamp: UInt64? = nil) -> (data: Data, responsePrefix: String) {
            let ts = timestamp ?? UInt64(Date().timeIntervalSince1970)
            let data = O5AidCommands.extendedSetPayload(feature: feature, attribute: attribute, data: "\(ts)")
            let prefix = O5AidCommands.extendedSetResponsePrefix(feature: feature, attribute: attribute)
            return (data, prefix)
        }
    }

    /// Command 2: TDI (Therapy Delivery Information) configuration.
    /// Sends: `S3.2=0003000E00,G3.2`
    /// Response: `3.2=0003000E00`
    ///
    /// The value `0003000E00` is hex-encoded: version(00), therapy type(03), delivery mode(00), bolus speed(0E), ?(00).
    struct TdiCommand {
        static let feature = "3"
        static let attribute = "2"
        static let defaultData = "0003000E00"

        static func payload(data: String = defaultData) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, data: data)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 3: Target BG profile — 48 half-hour BG target values for a 24-hour day.
    /// Sends: `S3.1=00c0[48 x 4-byte-BE target values],G3.1`
    /// Response: `3.1=00c0[48 x 4-byte-BE target values]`
    ///
    /// The `00c0` prefix = 192 = 48 * 4 (byte count of the 48 target entries).
    /// Each target is a 4-byte big-endian value in mg/dL (e.g., 0x006e = 110).
    struct TargetBgProfileCommand {
        static let feature = "3"
        static let attribute = "1"
        static let defaultTargetMgdl: UInt32 = 110  // 0x006e

        /// Creates the SLPE-wrapped payload for the target BG profile command.
        /// - Parameter targets: Array of 48 BG targets in mg/dL (defaults to all 110)
        /// - Returns: Tuple of (payload, responsePrefix)
        static func payload(targets: [UInt32]? = nil) -> (data: Data, responsePrefix: String) {
            let targetValues = targets ?? Array(repeating: defaultTargetMgdl, count: 48)
            assert(targetValues.count == 48, "Target BG profile must have exactly 48 half-hour entries")

            // Build the hex string: "00c0" prefix + 48 x 8-char hex values
            var hexString = "00c0"
            for target in targetValues {
                hexString += String(format: "%08x", target)
            }

            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, data: hexString)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 4: DIA (Duration of Insulin Action) setting.
    /// Sends: `S3.9=8,G3.9`
    /// Response: `3.9=8`
    ///
    /// Value "8" likely represents 8 half-hours = 4 hours DIA, but could be the raw value.
    struct DiaCommand {
        static let feature = "3"
        static let attribute = "9"
        static let defaultValue = "8"

        static func payload(value: String = defaultValue) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, data: value)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 5: EGV (Estimated Glucose Value) configuration.
    /// Sends: `S3.7=3670015,G3.7`
    /// Response: `3.7=3670015`
    ///
    /// The value `3670015` is a bitfield or composite config value for CGM/EGV settings.
    struct EgvCommand {
        static let feature = "3"
        static let attribute = "7"
        static let defaultValue = "3670015"

        static func payload(value: String = defaultValue) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, data: value)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 6: Algorithm Insulin History — sent 3 times with 24 records each.
    /// Sends: `SE2.1=00a8[168 bytes hex = 24 records x 7 bytes each]`
    /// Response: `ES2.1=0`
    ///
    /// The `00a8` prefix = 168 = 24 * 7 (byte count of the 24 history records).
    /// Each record is 7 bytes. For initial setup with no history, all records are zeros.
    struct AlgorithmInsulinHistoryCommand {
        static let feature = "2"
        static let attribute = "1"
        static let recordsPerBatch = 24
        static let bytesPerRecord = 7

        /// Creates the SLPE-wrapped payload for one batch of insulin history.
        /// - Parameter records: Array of 24 records, each 7 bytes (defaults to all zeros)
        /// - Returns: Tuple of (payload, responsePrefix)
        static func payload(records: [Data]? = nil) -> (data: Data, responsePrefix: String) {
            let recordData: [Data]
            if let records = records {
                assert(records.count == recordsPerBatch, "Must have exactly \(recordsPerBatch) records")
                recordData = records
            } else {
                // Default: 24 zero records of 7 bytes each
                recordData = Array(repeating: Data(count: bytesPerRecord), count: recordsPerBatch)
            }

            // Build hex string: "00a8" prefix + 168 bytes of record data as hex
            let totalBytes = recordsPerBatch * bytesPerRecord  // 168
            var hexString = String(format: "%04x", totalBytes)  // "00a8"
            for record in recordData {
                assert(record.count == bytesPerRecord, "Each record must be exactly \(bytesPerRecord) bytes")
                hexString += record.hexadecimalString
            }

            let payload = O5AidCommands.extendedSetPayload(feature: feature, attribute: attribute, data: hexString)
            let prefix = O5AidCommands.extendedSetResponsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 7: Unified AID Pod Status query.
    /// Sends: `G3.12`
    /// Response: `3.12=[29 bytes of AID status data]`
    struct UnifiedAidPodStatusCommand {
        static let feature = "3"
        static let attribute = "12"

        static func payload() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }
}
