//
//  PodSessionLogRetention.swift
//  OmnipodKit
//
//  Created for the pod session log feature.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// How long completed pod sessions are kept in the pod session log before
/// being pruned. Each pod session (normal deactivation, expiration, or fault)
/// is recorded with its activation/end dates and full pod status, including
/// fault code and PDM ref string when applicable, so it can be reviewed later
/// or reported to the pod manufacturer without relying on screenshots.
enum PodSessionLogRetention: Int, CaseIterable, Codable {
    case days30
    case days90
    case days180
    case days365
    case forever

    static let `default`: PodSessionLogRetention = .days90

    /// Number of days to retain entries, or nil to keep the log forever.
    var days: Int? {
        switch self {
        case .days30:
            return 30
        case .days90:
            return 90
        case .days180:
            return 180
        case .days365:
            return 365
        case .forever:
            return nil
        }
    }

    var title: String {
        switch self {
        case .days30:
            return LocalizedString("30 Days", comment: "Title string for PodSessionLogRetention.days30")
        case .days90:
            return LocalizedString("90 Days", comment: "Title string for PodSessionLogRetention.days90")
        case .days180:
            return LocalizedString("180 Days", comment: "Title string for PodSessionLogRetention.days180")
        case .days365:
            return LocalizedString("1 Year", comment: "Title string for PodSessionLogRetention.days365")
        case .forever:
            return LocalizedString("Forever", comment: "Title string for PodSessionLogRetention.forever")
        }
    }
}
