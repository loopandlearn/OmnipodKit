//
//  OmnipodKitWatchPlugin.swift
//  OmnipodKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

#if os(watchOS)
import Foundation
import LoopKit

/// The watch loads this kit at run time, as the phone loads its plugins: this is the bundle's principal class.
@objc(OmnipodKitWatchPlugin)
final class OmnipodKitWatchPlugin: NSObject, PumpManagerPlugin {
    var pumpManagerType: PumpManager.Type? { OmniPumpManager.self }
}
#endif
