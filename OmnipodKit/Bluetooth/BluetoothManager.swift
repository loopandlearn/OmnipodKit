//
//  BluetoothManager.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/BluetoothManager.swift
//  Created by Randall Knutson on 10/10/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import Foundation
import LoopKit
import os.log
import UIKit  // only for UIDevice (see shouldUseEagerConnect); lifecycle goes through HostAppState

enum BluetoothManagerError: Error {
    case bluetoothNotAvailable(CBManagerState)
}

extension BluetoothManagerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .bluetoothNotAvailable(let state):
            switch state {
            case .poweredOff:
                return LocalizedString("Bluetooth is powered off", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.poweredOff)")
            case .resetting:
                return LocalizedString("Bluetooth is resetting", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.resetting)")
            case .unauthorized:
                return LocalizedString("Bluetooth use is unauthorized", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.unauthorized)")
            case .unsupported:
                return LocalizedString("Bluetooth use unsupported on this device", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.unsupported)")
            case .unknown:
                return LocalizedString("Bluetooth is unavailable for an unknown reason.", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.unknown)")
            default:
                return String(format: LocalizedString("Bluetooth is unavailable: %1$@", comment: "The format string for BluetoothManagerError.bluetoothNotAvailable for unknown state (1: the unknown state)"), String(describing: state))
            }
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .bluetoothNotAvailable(let state):
            switch state {
            case .poweredOff:
                return LocalizedString("Turn bluetooth on", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.poweredOff)")
            case .resetting:
                return LocalizedString("Try again", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.resetting)")
            case .unauthorized:
                return LocalizedString("Please enable bluetooth permissions for this app in system settings", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.unauthorized)")
            case .unsupported:
                return LocalizedString("Please use a different device with bluetooth capabilities", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.unsupported)")
            default:
                return nil
            }
        }
    }
}

protocol OmniConnectionDelegate: AnyObject {

    /**
     Tells the delegate that a peripheral has been connected to

     - parameter manager: The manager for the peripheral that was connected
     */
    func omnipodPeripheralDidConnect(manager: PeripheralManager)

    /**
     Tells the delegate that a connected peripheral has been restored from session restoration

     - parameter manager: The manager for the peripheral that was connected
     */
    func omnipodPeripheralWasRestored(manager: PeripheralManager)


    /**
     Tells the delegate that a peripheral was disconnected

     - parameter peripheral: The peripheral that was disconnected
     */
    func omnipodPeripheralDidDisconnect(peripheral: CBPeripheral, error: Error?)

    /**
     Tells the delegate that a peripheral failed to connect

     - parameter peripheral: The peripheral that failed to connect
     */
    func omnipodPeripheralDidFailToConnect(peripheral: CBPeripheral, error: Error?)

    /// Write a message to Loop's persistent device log (survives background wakes / relaunch and is
    /// bundled in the issue report, unlike a live Console stream).
    func omnipodLogDeviceEvent(_ message: String)

    /// Tells the delegate a pump-provided heartbeat wake fired (a delayed-connect probe completed).
    /// The host (OmniPumpManager) turns this into pumpManagerBLEHeartbeatDidFire so Loop runs a cycle.
    func omnipodHeartbeatDidFire()

    /// Tells the delegate a pod alert was detected connectionlessly (from the advertisement). The host
    /// connects on demand and reads the real pod status, which surfaces the alert to Loop via the
    /// normal getPodStatus -> alertsChanged -> issueAlert path. `slots` is the decoded firing AlertSet.
    func omnipodDidDetectAlert(slots: AlertSet)
}

extension OmniConnectionDelegate {
    func omnipodLogDeviceEvent(_ message: String) {}
    func omnipodHeartbeatDidFire() {}
    func omnipodDidDetectAlert(slots: AlertSet) {}
}


class BluetoothManager: NSObject {

    weak var connectionDelegate: OmniConnectionDelegate?

    private let podType: PodType

    private let log = OSLog(category: "BluetoothManager")

    /// Isolated to `managerQueue`
    private var manager: CBCentralManager! = nil
    
    /// Isolated to `managerQueue`
    private var devices: [Omni] = []

    /// Last-seen DASH advertisement status word per peripheral, for connectionless alert detection.
    private var lastPodStatusWord: [String: Data] = [:]

    /// Re-wake quieting: true while a detected alert is being surfaced/active. A persisting alert keeps
    /// the pod advertising `C005`, so the alarm scan would keep waking us (harmless — re-processing is
    /// change-gated — but it churns the radio and nudges the heartbeat probe). We stop the alarm scan
    /// once an alert is surfaced and resume it when all alerts clear (via a connected status read).
    /// New faults are still caught within the heartbeat cadence while suppressed. managerQueue-isolated.
    private var alarmScanSuppressed = false

    /// Last advertisement timestamp per peripheral, to log inter-frame cadence (the DS-beacon-rate
    /// measurement the RE asked for — is there a usable periodic wake?).
    private var lastAdvSeen: [String: Date] = [:]

    /// Last full advert (svcUUIDs|mfg) device-logged per peripheral, so we record each DISTINCT advert
    /// once (captures the fault transition without flooding the device log).
    private var lastLoggedAdvKey: [String: String] = [:]

    /// Isolated to `managerQueue`
    private var discoveryModeEnabled: Bool = false

    /// Isolated to `managerQueue`
    private var autoConnectIDs: Set<String> = [] {
        didSet {
            updateConnections()
        }
    }

    /// The uuidPdmId is set after pairing...
    private var uuidPdmId: UInt32? = nil

    /// The O5 changes its service advertisement uuid from using FFFFFFFE the pdmId after pairing.
    /// This func is called to set this value to be used in uuid after pairing and with a nil (or 0) to reset.
    func setUuidPdmId(_ pdmId: UInt32?) {
        managerQueue.async {
            if let pdmId = pdmId, pdmId != 0 {
                self.log.bleDebug("Setting uuidPdmId to 0x%x", pdmId)
                self.uuidPdmId = pdmId
            } else {
                self.uuidPdmId = nil
            }
        }
    }

    /// Isolated to `managerQueue`
    private var hasDiscoveredAllAutoConnectDevices: Bool {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        return autoConnectIDs.isSubset(of: devices.map { $0.manager.peripheral.identifier.uuidString })
    }

    // MARK: - Synchronization
    private let managerQueue = DispatchQueue(label: "com.OmnipodKit.bluetoothManagerQueue", qos: .unspecified)

    /// Per-instance ID so multiple centrals under the shared "com.OmnipodKit" restore identifier
    /// can be told apart in the log. INIT/DEINIT + the central callbacks are all tagged with it:
    /// N distinct INITs with no matching DEINITs = leaked centrals (the suspected pairing-bug root).
    let instanceID = String(UUID().uuidString.prefix(8))

    /// Log each distinct pod advertisement ([ADV] → device log) so field Issue Reports capture what the
    /// pod broadcasts — raw material for decoding more fault/alert states — and enable allowDuplicates on
    /// the fallback monitor scan. Kept in production.
    static var advertisementMonitorEnabled: Bool {
        UserDefaults.standard.object(forKey: "OmnipodKit.advertisementMonitorEnabled") as? Bool ?? true
    }

    /// The shipped "normally disconnected" model: the pod is NOT held connected; PeripheralManager
    /// connects on demand for each session and disconnects when idle, and we alarm-scan while
    /// disconnected. Every command pays a (fast fresh-discovery) connect first.
    static var connectOnDemandEnabled: Bool {
        UserDefaults.standard.object(forKey: "OmnipodKit.connectOnDemandEnabled") as? Bool ?? true
    }

    /// Low-power fault-watch: the idle scan filters on the DASH FAULT service UUID(s) — `alarmServiceUUIDs`
    /// = [C00A] — with allowDuplicates OFF, so iOS wakes us only when the pod's 2nd service UUID flips to
    /// the fault value (C005→C00A). C00A isn't advertised in normal operation, so a fault is a fresh
    /// discovery → a fast (<1 min) background wake that survives suspension via State Restoration; zero
    /// wakes otherwise. Alerts (no service-UUID change) are NOT caught here — the heartbeat probe surfaces
    /// those. Coexists with the StartDelay heartbeat probe. See DASH_BEACON_FINDINGS.md.
    static var lowPowerMonitorEnabled: Bool {
        UserDefaults.standard.object(forKey: "OmnipodKit.lowPowerMonitorEnabled") as? Bool ?? true
    }

    /// Master switch for the IDLE scan (startScanning). ON = run the C00A fault listener while
    /// disconnected (connectionless fault detection). OFF = no idle scan. Command connects use
    /// fresh-discovery either way; this only governs the idle listener. The idle scan COEXISTS with the
    /// StartDelay heartbeat probe — both run while idle: the probe provides the periodic heartbeat/alert
    /// wake, the scan provides fast fault wakes.
    static var scanningEnabled: Bool {
        UserDefaults.standard.object(forKey: "OmnipodKit.scanningEnabled") as? Bool ?? true
    }

    // MARK: - Eager connect (InPlay / iPhone 16-class LL-deadlock mitigation)

    /// Master switch for the eager-connect watchdog. InPlay-firmware DASH pods (peripheral name
    /// "InPlay BLE") silently ignore the LL_CONNECTION_PARAM_REQ control PDU; on iPhone 16-class
    /// controllers iOS often issues that procedure early in a connect, deadlocking the LL procedure
    /// queue so the connect wedges in `.connecting` with no callback (~7s until the pod terminates the
    /// dead link, then iOS silently auto-retries — chains of invisible ~20s stalls). The watchdog caps
    /// the cost: a connect that hasn't reached `.connected` within `eagerConnectWatchdogSeconds` is
    /// presumed wedged, so we `cancelPeripheralConnection` (which tears the wedge down on-air, freeing
    /// the pod to advertise again, and re-arms iOS's fast connection scan) and re-connect. Healthy
    /// connects complete <1s and never trip it. Gated to affected phones + InPlay/unknown pods by
    /// `shouldUseEagerConnect(for:)`. Default ON.
    static var eagerConnectEnabled: Bool {
        UserDefaults.standard.object(forKey: "OmnipodKit.eagerConnectEnabled") as? Bool ?? true
    }

    /// Apply the eager watchdog on ANY device, bypassing the iPhone-model gate — for bench A/B testing.
    static var eagerConnectForceAllDevices: Bool {
        UserDefaults.standard.object(forKey: "OmnipodKit.eagerConnectForceAllDevices") as? Bool ?? false
    }

