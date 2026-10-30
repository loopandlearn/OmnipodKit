//
//  UIDevice+watchOS.swift
//  OmnipodKit
//
//  watchOS has no UIDevice. The BLE layer's affected-iPhone check compiles there and reads false:
//  a watch is never an affected iPhone.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

#if os(watchOS)
import Foundation

enum UIDevice {
    static var hasPossibleInPlayBLEIssues: Bool { false }
}
#endif
