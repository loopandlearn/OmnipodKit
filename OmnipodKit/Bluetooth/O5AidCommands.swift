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
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// Constructs O5 AID command payloads for the pre-SetupPod activation sequence.
///
/// These commands use plain ASCII key-value format (NOT the SLPE length-prefixed encoding
/// used by standard S0.0= commands). The data values can be ASCII text
/// (e.g., "8" for DIA) or raw binary bytes (e.g., 0x0003000E00 for TDI).
///
struct O5AidCommands {

    // MARK: - AID Payload Construction
    //
    // AID commands use plain ASCII key-value format with NO length prefix.
    // This is different from standard Omnipod SLPE (S0.0=...,G0.0) which uses
    // 2-byte big-endian length prefixes via StringLengthPrefixEncoding.formatKeys().
    //
    // Confirmed wire format is: ASCII key + data + ASCII suffix
    // For BINARY commands, data is raw bytes. For ASCII commands, data is text.

    /// Constructs a SET+GET command payload with ASCII text data.
    ///
    /// Wire format: `S[f].[a]=[ASCII data],G[f].[a]`
    static func setGetPayload(feature: String, attribute: String, data: String) -> Data {
        let command = "S\(feature).\(attribute)=\(data),G\(feature).\(attribute)"
        return Data(command.utf8)
    }

    /// Constructs a SET+GET command payload with raw binary data.
    ///
    /// Wire format: `S[f].[a]=` + [raw binary bytes] + `,G[f].[a]`
    static func setGetPayload(feature: String, attribute: String, binaryData: Data) -> Data {
        let prefix = Data("S\(feature).\(attribute)=".utf8)
        let suffix = Data(",G\(feature).\(attribute)".utf8)
        return prefix + binaryData + suffix
    }

    /// Constructs a GET-only command payload.
    ///
    /// Wire format: `G[f].[a]`
    static func getPayload(feature: String, attribute: String) -> Data {
        let command = "G\(feature).\(attribute)"
        return Data(command.utf8)
    }

    /// Constructs an Extended SET command payload with ASCII text data.
    ///
    /// Wire format: `SE[f].[a]=[ASCII data]`
    static func extendedSetPayload(feature: String, attribute: String, data: String) -> Data {
        let command = "SE\(feature).\(attribute)=\(data)"
        return Data(command.utf8)
    }

