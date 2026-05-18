//
//  SilencePodSelectionView.swift
//  OmnipodKit
//
//  From OmniBLE/PumpManageUI/Views/SilencePodSelectionView.swift
//  Created by Joe Moran 8/30/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI

private let minimumSilenceModeTime: TimeInterval = .seconds(30)

struct SilencePodSelectionView: View {

    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>

    private var initialValue: SilencePodPreference
    @State private var preference: SilencePodPreference

    private var initialEndTimeValue: Date?
    @State private var endTimeValue: Date?

    private var onSave: ((_ selectedValue: SilencePodPreference, _ selectedSilenceEnd: Date?, _ completion: @escaping (_ error: LocalizedError?) -> Void) -> Void)

    @State private var alertIsPresented: Bool = false
    @State private var error: LocalizedError?
    @State private var saving: Bool = false

    init(
        initialValue: SilencePodPreference,
        initialSilenceTimeEndTime: Date?,
        onSave: @escaping (_ selectedValue: SilencePodPreference,
                           _ selectedSilenceEnd: Date?,
                           _ completion: @escaping (_ error: LocalizedError?) -> Void) -> Void)
    {
        self.initialValue = initialValue
        self._preference = State(initialValue: initialValue)

        self.initialEndTimeValue = initialSilenceTimeEndTime
        self._endTimeValue = State(initialValue: initialSilenceTimeEndTime)

        self.onSave = onSave
    }

    var body: some View {
        contentWithCancel
    }

