//
//  PodDetailsView.swift
//  OmnipodKit
//
//  From OmniBLE/PumpManageUI/Views/PodDetailsView.swift
//  Created by Pete Schwamb on 4/14/20.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKitUI


struct PodDetails {
    var podType: PodType
    var address: UInt32
    var lotNumber: UInt32
    var sequenceNumber: UInt32
    var firmwareVersion: String
    var bleFirmwareVersion: String
    var deviceName: String?
    var totalDelivery: Double?
    var lastStatus: Date?
    var fault: DetailedStatus?
    var activatedAt: Date?
    var deliveryStoppedAt: Date?
    var podTime: TimeInterval
}

struct PodDetailsView: View {
    @Environment(\.guidanceColors) var guidanceColors
    
    var podDetails: PodDetails
    var title: String
    
    let statusAgeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()

        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = .short

        return formatter
    }()

    let activeTimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()

        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .full

        return formatter
    }()

    let dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.timeStyle = .short
        dateFormatter.dateStyle = .medium
        dateFormatter.doesRelativeDateFormatting = true
        return dateFormatter
    }()

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }

    var totalDeliveryText: String {
        if let delivery = podDetails.totalDelivery {
            return String(format: LocalizedString("%@ U", comment: "Format string for total delivery on pod details screen"), delivery.twoDecimals)
        } else {
            return LocalizedString("NA", comment: "String shown on pod details for total delivery when not available.")
        }
    }

    /// Returns the string for the number of hours pod was active
    var podHoursText: String {
        let podTime: TimeInterval

        // If pod faulted, use the faultTime instead of podTime
        if let fault = podDetails.fault, let faultTime = fault.faultEventTimeSinceActivation {
            podTime = faultTime
        } else {
            podTime = podDetails.podTime
        }
        return String(format: "%.02f", podTime.hours)
    }

    var lastStatusText: String {
        if let lastStatus = podDetails.lastStatus, let ageString = statusAgeFormatter.string(from: Date().timeIntervalSince(lastStatus)) {
            return String(format: LocalizedString("%@ ago", comment: "Format string for last status date on pod details screen"), ageString)
        } else {
            return LocalizedString("NA", comment: "String shown on pod details for last status date when not available.")
        }
    }

    var body: some View {
        List {
            row(LocalizedString("Pod Type", comment: "description label for pod type pod details row"), value: String(describing: podDetails.podType.description))
            if let deviceName = podDetails.deviceName {
                row(LocalizedString("Device Name", comment: "description label for device name pod details row"), value: deviceName)
            }
            row(LocalizedString("Address", comment: "description label for address pod details row"), value: String(format: "0x%08llX", podDetails.address))
            if podDetails.podType.isEros {
                row(LocalizedString("Lot", comment: "description label for lot pod details row"),
                    value: String(format: "L%05llu", podDetails.lotNumber))
            } else {
                row(LocalizedString("Lot", comment: "description label for lot pod details row"),
                    value: lotDecode(lot: podDetails.lotNumber).readableText)
                row(LocalizedString("Lot Number", comment: "description label for lot number pod details row"),
                    value: String(describing: podDetails.lotNumber))
            }
            row(LocalizedString("Sequence Number", comment: "description label for sequence number pod details row"), value: String(format: "%07llu", podDetails.sequenceNumber))
            row(LocalizedString("Firmware Version", comment: "description label for firmware version pod details row"), value: podDetails.firmwareVersion)
            row(LocalizedString("BLE Firmware Version", comment: "description label for ble firmware version pod details row"), value: podDetails.bleFirmwareVersion)
            row(LocalizedString("Total Delivery", comment: "description label for total delivery pod details row"), value: totalDeliveryText)
            row(LocalizedString("Pod Hours", comment: "description label for pod hours pod details row"), value: podHoursText)
            if let activatedAt = podDetails.activatedAt {
                row(LocalizedString("Activation", comment: "description label for activation pod details row"), value: dateFormatter.string(from: activatedAt))
            }
            if let deliveryStoppedAt = podDetails.deliveryStoppedAt {
                if podDetails.fault != nil {
                    row(LocalizedString("Faulted", comment: "description label for faulted pod details row"), value: dateFormatter.string(from: deliveryStoppedAt))
                } else {
                    row(LocalizedString("Deactivation", comment: "description label for deactivation pod details row"), value: dateFormatter.string(from: deliveryStoppedAt))
                }
            } else {
                row(LocalizedString("Last Status", comment: "description label for last status date pod details row"), value: lastStatusText)
            }
            if let fault = podDetails.fault, let pdmRef = fault.pdmRef {
                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(guidanceColors.critical)
                            Text(LocalizedString("Pod Fault Details", comment: "description label for pod fault details"))
                                .fontWeight(.semibold)
                        }.padding(.vertical, 4)
                        let faultCode = fault.faultEventCode
                        Text(String(format: LocalizedString("Internal Pod fault code %1$03lld\n%2$@\nRef: %3$@\n", comment: "The format string for the pod fault info: (1: fault code) (2: fault description) (3: pdm ref string)"), faultCode.rawValue, faultCode.faultDescription, pdmRef))
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.automatic)
    }
}

struct PodDetailsView_Previews: PreviewProvider {
    static var previews: some View {
        PodDetailsView(podDetails: PodDetails(podType: dashType, address: 0x17012345, lotNumber: 123456789, sequenceNumber: 1234567, firmwareVersion: "4.3.2", bleFirmwareVersion: "1.2.3", deviceName: "DashPreviewPod", totalDelivery: 99, lastStatus: Date(), fault: nil, activatedAt: Date().addingTimeInterval(.days(2)), deliveryStoppedAt: nil, podTime: .days(2)), title: "Pod Details")
    }
}
