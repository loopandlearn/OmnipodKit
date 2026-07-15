//
//  PodSessionLogView.swift
//  OmnipodKit
//
//  Created for the pod session log feature.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKitUI

struct PodSessionLogView: View {
    @ObservedObject var viewModel: OmniSettingsViewModel

    var body: some View {
        PodSessionLogListContent(
            details: viewModel.podSessionLogDetails,
            retention: $viewModel.podSessionLogRetention,
            onDelete: viewModel.deletePodSessionLogEntries,
            onClearAll: viewModel.clearPodSessionLog
        )
    }
}


/// Pure-data content view, split out so it can be previewed without a live OmniPumpManager.
struct PodSessionLogListContent: View {
    var details: [PodDetails]
    @Binding var retention: PodSessionLogRetention
    var onDelete: (IndexSet) -> Void = { _ in }
    var onClearAll: () -> Void = {}

    @Environment(\.guidanceColors) var guidanceColors

    @State private var showingClearConfirmation = false

    let dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.timeStyle = .short
        dateFormatter.dateStyle = .medium
        dateFormatter.doesRelativeDateFormatting = true
        return dateFormatter
    }()

    private func rowDate(for details: PodDetails) -> String {
        let date = details.deliveryStoppedAt ?? details.activatedAt
        guard let date = date else {
            return LocalizedString("Unknown Date", comment: "Pod session log row date when no date is available")
        }
        return dateFormatter.string(from: date)
    }

    private func rowSummary(for details: PodDetails) -> String {
        if let fault = details.fault {
            let faultCode = fault.faultEventCode
            if let pdmRef = fault.pdmRef {
                return String(format: LocalizedString("Fault %1$@ · Ref %2$@", comment: "Format string for pod session log row summary with a ref string: (1: fault code) (2: pdm ref string)"), String(format: "%03u", faultCode.rawValue), pdmRef)
            } else {
                return String(format: LocalizedString("Fault %1$@ · %2$@", comment: "Format string for pod session log row summary: (1: fault code) (2: fault description)"), String(format: "%03u", faultCode.rawValue), faultCode.faultDescription)
            }
        } else {
            return LocalizedString("No fault", comment: "Pod session log row summary when the pod had no fault")
        }
    }

    private func row(for details: PodDetails) -> some View {
        NavigationLink(destination: PodDetailsView(podDetails: details, title: rowDate(for: details))) {
            HStack {
                if details.fault != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(guidanceColors.critical)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(rowDate(for: details))
                        .foregroundColor(.primary)
                    Text(rowSummary(for: details))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    var body: some View {
        List {
            Section(header: Text(LocalizedString("Log Settings", comment: "Section header for pod session log settings"))) {
                Picker(LocalizedString("Keep Log For", comment: "Label for pod session log retention picker"), selection: $retention) {
                    ForEach(PodSessionLogRetention.allCases, id: \.self) { retention in
                        Text(retention.title).tag(retention)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                if $retention.wrappedValue == .forever {
                        Button(role: .destructive, action: {
                        showingClearConfirmation = true
                    }) {
                        Text(LocalizedString("Clear Pod Session Log", comment: "Button title to clear the entire pod session log"))
                    }
                    .disabled(details.isEmpty)
                    // Attach the dialog here so it anchors to the button on iPad
                    .confirmationDialog(
                        LocalizedString("Clear Pod Session Log?", comment: "Title for clear pod session log action sheet"),
                        isPresented: $showingClearConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(role: .destructive) {
                            onClearAll()
                        } label: {
                            Text(LocalizedString("Clear Log", comment: "Button title to confirm clearing the pod session log"))
                        }
                        
                        Button(role: .cancel) {
                            // Cancel action (handled automatically, but defined here)
                        } label: {
                            Text(LocalizedString("Cancel", comment: "Cancel button label"))
                        }
                    } message: {
                        Text(LocalizedString("This will permanently delete all recorded pod sessions. This cannot be undone.", comment: "Message for clear pod session log action sheet"))
                    }
                }
            }

            Section(
                header: Text(LocalizedString("Pod Sessions", comment: "Section header for pod session log entries")),
                footer: Text(LocalizedString("Each completed pod is recorded here with its fault code and ref string, if any, so you can report it to your supplier without needing a screenshot.", comment: "Footer explanation for the pod session log"))
            ) {
                if details.isEmpty {
                    Text(LocalizedString("No pod sessions recorded yet.", comment: "Text shown when the pod session log is empty"))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(details.enumerated()), id: \.offset) { _, details in
                        row(for: details)
                    }
                    .onDelete(perform: onDelete)
                }
            }
        }
        .navigationTitle(LocalizedString("Pod Session Log", comment: "Navigation title for the pod session log screen"))
        .navigationBarTitleDisplayMode(.automatic)
    }
}

#if DEBUG
struct PodSessionLogListContent_Previews: PreviewProvider {

    /// Builds a real, decodable DetailedStatus fault by hand-constructing the
    /// 22-byte encoded payload its `init(encodedData:)` expects.
    /// (DetailedStatus has no memberwise initializer — it only parses raw pod bytes.)
    static func mockFault(faultCode: UInt8) -> DetailedStatus {
        var bytes = [UInt8](repeating: 0, count: 22)
        bytes[1] = PodProgressStatus.faultEventOccurred.rawValue // podProgressStatus
        bytes[2] = 0                                             // deliveryStatus (overridden to suspended since faulted)
        bytes[3] = 0; bytes[4] = 0                                // bolusNotDelivered
        bytes[5] = 1                                              // lastProgrammingMessageSeqNum
        bytes[6] = 0; bytes[7] = 50                               // totalInsulinDelivered
        bytes[8] = faultCode                                      // faultEventCode
        bytes[9] = 0; bytes[10] = 120                             // faultEventTimeSinceActivation (minutes)
        bytes[11] = 0; bytes[12] = 100                            // reservoirLevel
        bytes[13] = 0; bytes[14] = 200                            // timeActive (minutes)
        bytes[15] = 0                                             // unacknowledgedAlerts
        bytes[16] = 0                                             // faultAccessingTables
        bytes[17] = 0x02                                          // errorEventInfo (non-zero so previousPodProgressStatus is valid)
        bytes[18] = 0                                             // WW: 0 selects Dash-style pdmRef
        bytes[19] = 0
        bytes[20] = 0x12; bytes[21] = 0x34                        // possibleFaultCallingAddress

        return try! DetailedStatus(encodedData: Data(bytes))
    }

    static var mockDetails: [PodDetails] {
        let calendar = Calendar.current
        let now = Date()

        func daysAgo(_ days: Double) -> Date {
            calendar.date(byAdding: .minute, value: -Int(days * 24 * 60), to: now)!
        }

        /// - Parameters:
        ///   - startedDaysAgo: when the pod was activated
        ///   - durationHours: how long it ran before deliveryStoppedAt (short = manually removed early, ~72h = ran full life)
        func detail(startedDaysAgo: Double, durationHours: Double, fault: DetailedStatus?, totalDelivery: Double) -> PodDetails {
            let activatedAt = daysAgo(startedDaysAgo)
            let stoppedAt = calendar.date(byAdding: .minute, value: Int(durationHours * 60), to: activatedAt)!
            return PodDetails(
                podType: PodType(rawValue: 4),
                address: 0x17012345,
                lotNumber: 123456789,
                sequenceNumber: 1234567,
                firmwareVersion: "4.3.2",
                bleFirmwareVersion: "1.2.3",
                deviceName: "DashPreviewPod",
                totalDelivery: totalDelivery,
                lastStatus: stoppedAt,
                fault: fault,
                activatedAt: activatedAt,
                deliveryStoppedAt: stoppedAt,
                podTime: .hours(durationHours)
            )
        }

        return [
            // Normal full-life completions
            detail(startedDaysAgo: 1, durationHours: 72, fault: nil, totalDelivery: 61.4),
            detail(startedDaysAgo: 4, durationHours: 71.5, fault: nil, totalDelivery: 58.2),

            // Manually ended early (no fault, short duration -> user pulled it early)
            detail(startedDaysAgo: 2, durationHours: 4.2, fault: nil, totalDelivery: 3.1),
            detail(startedDaysAgo: 9, durationHours: 0.5, fault: nil, totalDelivery: 0.2), // removed almost immediately

            // Occlusion fault
            detail(startedDaysAgo: 3, durationHours: 18, fault: mockFault(faultCode: 0x14), totalDelivery: 14.6),

            // Reservoir empty fault
            detail(startedDaysAgo: 5, durationHours: 68, fault: mockFault(faultCode: 0x18), totalDelivery: 49.9),

            // Insulin delivery command error
            detail(startedDaysAgo: 6, durationHours: 30, fault: mockFault(faultCode: 0x31), totalDelivery: 22.3),

            // Illegal reset fault
            detail(startedDaysAgo: 7, durationHours: 2, fault: mockFault(faultCode: 0x34), totalDelivery: 0.8),

            // Exceeded max pod life (80hr) fault
            detail(startedDaysAgo: 8, durationHours: 80, fault: mockFault(faultCode: 0x1C), totalDelivery: 65.0),

            // Encoder count too high fault
            detail(startedDaysAgo: 11, durationHours: 40, fault: mockFault(faultCode: 0x40), totalDelivery: 31.7),
        ]
    }

    struct PreviewWrapper: View {
        @State var retention: PodSessionLogRetention = .days365

        var body: some View {
            NavigationView {
                PodSessionLogListContent(
                    details: PodSessionLogListContent_Previews.mockDetails,
                    retention: $retention
                )
            }
        }
    }

    static var previews: some View {
        PreviewWrapper()
    }
}
#endif