    var content: some View {
        VStack {
            List {
                Section {
                    Text(LocalizedString("Silence Pod mode suppresses all Pod alert and confirmation reminder beeping.", comment: "Help text for Silence Pod view")).fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 10)
                }
                Section {
                    ForEach(SilencePodPreference.allCases, id: \.self) { preference in
                        HStack {
                            CheckmarkListItem(
                                title: Text(preference.title),
                                description: Text(preference.description),
                                isSelected: Binding(
                                    get: { self.preference == preference },
                                    set: { isSelected in
                                        if isSelected {
                                            self.preference = preference
                                        }
                                    }
                                )
                            )
                        }
                        .padding(.vertical, 4)
                    }
                    if self.preference == .enabled {
                        Section {
                            OptionalDatePicker(
                                title: LocalizedString("Silence End", comment: "Silence End label"),
                                footnote: LocalizedString("Silence Pod mode will remain in effect until Disabled or the Silence End time has been reached", comment: "Silence End time description"),
                                selection: $endTimeValue
                            )
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle()) // Disable row highlighting on selection
            }
            VStack {
                Button(action: {
                    doSave(preference, endTimeValue, dismissOnSuccess: true)
                }) {
                    Text(saveButtonText)
                        .actionButtonStyle(.primary)
                }
                .padding()
                .disabled(saving || !valueChanged)
            }
            .padding(self.horizontalSizeClass == .regular ? .bottom : [])
            .background(Color(UIColor.secondarySystemGroupedBackground).shadow(radius: 5))
        }
        .onChange(of: preference) { _ in
            /// Clear endTimeValue on any change of preference for hopefully a more consistent UX experience
            endTimeValue = nil
        }
        .onAppear {
            /// If the endTimeValue is no longer valid at the current time,
            /// reset the affected variables and save the updated values.
            if let endTime = endTimeValue, endTime <= earliestAllowedEndTime {
                preference = .disabled
                endTimeValue = nil
                doSave(preference, endTimeValue, dismissOnSuccess: false)
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(LocalizedString("Silence Pod", comment: "navigation title for Silence Pod"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(isPresented: $alertIsPresented, content: { alert(error: error) })
    }

    /// Save the given values to the onSave function after checking values
    private func doSave(_ selectedValue: SilencePodPreference, _ selectedSilenceEnd: Date?, dismissOnSuccess: Bool) {
        saving = true

        /// Make sure that a set of reasonable values for the current time will be saved
        let preferenceToSave: SilencePodPreference
        let endTimeToSave: Date?
        if preference == .disabled {
            preferenceToSave = .disabled
            endTimeToSave = nil
        } else if let endTime = endTimeValue, endTime <= earliestAllowedEndTime {
            /// endtime isn't past the earliestEndTimeAllowed, so switch to disabled mode
            preferenceToSave = .disabled
            endTimeToSave = nil
        } else {
            /// preference == .enabled && (endTimeValue == nil (untimed)  OR
            /// endTimeValue! > earliestAllowedEndTime (valid timed))
            preferenceToSave = .enabled
            endTimeToSave = endTimeValue
        }
        onSave(preferenceToSave, endTimeToSave) { (error) in
            saving = false
            if let error = error {
                self.error = error
                self.alertIsPresented = true
            } else if dismissOnSuccess {
                self.presentationMode.wrappedValue.dismiss()
            }
        }
    }

    private var contentWithCancel: some View {
        if saving {
            return AnyView(content
                .navigationBarBackButtonHidden(true)
            )
        } else if valueChanged {
            return AnyView(content
                .navigationBarBackButtonHidden(true)
                .navigationBarItems(leading: cancelButton)
            )
        } else {
            return AnyView(content)
        }
    }

    private var cancelButton: some View {
        Button(action: { self.presentationMode.wrappedValue.dismiss() } ) {
            Text(LocalizedString("Cancel", comment: "Button title for cancelling silence pod edit"))
        }
    }

    private var saveButtonText: String {
        if saving {
            return LocalizedString("Saving...", comment: "button title for saving silence pod preference while saving")
        } else {
            return LocalizedString("Save", comment: "button title for saving silence pod preference")
        }
    }

    private var valueChanged: Bool {
        return preference != initialValue || endTimeValue != initialEndTimeValue
    }

    /// N.B., Reevaluated on each reference
    private var earliestAllowedEndTime: Date {
        return Date().addingTimeInterval(minimumSilenceModeTime)
    }

    private func alert(error: Error?) -> SwiftUI.Alert {
        return SwiftUI.Alert(
            title: Text(LocalizedString("Failed to update silence pod preference", comment: "Alert title for error when updating silence pod preference")),
            message: Text(error?.localizedDescription ?? "No Error")
        )
    }
}

struct SilencePodSelectionView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            SilencePodSelectionView(initialValue: .disabled, initialSilenceTimeEndTime: nil) { selectedValue, selectedSilenceEnd, completion in
                print("Selected: \(selectedValue), end: \(String(describing: selectedSilenceEnd))")
                completion(nil)
            }
        }
    }
}


struct OptionalDatePicker: View {
    let title: String
    let footnote: String
    @Binding var selection: Date?

    private let minimumInterval: TimeInterval = .minutes(1)
    /// a bit more than 1/2 day allows for a AM/PM flip from the base time when using a 12 hour time
    private let maximumInterval: TimeInterval = .hours(13) + .minutes(1)

    private var now: Date
    private var earliestAllowedEndTime: Date
    private var minimumDate: Date
    private var maximumDate: Date

    private let defaultOffset: TimeInterval = .hours(1)

    @State private var pickerDate: Date
    @State private var lastCommittedDate: Date?

    // MARK: - Init

    init(
        title: String,
        footnote: String,
        selection: Binding<Date?>,
    ) {
        self.title = title
        self.footnote = footnote
        self._selection = selection

        now = Date()
        earliestAllowedEndTime = now.addingTimeInterval(minimumSilenceModeTime)
        minimumDate = now.addingTimeInterval(minimumInterval)
        maximumDate = now.addingTimeInterval(maximumInterval)

        let initial = selection.wrappedValue ?? now.addingTimeInterval(defaultOffset)
        _pickerDate = State(initialValue: initial)
        _lastCommittedDate = State(initialValue: selection.wrappedValue)
    }

    // MARK: - View

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)

            Spacer()

            if selection == nil {
                Button {
                    activatePicker()
                } label: {
                    Text("Not set")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                DatePicker(
                    String(""),
                    selection: $pickerDate,
                    displayedComponents: [.hourAndMinute]
                )
                .labelsHidden()
                .monospacedDigit()
                .onChange(of: pickerDate) { newValue in
                    applyRollingChange(newValue)
                }
            }

            if selection != nil {
                Button {
                    selection = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: selection) {
            newValue in syncFromBinding(newValue)
        }

        Text(footnote)
            .font(.caption)
            .opacity(0.50)
    }

    // MARK: - Activation

    private func activatePicker() {
        let base = now.addingTimeInterval(TimeInterval(hours: 1))
        let clamped = clamp(base)

        pickerDate = clamped
        selection = clamped
        lastCommittedDate = clamped
    }

    // MARK: - Rolling Logic

    private func applyRollingChange(_ newValue: Date) {
        let calendar = Calendar.current
        let base = lastCommittedDate ?? selection ?? pickerDate

        let oldHour = calendar.component(.hour, from: base)
        let oldMinute = calendar.component(.minute, from: base)
        let newHour = calendar.component(.hour, from: newValue)
        let newMinute = calendar.component(.minute, from: newValue)

        let oldTotalMinutes = oldHour * 60 + oldMinute
        let newTotalMinutes = newHour * 60 + newMinute

        var candidate = calendar.date(
            bySettingHour: newHour,
            minute: newMinute,
            second: 0,
            of: base
        )!

        let minutesInDay = 24 * 60
        let halfDay = minutesInDay / 2

        let delta = newTotalMinutes - oldTotalMinutes

        // Forward wrap: 23:59 → 00:00
        if delta <= -halfDay {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        // Backward wrap: 00:00 → 23:59
        else if delta >= halfDay {
            candidate = calendar.date(byAdding: .day, value: -1, to: candidate) ?? candidate
        }
        // else: same day (includes all midday transitions)

        let clamped: Date
        if candidate < minimumDate {
            clamped = minimumDate
        } else if candidate > maximumDate {
            clamped = maximumDate
        } else {
            clamped = candidate
        }

        pickerDate = clamped
        selection = clamped
        lastCommittedDate = clamped
    }


    // MARK: - Sync

    private func syncFromBinding(_ newValue: Date?) {
        if let date = newValue {
            let clamped = clamp(date)
            pickerDate = clamped
            lastCommittedDate = clamped
        } else {
            lastCommittedDate = nil
        }
    }

    // MARK: - Helpers

    private func clamp(_ date: Date) -> Date {
        min(max(date, minimumDate), maximumDate)
    }
}
