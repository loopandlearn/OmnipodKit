//
//  OmniPumpManager+PodKeepAlive.swift
//  OmnipodKit
//
//  Created by Joe Moran on 08/01/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit

/// Maximum time between pod responses before triggering a get status when pod keep alives are enabled.
/// This value must be less than 3 minutes plus margin to prevent DASH pods from disconnecting from an iPhone.
private var podKeepAliveRefreshInterval: TimeInterval = .minutes(2) + .seconds(40)

private var podKeepAliveTimer: Timer?

/// OmniPumpManager extension that manages the podKeepAliveTimer to implement timer based pod keep alives
/// by initiating a getPodStatus command if no response has been seen within the podKeepAliveRefreshInterval.
extension OmniPumpManager {

    private func timeStr(_ date: Date) -> String {
        return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    /// Reset the podKeepAliveTimer to expire at `when` and to do a getPodStatus() call if timer expires.
    private func setup_podKeepAliveTimer(when: TimeInterval) {

        /// Create a timer to trigger a getPodStatus call after the specified time from now.
        podKeepAliveTimer?.invalidate()
        podKeepAliveTimer = Timer(timeInterval: when, repeats: false) { _ in
            print("@@@ timer expired, reading pod status to stay connected at \(self.timeStr(Date()))")
            self.getPodStatus(canOptimize: false) { _ in }
        }

        if state.podKeepAlive.usesTimerBasedKeepAlives {
            let now = Date()
            let podKeepAliveTimerTarget = now + when
            print("@@@ podKeepAliveTimer set for \(timeStr(now)) + \(when.timeIntervalStr) = \(timeStr(podKeepAliveTimerTarget))")
            RunLoop.main.add(podKeepAliveTimer!, forMode: .default)
        }
    }

    /// Called when a pod response is received when timer based pod keep alives are enabled.
    func gotPodResponse() {
        if !state.podKeepAlive.usesTimerBasedKeepAlives {
            print("@@@ gotPodResponse disabling pod keep alive timer at \(timeStr(Date()))")
            podKeepAliveTimer?.invalidate()
            return
        }

        /// Reset the podKeepAliveTimer for the podKeepAliveRefreshInterval
        setup_podKeepAliveTimer(when: podKeepAliveRefreshInterval)
    }

    /// Handles all the setup and teardown for timer based pod keep alive modes
    func setPodKeepAliveTimerState(_ podKeepAlive: PodKeepAlive) {
        let now = Date()
        if state.podKeepAlive.usesTimerBasedKeepAlives {
            print("@@@ enabling pod keep alive timer for mode \(state.podKeepAlive) at \(timeStr(now))")

            /// Set up the callback from PodCommSession.send() for each response received
            gotPodResponseSetup(gotPodResponse)
 
            let lastResponseTime = state.podState?.podTimeUpdated ?? .distantPast
            let timeSinceLastResponse = now.timeIntervalSince(lastResponseTime)
            let minPodKeepAliveTimerInterval: TimeInterval = .seconds(30)

            if timeSinceLastResponse > podKeepAliveRefreshInterval - minPodKeepAliveTimerInterval {
                print("@@@ doing getPodStatus now with timeSinceLastResponse of \(timeSinceLastResponse.timeIntervalStr)")
                getPodStatus(canOptimize: false) { _ in }
            } else {
                /// Reduce the initial podKeepAliveTimer interval based on the time since the last response.
                let when = podKeepAliveRefreshInterval - timeSinceLastResponse
                print("@@@ setting up podKeepAliveTimer for \(when.timeIntervalStr) with timeSinceLastResponse of \(timeSinceLastResponse.timeIntervalStr)")
                setup_podKeepAliveTimer(when: when)
            }
        } else {
            print("@@@ disabling pod keep alive timer at \(timeStr(now))")
            gotPodResponseSetup(nil) // callbacks on pod responses no longer neededpwd
            podKeepAliveTimer?.invalidate()
        }
    }

    func rileyLinkTimerDidTick() {
        guard self.hasSetupPod else {
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
