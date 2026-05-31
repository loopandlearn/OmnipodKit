//
//  TestUtilities.swift
//  OmniTests
//
//  From OmniBLE/OmniBLETests/TestUtilities.swift
//  Created by Bill Gestrich on 12/11/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

@testable import OmnipodKit

enum OmniTestFixtures {
    /// BLE packet layout for Omnipod DASH tests ported from OmniBLE.
    static let dashBlePacketLayout = BlePodProfile.omnipodDash.packetLayout
    /// BLE packet layout for Omnipod 5 (244-byte MTU).
    static let o5BlePacketLayout = BlePodProfile.omnipod5.packetLayout
}

extension String {
    //From start to, but not including, toIndex
    func substring(startIndex _startIndexInt: Int, toIndex _toIndexInt: Int) -> String? {
        assert(_startIndexInt < _toIndexInt)
        let startIndex = index(self.startIndex, offsetBy: _startIndexInt)
        let endIndex = index(self.startIndex, offsetBy: _toIndexInt - 1)
        return String(self[startIndex...endIndex])
    }
}
