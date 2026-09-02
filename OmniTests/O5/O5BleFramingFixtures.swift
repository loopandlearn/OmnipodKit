//
//  O5BleFramingFixtures.swift
//  OmniTests
//

import Foundation

enum O5BleFramingFixtures {

    static func generatedPayload(count: Int, seed: UInt8 = 0xA5) -> Data {
        guard count >= 0 else { return Data() }
        return Data((0..<count).map { UInt8((Int(seed) + $0) & 0xFF) })
    }
}
