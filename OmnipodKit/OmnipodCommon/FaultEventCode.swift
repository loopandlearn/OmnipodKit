//
//  FaultEventCode.swift
//  OmnipodKit
//
//  Based on OmniBLE/OmnipodCommon/FaultEventCode.swift
//  Created by Pete Schwamb on 9/28/18.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import Foundation


struct FaultEventCode: CustomStringConvertible, Equatable {
    let rawValue: UInt8

    enum FaultEventType: UInt8 {
        case noFaults                             = 0x00
        case failedFlashErase                     = 0x01
        case failedFlashStore                     = 0x02
        case tableCorruptionBasalSubcommand       = 0x03
        case basalPulseTableCorruption            = 0x04
        case basalStepCorrupt                     = 0x05
        case autoWakeupTimeout                    = 0x06
        case wireOverDriven                       = 0x07
        case invalidBeepRepeatIndex               = 0x08
        case invalidBeepRepeatPattern             = 0x09
        case tempBasalStep                        = 0x0A
        case tableCorruptionTempBasalSubcommand   = 0x0B
        case bolusOverFlow                        = 0x0C
        case resetDueToCOP                        = 0x0D
        case resetDueToIllegalOpcode              = 0x0E
        case resetDueToIllegalAddress             = 0x0F
        case resetDueToSAWCOP                     = 0x10
        case bolusStep                            = 0x11
        case resetDueToLVD                        = 0x12
        case messageLengthTooLong                 = 0x13
        case occluded                             = 0x14
        case bolusProgChksum                      = 0x15
        case bolusLog                             = 0x16
        case corruptionInAValidatedTable          = 0x17
        case reservoirEmpty                       = 0x18
        case loadErr                              = 0x19
        case psaFailure                           = 0x1A
        case tickCntNotCleared                    = 0x1B
        case exceededMaximumPodLife80Hrs          = 0x1C
        case comdBitNotSet                        = 0x1D
        case invalidComdSet                       = 0x1E
        case wrongSummaryForTable129              = 0x1F
        case validateCountErrorWhenBolusing       = 0x20
        case badTimerVariableState                = 0x21
        case unexpectedRTCModuleValueDuringReset  = 0x22
        case problemCalibrateTimer                = 0x23
        case tickcntErrorRTC                      = 0x24
        case tickFailure                          = 0x25
        case rtcInterruptHandlerUnexpectedCall    = 0x26
        case missing2hourAlertToFillTank          = 0x27
        case invalidPassCode                      = 0x28
        case autoOff0                             = 0x29
        case autoOff1                             = 0x2A
        case autoOff2                             = 0x2B
        case autoOff3                             = 0x2C
        case autoOff4                             = 0x2D
        case autoOff5                             = 0x2E
        case autoOff6                             = 0x2F
        case autoOff7                             = 0x30
        case insulinDeliveryCommandError          = 0x31
        case copTestFailure                       = 0x32
        case connectedPodCommandTimeout           = 0x33
        case illegalReset                         = 0x34
        case vetoNotSet                           = 0x35
        case errorFlashInitialization             = 0x36
        case invalidBeepPattern                   = 0x37
        case wireStateMachine                     = 0x38
        case vetoTestDefault                      = 0x39
        case invalidAlertIndex                    = 0x3A
        case failedTestSawReset                   = 0x3B
        case testInProgress                       = 0x3C
        case stepSensorShorted                    = 0x3D
        case errorFlashWrite                      = 0x3E

