//
//  OmniPumpManager+PodKeepAlive.swift
//  OmnipodKit
//
//  Created by Joe Moran on 08/01/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import UIKit

/// Maximum time between pod responses before triggering a get status when pod keep alives are enabled
/// will be podKeepAliveRefreshMargin less than the podType.disconnectInterval (3 or 5 minutes)
/// with a possible adjustment for the case of InPlay pods being used with problematic iPhones.
private let podKeepAliveRefreshMargin = TimeInterval(seconds: 10)

private var podKeepAliveTimer: Timer?
private var podKeepAliveAppInBackground = false

/// OmniPumpManager extension that manages the podKeepAliveTimer to implement timer based pod keep alives
/// by initiating a getPodStatus command if no response has been seen within the podKeepAliveRefreshInterval.
extension OmniPumpManager {

    private var podKeepAliveRefreshInterval: TimeInterval {

        guard state.podType.disconnectInterval > 0 else {
            return .minutes(2) + .seconds(40) /// safe default value
        }

        let inPlayWedgingMargin: TimeInterval
        if usingInPlayPod == true && UIDevice.hasPossibleInPlayBLEIssues {
            /// Add an additional 10 seconds of margin for InPlay wedging configurations
            inPlayWedgingMargin = .seconds(10)
        } else {
            inPlayWedgingMargin = 0
        }

        return state.podType.disconnectInterval - podKeepAliveRefreshMargin - inPlayWedgingMargin
    }

    private func timeStr(_ date: Date) -> String {
        return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    /// Reset the podKeepAliveTimer to expire at `when` and to do a getPodStatus() call if timer expires.
    private func setup_podKeepAliveTimer(when: TimeInterval) {

        /// Create a timer to trigger a getPodStatus call after the specified time from now.
        podKeepAliveTimer?.invalidate()
        // Weak: the timer is a process-wide global, and must not keep this manager alive.
        podKeepAliveTimer = Timer(timeInterval: when, repeats: false) { [weak self] _ in
            guard let self else { return }
            #if os(iOS)
            podKeepAliveAppInBackground = UIApplication.shared.applicationState == .background
            #endif
            if self.hasPairedNonFaultedPod, self.podKeepAliveTimerAllowed {
                print("@@@ timer expired, reading pod status to stay connected at \(self.timeStr(Date()))")
                self.getPodStatus(canOptimize: false) { _ in }
            }
        }

        if podKeepAliveTimerAllowed {
            let now = Date()
            let podKeepAliveTimerTarget = now + when
            print("@@@ podKeepAliveTimer set for \(timeStr(now)) + \(when.timeIntervalStr) = \(timeStr(podKeepAliveTimerTarget))")
            RunLoop.main.add(podKeepAliveTimer!, forMode: .default)
        }
    }

    /// Handles common cleanup work to disable using the pod keep alive timer
    private func disablePodKeepAliveTimer(_ from: String) {
        gotPodResponseSetup(nil) // pod response callbacks no longer needed
        if podKeepAliveTimer?.isValid == true {
            print("@@@ \(from) disabling pod keep alive timer at \(timeStr(Date()))")
            podKeepAliveTimer?.invalidate()
        }
    }

    /// Timer keep alives run in the background only for modes that keep the pod connected there.
    private var podKeepAliveTimerAllowed: Bool {
        guard state.podKeepAlive.usesTimerBasedKeepAlives else { return false }
        return !(podKeepAliveAppInBackground && !state.podKeepAlive.keepsPodConnectedInBackground)
    }

    func podKeepAliveAppDidEnterBackground() {
        podKeepAliveAppInBackground = true
        if !podKeepAliveTimerAllowed {
            disablePodKeepAliveTimer(#function)
        }
    }

    func podKeepAliveAppWillEnterForeground() {
        podKeepAliveAppInBackground = false
        if state.podKeepAlive.usesTimerBasedKeepAlives {
            setPodKeepAliveTimerState()
        }
    }

    /// Called when a pod response is received when timer based pod keep alives are enabled.
    func gotPodResponse() {
        if !podKeepAliveTimerAllowed {
            disablePodKeepAliveTimer(#function)
            return
        }

        /// Reset the podKeepAliveTimer for the podKeepAliveRefreshInterval
        setup_podKeepAliveTimer(when: podKeepAliveRefreshInterval)
    }

    /// Handles all the setup and teardown for timer based pod keep alive modes.
    /// Must be called whenever state.podKeepAlive is value is updated.
    func setPodKeepAliveTimerState() {
        let now = Date()
        if state.podKeepAlive.usesTimerBasedKeepAlives {
            print("@@@ enabling pod keep alive timer for mode \(podKeepAlive) at \(timeStr(now))")

            /// Set up the callback from PodCommSession.send() for each response received
            // Weak: the callback is a process-wide global, and must not keep this manager alive.
            gotPodResponseSetup { [weak self] in self?.gotPodResponse() }
 
            let lastResponseTime = state.podState?.podTimeUpdated ?? .distantPast
            let timeSinceLastResponse = now.timeIntervalSince(lastResponseTime)
            let minPodKeepAliveTimerInterval: TimeInterval = .seconds(30)

            if timeSinceLastResponse > podKeepAliveRefreshInterval - minPodKeepAliveTimerInterval {
                if self.hasPairedNonFaultedPod {
                    print("@@@ doing getPodStatus with timeSinceLastResponse of \(timeSinceLastResponse.timeIntervalStr)")
                    getPodStatus(canOptimize: false) { _ in }
                }
            } else {
                /// Reduce the initial podKeepAliveTimer interval based on the time since the last response.
                let when = podKeepAliveRefreshInterval - timeSinceLastResponse
                print("@@@ setting up podKeepAliveTimer for \(when.timeIntervalStr) with timeSinceLastResponse of \(timeSinceLastResponse.timeIntervalStr)")
                setup_podKeepAliveTimer(when: when)
            }
        } else {
            disablePodKeepAliveTimer(#function)
        }
    }

    func rileyLinkTimerDidTick() {
        guard self.hasPairedNonFaultedPod else {
            return
        }

        let now = Date()
        let nowTimeStr = timeStr(now)

        let lastResponseTime = state.podState?.podTimeUpdated ?? .distantPast

        let refreshTargetTime = lastResponseTime.addingTimeInterval(podKeepAliveRefreshInterval)
        let refreshTargetTimeStr = timeStr(refreshTargetTime)
        print("@@@ RileyLinkTimerDidTick next refresh target time of \(timeStr(lastResponseTime)) + \(podKeepAliveRefreshInterval.timeIntervalStr) = \(refreshTargetTimeStr)")

        let rileyLinkTickInterval: TimeInterval = .minutes(1)
        let nextExpectedTickTime = now.addingTimeInterval(rileyLinkTickInterval)
        let nextExpectedTickTimeStr = timeStr(nextExpectedTickTime)
        print("@@@ next RileyLink tick expected at \(nowTimeStr) + \(rileyLinkTickInterval.timeIntervalStr) = \(nextExpectedTickTimeStr)")

        let pad: TimeInterval = .seconds(5)
        if refreshTargetTime < nextExpectedTickTime - pad {
            print("@@@ RileyLinkTimerDidTick refreshTargetTime \(refreshTargetTimeStr) within \(pad.timeIntervalStr) before nextExpectedTickTime \(nextExpectedTickTimeStr)")
            print("@@@ RileyLinkTimerDidTick calling getPodStatus at \(nowTimeStr)")
            self.getPodStatus(canOptimize: false) { _ in }
        }
    }
}
