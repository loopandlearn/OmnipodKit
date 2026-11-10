//
//  DisconnectPolicy.swift
//  OmnipodKit
//

import Foundation

/// What BluetoothManager does after a pod's link drops, kept free of CoreBluetooth so it can be tested.
struct DisconnectPolicy {
    struct Situation {
        var systemReconnecting = false
        var watchdogActive = false
        var eager = false
        var held = false
        var foreground = false
        var eagerHeartbeatMode = false
        var probeActive = false
        var autoConnect = false
        var sessionActive = false
    }

    enum Action: Equatable {
        case deferToSystemReconnect
        case deferToWatchdog
        case eagerReconnect
        case eagerHeartbeatReconnect
        case standingConnect
        case keepAliveReconnect
        case idle(armProbe: Bool)
    }

    struct Decision: Equatable {
        var action: Action
        var commandConnectInFlight: Bool
    }

    static func didDisconnect(_ situation: Situation, commandConnectInFlight: Bool) -> Decision {
        if situation.systemReconnecting {
            return Decision(action: .deferToSystemReconnect, commandConnectInFlight: commandConnectInFlight)
        }
        if situation.watchdogActive {
            return Decision(action: .deferToWatchdog, commandConnectInFlight: commandConnectInFlight)
        }
        if situation.eager && situation.held {
            let action: Action
            if situation.foreground {
                action = .eagerReconnect
            } else if situation.eagerHeartbeatMode {
                action = .eagerHeartbeatReconnect
            } else {
                action = .standingConnect
            }
            return Decision(action: action, commandConnectInFlight: commandConnectInFlight)
        }
        if situation.held && commandConnectInFlight {
            return Decision(action: .keepAliveReconnect, commandConnectInFlight: true)
        }
        if situation.sessionActive {
            // The session may still retry its connect; sessionsEnded settles the flag when it's done.
            // This also covers a cancelled probe's disconnect arriving after a command connect began.
            return Decision(action: .idle(armProbe: false), commandConnectInFlight: commandConnectInFlight)
        }
        // Nothing reconnects an unheld link, whoever dropped it, so it's idle now.
        return Decision(action: .idle(armProbe: situation.probeActive && situation.autoConnect),
                        commandConnectInFlight: false)
    }

    /// The last command session ended. A link that's still up goes idle through the idle disconnect;
    /// one that's already down, such as after the pod hung up mid-command, goes idle here.
    static func sessionsEnded(_ situation: Situation, linkDown: Bool, commandConnectInFlight: Bool) -> Decision? {
        guard !situation.held, linkDown else { return nil }
        return Decision(action: .idle(armProbe: situation.probeActive && situation.autoConnect),
                        commandConnectInFlight: false)
    }
}
