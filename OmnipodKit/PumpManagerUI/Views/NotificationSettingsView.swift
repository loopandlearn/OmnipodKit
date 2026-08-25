//
//  NotificationSettingsView.swift
//  OmnipodKit
//
//  From OmniBLE/PumpManageUI/Views/NotificationSettingsView.swift
//  Created by Pete Schwamb on 2/3/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI
import LoopAlgorithm


struct NotificationSettingsView: View {

    var dateFormatter: DateFormatter

    @Binding var expirationReminderDefault: Int

    @State private var showingHourPicker: Bool = false

    var scheduledReminderDate: Date?

    var allowedScheduledReminderDates: [Date]?

    var lowReservoirReminderDefaultValue: Int

    var lowReservoirReminderValue: Int

    let reservoirLevel: Double

    let hasActivePod: Bool

    var onSaveScheduledExpirationReminder: ((_ selectedDate: Date?, _ completion: @escaping (_ error: Error?) -> Void) -> Void)?

    var onSaveLowReservoir: ((_ selectedValue: Int, _ completion: @escaping (_ error: Error?) -> Void) -> Void)?

    var onSaveLowReservoirDefault: ((_ selectedValue: Int, _ completion: @escaping (_ error: Error?) -> Void) -> Void)?

    var insulinQuantityFormatter = QuantityFormatter(for: .internationalUnit)

    var body: some View {
        RoundedCardScrollView {

            /// Only display options to set the expiration reminder and low reservoir alerts if we have an active pod
            if hasActivePod {

                RoundedCard<EmptyView>(
                    title: LocalizedString("Current Pod Alerts", comment: "Title for Current Pod Alerts section"),
                    footer: LocalizedString("Current Reminders configured for the active Pod.", comment: "Footer text for Current Pod Alerts section")
                )

                if let allowedDates = allowedScheduledReminderDates {
                    RoundedCard(
                        footer: LocalizedString("Expiration reminder time for the current Pod.", comment: "Footer text for scheduled reminder area")
                    ) {
                        scheduledReminderRow(
                            scheduledDate: scheduledReminderDate,
                            allowedDates: allowedDates
                        )
                    }
                }

                RoundedCard(
                    footer: LocalizedString("Low reservoir alert value for the current Pod.", comment: "Footer text for Low Reservoir value row"
                    )
                ) {
                    /// If reservoirLevel 1.05 to 2.0 -> maxValue 1.0
                    let maxValue = floor(reservoirLevel - (Pod.pulseSize/10))
                    lowReservoirRow(
                        currentValue: lowReservoirReminderValue,
                        maxValue: maxValue
                    )
                }

                Spacer()
            }

            RoundedCard<EmptyView>(
                title: LocalizedString("Default Alerts", comment: "Title for Default Alerts section"),
                footer: LocalizedString("These default alerts will be configured when pairing a new Pod.", comment: "Footer text for the Notifications Settings Default Pod Alerts section"
                )
            )

            RoundedCard(
                footer: LocalizedString("The default number of hours advance notice to configure when pairing a new Pod.", comment: "Footer text for the Expiration Reminder Default row")
            ) {
                ExpirationReminderPickerView(
                    expirationReminderDefault: $expirationReminderDefault
                )
            }

            RoundedCard(
                footer: LocalizedString("The default number of units to configure for the low reservoir alert level when pairing a new Pod.", comment: "Footer text for Low Reservoir Default row")
            ) {
                lowReservoirDefaultRow
            }

            Spacer()

            RoundedCard<EmptyView>(
                title: LocalizedString("Critical Alerts", comment: "Title for critical alerts description"),
                footer: LocalizedString("These alerts will not sound on your device when it is in Silent or Do Not Disturb mode. There are other critical Pod alerts that will sound on your device even when set to Silent or Do Not Disturb mode.\n\nThe Pod will also use audible beeps for all Pod alerts except when the Pod is Silenced.",
                comment: "Description text for Critical Alerts section")
            )
        }
        .navigationTitle(
            LocalizedString("Notification Settings", comment: "navigation title for notification settings")
        )
    }

    @State private var scheduledReminderDateEditViewIsShown: Bool = false

