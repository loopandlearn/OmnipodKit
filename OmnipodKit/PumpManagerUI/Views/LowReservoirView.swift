//
//  LowReservoirView.swift
//  OmnipodKit
//
//  Based on OmniBLE/PumpManageUI/Views/LowReservoirReminder{Edit,Setup}View.swift
//  Created by Joe Moran on 1/28/26.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKitUI
import LoopKit
import HealthKit

struct LowReservoirView: View {
    private var reservoirLevel: Double // current reservoir level
    private var setDefault: Bool // true if setting the default low reservoir value
    private var initialValue: Int

    private var maxValue: Int
    private var reservoirLevelString: String
    private let title: String
    private let prompt: String

    private let allowedLowReservoirValues: [Int]

    var valueUpdated: ((_ value: Int) -> Void)?
    var continueButtonTapped: (() -> Void)?
    var cancelButtonTapped: (() -> Void)?
    var onSave: ((_ selectedValue: Int, _ completion: @escaping (_ error: Error?) -> Void) -> Void)?
    var onFinish: (() -> Void)?

    @State private var alertIsPresented: Bool = false
    @State private var error: Error?
    @State private var saving: Bool = false
    @State private var selectedValue: Int

    init(
        reservoirLevel: Double?,
        setDefault: Bool,
        initialValue: Int,
        valueUpdated: ((_ value: Int) -> Void)? = nil,
        continueButtonTapped: (() -> Void)? = nil,
        cancelButtonTapped: (() -> Void)? = nil,
        onSave: ((_ selectedValue: Int, _ completion: @escaping (_ error: Error?) -> Void) -> Void)? = nil,
        onFinish: (() -> Void)? = nil,
    ){
        self.setDefault = setDefault
        self.initialValue = initialValue
        self.reservoirLevel = reservoirLevel ?? Pod.reservoirLevelAboveThresholdMagicNumber

        if setDefault || reservoirLevel == Pod.reservoirLevelAboveThresholdMagicNumber {
            self.maxValue = Int(Pod.maximumReservoirReading)
            self.reservoirLevelString = "50+"
        } else {
            // Needs to be the next whole value below the current reservoir level
            self.maxValue = Int(self.reservoirLevel - Pod.pulseSize / 10)
            self.reservoirLevelString = String(format: "%.02f", self.reservoirLevel)
        }

        self.valueUpdated = valueUpdated
        self.cancelButtonTapped = cancelButtonTapped
        self.onSave = onSave
        self.onFinish = onFinish

        self.allowedLowReservoirValues = Array(0...self.maxValue)

        // Initialize the State-backed property
        let defaultValue = min(max(initialValue, 0), self.maxValue)
        self._selectedValue = State(initialValue: defaultValue)

        if setDefault {
            self.title = "Low Reservoir Default"
            self.prompt = String(format: LocalizedString("You can be optionally notified when the amount of insulin remaining in the reservoir reaches a selected level (1 - %1$lld units).\n\nSet the default low reservoir alert level to configure when pairing a Pod.", comment: "Description text on LowReservoirView Default value (1: max value)"), self.maxValue)
        } else {
            self.title = "Low Reservoir"
            self.prompt = String(format: LocalizedString("You can be optionally notified when the amount of insulin in the current Pod drops to a selected level below the current reservoir value of %1$@ units.\n\nSet the low reservoir alert level for the current Pod.", comment: "Description text on LowReservoirView for the current Pod (1: current reservoir value"), reservoirLevelString)
        }
    }

    var body: some View {
        contentWithCancel
    }

    var content: some View {
        GuidePage(content: {
            VStack(alignment: .leading, spacing: 8) {
                Text(prompt)
                Divider()
                HStack {
                    Text(title)
                    Spacer()
                    Text(formatLowReservoirAlertValue(selectedValue))
                }
                picker
            }
        }) {
            if let continueButtonTapped = continueButtonTapped {
                VStack {
                    Button(action: {
                        continueButtonTapped()
                    }) {
                        Text(LocalizedString("Next", comment: "Text of Next button on LowReservoirView"))
                            .actionButtonStyle(.primary)
                    }
                }
                .padding()
            } else {
                VStack {
                    Button(action: saveTapped) {
                        Text(saveButtonText)
                            .actionButtonStyle()
                            .padding()
                    }
                    /// N.B., The button color is no longer set
                    /// to gray when it is disabled in iOS 26!
                    .disabled(saving || !valueChanged)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.automatic)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let cancelButtonTapped {
                    Button(LocalizedString("Cancel", comment: "Cancel button title"), action: {
                        cancelButtonTapped()
                    })
                }
            }
        }
        .alert(isPresented: $alertIsPresented, content: { alert(error: error) })
    }

    private var picker: some View {
        Picker(String(""), selection: $selectedValue) {
            ForEach(self.allowedLowReservoirValues, id: \.self) { value in
                Text(formatLowReservoirAlertValue(value))
            }
        }.pickerStyle(WheelPickerStyle())
        .onChange(of: selectedValue) { value in
            valueUpdated?(value)
        }
    }

    var saveButtonText: String {
        if saving {
            return LocalizedString("Saving...", comment: "button title for saving low reservoir alert value while saving")
        } else {
            return LocalizedString("Save", comment: "button title for saving low reservoir alert value")
        }
    }

    private func saveTapped() {
        saving = true
        self.onSave?(selectedValue) { (error) in
            saving = false
            if let error = error {
                self.error = error
                self.alertIsPresented = true
            } else {
                self.onFinish?()
            }
        }
    }

    private var valueChanged: Bool {
        return selectedValue != initialValue
    }

    private var contentWithCancel: some View {
        if saving {
            return AnyView(content
                .navigationBarBackButtonHidden(true)
            )
        } else if valueChanged && onSave != nil {
            return AnyView(content
                .navigationBarBackButtonHidden(true)
                .navigationBarItems(leading: cancelButton)
            )
        } else {
            return AnyView(content)
        }
    }

    private var cancelButton: some View {
        Button(action: { self.onFinish?() } ) {
            Text(LocalizedString("Cancel", comment: "Button title for cancelling low reservoir edit"))
        }
    }

    private func alert(error: Error?) -> SwiftUI.Alert {
        return SwiftUI.Alert(
            title: Text(LocalizedString("Failed to Update Low Reservoir Value", comment: "Alert title for error when updating low reservoir value")),
            message: Text(error?.localizedDescription ?? "No Error")
        )
    }
}

struct LowReservoirView_Previews: PreviewProvider {
    static var previews: some View {
        LowReservoirView(
            reservoirLevel: nil,
            setDefault: true,
            initialValue: Int(Pod.defaultLowReservoirReminder),
            valueUpdated: { (_) in },
            continueButtonTapped: { },
            cancelButtonTapped: { },
            onSave: { (_, _) in },
            onFinish: { },
        )
    }
}
