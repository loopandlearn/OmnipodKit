//
//  OmnipodKitPlugin.swift
//  OmnipodKit
//
//  Created by Joseph Moran on 01/05/25.
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKitUI
import OmnipodKit
import os.log

class OmnipodKitPlugin: NSObject, PumpManagerUIPlugin {
    private let log = OSLog(__subsystem: "OmnipodKitPlugin", category: "com.loopkit.omnipodkit")

    public var pumpManagerType: PumpManagerUI.Type? {
        return OmniPumpManager.self
    }

    public var cgmManagerType: CGMManagerUI.Type? {
        return nil
    }

    // Per-instance ID: distinct IDs (and object addresses) across the log = real multiple
    // instantiations (Loop's plugin lookup does principalClass.init() per type query); one ID
    // repeated = capture duplication of a single instance.
    private let instanceID = String(UUID().uuidString.prefix(8))

    override init() {
        super.init()
        log.default("OmnipodKitPlugin #%{public}@ Instantiated (%{public}@)", instanceID, self.debugDescription)
    }
}