    private func scheduledReminderRow(
        scheduledDate: Date?,
        allowedDates: [Date]
    ) -> some View {
        Group {
            /// Make the expiration reminder time read-only for the current pod if there aren't any more available times.
            if allowedDates.isEmpty {
                scheduledReminderRowContents(disclosure: false)
            } else {
                NavigationLink(
                    destination: ScheduledExpirationReminderEditView(
                        scheduledExpirationReminderDate: scheduledDate,
                        allowedDates: allowedDates,
                        dateFormatter: dateFormatter,
                        onSave: onSaveScheduledExpirationReminder,
                        onFinish: {
                            scheduledReminderDateEditViewIsShown = false
                        }
                    ),
                    isActive: $scheduledReminderDateEditViewIsShown
                ) {
                    scheduledReminderRowContents(disclosure: true)
                }
            }
        }
    }

    private func scheduledReminderRowContents(disclosure: Bool) -> some View {
        RoundedCardValueRow(
            label: LocalizedString("Expiration Reminder", comment: "Label for Expiration Reminder value row"),
            value: scheduledReminderDateString(scheduledReminderDate),
            highlightValue: false,
            disclosure: disclosure
        )
    }

    private func scheduledReminderDateString(_ scheduledDate: Date?) -> String {
        if let scheduledDate = scheduledDate {
            return dateFormatter.string(from: scheduledDate)
        } else {
            return LocalizedString("No Reminder", comment: "Value text for no expiration reminder")
        }
    }

    @State private var lowReservoirDefaultIsShown: Bool = false

    var lowReservoirDefaultRow: some View {
        NavigationLink(
            destination: LowReservoirView(
                reservoirLevel: reservoirLevel,
                setDefault: true,
                initialValue: lowReservoirReminderDefaultValue,
                onSave: onSaveLowReservoirDefault,
                onFinish: { lowReservoirDefaultIsShown = false }
            ),
            isActive: $lowReservoirDefaultIsShown)
        {
            RoundedCardValueRow(
                label: LocalizedString("Low Reservoir Default", comment: "Label for Low Reservoir Default value row"),
                value: formatLowReservoirAlertValue(lowReservoirReminderDefaultValue),
                highlightValue: false,
                disclosure: true
            )
        }
    }

    @State private var lowReservoirRowIsShown: Bool = false

    private func lowReservoirRow(
        currentValue: Int,
        maxValue: Double
    ) -> some View {
        NavigationLink(
            destination: LowReservoirView(
                reservoirLevel: reservoirLevel,
                setDefault: false,
                initialValue: lowReservoirReminderValue,
                onSave: onSaveLowReservoir,
                onFinish: { lowReservoirRowIsShown = false }
            ),
            isActive: $lowReservoirRowIsShown
        ) {
            RoundedCardValueRow(
                label: LocalizedString("Low Reservoir", comment: "Label for Low Reservoir alert value row"),
                value: formatLowReservoirAlertValue(lowReservoirReminderValue),
                highlightValue: false,
                disclosure: true
            )
        }
    }
}

// Display a 0 low reservoir alert value as "No Alert"
func formatLowReservoirAlertValue(_ value: Int) -> String {
    if value == 0 {
        return LocalizedString("No Alert", comment: "No Alert low reservoir value")
    }
    return String(value)
}

struct NotificationSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        return Group {
            let now = Date()
            NavigationView {
                NotificationSettingsView(
                    dateFormatter: DateFormatter(),
                    expirationReminderDefault: .constant(1),
                    scheduledReminderDate: now + TimeInterval(hours: 1),
                    allowedScheduledReminderDates: [
                        now, now - TimeInterval(hours: 2),
                        now - TimeInterval(hours: 3),
                    ],
                    lowReservoirReminderDefaultValue: Int(Pod.defaultLowReservoirReminder),
                    lowReservoirReminderValue: 5,
                    reservoirLevel: Pod.maximumReservoirReading,
                    hasActivePod: true,
                )
                .previewDevice(
                    PreviewDevice(rawValue: "iPod touch (7th generation)")
                )
                .previewDisplayName("iPod touch (7th generation)")
            }

            NavigationView {
                NotificationSettingsView(
                    dateFormatter: DateFormatter(),
                    expirationReminderDefault: .constant(2),
                    scheduledReminderDate: now + TimeInterval(hours: 1),
                    allowedScheduledReminderDates: [
                        now, now - TimeInterval(hours: 2),
                        now - TimeInterval(hours: 3),
                    ],
                    lowReservoirReminderDefaultValue: Int(Pod.defaultLowReservoirReminder),
                    lowReservoirReminderValue: Int(Pod.defaultLowReservoirReminder),
                    reservoirLevel: Pod.maximumReservoirReading,
                    hasActivePod: false,
                )
                .colorScheme(.dark)
                .previewDevice(PreviewDevice(rawValue: "iPhone XS Max"))
                .previewDisplayName("iPhone XS Max - Dark")
            }
        }
    }
}