        case encoderCountTooHigh                  = 0x40
        case encoderCountExcessiveVariance        = 0x41
        case encoderCountTooLow                   = 0x42
        case encoderCountProblem                  = 0x43
        case checkVoltageOpenWire1                = 0x44
        case checkVoltageOpenWire2                = 0x45
        case problemWithLoad1and2type46           = 0x46
        case problemWithLoad1and2type47           = 0x47
        case badTimerCalibration                  = 0x48
        case badTickHigh                          = 0x49
        case badTickPeriod                        = 0x4A
        case badTrimValue                         = 0x4B
        case badBusClock                          = 0x4C
        case badCalMode                           = 0x4D
        case sawTrimError                         = 0x4E
        case rfmCrystalError                      = 0x4F
        case timerPulseWidthModulatorOverflow     = 0x50
        case tickcntError                         = 0x51
        case badRfmXtalStart                      = 0x52
        case badRxSensitivity                     = 0x53
        case packetFrameLengthTooLong             = 0x54
        case tickLowPhaseExceeded                 = 0x55
        case tickHighPhaseExceeded                = 0x56
        case occlusionCritVarFail                 = 0x57
        case occlusionParam                       = 0x58
        case occlusionProgFail                    = 0x59
        case occlusionCheckValueTooHigh           = 0x5A
        case loadTableCorruption                  = 0x5B
        case primeOpenCountTooLow                 = 0x5C
        case badValueByte109                      = 0x5D
        case disableFlashSecurityFailed           = 0x5E
        case checkVoltageFailure                  = 0x5F
        case occlusionCheckStartup1               = 0x60
        case occlusionCheckStartup2               = 0x61
        case occlusionCheckTimeouts1              = 0x62
        case occlusionParamInvalid                = 0x63

        case occlusionCheckTimeouts2              = 0x66
        case occlusionCheckTimeouts3              = 0x67
        case occlusionCheckPulseIssue             = 0x68
        case occlusionCheckBolusProblem           = 0x69
        case occlusionCheckAboveThreshold         = 0x6A

        case basalUnderInfusion                   = 0x80
        case basalOverInfusion                    = 0x81
        case tempBasalUnderInfusion               = 0x82
        case tempBasalOverInfusion                = 0x83
        case bolusUnderInfusion                   = 0x84
        case bolusOverInfusion                    = 0x85
        case basalOverInfusionPulse               = 0x86
        case tempBasalOverInfusionPulse           = 0x87
        case bolusOverInfusionPulse               = 0x88
        case immediateBolusOverInfusionPulse      = 0x89
        case extendedBolusOverInfusionPulse       = 0x8A
        case corruptionOfTables                   = 0x8B

        case unrecognizedPulse                    = 0x8D
        case syncWithoutTempActive                = 0x8E
        case interlockLoad                        = 0x8F
        case illegalChanParam                     = 0x90
        case basalPulseChanInactive               = 0x91
        case tempPulseChanInactive                = 0x92
        case bolusPulseChanInactive               = 0x93
        case intSemaphoreNotSet                   = 0x94
        case illegalInterLockChan                 = 0x95
        case terimateBolus                        = 0x96
        case openTransitionsCount                 = 0x97

        /// End of shared fault codes for all pod types
        /// The following fault code are DASH and O5 only

        // O5 only
        case syncWithoutClosedLoop                = 0x98
        case qnStatusMismatch                     = 0x99
        case apLoopMismatch                       = 0x9A

        // Dash and O5
        case bleTimeout                           = 0xA0
        case bleInitiated                         = 0xA1
        case bleUnkAlarm                          = 0xA2

        // O5 only
        case adcLibNotInitialized                 = 0xA3
        case adcLibMemorySize                     = 0xA4
        case adcLibNVMemoryCrc                    = 0xA5

        // Dash and O5
        case bleIaas                              = 0xA6
        case crcFailure                           = 0xA8
        case bleWdPingTimeout                     = 0xA9
        case bleExcessiveResets                   = 0xAA
        case bleNakError                          = 0xAB
        case bleReqHighTimeout                    = 0xAC
        case bleUnknownResp                       = 0xAD
        // 0xAE
        case bleReqStuckHigh                      = 0xAF
        case bleStateMachine1                     = 0xB1
        case bleStateMachine2                     = 0xB2

        case bleArbLost                           = 0xB4

        // O5 only
        case bolusExtendedNotAllowed              = 0xB5
        case agcInOpenLoop                        = 0xB6
        case agcBolusExtendedNotAllowed           = 0xB7
        case agcPulsesExceeded                    = 0xB8
        case agcBolusAlreadyActive                = 0xB9
        case agcBolusTooEarly                     = 0xBA
        case immedBolusMismatch                   = 0xBB
        case agcMealCorrBolusNotZero              = 0xBC
        case tempBasalNotAllowed                  = 0xBD
        case basalNotAllowed                      = 0xBE
        case agcBolusTooLate                      = 0xBF

        // Dash and O5
        case bleDualNack                          = 0xC0
        case bleQnExceedMaxRetry                  = 0xC1
        case bleQnCritVarFail                     = 0xC2
        case bleQnOptIntvlInvalid                 = 0xC3

