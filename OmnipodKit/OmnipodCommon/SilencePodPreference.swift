//
//  SilencePodPreference.swift
//  OmnipodKit
//
//  From OmniBLE/OmnipodCommon/SilencePodPreference.swift
//  Created by Joe Moran on 8/30/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import Foundation

enum SilencePodPreference: Int, CaseIterable {
    case disabled
    case enabled

    var title: String {
        switch self {
        case .disabled:
            return LocalizedString("Disabled", comment: "Title string for SilencePodPreference.disabled")
        case .enabled:
            return LocalizedString("Silenced", comment: "Title string for SilencePodPreference.enabled")
        }
    }

    var description: String {
        switch self {
        case .disabled:
            return LocalizedString("Normal operation mode where audible Pod beeps are used for all Pod alerts and when confidence reminders are enabled.", comment: "Description for SilencePodPreference.disabled")
        case .enabled:
            return LocalizedString("All Pod alerts use no beeps and confirmation reminder beeps are suppressed. The Pod will only beep for fatal Pod faults and when playing test beeps.\n\n⚠️Warning - If your phone is out of range of the pod while this feature is enabled, you will not receive any in-app notifications; and the pod will not beep to alert you.", comment: "Description for SilencePodPreference.enabled")
        }
    }

    var altDescription: String {
        switch self {
        case .disabled:
            return self.description
        case .enabled:
            return LocalizedString("All confirmation reminder beeps are suppressed, but other audible Pod alert beeping cannot be silenced for this Pod.", comment: "Alternate black dot description for SilencePodPreference.disabled")
        }
    }
}
