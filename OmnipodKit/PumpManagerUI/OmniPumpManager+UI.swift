//
//  OmniPumpManager+UI.swift
//  OmnipodKit
//
//  Based on OmniBLE/PumpManagerUI/OmniBLEPumpManager+UI.swift
//  Created by Joe Moran on 1/7/25
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import Foundation

import UIKit
import LoopKit
import LoopKitUI
import SwiftUI

extension OmniPumpManager: PumpManagerUI {
    public static var onboardingImage: UIImage? {
        return UIImage(named: "Onboarding", in: Bundle(for: OmniSettingsViewModel.self), compatibleWith: nil)
    }
        
    public static func setupViewController(initialSettings settings: PumpManagerSetupSettings, bluetoothProvider: BluetoothProvider, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool, prefersToSkipUserInteraction: Bool = false, allowedInsulinTypes: [InsulinType]) -> SetupUIResult<PumpManagerViewController, PumpManagerUI>
    {
        let vc = OmniUICoordinator(colorPalette: colorPalette, pumpManagerSettings: settings, allowDebugFeatures: allowDebugFeatures, allowedInsulinTypes: allowedInsulinTypes)
        return .userInteractionRequired(vc)
    }
        
    public func settingsViewController(bluetoothProvider: BluetoothProvider, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool, allowedInsulinTypes: [InsulinType]) -> PumpManagerViewController {
        return OmniUICoordinator(pumpManager: self, colorPalette: colorPalette, allowDebugFeatures: allowDebugFeatures, allowedInsulinTypes: allowedInsulinTypes)
    }
    
    public func deliveryUncertaintyRecoveryViewController(colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool) -> (UIViewController & CompletionNotifying) {
        return OmniUICoordinator(pumpManager: self, colorPalette: colorPalette, allowDebugFeatures: allowDebugFeatures)
    }
    
    public var smallImage: UIImage? {
        return UIImage(named: "Pod", in: Bundle(for: OmniSettingsViewModel.self), compatibleWith: nil)!
    }

    public func hudProvider(bluetoothProvider: BluetoothProvider, colorPalette: LoopUIColorPalette, allowedInsulinTypes: [InsulinType]) -> HUDProvider? {
        return OmniHUDProvider(pumpManager: self, bluetoothProvider: bluetoothProvider, colorPalette: colorPalette, allowedInsulinTypes: allowedInsulinTypes)
    }

    public static func createHUDView(rawValue: HUDProvider.HUDViewRawState) -> BaseHUDView? {
        return OmniHUDProvider.createHUDView(rawValue: rawValue)
    }
}

public enum OmniStatusBadge: DeviceStatusBadge {
    case timeSyncNeeded
    
    public var image: UIImage? {
        switch self {
        case .timeSyncNeeded:
            return UIImage(systemName: "clock.fill")
        }
    }
    
    public var state: DeviceStatusBadgeState {
        switch self {
        case .timeSyncNeeded:
            return .warning
        }
    }
}

// MARK: - PumpStatusIndicator
extension OmniPumpManager {
    
    public var pumpStatusHighlight: PumpStatusHighlight? {
        return buildPumpStatusHighlight(for: state)
    }

    public var pumpLifecycleProgress: DeviceLifecycleProgress? {
        return buildPumpLifecycleProgress(for: state)
    }

    public var pumpStatusBadge: DeviceStatusBadge? {
        if isClockOffset {
            return OmniStatusBadge.timeSyncNeeded
        } else {
            return nil
        }
    }
}
