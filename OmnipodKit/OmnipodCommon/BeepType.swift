//
//  BeepType.swift
//  OmnipodKit
//
//  From OmniBLE/OmnipodCommon/BeepType.swift
//  Created by Joseph Moran on 5/12/19.
//  Copyright © 2019 Pete Schwamb. All rights reserved.
//

import Foundation

//
// BeepType is used for the 0x19 Configure Alerts, 0x1E Set Beep Options and 0x1F Cancel Delivery commands.
// Some beep types values behave differently based on the command & circumstances due to Omnipod internals.
//
// Beep types 0x0, 0x9 & 0xA (as well as 0xE when the pod isn't suspended) will have no beeps or errors
// (when used in 0x19 Configure Alerts with an 'a' bit of 0 or 0x1F Cancel) and will return 0x6 Error
// response, code 7 (when used in 0x19 Configure Alerts with an 'a' bit of 1 or in 0x1E Beep Configure).
//
// For non "black dot" O5 pods, beep type 0xF will have no beeps or errors (when used in 0x19
// Configure Alerts or 0x1E Beep Configure), but will cause a 0x37 pod fault when used in 0x1F Cancel!
// For "black dot" O5 pods, beep type 0xF will emit a bipBip, thus crippling Silence Pod mode. :(
enum BeepType: UInt8 {
    case noBeepCancel = 0x0 // silent for 0x1F Cancel & inactive 0x19 alerts; error for 0x1E Beep Options & active 0x19 alerts
    case beepBeepBeepBeep = 0x1
    case bipBeepBipBeepBipBeepBipBeep = 0x2
    case bipBip = 0x3
    case beep = 0x4
    case beepBeepBeep = 0x5
    case beeeeeep = 0x6
    case bipBipBipbipBipBip = 0x7
    case beeepBeeep = 0x8
    case unusedBeepType0x9 = 0x9 // silent for 0x1F Cancel & inactive 0x19 alerts; error for 0x1E Beep Options & active 0x19 alerts
    case unusedBeepType0xA = 0xA // silent for 0x1F Cancel & inactive 0x19 alerts; error for 0x1E Beep Options & active 0x19 alerts
    case beepBeep = 0xB
    case beeep = 0xC
    case bipBeeeeep = 0xD
    // If pod is currently suspended, 5 second beep for the 0x19, 0x1E & 0x1F commands
    // If pod is not suspended, silent for 0x1F Cancel & inactive 0x19 alerts; error for 0x1E Beep Options & active 0x19 alerts
    case fiveSecondBeep = 0xE

    /// For all Eros, DASH and pre "black dot" O5 pods, will be silent for 0x1E Beep Options & 0x19
    /// Configure Alerts, but will cause an 0x37 pod fault when used with an 0x1F Cancel command!
    /// For the newer "black dot" O5 pods, emits a bipBip for all commands, thus crippling Silence Pod mode. :(
    case noBeepNonCancel = 0xF
}
