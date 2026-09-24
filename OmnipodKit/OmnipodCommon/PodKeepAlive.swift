//
//  PodKeepAlive.swift
//  OmnipodKit
//
//  Created by Joe Moran on 7/21/26.
//  Copyright © 2026 Joe Moran. All rights reserved.
//

import Foundation

enum PodKeepAlive: Int, CaseIterable, Codable {
    case disabled
    case whenOpen
    case silentTune
    case rileyLink

    var title: String {
        switch self {
        case .disabled:
            return LocalizedString("Disabled", comment: "Title string for PodKeepAlive.disabled")
        case .whenOpen:
            return LocalizedString("When Open", comment: "Title string for PodKeepAlive.whenOpen")
        case .silentTune:
            return LocalizedString("Silent Tune", comment: "Title string for PodKeepAlive.silentTune")
        case .rileyLink:
            return LocalizedString("RileyLink", comment: "Title string for PodKeepAlive.rileyLink")
        }
    }

    var description: String {
        switch self {
        case .disabled:
            return "" /// For internal use, this value will never be displayed
        case .whenOpen:
            return LocalizedString("Pod keep alive enabled when app is in the foreground with phone unlocked. Attempt to keep pod connected by issuing additional pod status request after 2 minutes, 40 seconds.", comment: "Description for PodKeepAlive.whenOpen")
        case .silentTune:
            return LocalizedString("Pod keep alive enabled. Attempt to keep pod connected by issuing additional pod status request after 2 minutes, 40 seconds even when phone is locked by playing a silent tune. The silent tune may be interrupted by other apps. If silent tune is interrupted, pod keep alive stops working. The silent tune consumes extra iPhone battery.", comment: "Description for PodKeepAlive.silentTune")
        case .rileyLink:
            return LocalizedString("Pod keep alive enabled. Additional pod status request issued after 2 minutes.\n\nRequires a RileyLink-compatible device within Bluetooth range. Allows pod keep alive messages when app is in background. This method uses less iPhone battery and slightly more DASH battery than the Silent Tune method. A RileyLink-compatible device must be enabled in pump view.",
                comment: "Description for PodKeepAlive.rileyLink")
        }
    }

    /// Modes that keep the pod connected even while the app is backgrounded / phone locked (silentTune via
    /// a background silent-tune, rileyLink via a BLE wake device). The connection layer holds the pod
    /// connected in these modes instead of applying connect-on-demand's idle/background disconnect.
    /// `.whenOpen` keeps alive only while foregrounded (already covered by the foreground keep-alive), and
    /// `.disabled` is nominal connect-on-demand — both are false here.
    var keepsPodConnectedInBackground: Bool {
        switch self {
        case .disabled:
            return false /// No additional pod status requests to keep pod connected
        case .whenOpen:
            return false /// Only tries to keep pod connected when in foregrounded, but not in background
        case .silentTune:
            return true /// Always tries to stay connected by playing a silent tune in background
        case .rileyLink:
            return true /// Always tries to stay connected by using RileyLink BLE wakeups
        }
    }

    /// Modes that use a timer based keep alive either in foreground or background.
    var usesTimerBasedKeepAlives: Bool {
        switch self {
        case .disabled:
            return false /// No additional pod status requests to keep pod connected
        case .whenOpen:
            return true /// Uses timer based keep alives, but only when in foreground
        case .silentTune:
            return true /// Uses timer based keep alives, both when in foreground and in background
        case .rileyLink:
            return false /// Uses BLE wakeups instead of timers
        }
    }
}

/// Return the default Pod Keep Alive value for the given podType
func defaultPodKeepAliveValue(podType: PodType) -> PodKeepAlive {
    if podType.isDash || podType.isO5 {
        return .whenOpen /// default value for all BLE pod types to improve the user experience
    }
    return .disabled
}