        // O5 only
        case bleQnCgmUtcMismatch                  = 0xC4
        case bleQnCgmTxidNotAllowed               = 0xC5
        // 0xC6 undefined
        case bleQnAlgNotRun                       = 0xC7
        case bleQnHypoInOpenLoop                  = 0xC8
        case bleQnAlgSetupFail                    = 0xC9
        case bleQnAgcRunTooLate                   = 0xCA

        // Dash and possibly O5
        case unknown0xCB                          = 0xCB
        // 0xCC - 0xD3 undefined and never seen
        case unknown0xD4                          = 0xD4
        case unknown0xD5                          = 0xD5
        case resetFault0xD6                       = 0xD6
        case resetFault0xD7                       = 0xD7
        case unknown0xD8                          = 0xD8
        case unknown0xD9                          = 0xD9

        // O5 only
        case bleAgcPotentialDivZero               = 0xE1
        case bleAgcInvalidInputParam              = 0xE2
        case bleAgcInvalidParam                   = 0xE3
        case bleAgcStateVectorParam               = 0xE4
        case bleAgcInvalidAlgoStateParam          = 0xE5
        case bleAgcInvalidHypoSetting             = 0xE6
        case bleAgcOutputOutOfBounds              = 0xE7
        case bleAgcInvalidFirstRunInInitState     = 0xE8
        case bleAgcInvalidOffset                  = 0xE9

        case valuesDoNotMatch                     = 0xFF
    }