    /// Constructs an Extended SET command payload with raw binary data.
    ///
    /// Wire format: `SE[f].[a]=` + [raw binary bytes]
    static func extendedSetPayload(feature: String, attribute: String, binaryData: Data) -> Data {
        let prefix = Data("SE\(feature).\(attribute)=".utf8)
        return prefix + binaryData
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

    /// Command 2: TDI (Total Daily Insulin) configuration.
    /// Binary wire format: `S3.2=` + [0x00,0x03,0x00,0x0E,0x00] + `,G3.2` (15 bytes)
    /// Response: `3.2=` + [5 binary bytes echoed back]
    ///
    /// The 5 data bytes: body length(0003), TDI in U/day(000E = 14U), flags(00; bit 0 = sufficient insulin history).
    struct TdiCommand {
        static let feature = "3"
        static let attribute = "2"
        static let defaultBinaryData = binaryData(totalDailyInsulin: 14, sufficientInsulinHistory: false)

        static func binaryData(totalDailyInsulin: UInt16, sufficientInsulinHistory: Bool) -> Data {
            var data = Data()
            data.appendBigEndian(UInt16(3))
            data.appendBigEndian(totalDailyInsulin)
            data.append(UInt8(sufficientInsulinHistory ? 0x01 : 0x00))
            return data
        }

        static func payload() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, binaryData: defaultBinaryData)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 3: Target BG profile — 48 half-hour BG target values for a 24-hour day.
    /// Binary wire format: `S3.1=` + [0x00,0xC0] + [48 x 4-byte-BE targets] + `,G3.1` (204 bytes)
    /// Response: `3.1=` + [194 binary bytes echoed back]
    ///
    /// The 0x00C0 prefix = 192 = 48 * 4 (byte count of the 48 target entries).
    /// Each target is a 4-byte big-endian value in mg/dL (e.g., 0x0000006E = 110).
    struct TargetBgProfileCommand {
        static let feature = "3"
        static let attribute = "1"
        static let defaultTargetMgdl: UInt32 = 110  // 0x006e

        static func payload(targets: [UInt32]? = nil) -> (data: Data, responsePrefix: String) {
            let targetValues = targets ?? Array(repeating: defaultTargetMgdl, count: 48)
            assert(targetValues.count == 48, "Target BG profile must have exactly 48 half-hour entries")

            var binaryData = Data()
            let totalBytes = UInt16(targetValues.count * 4)  // 192 = 0x00C0
            binaryData.appendBigEndian(totalBytes)
            for target in targetValues {
                binaryData.appendBigEndian(target)
            }
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 4: DIA (Duration of Insulin Action) setting.
    /// Sends: `S3.9=8,G3.9`
    /// Response: `3.9=8`
    ///
    /// Value "8" is 8 half-hours = 4 hours DIA. Valid range is 4–12 (2–6 hours).
    struct DiaCommand {
        static let feature = "3"
        static let attribute = "9"
        static let defaultValue = value(halfHours: 8)
        static let validHalfHours: ClosedRange<Int> = 4...12

        static func value(halfHours: Int) -> String {
            return String(halfHours)
        }

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
    /// The value packs the low and high EGV thresholds in mg/dL as `high | (low << 16)`:
    /// `3670015` = 0x0037FFFF = low 55, high 65535.
    struct EgvCommand {
        static let feature = "3"
        static let attribute = "7"
        static let defaultValue = value(low: 55, high: 65535)

        static func value(low: UInt16, high: UInt16) -> String {
            return String(UInt32(high) | (UInt32(low) << 16))
        }

        static func payload(value: String = defaultValue) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, data: value)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 6: Algorithm Insulin History — sent 3 times with 24 records each.
    /// Binary wire format: `SE2.1=` + [0x00,0xA8] + [168 raw bytes] (176 bytes)
    /// Response: `ES2.1=0`
    ///
    /// The 0x00A8 prefix = 168 = 24 * 7 (byte count of the 24 history records).
    /// Each record is 7 bytes: UTC timestamp(4-byte BE), then algorithm, correction and meal pulse counts(1 byte each).
    /// For initial setup with no history, all records are zeros.
    struct AlgorithmInsulinHistoryCommand {
        static let feature = "2"
        static let attribute = "1"
        static let recordsPerBatch = 24
        static let bytesPerRecord = 7

        static func record(timestamp: UInt32, algorithmPulses: UInt8, correctionPulses: UInt8, mealPulses: UInt8) -> Data {
            var data = Data()
            data.appendBigEndian(timestamp)
            data.append(contentsOf: [algorithmPulses, correctionPulses, mealPulses])
            return data
        }

        static func payload(records: [Data]? = nil) -> (data: Data, responsePrefix: String) {
            let recordData: [Data]
            if let records = records {
                assert(records.count == recordsPerBatch, "Must have exactly \(recordsPerBatch) records")
                recordData = records
            } else {
                // Default: 24 zero records of 7 bytes each
                recordData = Array(repeating: Data(count: bytesPerRecord), count: recordsPerBatch)
            }

            let totalBytes = UInt16(recordsPerBatch * bytesPerRecord)  // 168 = 0x00A8
            var binaryData = Data()
            binaryData.appendBigEndian(totalBytes)
            for record in recordData {
                assert(record.count == bytesPerRecord, "Each record must be exactly \(bytesPerRecord) bytes")
                binaryData.append(record)
            }
            let payload = O5AidCommands.extendedSetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.extendedSetResponsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 7 (Gen1): AID Pod Status query.
    /// Sends: `G3.11`
    /// Response: `3.11=[fixed 30-byte payload: 2-byte length + 28-byte body]`
    ///
    /// Used for Gen1 pods (firmware majorVersion < 7).
    struct AidPodStatusCommand {
        static let feature = "3"
        static let attribute = "11"

        static func payload() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 7 (non-Gen1): Unified AID Pod Status query.
    /// Sends: `G3.12`
    /// Response: `3.12=[29 bytes of AID status data]`
    ///
    /// Used for non-Gen1 pods (firmware majorVersion >= 7).
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
