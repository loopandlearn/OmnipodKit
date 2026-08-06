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

    var title: String {
        switch self {
        case .disabled:
            return LocalizedString("Disabled", comment: "Title string for PodKeepAlive.disabled")
        case .whenOpen:
            return LocalizedString("When Open", comment: "Title string for PodKeepAlive.whenOpen")
        case .silentTune:
            return LocalizedString("Silent Tune", comment: "Title string for PodKeepAlive.silentTune")
        }
    }

    var description: String {
        switch self {
        case .disabled:
            return LocalizedString("Pod keep alive disabled. Additional pod status requests are not issued to prevent pod disconnects (nominal behavior).", comment: "Description for PodKeepAlive.disabled")
        case .whenOpen:
            return LocalizedString("Pod keep alive enabled when app is in the foreground with phone unlocked. Attempt to keep pod connected by issuing additional pod status request after 2 minutes, 40 seconds.", comment: "Description for PodKeepAlive.whenOpen")
        case .silentTune:
            return LocalizedString("Pod keep alive enabled. Attempt to keep pod connected by issuing additional pod status request after 2 minutes, 40 seconds even when phone is locked by playing a silent tune. The silent tune may be interrupted by other apps. If silent tune is interrupted, pod keep alive stops working. The silent tune consumes extra iPhone battery.", comment: "Description for PodKeepAlive.silentTune")
        }
    }

    /// Modes that keep the pod connected even while the app is backgrounded or phone locked.
    var keepsPodConnectedInBackground: Bool {
        switch self {
        case .disabled:
            return false /// No additional pod status requests to keep pod connected
        case .whenOpen:
            return false /// Only tries to keep pod connected when in foregrounded, but not in background
        case .silentTune:
            return true /// Always tries to stay connected by playing a silent tune in background
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
        }
    }
}
