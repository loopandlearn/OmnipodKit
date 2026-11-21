//
//  ReservoirEstimate.swift
//  OmnipodKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// Approximates the insulin left in a pod while the pod only reports 50+ U.
///
/// A pod measures its reservoir only once `Pod.maximumReservoirReading` (50 U) or less remain.
/// Above that, the amount left can be approximated from what the user filled the pod with,
/// minus everything the pod has dispensed since activation (including prime and cannula insertion).
///
/// The approximation is for display only. It is never reported as a reservoir reading,
/// since reservoir readings can be turned into insulin delivery by the app's dose store.
enum ReservoirEstimate {
    /// Pods need at least this much insulin to be filled
    static let minimumFillAmount: Double = 85

    /// Pods hold at most this much insulin
    static let maximumFillAmount: Double = Pod.reservoirCapacity

    /// Step between the fill amounts offered in settings
    static let fillAmountStep = 5

    /// The fill amounts offered in settings, in units
    static let allowedFillAmounts = Array(stride(from: Int(minimumFillAmount), through: Int(maximumFillAmount), by: fillAmountStep))

    /// The approximate units remaining, rounded down to whole units, or nil when the
    /// pod's own reading should be shown instead.
    ///
    /// Returns nil when no fill amount is set, when the pod has not reported its delivery yet,
    /// when the pod has measured 50 U or less, and when the approximation is not above 50 U
    /// although the pod still reads 50+ U (the fill amount was set too low).
    ///
    /// - Parameters:
    ///   - fillAmount: Units the pod was filled with, nil when no fill amount is set.
    ///   - reservoirLevel: Reservoir level from the pod's last status, nil when not yet known.
    ///   - insulinDispensed: Units the pod has dispensed since activation, nil when not yet known.
    static func approximateUnitsRemaining(fillAmount: Double?, reservoirLevel: Double?, insulinDispensed: Double?) -> Double? {
        guard let fillAmount, let insulinDispensed else {
            return nil
        }

        // Once the pod measures its reservoir, its reading always wins.
        if let reservoirLevel, reservoirLevel <= Pod.maximumReservoirReading {
            return nil
        }

        // Deliveries are whole 0.05 U pulses, so the small offset only absorbs
        // floating point error without moving a real value across a whole unit.
        let wholeUnits = (fillAmount - insulinDispensed + 0.001).rounded(.down)

        guard wholeUnits > Pod.maximumReservoirReading else {
            return nil
        }
        return wholeUnits
    }
}