    var faultType: FaultEventType? {
        return FaultEventType(rawValue: rawValue)
    }

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    var faultDescription: String {
        switch faultType {
        case .noFaults:
            return "No fault"
        case .failedFlashErase:
            return "Flash erase failed"
        case .failedFlashStore:
            return "Flash store failed"
        case .tableCorruptionBasalSubcommand:
            return "Basal subcommand table corruption"
        case .basalPulseTableCorruption:
            return "Basal pulse table corruption"
        case .basalStepCorrupt:
            return "Basal step corrupt"
        case .autoWakeupTimeout:
            return "Auto wakeup timeout"
        case .wireOverDriven:
            return "Wire overdriven"
        case .invalidBeepRepeatIndex:
            return "Invalid beep repeat index"
        case .invalidBeepRepeatPattern:
            return "Invalid beep repeat pattern"
        case .tempBasalStep:
            return "Temp Basal Step"
        case .tableCorruptionTempBasalSubcommand:
            return "Temp basal subcommand table corruption"
        case .bolusOverFlow:
            return "Bolus overflow"
        case .resetDueToCOP:
            return "Reset due to COP"
        case .resetDueToIllegalOpcode:
            return "Reset due to illegal opcode"
        case .resetDueToIllegalAddress:
            return "Reset due to illegal address"
        case .resetDueToSAWCOP:
            return "Reset due to SAWCOP"
        case .bolusStep:
            return "Bolus step"
        case .resetDueToLVD:
            return "Reset due to LVD"
        case .messageLengthTooLong:
            return "Message length too long"
        case .occluded:
            return "Occluded"
        case .bolusProgChksum:
            return "Bolus Prog Chksum"
        case .bolusLog:
            return "Bolus log"
        case .corruptionInAValidatedTable:
            return "Corruption in a validated table"
        case .reservoirEmpty:
            return "Reservoir empty or exceeded maximum pulse delivery"
        case .loadErr:
            return "Load error"
        case .psaFailure:
            return "PSA failure"
        case .tickCntNotCleared:
            return "Tick count not cleared"
        case .exceededMaximumPodLife80Hrs:
            return "Exceeded maximum Pod life of 80 hours"
        case .comdBitNotSet:
            return "Comd bit not set"
        case .invalidComdSet:
            return "Invalid comd set"
        case .wrongSummaryForTable129:
            return "Sum mismatch for word_129 table"
        case .validateCountErrorWhenBolusing:
            return "Validate encoder count error when bolusing"
        case .badTimerVariableState:
            return "Bad timer variable state"
        case .unexpectedRTCModuleValueDuringReset:
            return "Unexpected RTC Modulo Register value during reset"
        case .problemCalibrateTimer:
            return "Problem in calibrate_timer_case_3"
        case .tickcntErrorRTC:
            return "Tick count error RTC"
        case .tickFailure:
            return "Tick failure"
        case .rtcInterruptHandlerUnexpectedCall:
            return "RTC interrupt handler unexpectedly called"
        case .missing2hourAlertToFillTank:
            return "Failed to set up 2 hour alert for tank fill operation"
        case .invalidPassCode:
            return "Invalid pass code"
        case .autoOff0:
            return "Alert #0 auto-off timeout"
        case .autoOff1:
            return "Alert #1 auto-off timeout"
        case .autoOff2:
            return "Alert #2 auto-off timeout"
        case .autoOff3:
            return "Alert #3 auto-off timeout"
        case .autoOff4:
            return "Alert #4 auto-off timeout"
        case .autoOff5:
            return "Alert #5 auto-off timeout"
        case .autoOff6:
            return "Alert #6 auto-off timeout"
        case .autoOff7:
            return "Alert #7 auto-off timeout"
        case .insulinDeliveryCommandError:
            return "Incorrect pod state for command or error during insulin command setup"
        case .copTestFailure:
            return "COP test failure"
        case .connectedPodCommandTimeout:
            return "Connected Pod command timeout"
        case .illegalReset:
            return "Illegal reset"
        case .vetoNotSet:
            return "Veto not set"
        case .errorFlashInitialization:
            return "Flash initialization error"
        case .invalidBeepPattern:
            return "Invalid beep pattern"
        case .wireStateMachine:
            return "Wire state machine"
        case .vetoTestDefault:
            return "Veto test default"
        case .invalidAlertIndex:
            return "Invalid alert index"
        case .failedTestSawReset:
            return "SAW reset testing fail"
        case .testInProgress:
            return "test in progress"
        case .stepSensorShorted:
            return "Step sensor shorted"
        case .errorFlashWrite:
            return "Flash initialization or write error"

        case .encoderCountTooHigh:
            return "Encoder count too high"
        case .encoderCountExcessiveVariance:
            return "Encoder count excessive variance"
        case .encoderCountTooLow:
            return "Encoder count too low"
        case .encoderCountProblem:
            return "Encoder count problem"
        case .checkVoltageOpenWire1:
            return "Check voltage open wire 1 problem"
        case .checkVoltageOpenWire2:
            return "Check voltage open wire 2 problem"
        case .problemWithLoad1and2type46:
            return "Problem with LOAD1/LOAD2"
        case .problemWithLoad1and2type47:
            return "Problem with LOAD1/LOAD2"
        case .badTimerCalibration:
            return "Bad timer calibration"
        case .badTickHigh:
            return "Bad timer values: COP timer ratio bad"
        case .badTickPeriod:
            return "Bad tick period"
        case .badTrimValue:
            return "Bad trim value"
        case .badBusClock:
            return "Bad bus clock"
        case .badCalMode:
            return "Bad cal mode"
        case .sawTrimError:
            return "SAW Trim Error"
        case .rfmCrystalError:
            return "RFM Crystal Error"
        case .timerPulseWidthModulatorOverflow:
            return "Timer pulse-width modulator overflow"
        case .tickcntError:
            return "Bad tick count state before starting pump"
        case .badRfmXtalStart:
            return "Bad RFM crystal start"
        case .badRxSensitivity:
            return "Bad Rx sensitivity"
        case .packetFrameLengthTooLong:
            return "Packet frame length too long"
        case .tickLowPhaseExceeded:
            return "Tick low phase exceeded"
        case .tickHighPhaseExceeded:
            return "Tick high phase exceeded"
        case .occlusionCritVarFail:
            return "Occlusion critical variable fail"
        case .occlusionParam:
            return "Occlusion param"
        case .occlusionProgFail:
            return "Occlusion prog fail"
        case .occlusionCheckValueTooHigh:
            return "Occlusion check value too high"
        case .loadTableCorruption:
            return "Load table corruption"
        case .primeOpenCountTooLow:
            return "Prime open count too low"
        case .badValueByte109:
            return "Bad byte_109 value"
        case .disableFlashSecurityFailed:
            return "Write flash byte to disable flash security failed"
        case .checkVoltageFailure:
            return "Two check voltage failures before starting pump"
        case .occlusionCheckStartup1:
            return "Occlusion check startup problem 1"
        case .occlusionCheckStartup2:
            return "Occlusion check startup problem 2"
        case .occlusionCheckTimeouts1:
            return "Occlusion check excess timeouts 1"
        case .occlusionParamInvalid:
            return "Occlusion param invalid"

        case .occlusionCheckTimeouts2:
            return "Occlusion check excess timeouts 2"
        case .occlusionCheckTimeouts3:
            return "Occlusion check excess timeouts 3"
        case .occlusionCheckPulseIssue:
            return "Occlusion check pulse issue"
        case .occlusionCheckBolusProblem:
            return "Occlusion check bolus problem"
        case .occlusionCheckAboveThreshold:
            return "Occlusion check above threshold"

        case .basalUnderInfusion:
            return "Basal under infusion"
        case .basalOverInfusion:
            return "Basal over infusion"
        case .tempBasalUnderInfusion:
            return "Temp basal under infusion"
        case .tempBasalOverInfusion:
            return "Temp basal over infusion"
        case .bolusUnderInfusion:
            return "Bolus under infusion"
        case .bolusOverInfusion:
            return "Bolus over infusion"
        case .basalOverInfusionPulse:
            return "Basal over infusion pulse"
        case .tempBasalOverInfusionPulse:
            return "Temp basal over infusion pulse"
        case .bolusOverInfusionPulse:
            return "Bolus over infusion pulse"
        case .immediateBolusOverInfusionPulse:
            return "Immediate bolus under infusion pulse"
        case .extendedBolusOverInfusionPulse:
            return "Extended bolus over infusion pulse"
        case .corruptionOfTables:
            return "Corruption of tables"

        case .unrecognizedPulse:
            return "Bad pulse value"
        case .syncWithoutTempActive:
            return "Sync with no temp basal active"
        case .interlockLoad:
            return "Interlock load"
        case .illegalChanParam:
            return "illegan channel parameter"
        case .basalPulseChanInactive:
            return "basal pulse channel inactive"
        case .tempPulseChanInactive:
            return "temp basal channel inactive"
        case .bolusPulseChanInactive:
            return "bolus pulse channel inactive"
        case .intSemaphoreNotSet:
            return "Bad table specifier field6 in 1A command"
        case .illegalInterLockChan:
            return "Illegal interlock channel"
        case .terimateBolus:
            return "Terminate bolus"
        case .openTransitionsCount:
            return "Open transitions count"
        case .syncWithoutClosedLoop:
            return "Sync without closed loop"
        case .qnStatusMismatch:
            return "QN status mismatch"
        case .apLoopMismatch:
            return "AP loop mismatch"
        case .bleTimeout:
            return "BLE timeout"
        case .bleInitiated:
            return "BLE initiated"
        case .bleUnkAlarm:
            return "BLE unknown alarm"
        case .adcLibNotInitialized:
            return "ADC library not initialized"
        case .adcLibMemorySize:
            return "ADC library memory size"
        case .adcLibNVMemoryCrc:
            return "ADC library NV memory CRC"
        case .bleIaas:
            return "BLE IAAS"
        case .crcFailure:
            return "CRC failure"
        case .bleWdPingTimeout:
            return "BLE WD ping timeout"
        case .bleExcessiveResets:
            return "BLE excessive resets"
        case .bleNakError:
            return "BLE NAK error"
        case .bleReqHighTimeout:
            return "BLE request high timeout"
        case .bleUnknownResp:
            return "BLE unknown response"

        case .bleReqStuckHigh:
            return "BLE request stuck high"
        case .bleStateMachine1:
            return "BLE state machine 1"
        case .bleStateMachine2:
            return "BLE state machine 2"
        case .bleArbLost:
            return "BLE arbitration lost"
        case .bolusExtendedNotAllowed:
            return "Bolus extended not allowed"
        case .agcInOpenLoop:
            return "AGC in open loop"
        case .agcBolusExtendedNotAllowed:
            return "AGC bolus extended not allowed"
        case .agcPulsesExceeded:
            return "AGC pulses exceeded"
        case .agcBolusAlreadyActive:
            return "AGC bolus already active"
        case .agcBolusTooEarly:
            return "AGC bolus too early"
        case .immedBolusMismatch:
            return "Immediate bolus mismatch"
        case .agcMealCorrBolusNotZero:
            return "AGC meal correction bolus not zero"
        case .tempBasalNotAllowed:
            return "Temporary basal not allowed"
        case .basalNotAllowed:
            return "Basal not allowed"
        case .agcBolusTooLate:
            return "AGC bolus too late"
        case .bleDualNack:
            return "BLE dual Nack"
        case .bleQnExceedMaxRetry:
            return "BLE QN exceed max retry"
        case .bleQnCritVarFail:
            return "BLE QN critical variable fail"
        case .bleQnOptIntvlInvalid:
            return "BLE QN optional interval invalid"
        case .bleQnCgmUtcMismatch:
            return "BLE QN CGM UTC mismatch"
        case .bleQnCgmTxidNotAllowed:
            return "BLE QN CGM TXID not allowed"
        case .bleQnAlgNotRun:
            return "BLE QN algorithm not run"
        case .bleQnHypoInOpenLoop:
            return "BLE QN hypo in open loop"
        case .bleQnAlgSetupFail:
            return "BLE QN algorithm setup fail"
        case .bleQnAgcRunTooLate:
            return "BLE QN AGC run too late"

        case .bleAgcPotentialDivZero:
            return "BLE AGC potential divide by zero"
        case .bleAgcInvalidInputParam:
            return "BLE AGC invalid input parameter"
        case .bleAgcInvalidParam:
            return "BLE AGC invalid parameter"
        case .bleAgcStateVectorParam:
            return "BLE AGC state vector parameter"
        case .bleAgcInvalidAlgoStateParam:
            return "BLE AGC invalid algorithm state parameter"
        case .bleAgcInvalidHypoSetting:
            return "BLE AGC invalid hypo setting"
        case .bleAgcOutputOutOfBounds:
            return "BLE AGC output out of bounds"
        case .bleAgcInvalidFirstRunInInitState:
            return "BLE AGC invalid first run in init state"
        case .bleAgcInvalidOffset:
            return "BLE AGC invalid offset"

        case .resetFault0xD6, .resetFault0xD7:
            return "Reset fault of unknown origin"
        case .unknown0xCB, .unknown0xD4, .unknown0xD5, .unknown0xD8, .unknown0xD9, .none:
            return "Unknown fault"

        case .valuesDoNotMatch:
            return "Unknown fault code"
        }
    }