    /// How long to wait for didConnect before presuming a connect is wedged (~3-5x the measured healthy
    /// connect population of <1s).
    /// Watchdog interval while the app is FOREGROUND. The user may be waiting to bolus, so retry
    /// harder: a wedge is unrecoverable by waiting and a cancel/retry cycle costs ~1.3s, so a shorter
    /// deadline strictly reduces time-to-connect at the cost of a few extra (cheap) retries.
    static var eagerConnectForegroundWatchdogSeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "OmnipodKit.eagerConnectForegroundWatchdogSeconds") as? Double) ?? 1.5
    }

    static var eagerConnectWatchdogSeconds: TimeInterval {
        // 2s: healthy connects complete sub-second (ATT ~90-280ms after capture on-air; 0-1s
        // app-level), and a post-cancel retry cycle is ~1.3s — so 2s is ~2x margin over the healthy
        // population while wasting ~1s less per wedge than the original 3s. A false trip costs only
        // ~1s (one extra cancel/retry); watch the fired-but-healthy telemetry to validate.
        (UserDefaults.standard.object(forKey: "OmnipodKit.eagerConnectWatchdogSeconds") as? Double) ?? 2.0
    }

    /// Pause after `cancelPeripheralConnection` before re-issuing `connect()`, to let the LL termination
    /// land and the pod resume advertising (observed ~10ms; 200ms is comfortable margin).
    static var eagerConnectTeardownSeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "OmnipodKit.eagerConnectTeardownSeconds") as? Double) ?? 0.2
    }

    /// Overall budget for the eager cancel/retry cycle on an on-demand command connect. Kept just under
    /// the PeripheralManager `runCommand` `.connect` timeout (45s) so the watchdog owns the retries
    /// underneath that single wait (which only clears on a real didConnect). Field data (2026-08-19,
    /// InPlay + iPhone 16 Pro): per-attempt wedge probability is PER-POD (~55% and ~84% observed on two
    /// pods). At 84%, 28s (~12 cycles) measured ~10% command failure (all budget exhaustions); 40s
    /// (~17 cycles at ~2.3s) predicts ~5%. Failures self-heal on the next loop cycle.
    static var eagerConnectBudgetSeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "OmnipodKit.eagerConnectBudgetSeconds") as? Double) ?? 40.0
    }

    /// Overall budget for the eager cancel/retry cycle during pairing discovery — longer than one
    /// wedge-cycle so a wedged first attempt doesn't consume the whole pairing window.
    static var eagerPairingBudgetSeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "OmnipodKit.eagerPairingBudgetSeconds") as? Double) ?? 40.0
    }

    /// EXPERIMENT: pass CBConnectPeripheralOptionEnableAutoReconnect (iOS 17+) on eager connects, to
    /// probe whether it changes the low-level stack's reacquisition behavior on wedge-prone pods.
    /// With it, an unexpected post-establishment drop is auto-reconnected by the system, reported via
    /// centralManager(_:didDisconnectPeripheral:timestamp:isReconnecting:error:) with
    /// isReconnecting=true (we then defer to the system; didConnect fires on re-establishment). An
    /// explicit cancelPeripheralConnection (idle-disconnect, watchdog) still cancels any pending
    /// auto-reconnect, so the normally-disconnected model is unaffected.
    /// Optional gate: only fire a disconnect-driven heartbeat if the host hasn't seen a CGM reading in
    /// at least this long. Default 0 = always fire on a drop (Loop ignores a heartbeat it doesn't need,
    /// and an extra wake is far cheaper than a missed one).
    static var eagerHeartbeatStaleReadingSeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "OmnipodKit.eagerHeartbeatStaleReadingSeconds") as? Double) ?? 0
    }

    /// Minimum spacing between disconnect-driven heartbeats.
    static var eagerHeartbeatMinIntervalSeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "OmnipodKit.eagerHeartbeatMinIntervalSeconds") as? Double) ?? 150
    }

    static var eagerAutoReconnectEnabled: Bool {
        UserDefaults.standard.object(forKey: "OmnipodKit.eagerAutoReconnectEnabled") as? Bool ?? true
    }

    /// Connect options for eager connects (auto-reconnect experiment when enabled and available).
    /// Disconnect-driven heartbeat mode: a wedge-prone pod on an affected phone whose host needs the
    /// pump to provide background wakes. Here we deliberately do NOT use auto-reconnect — instead we let
    /// the pod hang up on its own ~180s inactivity timer, take CoreBluetooth's didDisconnect as the wake
    /// (State Restoration delivers it to a suspended app), eagerly reconnect (re-arming the next cycle),
    /// and fire the heartbeat if the host's CGM data has gone stale. That yields a regular ~3min wake
    /// cadence, versus the irregular ~9min observed when auto-reconnect silently holds the link up.
    var isEagerHeartbeatMode: Bool {
        guard heartbeatEnabled else { return false }
        guard let peripheral = keepAlivePeripheral else { return false }
        return shouldUseEagerConnect(for: peripheral)
    }

    private var eagerConnectOptions: [String: Any]? {
        // Disconnect-driven heartbeat mode owns its own reconnects — auto-reconnect would silently
        // re-establish the link and rob us of the wake.
        if isEagerHeartbeatMode { return nil }
        // BACKGROUND: ask the system to keep the link up for us — it can re-establish while the app is
        // suspended, which no app-side timer can do.
        // FOREGROUND: do NOT use auto-reconnect. The user may be waiting to bolus, and the system's
        // silent reacquisition (~27s median measured) is far slower than our eager cancel/retry cycle
        // (~1.3s); an armed auto-reconnect would just compete with the watchdog.
        if isAppForeground { return nil }
        if #available(iOS 17.0, *), BluetoothManager.eagerAutoReconnectEnabled {
            return [CBConnectPeripheralOptionEnableAutoReconnect: true]
        }
        return nil
    }

    /// CoreBluetooth peripheral (advertised local) name of the affected InPlay-firmware DASH pod variant.
    /// (OmniPumpManager's `usingInPlayPod` matches against this same constant.)
    static let inPlayPeripheralName = "InPlay BLE"


    /// Fallback start delay (seconds) for the delayed-connect probe when Loop hasn't supplied a heartbeat
    /// schedule (no `heartbeatTargetDate`). Normally the delay is computed from the CGM reading schedule —
    /// see `issueDelayedConnectProbe`. Note the real wake lands at StartDelay + an iOS reacquisition tail
    /// (~40s observed), so 300 → wake ~340s.
    static var delayedConnectProbeSeconds: Int {
        (UserDefaults.standard.object(forKey: "OmnipodKit.delayedConnectProbeSeconds") as? Int) ?? 300
    }

    /// Buffer (seconds) added after the next expected CGM reading when scheduling the heartbeat, so a
    /// remote/network CGM value has time to be fetched and stored before the heartbeat drives a Loop cycle.
    static var heartbeatBufferSeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "OmnipodKit.heartbeatBufferSeconds") as? Double) ?? 20
    }

    /// Floor (seconds) for the computed StartDelay, so a stale/overdue reading target can't produce a
    /// near-zero delay that immediately reconnects. Overdue targets retry at this cadence.
    static var heartbeatMinDelaySeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "OmnipodKit.heartbeatMinDelaySeconds") as? Double) ?? 60
    }

    /// Backoff (seconds) before re-arming the StartDelay probe after a connect FAILURE, so a
    /// persistently-failing connect can't re-issue in a tight loop.
    static var heartbeatFailureBackoffSeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "OmnipodKit.heartbeatFailureBackoffSeconds") as? Double) ?? 30
    }

    /// Idle-disconnect delay (seconds) after the last command's session. Kept SHORT so that in the
    /// background a heartbeat-wake cycle disconnects promptly — before iOS suspends the app — which lets
    /// the StartDelay probe re-arm (it needs a DISCONNECTED pod). A long delay let the app suspend with the
    /// link still up and the timer frozen, so the probe never re-armed → a ~12-min missed loop (tester
    /// report). Foreground / Pod Keep Alive hold the connection separately (`shouldHoldConnection`), so this
    /// only takes effect while backgrounded. The status→dose burst still shares one connection: each session
    /// resets `idleStart`, so the disconnect lands this many seconds after the LAST command.
    static var idleDisconnectSeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "OmnipodKit.idleDisconnectSeconds") as? Double) ?? 4
    }

    /// Idle-disconnect delay for eager-gated pods (InPlay + affected iPhone), where every reconnect
    /// risks a wedge storm (median ~10s, worst ~30s+ measured). Sized ABOVE the observed inter-cycle
    /// command cadence (~3 min), so the connection is effectively held continuously while looping and
    /// each cycle's first command lands on a live link (a 60s window measured on 2026-08-20 hung up
    /// ~1 min before the next cycle every time — paying a storm per cycle anyway). If cycles stop
    /// (CGM gap, app suspended), the pod still disconnects at this deadline and the background
    /// heartbeat probe re-arms as designed.
    ///
    /// Default 3600 (hold-while-looping): field data (2026-08-20) showed cycle cadence varies 3-5 min,
    /// and both 60s and 240s windows repeatedly hung up <1 min before the next cycle — paying a wedge
    /// storm each time for nothing. Every command resets the timer, so any activity within the hour
    /// keeps the link; a true idle hour still releases the pod (advertising/probe/fault-scan resume).
    static var eagerIdleDisconnectSeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "OmnipodKit.eagerIdleDisconnectSeconds") as? Double) ?? 3600
    }

    /// Candidate DASH alarm-state service UUIDs to filter on in low-power mode.
    /// - `C005`: CONFIRMED 16-bit alarm 2nd-UUID on this pod (expiration reminder). Extend as more
    ///   alert/alarm types are captured.
    /// - `C00A`: CONFIRMED fault 2nd-UUID (captured occlusion 0x14 — the pod's 2nd service UUID went
    ///   C001(normal)→C005(alert)→C00A(fault)). Include it so a fault wakes the low-power scan.
    /// C00A-ONLY fault scan (the adopted design; validated 2026-07-08). scanForPeripherals(withServices:)
    /// is an OR filter, so including C005 kept the pod perpetually matched (a reminder is always
    /// configured → C005 always advertised) → iOS treated it as already-discovered and COALESCED the
    /// C005→C00A re-discovery (~7min deep-idle fault latency measured). Filtering on C00A ONLY means the
    /// pod does not match during normal operation, so a fault's C005→C00A flip is a genuinely NEW
    /// discovery — the event iOS wakes a suspended app for — giving <1min proactive deep-idle fault
    /// detection (measured, probe off). We forgo C005-based connectionless ALERT detection, which never
    /// worked in deep idle anyway (mfg-only change, no UUID change to wake on); alerts are surfaced by
    /// the heartbeat probe (~5min) and the foreground keep-alive connection.
    static let alarmServiceUUIDs: [CBUUID] = [
        CBUUID(string: "C00A"),
    ]

    /// Connect-request timestamps (by peripheral UUID) for measuring connect latency in didConnect.
    private var connectRequestedAt: [String: Date] = [:]

    /// Delayed-connect probe: true while a StartDelay connect is in flight (issued, awaiting didConnect),
    /// so didDiscover doesn't re-issue during the wait; the issue timestamp measures the true delay.
    private var delayedProbeInFlight = false
    private var delayedProbeIssuedAt: Date?
    /// StartDelay (seconds) of the probe currently in flight, for latency logging in didConnect.
    private var delayedProbeDelay: TimeInterval?

    /// Target time for the next pump-provided heartbeat: the probe's StartDelay is computed so the wake
    /// lands no earlier than this. Recomputed from Loop's `PumpHeartbeatRequest` each time it updates
    /// (i.e. after each CGM reading), so the cadence tracks the actual reading schedule. nil = no schedule
    /// supplied (fall back to `delayedConnectProbeSeconds`). managerQueue-isolated.
    private var heartbeatTargetDate: Date?

    /// The reading interval last supplied via `setHeartbeatRequest`, used to advance a chronically-stale
    /// target so it doesn't collapse onto the floor. managerQueue-isolated.
    private var heartbeatInterval: TimeInterval?

    /// When `heartbeatTargetDate` was last (re)set. A host that supplies a live reading schedule refreshes
    /// this every reading; a host that only calls the legacy `setMustProvideBLEHeartbeat` sets it once. That
    /// distinction is how `issueDelayedConnectProbe` tells a briefly-late reading (retry at the floor) from a
    /// target no host is refreshing (advance it). managerQueue-isolated.
    private var heartbeatTargetSetAt: Date?

    /// Most recent CGM reading time reported by the host (via PumpHeartbeatRequest). Used by the
    /// disconnect-driven heartbeat to decide whether a wake is actually needed.
    private var lastCGMReadingDate: Date?

    /// When we last fired a disconnect-driven heartbeat, for throttling.
    private var lastEagerHeartbeatFire: Date?

    /// True while a real command's connect owns the link (connect-on-demand). The heartbeat probe and
    /// a command connect must never be outstanding together — a command preempts the probe and, while
    /// it's active, the probe is neither armed nor allowed to claim a didConnect. Cleared on the
    /// idle-disconnect (going idle) so the probe re-arms. managerQueue-isolated.
    private var commandConnectInFlight = false

    /// Set when a delayed-connect probe completes (a heartbeat wake): we disconnect the wake link and
    /// fire the heartbeat from the resulting didDisconnect, so Loop's commands start from a clean
    /// disconnected state via connect-on-demand. managerQueue-isolated.
    private var pendingHeartbeatFire = false

    /// True while the app is foregrounded. While foreground we keep the pod connected (skip the
    /// idle-disconnect, reconnect on an unintended drop) so connection-gated UI (test beeps, etc.) is
    /// live and in-app commands are instant. On background we disconnect and resume the heartbeat probe.
    private var isAppForeground = false

    /// Set via BlePodComm.setPodKeepAliveKeepsConnectedInBackground() which is used by
    /// OmniPumpManager to track podKeepAlive.keepsPodConnectedInBackground state.
    var podKeepAliveKeepsConnectedInBackground = false

    /// True when the pod should be HELD connected rather than idle/background-disconnected — the gate that
    /// suppresses connect-on-demand's disconnects. True while the app is foregrounded (foreground
    /// keep-alive), OR whenever a *background* Pod Keep Alive mode (silentTune / rileyLink — DASH only) is
    /// selected. Those modes exist for iPhone 16/17e + InPlay (Atlas) DASH pods where a disconnect→reconnect
    /// is unreliable, so the pod must stay connected and the keep-alive's periodic status refresh maintains
    /// the link. When Pod Keep Alive is `.disabled` (the default) OR `.whenOpen`, this collapses to exactly
    /// `isAppForeground` — i.e. no change from the validated connect-on-demand behavior. Read from
    /// managerQueue and cross-queue by PeripheralManager (benign bool race).
    var shouldHoldConnection: Bool {
        if isAppForeground { return true }
        // Eager-gated pods (InPlay + affected iPhone): reconnecting costs a wedge storm, and the pod
        // releases the link itself after ~180s of inactivity anyway — so never tear it down on
        // backgrounding. The link is kept via CBConnectPeripheralOptionEnableAutoReconnect (issued on
        // background connects), which restores it without needing app CPU while suspended.
        if let peripheral = keepAlivePeripheral, shouldUseEagerConnect(for: peripheral) { return true }
        return podKeepAliveKeepsConnectedInBackground
    }

    /// True once this PROCESS has ever been foregrounded. A [delayedConnect] with everFg=false means
    /// iOS ran this process entirely in the background — proof of a background wake/relaunch the user
    /// did NOT initiate (a manual open would have foregrounded it). Set on the main queue via a
    /// lifecycle observer; read from managerQueue for logging (benign race for a bool).
    private var everForeground = false

    /// Runtime heartbeat request (from PumpManager.setMustProvideBLEHeartbeat via BlePodComms). When
    /// true, run the delayed-connect loop so the pump provides periodic background wakes — used only
    /// when the CGM can't (network CGM). Normally false: stay disconnected + alarm-scan, connect on
    /// demand. managerQueue-isolated.
    private var heartbeatEnabled = false

    /// Whether a host has asked the pump to provide the BLE heartbeat. Exposed so the pump manager can
    /// warn when this is requested on a wedge-prone pod/phone combo, where we hold the connection (and
    /// so the StartDelay probe — which requires a DISCONNECTED pod — can never run).
    var isBLEHeartbeatRequested: Bool { heartbeatEnabled }

    /// The delayed-connect (StartDelay) heartbeat probe runs when Loop asks the pump to provide the BLE
    /// heartbeat (`heartbeatEnabled`, via PumpManager.setBLEHeartbeatRequest) AND we are NOT holding the pod
    /// connected. CBConnectPeripheralOptionStartDelayKey is a background-only mechanism — iOS ignores the
    /// delay while the app is foreground, so a foreground probe connects immediately, is treated as a wake,
    /// disconnects, re-arms, and churns. When we're holding the connection (foreground, or a background Pod
    /// Keep Alive mode) the pod is already connected and the heartbeat rides that link; the probe would
    /// fight it. Isolated to managerQueue (all probe call sites run there).
    private var delayedConnectProbeActive: Bool {
        heartbeatEnabled && !shouldHoldConnection
    }

    /// Enable/disable and schedule the pump-provided heartbeat (delayed-connect loop). Driven by
    /// PumpManager.setBLEHeartbeatRequest. `request == nil` disables it (fall back to connect-on-demand +
    /// alarm scan). When non-nil, the next-heartbeat target is (lastCGMReading + expectedInterval + buffer);
    /// this is refreshed on every call (e.g. after each CGM reading) so the cadence tracks the reading
    /// schedule. Refreshing the target while a probe is already in flight does NOT churn it — the in-flight
    /// probe completes and the next one picks up the new target.
    func setHeartbeatRequest(_ request: PumpHeartbeatRequest?) {
        managerQueue.async {
            let enabled = request != nil
            if let request = request {
                let base = request.lastCGMReadingDate ?? Date()
                self.lastCGMReadingDate = request.lastCGMReadingDate
                self.heartbeatTargetDate = base.addingTimeInterval(request.expectedCGMReadingInterval + BluetoothManager.heartbeatBufferSeconds)
                self.heartbeatInterval = request.expectedCGMReadingInterval
                self.heartbeatTargetSetAt = Date()
            } else {
                self.heartbeatTargetDate = nil
                self.heartbeatInterval = nil
                self.heartbeatTargetSetAt = nil
                self.lastCGMReadingDate = nil
            }
            let wasEnabled = self.heartbeatEnabled
            self.heartbeatEnabled = enabled
            let pid = ProcessInfo.processInfo.processIdentifier
            let targetDesc = self.heartbeatTargetDate.map { String(format: "%.0fs", $0.timeIntervalSinceNow) } ?? "-"
            self.log.default("[heartbeat] pid=%{public}d providesHeartbeat=%{public}@ targetIn=%{public}@", pid, String(enabled), targetDesc)
            self.connectionDelegate?.omnipodLogDeviceEvent("[heartbeat] pid=\(pid) providesHeartbeat=\(enabled) targetIn=\(targetDesc)")
            if enabled {
                // (Re)arm against the known autoconnect pod (nil if no active pod — don't probe a
                // stale/discarded device). No-ops if a probe is already in flight.
                if let peripheral = self.keepAlivePeripheral {
                    self.issueDelayedConnectProbe(peripheral)
                }
            } else if wasEnabled {
                // Stop the loop; fall back to connect-on-demand + alarm scan. Don't drop a live connection
                // while we're holding it (foreground keep-alive, or a background Pod Keep Alive mode).
                self.delayedProbeInFlight = false
                if !self.shouldHoldConnection {
                    for device in self.devices where device.manager.peripheral.state != .disconnected {
                        self.manager.cancelPeripheralConnection(device.manager.peripheral)
                    }
                }
                self.resumeScanIfNeeded()
            }
        }
    }

    /// Stamp the connect time and issue the connect, so didConnect can report the latency.
    private func timedConnect(_ peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        if connectRequestedAt[peripheral.identifier.uuidString] == nil {
            connectRequestedAt[peripheral.identifier.uuidString] = Date()
        }
        let cm: CBCentralManager = manager
        cm.connect(peripheral, options: nil)
        // Pairing/discovery connect: without a watchdog, a wedged connect was abandoned on the discovery
        // timeout WITHOUT cancelling, leaving iOS silently re-wedging the pod — which then stops
        // advertising and blinds the very scan trying to rediscover it. Arm the watchdog so a wedged
        // pairing connect is cancelled (freeing the pod to advertise) and retried within the budget.
        if shouldUseEagerConnect(for: peripheral) {
            connectionDelegate?.omnipodLogDeviceEvent("[eager] pairing connect — arming watchdog")
            armConnectWatchdog(peripheral, deadline: Date().addingTimeInterval(BluetoothManager.eagerPairingBudgetSeconds))
        }
    }

    /// Issue a connect with CBConnectPeripheralOptionStartDelayKey and record the time — the pump-provided
    /// heartbeat wake. iOS holds the request for `delayedConnectProbeSeconds`, then connects.
    private func issueDelayedConnectProbe(_ peripheral: CBPeripheral) {
        // Never run the heartbeat probe during pairing — its connect/disconnect churn clobbers the
        // discovery scan (this blocked pairing a new pod after the old one was discarded).
        guard !discoveryModeEnabled else { return }
        guard delayedConnectProbeActive, !delayedProbeInFlight, !commandConnectInFlight,
              peripheral.state == .disconnected else { return }
        // Compute the StartDelay so the wake lands no earlier than the next-heartbeat target
        // (lastCGMReading + expectedInterval + buffer). Floored so an overdue target can't collapse to a
        // near-zero delay — an overdue target (missed/late reading) retries at the floor, which for a
        // network CGM promptly catches a value that arrives a little late. Falls back to the fixed probe
        // interval when Loop hasn't supplied a schedule.
        // If no host is refreshing the schedule -- it set the heartbeat preference once (legacy
        // setMustProvideBLEHeartbeat) and hasn't updated it within ~1.5 reading intervals -- the fixed
        // target goes chronically overdue and every probe collapses onto heartbeatMinDelaySeconds (the 60s
        // floor). That produces a ~60s background wake cadence that burns the iOS background budget and gets
        // the app suspended for long stretches (Trio field report, LoopKit/LoopKit#599). Advance the stale
        // target by whole reading intervals so we hold the expected ~interval cadence instead. A host that
        // refreshes the schedule every reading (Loop) keeps heartbeatTargetSetAt fresh, so its floor-based
        // late-reading retry is untouched.
        if let interval = heartbeatInterval, interval > 0,
           let setAt = heartbeatTargetSetAt, Date().timeIntervalSince(setAt) > interval * 1.5,
           var advanced = heartbeatTargetDate, advanced <= Date() {
            let now = Date()
            while advanced <= now { advanced.addTimeInterval(interval) }
            heartbeatTargetDate = advanced
        }
        let target = heartbeatTargetDate ?? Date().addingTimeInterval(TimeInterval(BluetoothManager.delayedConnectProbeSeconds))
        // CBConnectPeripheralOptionStartDelayKey requires an INTEGER number of seconds — a fractional
        // NSNumber(double) is rejected with CBErrorDomain Code=1 "One or more parameters were invalid",
        // which (combined with the failure re-arm) produced a tight connect/fail loop. Round to whole
        // seconds, floored so an overdue target can't collapse to a near-zero delay.
        let delaySeconds = max(Int(BluetoothManager.heartbeatMinDelaySeconds), Int(target.timeIntervalSinceNow.rounded()))
        // Fault-listener coexistence: keep the alarm-filtered scan (C005, non-allowDuplicates — light)
        // running alongside the StartDelay probe, so faults are still caught during the heartbeat
        // wait. Only a HEAVY allowDuplicates scan (monitor/beacon mode) starves the connect, so stop
        // just that. didConnect stops whatever scan remains for the duration of the connection.
        if manager.isScanning, !BluetoothManager.lowPowerMonitorEnabled { manager.stopScan() }
        delayedProbeInFlight = true
        delayedProbeIssuedAt = Date()
        delayedProbeDelay = TimeInterval(delaySeconds)
        let pid = ProcessInfo.processInfo.processIdentifier
        log.default("[delayedConnect] pid=%{public}d everFg=%{public}@ issuing connect with StartDelay=%{public}ds for %{public}@", pid, String(everForeground), delaySeconds, peripheral.identifier.uuidString)
        connectionDelegate?.omnipodLogDeviceEvent("[delayedConnect] pid=\(pid) everFg=\(everForeground) issuing connect StartDelay=\(delaySeconds)s")
        manager.connect(peripheral, options: [CBConnectPeripheralOptionStartDelayKey: NSNumber(value: delaySeconds)])
    }

    /// The keep-connected auto-reconnect. Suppressed in connect-on-demand mode, where the pod is
    /// left disconnected between commands (and observable via advertisements) and connected on
    /// demand by PeripheralManager. Explicit connects (pairing, retrieveAndConnectKnownPod, the
    /// on-demand connect) do NOT route through here and are unaffected.
    private func autoReconnect(_ peripheral: CBPeripheral) {
        if BluetoothManager.connectOnDemandEnabled {
            log.debug("[connectOnDemand] suppressing auto-reconnect to %{public}@", peripheral.identifier.uuidString)
            return
        }
        timedConnect(peripheral)
    }

    init(podType: PodType) {
        self.podType = podType
        super.init()

        log.default("BluetoothManager #%{public}@ INIT (podType=%{public}@)", instanceID, String(describing: podType))

        managerQueue.sync {
            self.manager = CBCentralManager(delegate: self, queue: managerQueue, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.OmnipodKit"])
        }

        // Track foreground/background so we can tell an iOS background wake/relaunch (everFg stays
        // false) from a user-initiated open (foregrounds → everFg true). Log the transitions to the
        // persistent device log with PID for the timeline.
        let center = NotificationCenter.default
        center.addObserver(forName: HostAppState.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            let pid = ProcessInfo.processInfo.processIdentifier
            self?.managerQueue.async {
                guard let self = self else { return }
                self.everForeground = true
                self.log.default("[lifecycle] pid=%{public}d APP FOREGROUND", pid)
                self.connectionDelegate?.omnipodLogDeviceEvent("[lifecycle] pid=\(pid) APP FOREGROUND")
                self.enterForeground()
            }
        }
        center.addObserver(forName: HostAppState.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            let pid = ProcessInfo.processInfo.processIdentifier
            self?.managerQueue.async {
                guard let self = self else { return }
                self.log.default("[lifecycle] pid=%{public}d APP BACKGROUND", pid)
                self.connectionDelegate?.omnipodLogDeviceEvent("[lifecycle] pid=\(pid) APP BACKGROUND")
                self.enterBackground()
            }
        }

        // Seed from the live application state. If this manager is constructed AFTER the app has
        // already become active — a pump manager built lazily on a cold launch — the observer above
        // never fires for that launch, so isAppForeground stays false for the whole foreground
        // session. shouldHoldConnection is then false while the user is looking at the screen, and
        // the idle-disconnect drops the link ~4s after each command (loopandlearn/OmnipodKit#133).
        // If the notification wins the race instead, the isAppForeground guard makes this a no-op.
        DispatchQueue.main.async { [weak self] in
            guard HostAppState.isActive else { return }
            let pid = ProcessInfo.processInfo.processIdentifier
            self?.managerQueue.async {
                guard let self = self, !self.isAppForeground else { return }
                self.everForeground = true
                self.log.default("[lifecycle] pid=%{public}d APP FOREGROUND (seeded at init)", pid)
                self.connectionDelegate?.omnipodLogDeviceEvent("[lifecycle] pid=\(pid) APP FOREGROUND (seeded at init)")
                self.enterForeground()
            }
        }
    }

    deinit {
        log.default("BluetoothManager #%{public}@ DEINIT", instanceID)
    }

    @discardableResult
    private func addPeripheral(_ peripheral: CBPeripheral, podAdvertisement: PodAdvertisement?) -> Omni {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        var device: Omni! = devices.first(where: { $0.manager.peripheral.identifier == peripheral.identifier })

        if let device = device {
            log.default("Matched peripheral %{public}@ to existing device: %{public}@", peripheral, String(describing: device))
            device.manager.peripheral = peripheral
            device.manager.bluetoothManager = self   // ensure the queue-correct central helpers are reachable
            if let podAdvertisement = podAdvertisement {
                device.advertisement = podAdvertisement
            }
        } else {
            let pm = PeripheralManager(peripheral: peripheral, podType: podType, centralManager: manager)
            pm.bluetoothManager = self   // for fresh-discovery connect-on-demand
            device = Omni(peripheralManager: pm, advertisement: podAdvertisement)
            devices.append(device)
            log.info("Created device")
        }
        return device
    }
    
    // MARK: - Actions
    
    func discoverPods(completion: @escaping (BluetoothManagerError?) -> Void) {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.sync {
            self.discoverPods(completion)
        }
    }
    
    func endPodDiscovery() {
        managerQueue.sync {
            self.discoveryModeEnabled = false
            self.manager.stopScan()
            
            // Disconnect from all devices not in our connection list
            for device in devices {
                let peripheral = device.manager.peripheral
                if !autoConnectIDs.contains(peripheral.identifier.uuidString) &&
                   (peripheral.state == .connected || peripheral.state == .connecting)
                {
                    log.default("Disconnecting from peripheral: %{public}@", peripheral)
                    manager.cancelPeripheralConnection(peripheral)
                }
            }
        }
    }
    
    func connectToDevice(uuidString: String) {
        managerQueue.async {
            self.autoConnectIDs.insert(uuidString)
            // If powered on and peripheral not yet in devices, retrieve it now.
            // This handles the user-terminated app restart where willRestoreState wasn't called.
            if self.manager.state == .poweredOn,
               !self.devices.contains(where: { $0.manager.peripheral.identifier.uuidString == uuidString }),
               let uuid = UUID(uuidString: uuidString),
               let peripheral = self.manager.retrievePeripherals(withIdentifiers: [uuid]).first
            {
                self.log.default("connectToDevice: retrieved peripheral %{public}@ via retrievePeripherals", uuidString)
                self.addPeripheral(peripheral, podAdvertisement: nil)
                self.autoReconnect(peripheral)
            }
        }
    }

    /// Retrieve a known peripheral by UUID (without scanning), add it to devices, and initiate connection.
    /// Returns the Omni device synchronously; the actual BLE connection completes asynchronously.
    func retrieveAndConnectKnownPod(uuidString: String) -> Omni? {
        var result: Omni?
        managerQueue.sync {
            guard manager.state == .poweredOn, let uuid = UUID(uuidString: uuidString) else { return }
            let peripherals = manager.retrievePeripherals(withIdentifiers: [uuid])
            guard let peripheral = peripherals.first else {
                log.error("retrieveAndConnectKnownPod: no peripheral found for UUID %{public}@", uuidString)
                return
            }
            let device = addPeripheral(peripheral, podAdvertisement: nil)
            autoConnectIDs.insert(uuidString)
            autoReconnect(peripheral)
            log.default("retrieveAndConnectKnownPod: initiating connection to %{public}@", peripheral)
            result = device
        }
        return result
    }
    
    func disconnectFromDevice(uuidString: String) {
        managerQueue.async {
            self.autoConnectIDs.remove(uuidString)
            // Prune the discarded pod from devices[] (otherwise append-only) and drop any connection, so
            // a stale device can't be picked up later by the heartbeat/keep-alive machinery or churned
            // while pairing a new pod. (devices[] never being pruned is long-standing; this closes it.)
            if let idx = self.devices.firstIndex(where: { $0.manager.peripheral.identifier.uuidString == uuidString }) {
                let peripheral = self.devices[idx].manager.peripheral
                if peripheral.state == .connected || peripheral.state == .connecting {
                    self.manager.cancelPeripheralConnection(peripheral)
                }
                self.devices.remove(at: idx)
                self.log.default("Removed discarded pod %{public}@ from devices", uuidString)
                self.connectionDelegate?.omnipodLogDeviceEvent("[pairing] removed discarded pod \(uuidString) from devices")
            }
            // Quiet any heartbeat probe that was driving off the (now-discarded) pod.
            self.delayedProbeInFlight = false
        }
    }
    
    private func updateConnections() {
        guard manager.state == .poweredOn else {
            log.debug("Skipping updateConnections until state is poweredOn")
            return
        }
        
        for device in devices {
            let peripheral = device.manager.peripheral
            if autoConnectIDs.contains(peripheral.identifier.uuidString) {
                if peripheral.state == .disconnected || peripheral.state == .disconnecting {
                    log.info("updateConnections: Connecting to peripheral: %{public}@", peripheral)
                    autoReconnect(peripheral)
                }
            } else {
                if peripheral.state == .connected || peripheral.state == .connecting {
                    log.info("updateConnections: Disconnecting from peripheral: %{public}@", peripheral)
                    manager.cancelPeripheralConnection(peripheral)
                }
            }
        }
    }

    private func discoverPods(_ completion: @escaping (BluetoothManagerError?) -> Void) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("discoverPods()")

        guard manager.state == .poweredOn else {
            completion(.bluetoothNotAvailable(manager.state))
            return
        }

        // We will attempt to connect to all pairable devices when in discovery mode
        discoveryModeEnabled = true
        connectionDelegate?.omnipodLogDeviceEvent("[pairing] discoverPods — scanning for a pairable pod")
        // Quiet any in-flight heartbeat probe / stale connect churn so it doesn't clobber discovery.
        delayedProbeInFlight = false
        alarmScanSuppressed = false
        manager.stopScan()
        for device in devices {
            let peripheral = device.manager.peripheral
            if peripheral.state == .disconnected || peripheral.state == .disconnecting {
                log.info("discoverPods: Connecting to peripheral: %{public}@", peripheral)
                timedConnect(peripheral)  // pairing/discovery — an explicit connect, not auto-reconnect
            }
        }
        startScanning()

        completion(nil)
    }

    /// The service UUID the pod advertises when healthy-disconnected (used to discover it for a fast
    /// connect). O5 switches to a pdmId-based UUID after pairing.
    private var podScanServiceUUID: CBUUID {
        if podType.isO5, let pdmId = uuidPdmId {
            return o5ServiceAdvertisementUUID(pdmId)
        }
        return podType.blePodProfile.advertisementServiceUUID
    }

    /// O5 connectionless fault-watch filter: the pod-specific "attention" advertisement (status-suffix …02),
    /// built from our paired controllerId. Nil on DASH or until we know the controllerId (post-pairing).
    /// Analogous to the DASH `alarmServiceUUIDs` (C00A) but pod-specific — O5 embeds the controllerId in the
    /// UUID rather than using a shared 16-bit fault UUID, so this can't be a static constant.
    private var o5FaultScanServiceUUID: CBUUID? {
        guard podType.isO5, let pdmId = uuidPdmId else { return nil }
        return o5FaultAdvertisementUUID(pdmId)
    }

    /// Peripheral awaiting a fresh-discovery connect: while set, the next matching didDiscover stops
    /// the scan and connects on that just-heard advertisement (fast) instead of a cold reacquisition.
    private var pendingFreshConnectID: String?

    /// Connect fast by first hearing the pod: scan for its service, and on the next discovery stop the
    /// scan and connect on that fresh advertisement (~1-2s) rather than a bare cold connect (~16s).
    /// Falls back to a direct connect if we don't hear it quickly.
    func connectViaFreshDiscovery(_ peripheral: CBPeripheral) {
        managerQueue.async {
            let id = peripheral.identifier.uuidString
            self.pendingFreshConnectID = id
            self.manager.stopScan()
            self.manager.scanForPeripherals(withServices: [self.podScanServiceUUID], options: nil)
            self.log.default("[connectOnDemand] fresh-discovery scan for %{public}@", id)
            self.connectionDelegate?.omnipodLogDeviceEvent("[connectOnDemand] fresh-discovery scan started")
            self.managerQueue.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self = self, self.pendingFreshConnectID == id else { return }
                self.pendingFreshConnectID = nil
                self.log.default("[connectOnDemand] no fresh discovery in 4s — direct (cold) connect")
                self.connectionDelegate?.omnipodLogDeviceEvent("[connectOnDemand] no fresh discovery in 4s — cold connect fallback")
                self.manager.stopScan()
                self.freshConnect(peripheral)
            }
        }
    }

    /// Issue an on-demand connect with a stale-state flush. The first connect on a peripheral is
    /// clean, but a cached CBPeripheral that was previously connected then cancelPeripheralConnection'd
    /// wedges in .connecting on a bare reconnect (measured: every reconnect after an idle-disconnect
    /// timed out at 20s while iOS reported it .disconnected + advertising connectable). Cancel any
    /// lingering iOS-side connection intent and re-fetch the peripheral before connecting.
    private func freshConnect(_ peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        // freshConnect exists ONLY to unstick a wedged .connecting state before a cold connect. If the pod
        // is already healthily .connected, cancelling here would murder the live link (the self-inflicted
        // disconnect that didDisconnect then mislabels a "drop"). Leave the connection alone.
        if peripheral.state == .connected {
            log.default("[connectOnDemand] freshConnect skipped — already connected to %{public}@", peripheral.identifier.uuidString)
            pendingFreshConnectID = nil
            return
        }
        manager.cancelPeripheralConnection(peripheral)
        let target = manager.retrievePeripherals(withIdentifiers: [peripheral.identifier]).first ?? peripheral
        // Keep the session's peripheral reference in sync with the object we actually connect.
        if let device = devices.first(where: { $0.manager.peripheral.identifier == peripheral.identifier }) {
            device.manager.peripheral = target
        }
        manager.connect(target, options: nil)
    }

    // MARK: - Eager connect watchdog (InPlay / iPhone 16-class)

    /// Governing generation token per peripheral id — bumped on every arm/disarm so a stale scheduled
    /// watchdog tick no-ops (same token pattern as `pendingFreshConnectID`).
    private var connectWatchdogGeneration: [String: Int] = [:]

    /// When we began waiting for a connection with the app foregrounded (per peripheral id), for the
    /// user-visible foreground time-to-connect metric.
    private var foregroundConnectWaitSince: [String: Date] = [:]

    /// Peripheral ids with a system auto-reconnect in progress (didDisconnect reported
    /// isReconnecting=true), keyed to when we learned of it — used to measure and log the
    /// re-establishment latency when didConnect completes it.
    private var autoReconnectPendingSince: [String: Date] = [:]

    /// Peripheral ids currently under active watchdog management. While present, `didDisconnect` and
    /// `didFailToConnect` must NOT independently reconnect (the watchdog's cancel fires those callbacks
    /// and the watchdog itself owns the cancel/retry cycle — otherwise the handlers race it).
    private var connectWatchdogActive: Set<String> = []

    /// Whether the eager watchdog currently owns (re)connection for this peripheral.
    private func isConnectWatchdogActive(_ peripheral: CBPeripheral) -> Bool {
        connectWatchdogActive.contains(peripheral.identifier.uuidString)
    }

    /// Whether to use the eager cancel/retry connect strategy for this peripheral: the feature is on,
    /// the phone is an affected model (or force-all is set), AND the pod is InPlay or its type isn't yet
    /// known (pre-pairing / cold reconnect — we can't tell it's NOT InPlay). A pod whose name is known
    /// and is not "InPlay BLE" opts out.
    func shouldUseEagerConnect(for peripheral: CBPeripheral) -> Bool {
        guard BluetoothManager.eagerConnectEnabled else { return false }
        guard BluetoothManager.eagerConnectForceAllDevices || UIDevice.hasPossibleInPlayBLEIssues else { return false }
        if let name = peripheral.name, !name.isEmpty {
            return name == BluetoothManager.inPlayPeripheralName
        }
        return true
    }

    /// Direct eager connect: skip the fresh-discovery scan (a known/recovered peripheral is reconnected
    /// via `retrievePeripherals` + a plain `connect()`, which also re-arms iOS's fast connection scan)
    /// and arm the watchdog. Used for on-demand command connects to affected pods.
    private func eagerConnect(_ peripheral: CBPeripheral, deadline: Date) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        let target = manager.retrievePeripherals(withIdentifiers: [peripheral.identifier]).first ?? peripheral
        if let device = devices.first(where: { $0.manager.peripheral.identifier == peripheral.identifier }) {
            device.manager.peripheral = target
        }
        if manager.isScanning { manager.stopScan() }  // a concurrent scan starves connection completion on iOS
        log.default("[eager] direct connect for %{public}@ (name=%{public}@)", target.identifier.uuidString, target.name ?? "?")
        connectionDelegate?.omnipodLogDeviceEvent("[eager] direct connect (name=\(target.name ?? "?"))")
        manager.connect(target, options: eagerConnectOptions)
        armConnectWatchdog(target, deadline: deadline)
    }

    /// Arm the eager-connect watchdog for `peripheral`. If it hasn't reached `.connected` within
    /// `eagerConnectWatchdogSeconds`, presume the InPlay/iPhone-16 LL deadlock: log the (pathognomonic)
    /// still-`.connecting` state, `cancelPeripheralConnection` to tear the wedge down on-air, wait
    /// `eagerConnectTeardownSeconds`, then re-issue `connect()` and re-arm — until `deadline`. Disarmed
    /// by `didConnect`. Runs entirely on `managerQueue`.
    private func armConnectWatchdog(_ peripheral: CBPeripheral, deadline: Date) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        let id = peripheral.identifier.uuidString
        let generation = (connectWatchdogGeneration[id] ?? 0) + 1
        connectWatchdogGeneration[id] = generation
        connectWatchdogActive.insert(id)
        let interval = isAppForeground ? BluetoothManager.eagerConnectForegroundWatchdogSeconds
                                       : BluetoothManager.eagerConnectWatchdogSeconds
        managerQueue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self = self, self.connectWatchdogGeneration[id] == generation else { return }  // stale / disarmed
            let target = self.manager.retrievePeripherals(withIdentifiers: [peripheral.identifier]).first ?? peripheral
            guard target.state != .connected else { self.disarmConnectWatchdog(target); return }
            self.log.default("[eager] connect watchdog FIRED for %{public}@ state=%{public}d name=%{public}@ — cancelling wedged connect",
                             id, target.state.rawValue, target.name ?? "?")
            // Distinct telemetry: watchdog firing with state==connecting is pathognomonic for the wedge;
            // tagging the pod name ("InPlay BLE") lets prevalence be measured per pod lot / phone model.
            self.connectionDelegate?.omnipodLogDeviceEvent("[eager] watchdog fired state=\(target.state.rawValue) name=\(target.name ?? "?") — cancel+retry")
            self.manager.cancelPeripheralConnection(target)
            guard Date().addingTimeInterval(BluetoothManager.eagerConnectTeardownSeconds) < deadline else {
                self.log.default("[eager] connect watchdog budget exhausted for %{public}@ — giving up", id)
                self.disarmConnectWatchdog(target)
                return
            }
            self.managerQueue.asyncAfter(deadline: .now() + BluetoothManager.eagerConnectTeardownSeconds) { [weak self] in
                guard let self = self, self.connectWatchdogGeneration[id] == generation else { return }
                let retryTarget = self.manager.retrievePeripherals(withIdentifiers: [peripheral.identifier]).first ?? peripheral
                guard retryTarget.state != .connected else { self.disarmConnectWatchdog(retryTarget); return }
                if let device = self.devices.first(where: { $0.manager.peripheral.identifier == peripheral.identifier }) {
                    device.manager.peripheral = retryTarget
                }
                self.log.default("[eager] re-issuing connect for %{public}@ after teardown", id)
                self.connectionDelegate?.omnipodLogDeviceEvent("[eager] re-issue connect")
                self.manager.connect(retryTarget, options: self.eagerConnectOptions)
                self.armConnectWatchdog(retryTarget, deadline: deadline)
            }
        }
    }

    /// Fire the pump-provided heartbeat off a real link drop (disconnect-driven heartbeat mode).
    /// Throttled by `eagerHeartbeatMinIntervalSeconds` because our own watchdog cancels can produce a
    /// burst of disconnects during a wedge storm — those must not each count as a wake. Optionally
    /// gated on CGM staleness (`eagerHeartbeatStaleReadingSeconds`, default 0 = always fire).
    private func fireEagerHeartbeatIfNeeded() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        let now = Date()
        if let last = lastEagerHeartbeatFire,
           now.timeIntervalSince(last) < BluetoothManager.eagerHeartbeatMinIntervalSeconds {
            log.debug("[heartbeat] eager drop-driven heartbeat throttled")
            return
        }
        let staleAfter = BluetoothManager.eagerHeartbeatStaleReadingSeconds
        if staleAfter > 0, let lastReading = lastCGMReadingDate,
           now.timeIntervalSince(lastReading) < staleAfter {
            log.debug("[heartbeat] eager drop-driven heartbeat skipped — recent CGM reading")
            return
        }
        lastEagerHeartbeatFire = now
        let sinceReading = lastCGMReadingDate.map { String(format: "%.0fs", now.timeIntervalSince($0)) } ?? "?"
        log.default("[heartbeat] firing on link drop (eager heartbeat mode, lastCGM %{public}@ ago)", sinceReading)
        connectionDelegate?.omnipodLogDeviceEvent("[heartbeat] firing on link drop (eager mode, lastCGM \(sinceReading) ago)")
        connectionDelegate?.omnipodHeartbeatDidFire()
    }

    /// Invalidate any pending watchdog tick for this peripheral (bump the generation token).
    private func disarmConnectWatchdog(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier.uuidString
        connectWatchdogActive.remove(id)
        if let gen = connectWatchdogGeneration[id] {
            connectWatchdogGeneration[id] = gen + 1
        }
    }

    // MARK: - Central calls (MUST run on managerQueue)
    //
    // CBCentralManager was created with `managerQueue`, so every call into it has to be serialized on
    // that same queue — otherwise connect/cancel race the delegate callbacks and CoreBluetooth's
    // internal state machine. Connect-on-demand was calling central.connect()/cancelPeripheralConnection()
    // from PeripheralManager.queue, which wedged reconnects in .connecting (intermittently). These
    // helpers give PeripheralManager a queue-correct way to drive the central.

    /// Connect the (known/recovered) peripheral on the central's queue for a real command. A command
    /// preempts the heartbeat probe: cancel any in-flight StartDelay probe first so its pending connect
    /// can't complete and get mis-attributed as this command connect, then mark the command in flight
    /// (so the probe won't re-arm or claim the didConnect) and connect.
    func connectOnDemand(_ peripheral: CBPeripheral) {
        managerQueue.async { [weak self] in
            self?.beginCommandConnect(peripheral)
        }
    }

    /// Start a command (or keep-alive) connect. Must run on managerQueue.
    private func beginCommandConnect(_ peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        if delayedProbeInFlight {
            log.default("[connectOnDemand] command preempts heartbeat probe — cancelling probe")
            connectionDelegate?.omnipodLogDeviceEvent("[connectOnDemand] command preempts heartbeat probe — cancelling probe")
            delayedProbeInFlight = false
            delayedProbeIssuedAt = nil
            manager.cancelPeripheralConnection(peripheral)
        }
        commandConnectInFlight = true
        // Eager connect (InPlay / iPhone-16 mitigation): a known pod on an affected phone connects
        // directly (skipping the fresh-discovery scan), with the watchdog cancelling and retrying any
        // wedged attempt within a bounded budget instead of a single blind wait.
        if shouldUseEagerConnect(for: peripheral) {
            // Dedupe: two sessions racing (field logs show doubled command connects seconds apart)
            // must not issue a second connect on top of a watchdog-managed one. If the watchdog
            // already owns an in-flight connect attempt, just refresh its budget — re-arming bumps
            // the generation token, superseding the old timer; the pending connect stays pending and
            // didConnect satisfies every waiting session's .connect condition.
            if isConnectWatchdogActive(peripheral), peripheral.state == .connecting {
                log.default("[eager] command connect for %{public}@ — watchdog already managing an in-flight connect; refreshing budget", peripheral.identifier.uuidString)
                connectionDelegate?.omnipodLogDeviceEvent("[eager] command connect — already in flight, refreshing budget")
                armConnectWatchdog(peripheral, deadline: Date().addingTimeInterval(BluetoothManager.eagerConnectBudgetSeconds))
                return
            }
            log.default("[eager] command connect for %{public}@", peripheral.identifier.uuidString)
            connectionDelegate?.omnipodLogDeviceEvent("[eager] command connect")
            eagerConnect(peripheral, deadline: Date().addingTimeInterval(BluetoothManager.eagerConnectBudgetSeconds))
            return
        }
        // Fresh-discovery connect: briefly scan for the pod and connect on its just-heard advert
        // (~1-2s) instead of a bare cold connect() that waits out iOS's duty-cycled reacquisition
        // (~10-16s — the slow user-initiated Suspend). Falls back to a cold connect after 4s if the
        // pod isn't heard. (The heartbeat probe still uses StartDelay; the two stay serialized via
        // commandConnectInFlight.)
        log.default("[connectOnDemand] fresh-discovery command connect for %{public}@", peripheral.identifier.uuidString)
        connectViaFreshDiscovery(peripheral)
    }

    /// The known/autoconnect pod peripheral, for foreground keep-alive and heartbeat. Returns nil when
    /// there is no active pod (autoConnectIDs empty) — do NOT fall back to a stale device, or the
    /// heartbeat probe churns against the discarded pod and clobbers pairing a new one.
    private var keepAlivePeripheral: CBPeripheral? {
        return devices.first(where: { autoConnectIDs.contains($0.manager.peripheral.identifier.uuidString) })?.manager.peripheral
    }

    /// App entered the foreground: keep the pod connected so connection-gated UI is live and commands
    /// are instant. Pre-connect if it's currently disconnected. (Idle-disconnect is skipped while
    /// foreground; a drop is reconnected in didDisconnect.)
    private func enterForeground() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        isAppForeground = true
        guard let peripheral = keepAlivePeripheral else { return }
        switch peripheral.state {
        case .connected, .disconnecting:
            return
        case .disconnected:
            log.default("[connectOnDemand] foreground — pre-connecting for keep-alive")
            connectionDelegate?.omnipodLogDeviceEvent("[connectOnDemand] foreground — pre-connecting for keep-alive")
            noteForegroundConnectWait(peripheral)
            beginCommandConnect(peripheral)
        case .connecting:
            // The user is looking at the app and may want to bolus NOW. A `.connecting` peripheral here
            // is either a slow system reacquisition or a wedge — either way, waiting it out is the worst
            // option. If nothing is supervising it, cancel and restart the eager cycle immediately; if
            // the watchdog already owns it, re-arm so it runs on the (shorter) foreground interval.
            noteForegroundConnectWait(peripheral)
            if isConnectWatchdogActive(peripheral) {
                log.default("[foreground] connect in flight under watchdog — re-arming on foreground interval")
                connectionDelegate?.omnipodLogDeviceEvent("[foreground] re-arming watchdog on foreground interval")
                armConnectWatchdog(peripheral, deadline: Date().addingTimeInterval(BluetoothManager.eagerConnectBudgetSeconds))
            } else if shouldUseEagerConnect(for: peripheral) {
                log.default("[foreground] unsupervised connect in flight — cancelling and reconnecting eagerly")
                connectionDelegate?.omnipodLogDeviceEvent("[foreground] cancelling stale in-flight connect, reconnecting eagerly")
                manager.cancelPeripheralConnection(peripheral)
                managerQueue.asyncAfter(deadline: .now() + BluetoothManager.eagerConnectTeardownSeconds) { [weak self] in
                    guard let self = self, self.isAppForeground, peripheral.state != .connected else { return }
                    self.beginCommandConnect(peripheral)
                }
            }
        @unknown default:
            return
        }
    }

    /// Stamp the moment we started waiting for a connection with the app in the foreground, so
    /// `didConnect` can report the user-visible "how long until the app could talk to the pod" latency.
    private func noteForegroundConnectWait(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier.uuidString
        if foregroundConnectWaitSince[id] == nil {
            foregroundConnectWaitSince[id] = Date()
        }
    }

    /// App entered the background: normally drop the kept-alive connection and resume the heartbeat probe.
    /// EXCEPTION — a background Pod Keep Alive mode (silentTune / rileyLink, DASH): keep the pod connected,
    /// because those modes exist for phone/pod combos where a disconnect→reconnect is unreliable. The
    /// keep-alive's periodic status refresh maintains the link; we just leave it connected and don't probe.
    private func enterBackground() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        isAppForeground = false
        guard let peripheral = keepAlivePeripheral else { return }
        if shouldHoldConnection {   // background Pod Keep Alive mode — do NOT disconnect
            log.default("[connectOnDemand] background — Pod Keep Alive holding connection (no disconnect)")
            connectionDelegate?.omnipodLogDeviceEvent("[connectOnDemand] background — Pod Keep Alive holding connection")
            if peripheral.state == .disconnected {
                // We want it held connected but it's currently down — reconnect so keep-alive can refresh it.
                beginCommandConnect(peripheral)
            }
            return
        }
        commandConnectInFlight = false   // deliberate disconnect: let the probe re-arm
        if peripheral.state == .connected || peripheral.state == .connecting {
            log.default("[connectOnDemand] background — disconnecting, resuming heartbeat probe")
            connectionDelegate?.omnipodLogDeviceEvent("[connectOnDemand] background — disconnecting, resuming heartbeat probe")
            manager.cancelPeripheralConnection(peripheral)   // didDisconnect resumes scan + arms probe
        } else {
            resumeScanIfNeeded()                             // fault-listener scan while idle
            issueDelayedConnectProbe(peripheral)             // + heartbeat probe alongside (if needed)
        }
    }

    /// Cancel/disconnect the peripheral on the central's queue. This is the idle-disconnect / teardown
    /// path, so we're going idle: clear commandConnectInFlight so the resulting didDisconnect re-arms
    /// the heartbeat probe.
    func disconnectOnDemand(_ peripheral: CBPeripheral) {
        managerQueue.async { [weak self] in
            guard let self = self else { return }
            self.commandConnectInFlight = false
            self.log.default("[connectOnDemand] central.cancel on managerQueue for %{public}@", peripheral.identifier.uuidString)
            self.manager.cancelPeripheralConnection(peripheral)
        }
    }

    private func startScanning() {
        let serviceUUID: CBUUID = podScanServiceUUID
        let services: [CBUUID]?
        let options: [String: Any]
        if discoveryModeEnabled {
            // Pairing: scan for the pod's main advertisement service so a new/unpaired pod is found.
            // MUST take precedence over the low-power alarm scan (which filters on C005/C00A and would
            // never see a pairing pod) and over scanningEnabled (pairing has to scan regardless).
            services = [serviceUUID]
            options = [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            log.default("Start scanning (discovery/pairing filter=%{public}@)", serviceUUID.uuidString)
            connectionDelegate?.omnipodLogDeviceEvent("[pairing] scan started (filter=\(serviceUUID.uuidString))")
            manager.scanForPeripherals(withServices: services, options: options)
            return
        }
        guard BluetoothManager.scanningEnabled else {
            log.default("[connectOnDemand] scanning disabled — not starting a scan (scan-free connect mode)")
            return
        }
        if BluetoothManager.lowPowerMonitorEnabled && podType.isDash {
            // Low-power fault-watch (DASH only): wake on a fault-state advertisement — filter on the alarm
            // UUID(s) (C00A), no allowDuplicates. C00A is DASH-specific, so never used for O5.
            services = BluetoothManager.alarmServiceUUIDs
            options = [:]
        } else if BluetoothManager.lowPowerMonitorEnabled, let o5Fault = o5FaultScanServiceUUID {
            // Low-power fault-watch (O5): filter on the pod-specific "attention" advertisement (status-suffix
            // …02), built from our controllerId. Not advertised in normal operation, so the …00→…02 flip is a
            // fresh discovery that wakes a suspended app — the same mechanism as the DASH C00A scan. The wake
            // is handled in didDiscover (own-pod-gated), which connects + reads the real status.
            services = [o5Fault]
            options = [:]
        } else {
            // Monitor mode: filter on the pod's main service (O5-aware via podScanServiceUUID);
            // allowDuplicates to see the advert cadence.
            services = [serviceUUID]
            options = BluetoothManager.advertisementMonitorEnabled ? [CBCentralManagerScanOptionAllowDuplicatesKey: true] : [:]
        }
        let filterDesc = services == nil ? "wildcard" : services!.map { $0.uuidString }.joined(separator: ",")
        log.default("Start scanning (filter=%{public}@, lowPowerMonitor=%{public}@, allowDuplicates=%{public}@)",
                    filterDesc,
                    String(describing: BluetoothManager.lowPowerMonitorEnabled),
                    String(describing: options[CBCentralManagerScanOptionAllowDuplicatesKey] != nil))
        // Device-log the idle-scan arm so a fault-detection test can confirm which filter is actually live
        // (e.g. the O5 …02 fault UUID built from our controllerId) even when the app is suspended and only
        // the persistent device log survives.
        connectionDelegate?.omnipodLogDeviceEvent("[scan] armed filter=[\(filterDesc)] lowPowerMonitor=\(BluetoothManager.lowPowerMonitorEnabled) allowDuplicates=\(options[CBCentralManagerScanOptionAllowDuplicatesKey] != nil)")
        manager.scanForPeripherals(withServices: services, options: options)
    }

    private func stopScanning() {
        log.default("Stop scanning")
        manager.stopScan()
    }

    /// Resume the monitor/beacon scan after a connect attempt ends (connect-on-demand stops the scan
    /// during the connect because an active allowDuplicates scan starves connection completion).
    /// Only when nothing is connected, so we never scan while a command is using the link.
    private func resumeScanIfNeeded() {
        guard BluetoothManager.advertisementMonitorEnabled || BluetoothManager.lowPowerMonitorEnabled else { return }
        guard !alarmScanSuppressed else { return }   // an alert is active — stay quiet (re-wake quieting)
        guard manager?.state == .poweredOn, !manager.isScanning else { return }
        guard !devices.contains(where: { $0.manager.peripheral.state == .connected || $0.manager.peripheral.state == .connecting }) else { return }
        log.default("[connectOnDemand] resuming scan after connect attempt")
        startScanning()
    }

    /// Called (via BlePodComms) when a connected status read shows all pod alerts cleared: lift the
    /// re-wake suppression and resume the connectionless alarm scan.
    func resumeAlarmScanAfterAlertsCleared() {
        managerQueue.async { [weak self] in
            guard let self = self, self.alarmScanSuppressed else { return }
            self.alarmScanSuppressed = false
            self.log.default("[POD-ALERT] alerts cleared — resuming alarm scan")
            self.connectionDelegate?.omnipodLogDeviceEvent("[POD-ALERT] alerts cleared — resuming alarm scan")
            self.resumeScanIfNeeded()
        }
    }

    // MARK: - Accessors

    func getConnectedDevices() -> [Omni] {
        var connected: [Omni] = []
        managerQueue.sync {
            connected = self.devices.filter { $0.manager.peripheral.state == .connected }
        }
        return connected
    }

    /// The PeripheralManager for a known device by peripheral UUID — connected OR NOT. Connect-on-demand
    /// uses this to obtain the pod's manager while disconnected (BlePodComms.manager is otherwise only
    /// set in omnipodPeripheralDidConnect, so it's nil on a fresh launch when auto-reconnect is off).
    func peripheralManager(forIdentifier uuidString: String) -> PeripheralManager? {
        var result: PeripheralManager?
        managerQueue.sync {
            result = self.devices.first(where: { $0.manager.peripheral.identifier.uuidString == uuidString })?.manager
        }
        return result
    }

    override var debugDescription: String {
        
        var report = [
            "## BluetoothManager",
            "central: \(manager!)"
        ]

        for device in devices {
            report.append(String(reflecting: device))
            report.append("")
        }

        return report.joined(separator: "\n\n")
    }
}


extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("[#%{public}@] %{public}@: %{public}@", instanceID, #function, String(describing: central.state.rawValue))

        if case .poweredOn = central.state {
            // bluetooth may have reset; update peripheral references
            for device in devices {
                if let newPeripheral = central.retrievePeripherals(withIdentifiers: [device.manager.peripheral.identifier]).first {
                    log.debug("Re-connecting to known peripheral %{public}@", newPeripheral.identifier.uuidString)
                    device.manager.peripheral = newPeripheral
                    autoReconnect(newPeripheral)
                }
            }

            // Recover peripherals from autoConnectIDs that aren't yet in devices.
            // This handles the user-terminated app restart where willRestoreState wasn't called.
            let knownDeviceIDs = Set(devices.map { $0.manager.peripheral.identifier.uuidString })
            for uuidString in autoConnectIDs where !knownDeviceIDs.contains(uuidString) {
                if let uuid = UUID(uuidString: uuidString),
                   let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first
                {
                    log.default("[#%{public}@] Recovered peripheral from autoConnectIDs: %{public}@", instanceID, uuidString)
                    addPeripheral(peripheral, podAdvertisement: nil)
                    autoReconnect(peripheral)
                }
            }

            updateConnections()
            
            if BluetoothManager.advertisementMonitorEnabled {
                // Monitor mode: keep scanning continuously so we observe pod advertisements,
                // regardless of whether all autoConnect devices are known/connected.
                if !manager.isScanning { startScanning() }
            } else if (discoveryModeEnabled || !hasDiscoveredAllAutoConnectDevices) && !manager.isScanning {
                startScanning()
            } else if !discoveryModeEnabled && manager.isScanning {
                stopScanning()
            }
        }

        for device in devices {
            device.manager.assertConfiguration()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        log.info("Omni %{public}@: %{public}@", #function, dict)

        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                let device = addPeripheral(peripheral, podAdvertisement: nil)
                
                if autoConnectIDs.contains(peripheral.identifier.uuidString) {
                    if peripheral.state == .connected {
                        connectionDelegate?.omnipodPeripheralWasRestored(manager: device.manager)
                    }
                } else if peripheral.state == .connected || peripheral.state == .connecting {
                    // Don't disconnect — autoConnectIDs may not be populated yet due to init ordering.
                    // updateConnections() will clean up any truly unwanted peripherals after autoConnectIDs is set.
                    log.info("Restored peripheral %{public}@ not yet in autoConnectIDs, deferring cleanup to updateConnections", peripheral.identifier.uuidString)
                }
            }
        }
    }

    /// The DASH "clear / no alert" status word (see DASH_BEACON_FINDINGS.md). Any other value while
    /// the pod is otherwise healthy indicates an active alert/alarm.
    private static let podStatusClear = Data([0x00, 0x02, 0x00, 0x00])

    /// Extract the 4-byte DASH status word from the manufacturer data: it sits immediately before the
    /// 3-byte address+trailer tail (…000a‹STATUS›f10cbc). End-anchored so it's robust to the fixed
    /// pod-id prefix. Returns nil if the mfg data isn't the expected DASH shape.
    private func podStatusWord(from advertisementData: [String: Any]) -> Data? {
        guard let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 8 else { return nil }
        return mfg.subdata(in: (mfg.count - 7)..<(mfg.count - 3))
    }

    /// Connectionless fault/alert detection: read the pod's alarm state straight from its advertisement —
    /// no connection needed. Decodes the status word (b2 = FaultEventCode, b3 = AlertSet bitmask) and, on
    /// a fault/alert transition, surfaces it to the pump manager (which fetches status and raises the pod
    /// alarm), then quiets the scan until it clears.
    private func detectPodAlertStatus(peripheral: CBPeripheral, advertisementData: [String: Any]) {
        guard let status = podStatusWord(from: advertisementData) else { return }
        let id = peripheral.identifier.uuidString
        guard lastPodStatusWord[id] != status else { return }   // only on change
        // The 4-byte status word is [b0 b1 b2 b3]. b3 is the AlertSet bitmask (bit N = slot N firing);
        // e.g. clear=…00, expiration-reminder(slot3)=…08. b1 carries a baseline 0x02 (slot1 "NotUsed")
        // plus the same alert bit, so we log it too as a cross-check while enumerating alert types.
        // The 4-byte status word is [b0 b1 b2 b3]:
        //  - b3 = AlertSet bitmask (bit N = alert slot N FIRING); e.g. expiration-reminder(slot3)=0x08.
        //  - b2 = FAULT code (0x00 in every non-fault state; = FaultEventCode on a fault, e.g. occlusion
        //    0x14 — confirmed by a captured occlusion: word 00141400, connected read "0x14 Occluded").
        //  - b1 = an "alert configured"/current-alarm byte (baseline 0x02, 0x0a with a reminder set,
        //    and the fault code on a fault) — logged as a cross-check only.
        let bytes = Array(status)
        let alertByte: UInt8 = bytes.count >= 4 ? bytes[3] : 0
        let faultByte: UInt8 = bytes.count >= 3 ? bytes[2] : 0
        let statusByte1: UInt8 = bytes.count >= 2 ? bytes[1] : 0
        let alertSet = AlertSet(rawValue: alertByte)
        let prevBytes = lastPodStatusWord[id].map { Array($0) }
        let prevAlertByte: UInt8 = (prevBytes?.count ?? 0) >= 4 ? prevBytes![3] : 0
        let prevFaultByte: UInt8 = (prevBytes?.count ?? 0) >= 3 ? prevBytes![2] : 0
        let wasAlert = prevAlertByte != 0
        let isAlert = alertByte != 0
        let wasFault = prevFaultByte != 0
        let isFault = faultByte != 0
        lastPodStatusWord[id] = status
        let slotDesc = alertSet.isEmpty ? "none" : alertSet.map { String(describing: $0) }.joined(separator: ",")
        let faultDesc = isFault ? String(describing: FaultEventCode(rawValue: faultByte)) : "none"
        log.default("[POD-STATUS] %{public}@ status=%{public}@ alertByte=0x%{public}02x faultByte=0x%{public}02x b1=0x%{public}02x slots=[%{public}@] fault=%{public}@ — connectionless detect",
                    id, status.hexadecimalString, alertByte, faultByte, statusByte1, slotDesc, faultDesc)
        connectionDelegate?.omnipodLogDeviceEvent("[POD-STATUS] status=\(status.hexadecimalString) alertByte=0x\(String(format: "%02x", alertByte)) faultByte=0x\(String(format: "%02x", faultByte)) slots=[\(slotDesc)] fault=\(faultDesc) — connectionless detect")

        // A pod FAULT just appeared (b2 went non-zero): the pod has stopped delivery. Surface it.
        if !wasFault && isFault {
            log.default("[POD-FAULT] %{public}@ → FAULT 0x%{public}02x (%{public}@) (from advertisement, no connect)", id, faultByte, faultDesc)
            connectionDelegate?.omnipodLogDeviceEvent("[POD-FAULT] → FAULT 0x\(String(format: "%02x", faultByte)) (\(faultDesc)) (from advertisement, no connect)")
            surfacePodConditionAndQuiet(alertSet: alertSet)
        } else if !wasAlert && isAlert {
            // An alert slot just started firing.
            log.default("[POD-ALERT] %{public}@ → ALERT ACTIVE slots=[%{public}@] (from advertisement, no connect)", id, slotDesc)
            connectionDelegate?.omnipodLogDeviceEvent("[POD-ALERT] → ALERT ACTIVE slots=[\(slotDesc)] (from advertisement, no connect)")
            surfacePodConditionAndQuiet(alertSet: alertSet)
        } else if (wasAlert && !isAlert) || (wasFault && !isFault) {
            log.default("[POD-ALERT] %{public}@ → CLEARED slots=[%{public}@] (from advertisement, no connect)", id, slotDesc)
            connectionDelegate?.omnipodLogDeviceEvent("[POD-ALERT] → CLEARED slots=[\(slotDesc)] (from advertisement, no connect)")
        }
    }

    /// Connect on demand + read the real pod status so a connectionless-detected alert/fault surfaces to
    /// Loop (getPodStatus -> alertsChanged/issueAlert or fault handling), then quiet the alarm scan while
    /// the condition persists (re-wake quieting; lifted by resumeAlarmScanAfterAlertsCleared()).
    private func surfacePodConditionAndQuiet(alertSet: AlertSet) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        // Notify the host OFF managerQueue. The delegate handles this synchronously by driving
        // getPodStatus -> runSession -> bleRunSession -> peripheralManager(forIdentifier:), which does
        // managerQueue.sync. This runs from didDiscover (already on managerQueue), so calling the delegate
        // inline is a sync-to-self deadlock — it hung/crash-looped the app on a fresh launch when a DASH pod
        // advertised a fault/alert before any connection had established BlePodComms.manager
        // (loopandlearn/OmnipodKit#126). Quieting the alarm scan stays on managerQueue.
        let delegate = connectionDelegate
        DispatchQueue.global(qos: .userInitiated).async {
            delegate?.omnipodDidDetectAlert(slots: alertSet)
        }
        alarmScanSuppressed = true
        if manager.isScanning { manager.stopScan() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.debug("%{public}@: %{public}@, %{public}@", #function, peripheral, advertisementData)

        // Full advertisement dump for pod-adjacent frames — field data on what the pod advertises, and
        // the input to the connectionless fault-detection path. Captures every field.
        let advSvcUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let isPodFrame = autoConnectIDs.contains(peripheral.identifier.uuidString) || PodAdvertisement(advertisementData, podType: podType) != nil
        // Only OUR paired pod (unique BLE identity) may drive fault detection / connect / probe. The
        // C00A fault-scan filter is generic (any DASH pod's fault matches), so a nearby stranger's
        // faulted pod can wake us — we must NOT act on it (no false alarm, and no foreign connect or
        // scan-suppression). Advert LOGGING below stays on any pod-shaped frame (diagnostics + pairing).
        let isOwnPod = autoConnectIDs.contains(peripheral.identifier.uuidString)
        if BluetoothManager.advertisementMonitorEnabled, isPodFrame {
            let svcUUIDs = advSvcUUIDs.map { $0.uuidString }.joined(separator: ",")
            let mfg = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.hexadecimalString ?? "-"
            let svcData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?
                .map { "\($0.key.uuidString):\($0.value.hexadecimalString)" }.joined(separator: ",") ?? "-"
            let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "-"
            // Inter-frame delta = the advertising cadence (RE's DS-beacon-rate question).
            let now = Date()
            let dt = lastAdvSeen[peripheral.identifier.uuidString].map { String(format: "%.2f", now.timeIntervalSince($0)) } ?? "-"
            lastAdvSeen[peripheral.identifier.uuidString] = now
            log.default("[ADV] %{public}@ dt=%{public}@s rssi=%{public}@ state=%{public}@ connectable=%{public}@ name=%{public}@ svcUUIDs=[%{public}@] mfg=%{public}@ svcData=%{public}@",
                        peripheral.identifier.uuidString, dt, RSSI, String(describing: peripheral.state.rawValue),
                        String(describing: connectable), name.isEmpty ? "-" : name, svcUUIDs.isEmpty ? "-" : svcUUIDs, mfg, svcData)
            // Field advert logging (kept in production): record each DISTINCT pod advert to the device log
            // so real-world Issue Reports capture what the pod advertises — the raw material for decoding
            // more fault/alert states. Deduped by svcUUIDs|mfg (the advert is stable between state changes,
            // so this logs a transition once, not every ~1Hz frame). Fires whenever we discover the pod —
            // i.e. during each command connect's fresh-discovery scan and on a C00A fault-scan wake.
            if isPodFrame {
                let advKey = "\(svcUUIDs)|\(mfg)|conn=\(String(describing: connectable))"
                if lastLoggedAdvKey[peripheral.identifier.uuidString] != advKey {
                    lastLoggedAdvKey[peripheral.identifier.uuidString] = advKey
                    connectionDelegate?.omnipodLogDeviceEvent("[ADV] svcUUIDs=[\(svcUUIDs.isEmpty ? "-" : svcUUIDs)] mfg=\(mfg) connectable=\(String(describing: connectable)) svcData=\(svcData)")
                }
            }
        } else if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
                  BluetoothManager.advertisementMonitorEnabled {
            log.default("[SCAN] ManufacturerData: %{public}@ (%{public}d bytes)", mfgData.hexadecimalString, mfgData.count)
        }

        // Connectionless alarm decode is DASH-specific (parses the DASH iBeacon status word). O5 encodes
        // state differently (see the capture) — never run the DASH decode against an O5 advert. Gated on
        // isOwnPod so a foreign pod that matched the generic C00A filter can't drive detection/connect/probe.
        if isOwnPod && podType.isDash {
            detectPodAlertStatus(peripheral: peripheral, advertisementData: advertisementData)
            // Fresh-discovery connect: we just heard the pod — stop scanning and connect NOW on this
            // fresh advertisement (fast) instead of waiting out iOS's cold reacquisition (~16s).
            if pendingFreshConnectID == peripheral.identifier.uuidString {
                pendingFreshConnectID = nil
                log.default("[connectOnDemand] fresh discovery -> connect %{public}@", peripheral.identifier.uuidString)
                connectionDelegate?.omnipodLogDeviceEvent("[connectOnDemand] pod heard -> connecting on fresh advert")
                manager.stopScan()
                // Defer the connect one managerQueue tick so the scan actually tears down first.
                // Connecting synchronously here (still inside the scan's didDiscover) starved the
                // connect -> it wedged in .connecting and timed out at 20s. Let iOS settle the
                // stopScan, then connect on the just-heard advert. Direct connect (not freshConnect):
                // the peripheral was just heard and is connectable, so skip the cancel+re-retrieve
                // stale-flush (an In-Play stall workaround) that added a round-trip on the good pod.
                managerQueue.async { [weak self] in
                    self?.manager.connect(peripheral, options: nil)
                }
            }
            // Kick off / re-arm the delayed-connect probe once we know the pod is present + disconnected.
            issueDelayedConnectProbe(peripheral)
        }

        // O5 connectionless fault-watch. Our O5 pod flips its single service-UUID status suffix from …00
        // (normal) to …02 (attention/fault). Field-validated end-to-end: an induced occlusion flipped the
        // advert to …02, this scan woke the backgrounded app, and the follow-on getPodStatus surfaced
        // "Occluded" (0x14) to the pump manager (see O5_ADVERTISING_FINDINGS.md). Gated on isOwnPod: the
        // controllerId embedded in the UUID can collide across app builds, so a stranger's faulted pod can
        // match the …02 filter; only OUR pod (unique BLE identity) may drive detection. The suffix is a
        // COARSE 4-state signal (00/01/02/03), NOT fault-specific — so we don't decode a fault type from it,
        // we surface it to connect + read the real status (getPodStatus resolves the exact fault/alert), then
        // quiet the scan while it persists. Suffixes 01/03 have not been observed and are intentionally not
        // matched; any other attention state is simply caught on the next status read instead of the scan.
        if isOwnPod, podType.isO5, let o5Fault = o5FaultScanServiceUUID, advSvcUUIDs.contains(o5Fault) {
            log.default("[POD-FAULT] %{public}@ → O5 attention advert (…02) (from advertisement, no connect)", peripheral.identifier.uuidString)
            connectionDelegate?.omnipodLogDeviceEvent("[POD-FAULT] → O5 attention advert (…02) — connecting to read status")
            surfacePodConditionAndQuiet(alertSet: AlertSet(rawValue: 0))
        }

        if let podAdvertisement = PodAdvertisement(advertisementData, podType: podType) {
            addPeripheral(peripheral, podAdvertisement: podAdvertisement)

            if discoveryModeEnabled {
                connectionDelegate?.omnipodLogDeviceEvent("[pairing] heard pod \(peripheral.identifier.uuidString) pairable=\(podAdvertisement.pairable) state=\(peripheral.state.rawValue)")
            }
            if discoveryModeEnabled && podAdvertisement.pairable {
                // We've heard our target pairable pod — stop the discovery scan so it doesn't starve the
                // connect (an active allowDuplicates scan wedges the connect in .connecting, which is
                // what stalled pairing), then connect if it's disconnected. A watchdog-managed connect
                // in flight is left alone (it's supervised and will retry itself).
                if manager.isScanning { manager.stopScan() }
                if peripheral.state == .disconnected {
                    log.default("Connecting to pairable device %{public}@ in discovery mode", peripheral)
                    connectionDelegate?.omnipodLogDeviceEvent("[pairing] connecting to pairable pod \(peripheral.identifier.uuidString)")
                    timedConnect(peripheral)  // pairing — an explicit connect, not auto-reconnect
                } else if peripheral.state == .connecting && !isConnectWatchdogActive(peripheral) {
                    // ZOMBIE pending connect: we just HEARD this pod advertise, so it is not in a live
                    // connection — a stale, unsupervised connect request (e.g. from an abandoned pairing
                    // attempt) is pinning it in .connecting. Field failure mode: every rescan reported
                    // "heard pod ... state=1" and then declined to connect, so pairing never succeeded.
                    // Cancel the zombie and connect fresh (re-arming the watchdog) once teardown lands.
                    log.default("[pairing] pairable pod %{public}@ stuck in .connecting with no watchdog — cancelling zombie connect", peripheral.identifier.uuidString)
                    connectionDelegate?.omnipodLogDeviceEvent("[pairing] zombie connect on pairable pod — cancelling and reconnecting")
                    manager.cancelPeripheralConnection(peripheral)
                    managerQueue.asyncAfter(deadline: .now() + BluetoothManager.eagerConnectTeardownSeconds) { [weak self] in
                        guard let self = self, self.discoveryModeEnabled, peripheral.state != .connected else { return }
                        self.log.default("[pairing] reconnecting to pairable pod %{public}@ after zombie teardown", peripheral.identifier.uuidString)
                        self.connectionDelegate?.omnipodLogDeviceEvent("[pairing] connecting to pairable pod \(peripheral.identifier.uuidString) (post-zombie)")
                        self.timedConnect(peripheral)
                    }
                }
            } else if autoConnectIDs.contains(peripheral.identifier.uuidString) && peripheral.state == .disconnected {
                log.debug("Reconnecting to autoconnect device")
                autoReconnect(peripheral)
            } else {
                log.info("Ignoring paired or unconnectable peripheral: %{public}@", peripheral)
            }
        } else {
            log.info("Ignoring peripheral with unexpected advertisement data: %{public}@", advertisementData)
        }
        
        if !BluetoothManager.advertisementMonitorEnabled && !discoveryModeEnabled && central.isScanning && hasDiscoveredAllAutoConnectDevices {
            log.debug("All peripherals discovered")
            stopScanning()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        // We are connected — any outstanding fresh-discovery cold-connect fallback is now moot. Clearing
        // the token no-ops a still-pending 4s fallback timer (connectViaFreshDiscovery) so it cannot fire
        // freshConnect() → cancelPeripheralConnection() against THIS live link. That stale-timer teardown,
        // re-read by didDisconnect as an unintended "drop", was the root of the self-inflicted
        // connect → cancel → "reconnecting after drop" → reconnect loop.
        if pendingFreshConnectID == peripheral.identifier.uuidString {
            pendingFreshConnectID = nil
        }

        // A completed connect satisfies the eager watchdog — invalidate any pending cancel/retry tick.
        disarmConnectWatchdog(peripheral)

        // Foreground time-to-connect: the user-facing number (how long after opening the app before we
        // could talk to the pod).
        if let since = foregroundConnectWaitSince.removeValue(forKey: peripheral.identifier.uuidString) {
            let latency = Date().timeIntervalSince(since)
            log.default("[foreground] connected %{public}.1fs after foreground wait began", latency)
            connectionDelegate?.omnipodLogDeviceEvent("[foreground] connected \(String(format: "%.1f", latency))s after foregrounding")
        }

        // If this connect completes a system auto-reconnect (EnableAutoReconnect experiment), log the
        // measured re-establishment latency — the key observable for the experiment.
        if let since = autoReconnectPendingSince.removeValue(forKey: peripheral.identifier.uuidString) {
            let latency = Date().timeIntervalSince(since)
            log.default("[autoReconnect] link RE-ESTABLISHED by system after %{public}.1fs for %{public}@", latency, peripheral.identifier.uuidString)
            connectionDelegate?.omnipodLogDeviceEvent("[autoReconnect] link re-established by system after \(String(format: "%.1f", latency))s")
        }

        // Connected — stop the connect-helper scan (connectOnDemand started a light scan to speed the
        // connect). We don't scan while connected; the monitor scan is restored on the next disconnect.
        if manager.isScanning {
            manager.stopScan()
        }

        // Delayed-connect probe: report the delay, then disconnect after a brief hold so the loop
        // re-arms (didDisconnect issues the next probe). Skip the normal session proxy — timing only.
        // A genuine heartbeat-probe wake: the StartDelay connect WE issued completed, and no command
        // is using the link. (A command connect sets commandConnectInFlight and clears delayedProbeInFlight,
        // so it never lands here — that was the old hijack that cancelled real commands after 2s.)
        let treatAsProbe = (delayedProbeInFlight && !commandConnectInFlight)
        if treatAsProbe {
            let measured = delayedProbeIssuedAt.map { String(format: "%.1f", Date().timeIntervalSince($0)) } ?? "?(restored)"
            let startDelayStr = delayedProbeDelay.map { String(format: "%.0f", $0) } ?? "?"
            let pid = ProcessInfo.processInfo.processIdentifier
            log.default("[delayedConnect] pid=%{public}d everFg=%{public}@ CONNECTED after %{public}@s (StartDelay=%{public}@s) %{public}@ — heartbeat wake",
                        pid, String(everForeground), measured, startDelayStr, peripheral.identifier.uuidString)
            connectionDelegate?.omnipodLogDeviceEvent("[delayedConnect] pid=\(pid) everFg=\(everForeground) CONNECTED after \(measured)s (StartDelay=\(startDelayStr)s) — heartbeat wake")
            delayedProbeInFlight = false
            delayedProbeIssuedAt = nil
            delayedProbeDelay = nil
            // Drop the wake connection and fire the heartbeat from didDisconnect (clean idle state), so
            // Loop's resulting status/dose commands run via connect-on-demand rather than fighting this
            // transient probe link.
            pendingHeartbeatFire = true
            manager.cancelPeripheralConnection(peripheral)
            return
        }

        if let requestedAt = connectRequestedAt.removeValue(forKey: peripheral.identifier.uuidString) {
            let latency = String(format: "%.3f", Date().timeIntervalSince(requestedAt))
            log.default("[#%{public}@] CONNECTED: %{public}@ — connect latency %{public}@s (known device: %{public}@)",
                        instanceID, peripheral, latency,
                        String(describing: devices.contains { $0.manager.peripheral.identifier == peripheral.identifier }))
        } else {
            log.default("[#%{public}@] CONNECTED: %{public}@ — connect latency unknown (no request stamp) (known device: %{public}@)",
                        instanceID, peripheral, String(describing: devices.contains { $0.manager.peripheral.identifier == peripheral.identifier }))
        }

        // Proxy connection events to peripheral manager
        for device in devices where device.manager.peripheral.identifier == peripheral.identifier {
            device.manager.centralManager(central, didConnect: peripheral)
            connectionDelegate?.omnipodPeripheralDidConnect(manager: device.manager)

            // Get an RSSI reading for logging
            peripheral.readRSSI()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handleDisconnect(central, peripheral: peripheral, error: error, isReconnecting: false)
    }

    /// iOS 17+ variant: when implemented, CoreBluetooth calls this INSTEAD of the classic
    /// didDisconnectPeripheral for all disconnects. `isReconnecting == true` means the connect was made
    /// with CBConnectPeripheralOptionEnableAutoReconnect and the SYSTEM is re-establishing the link
    /// itself (didConnect will fire again on success) — so we log it distinctly and skip our own
    /// reconnection machinery for that case.
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        let age = CFAbsoluteTimeGetCurrent() - timestamp
        log.default("[autoReconnect] didDisconnect(timestamp:isReconnecting:) isReconnecting=%{public}@ eventAge=%{public}.3fs error=%{public}@",
                    String(describing: isReconnecting), age, String(describing: error))
        // Log EVERY invocation to the device log (not just isReconnecting==true), so an Issue Report
        // proves whether iOS is calling this iOS-17+ signature at all — otherwise "no [autoReconnect]
        // events" is ambiguous between "never called" and "called with isReconnecting=false".
        let errStr = error.map { String(describing: $0) } ?? "nil"
        if isReconnecting {
            connectionDelegate?.omnipodLogDeviceEvent("[autoReconnect] system auto-reconnecting (drop \(String(format: "%.1f", age))s ago, error=\(errStr))")
        } else {
            connectionDelegate?.omnipodLogDeviceEvent("[autoReconnect] didDisconnect isReconnecting=false (eventAge \(String(format: "%.1f", age))s, error=\(errStr))")
        }
        handleDisconnect(central, peripheral: peripheral, error: error, isReconnecting: isReconnecting)
    }

    private func handleDisconnect(_ central: CBCentralManager, peripheral: CBPeripheral, error: Error?, isReconnecting: Bool) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("[#%{public}@] DISCONNECTED: %{public}@ error=%{public}@ willReconnect=%{public}@ systemReconnecting=%{public}@", instanceID, peripheral,
                    String(describing: error), String(describing: autoConnectIDs.contains(peripheral.identifier.uuidString)), String(describing: isReconnecting))

        // Proxy disconnection events to peripheral manager
        for device in devices where device.manager.peripheral.identifier == peripheral.identifier {
            device.manager.centralManager(central, didDisconnect: peripheral, error: error)
        }

        connectionDelegate?.omnipodPeripheralDidDisconnect(peripheral: peripheral, error: error)

        // The system is auto-reconnecting this link itself (EnableAutoReconnect experiment): defer to
        // it — no app-side reconnect, no probe re-arm; didConnect fires when it re-establishes. The
        // eager watchdog (if active) stays armed as a bounded supervisor: its cancel would also cancel
        // the system's auto-reconnect before re-issuing a supervised connect.
        if isReconnecting {
            autoReconnectPendingSince[peripheral.identifier.uuidString] = Date()
            delayedProbeInFlight = false
            return
        }

        // The eager watchdog owns this connect's cancel/retry cycle — its own cancelPeripheralConnection
        // produced THIS callback. Do not independently reconnect (that would race the watchdog's retry,
        // reviving the old cancel↔"reconnecting after drop" loop); the watchdog re-issues after teardown.
        if isConnectWatchdogActive(peripheral) {
            log.default("[eager] didDisconnect under active watchdog for %{public}@ — deferring reconnect to watchdog", peripheral.identifier.uuidString)
            delayedProbeInFlight = false
            return
        }

        if autoConnectIDs.contains(peripheral.identifier.uuidString) {
            log.debug("Reconnecting disconnected autoconnect peripheral")
            autoReconnect(peripheral)
        }
        delayedProbeInFlight = false

        // Eager-gated pods: the recovery strategy differs by app state.
        //  - FOREGROUND: the user may be waiting to bolus — reconnect eagerly (direct connect + fast
        //    watchdog cancel/retry), no auto-reconnect.
        //  - BACKGROUND: we may be suspended at any moment, so no app-side timer can be trusted. Issue a
        //    standing connect carrying CBConnectPeripheralOptionEnableAutoReconnect and let the system
        //    re-establish the link (measured ~27s median) with no app CPU required. This is what keeps
        //    the pod connected through its ~180s inactivity hangups while backgrounded.
        if shouldUseEagerConnect(for: peripheral) {
            if isAppForeground {
                log.default("[eager] drop while foreground — reconnecting eagerly")
                connectionDelegate?.omnipodLogDeviceEvent("[eager] drop while foreground — reconnecting eagerly")
                noteForegroundConnectWait(peripheral)
                beginCommandConnect(peripheral)
            } else if isEagerHeartbeatMode {
                // Disconnect-driven heartbeat: CoreBluetooth just woke us for this drop (State
                // Restoration delivers it even to a suspended app). Fire the heartbeat, then eagerly
                // reconnect — the fresh connection re-arms the pod's ~180s inactivity timer, so the
                // next hangup becomes the next wake, giving a self-sustaining ~3min cadence.
                fireEagerHeartbeatIfNeeded()
                log.default("[eager] drop while background (heartbeat mode) — eager reconnect")
                connectionDelegate?.omnipodLogDeviceEvent("[eager] drop while background (heartbeat mode) — eager reconnect")
                eagerConnect(peripheral, deadline: Date().addingTimeInterval(BluetoothManager.eagerConnectBudgetSeconds))
            } else {
                let target = manager.retrievePeripherals(withIdentifiers: [peripheral.identifier]).first ?? peripheral
                if let device = devices.first(where: { $0.manager.peripheral.identifier == peripheral.identifier }) {
                    device.manager.peripheral = target
                }
                log.default("[eager] drop while background — standing connect with auto-reconnect")
                connectionDelegate?.omnipodLogDeviceEvent("[eager] drop while background — standing connect (auto-reconnect)")
                manager.connect(target, options: eagerConnectOptions)
            }
            return
        }

        if shouldHoldConnection && commandConnectInFlight {
            // Keep-alive (foreground, or a background Pod Keep Alive mode): an unintended drop while we want
            // to stay connected (a deliberate background/idle disconnect clears commandConnectInFlight first,
            // so it won't reconnect).
            log.default("[connectOnDemand] keep-alive — reconnecting after drop")
            connectionDelegate?.omnipodLogDeviceEvent("[connectOnDemand] keep-alive — reconnecting after drop")
            connectViaFreshDiscovery(peripheral)
        } else {
            // Idle: run the fault-listener alarm scan, AND (if a heartbeat is needed) arm the StartDelay
            // probe alongside it. The two coexist — the scan is light and issueDelayedConnectProbe no
            // longer stops it. Re-arm the probe only when idle (never while a command owns the link).
            resumeScanIfNeeded()
            if delayedConnectProbeActive && !commandConnectInFlight && autoConnectIDs.contains(peripheral.identifier.uuidString) {
                issueDelayedConnectProbe(peripheral)
            }
        }
        // If this disconnect ended a heartbeat-probe wake, fire the heartbeat now (clean idle state) so
        // Loop runs its cycle; its commands then preempt the just-armed probe via connect-on-demand.
        if pendingHeartbeatFire {
            pendingHeartbeatFire = false
            log.default("[delayedConnect] firing heartbeat (pumpManagerBLEHeartbeatDidFire)")
            connectionDelegate?.omnipodLogDeviceEvent("[delayedConnect] firing heartbeat (pumpManagerBLEHeartbeatDidFire)")
            connectionDelegate?.omnipodHeartbeatDidFire()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.error("[#%{public}@] FAILED TO CONNECT: %{public}@ error=%{public}@", instanceID, peripheral, String(describing: error))

        connectionDelegate?.omnipodPeripheralDidFailToConnect(peripheral: peripheral, error: error)

        // Under active watchdog: defer reconnection to it (don't start the idle scan / probe here, which
        // would starve the watchdog's next connect attempt).
        if isConnectWatchdogActive(peripheral) {
            log.default("[eager] didFailToConnect under active watchdog for %{public}@ — deferring to watchdog", peripheral.identifier.uuidString)
            delayedProbeInFlight = false
            return
        }

        if autoConnectIDs.contains(peripheral.identifier.uuidString) {
            autoReconnect(peripheral)
        }
        delayedProbeInFlight = false
        resumeScanIfNeeded()   // keep the fault-listener alarm scan running while idle
        if delayedConnectProbeActive && !commandConnectInFlight && autoConnectIDs.contains(peripheral.identifier.uuidString) {
            // Re-arm AFTER a backoff — a synchronously-failing connect (bad parameters, radio off, pod
            // gone) must never re-issue at CPU speed. Re-fetch and re-check state after the delay.
            let id = peripheral.identifier.uuidString
            managerQueue.asyncAfter(deadline: .now() + BluetoothManager.heartbeatFailureBackoffSeconds) { [weak self] in
                guard let self = self,
                      self.delayedConnectProbeActive, !self.commandConnectInFlight, !self.delayedProbeInFlight,
                      self.autoConnectIDs.contains(id),
                      let p = self.devices.first(where: { $0.manager.peripheral.identifier.uuidString == id })?.manager.peripheral,
                      p.state == .disconnected else { return }
                self.issueDelayedConnectProbe(p)
            }
        }
    }
}
