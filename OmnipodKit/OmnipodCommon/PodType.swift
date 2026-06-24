//
//  PodType.swift
//  OmnipodKit
//
//  Created by Joe Moran on 1/18/25.
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//

import Foundation

struct PodType: CustomStringConvertible, Equatable {
    let rawValue: UInt8

    // Product ID code values returned in the VersionResponse productId byte
    enum PodModelType: UInt8 {

        case productIdUnknown = 0x0 // can be used before actual pod type is known

        // 1 is unsupported, probably the larger form factor first gen Omnipod using 4 batteries

        case productIdEros = 2 // Omnipod Eros AKA "Omnipod Classic (gen 3)"

        // 3 is unsupported & unknown, maybe an early gen DASH or for other medical use

        case productIdDash = 4 // Omnipod DASH, both TWI BOARD (firmware 4.x.y) or NXP BLE (firmware 3.x.y)

        case productIdOmnipod5 = 5 // Omnipod 5, all lot types (PP1, PH1, PR1)

    }

    var podType: PodModelType? {
        return PodModelType(rawValue: rawValue)
    }

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(podType: PodModelType) {
        self.rawValue = podType.rawValue
    }

    var localizedDescription: String {
        switch podType {
        case .productIdEros:
            return LocalizedString("Omnipod Classic Pods (also known as Eros Pods) have a clear needle tab with a 6-character LOT number starting with 'L'. These Pods require the use of a RileyLink to communicate with the iPhone.", comment: "Description for Omnipod Classic pods")
        case .productIdDash:
            return LocalizedString("Omnipod DASH Pods have a blue needle tab with a 12-character LOT number typically starting with 'PD1'.", comment: "Description for Omnipod DASH pods")
        case .productIdOmnipod5:
            return LocalizedString("Omnipod 5 Pods have a clear needle tab with a 12-character LOT number typically starting with 'PH1' or 'PR1'. The Pod's \"SmartAdjust\" technology will not be used for closed loop control.", comment: "Description for Omnipod 5 pods")
        default:
            return LocalizedString("Unknown Omnipod Pod Type", comment: "Description for an unknown Omnipod pod type")
        }
    }

    var description: String {
        switch podType {
        case .productIdUnknown:
            return LocalizedString("Omnipod", comment: "Title string for an unknown Omnipod")
        case .productIdEros:
            return LocalizedString("Omnipod Classic", comment: "Title string for Omnipod Classic")
        case .productIdDash:
            return LocalizedString("Omnipod DASH", comment: "Title string for Omnipod DASH")
        case .productIdOmnipod5:
            return LocalizedString("Omnipod 5", comment: "Title string for Omnipod 5")
        default:
            return "Unknown"
        }
    }

    var briefName: String {
        switch podType {
        case .productIdUnknown:
            return ""
        case .productIdEros:
            return "Eros"
        case .productIdDash:
            return "DASH"
        case .productIdOmnipod5:
            return "O5"
        default:
            return "Unknown"
        }
    }

    var fullName: String {
        if let podType = podType {
            switch podType {
            case .productIdEros, .productIdDash, .productIdOmnipod5:
                return String(format: "Product ID %d %@", rawValue, description)
            default:
                break
            }
        }
        return String(format: "Unknown Omnipod Product ID %d", rawValue)
    }

    // DASH uses a blue tab while both Eros and 05 pods use a clear tab
    var tabColor: String {
        switch podType {
        case .productIdDash:
            return "blue"
        default:
            return "clear"
        }
    }

    // Return the per pod type PodBottom image name
    var podBottomTabImage: String {
        switch podType {
        case .productIdDash:
            return "PodBottomBlueTab"
        default:
            return "PodBottomClearTab"
        }
    }

    // Only Eros pods uses RileyLinks
    var usesRileyLink: Bool {
        switch podType {
        case .productIdEros:
            return true
        default:
            return false
        }
    }

    // Only Eros pods reports the RSSI value in the DetailedStatus
    var reportsRSSI: Bool {
        switch podType {
        case .productIdEros:
            return true
        default:
            return false
        }
    }

    // non-Eros pods using a nearZeroBasalRate for pulse timing for zero basal rates
    var zeroBasalRate: Double {
        let nearZeroBasalRate = 0.01

        switch podType {
        case .productIdEros:
            return 0
        default:
            return nearZeroBasalRate
        }
    }

    // The Eros PDM uses 0x1F for the top byte of the 32 bit Id address.
    // The Dash PDM uses the PDM's SN << 2 for the bottom 5 nibbles and some
    // unknown values for the top 3 nibbles of its fixed 32-bit controller Id.
    // The Omnipod 5 controller uses its SN << 2 for the basis of its fixed 32-bit,
    // but this can't be customized since it must match the certificate's value.
    var topIdByte: UInt8 {
        switch podType {
        case .productIdEros:
            return 0x1F
        case .productIdDash:
            return 0x17
        case .productIdOmnipod5:
            return 0x00 // not actually used; comes from certifcate controllerId
        default:
            return 0x0
        }
    }

    var isEros: Bool {
        return podType == .productIdEros
    }

    var isDash: Bool {
        return podType == .productIdDash
    }

    var isO5: Bool {
        return podType == .productIdOmnipod5
    }
}

/* convenience constants */
let unknownOmnipodType = PodType(podType: .productIdUnknown)
let erosType = PodType(podType: .productIdEros)
let dashType = PodType(podType: .productIdDash)
let omnipod5Type = PodType(podType: .productIdOmnipod5)