    var description: String {
        return String(format: "Fault Event Code 0x%02llx: %@", rawValue, faultDescription)
    }

    var localizedDescription: String {
        if let faultType = faultType {
            switch faultType {
            case .noFaults:
                return LocalizedString("No faults", comment: "Description for Fault Event Code .noFaults")
            case .reservoirEmpty:
                return LocalizedString("Empty reservoir", comment: "Description for Empty reservoir pod fault")
            case .exceededMaximumPodLife80Hrs:
                return LocalizedString("Pod expired", comment: "Description for Pod expired pod fault")
            case .occluded:
                return LocalizedString("Occlusion detected", comment: "Description for Occlusion detected pod fault")
            default:
                return String(format: LocalizedString("Internal pod fault %1$03lld", comment: "The format string for Internal pod fault (1: The fault code value)"), rawValue)
            }
        } else {
            return String(format: LocalizedString("Unknown pod fault %1$03lld", comment: "The format string for Unknown pod fault (1: The fault code value)"), rawValue)
        }
    }

    // Convenience alert notification strings
    var notificationTitle: String {
        switch self.faultType {
        case .reservoirEmpty:
            return LocalizedString("Empty Reservoir", comment: "The title for Empty Reservoir alarm notification")
        case .occluded, .occlusionCheckStartup1, .occlusionCheckStartup2, .occlusionCheckTimeouts1, .occlusionCheckTimeouts2, .occlusionCheckTimeouts3, .occlusionCheckPulseIssue, .occlusionCheckBolusProblem:
            return LocalizedString("Occlusion Detected", comment: "The title for Occlusion alarm notification")
        case .exceededMaximumPodLife80Hrs:
            return LocalizedString("Pod Expired", comment: "The title for Pod Expired alarm notification")
        default:
            return String(format: LocalizedString("Critical Pod Fault %1$03lld", comment: "The title for AlarmCode.other notification: (1: fault code value)"), rawValue)
        }
    }

    var notificationBody: String {
        return LocalizedString("Insulin delivery stopped. Change Pod now.", comment: "The default notification body for AlarmCodes")
    }
}
