//
//  PairResult.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/Pair/PairResult.swift
//  Created by Randall Knutson on 8/4/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import Foundation

struct PairResult {
    var ltk: Data
    var address: UInt32
    var msgSeq: UInt8
    /// What the pod's certificate said about it. DASH pods do not present
    /// one, so they are always unverified.
    var podAuthenticity: O5PodAuthenticity = .unverified
}
