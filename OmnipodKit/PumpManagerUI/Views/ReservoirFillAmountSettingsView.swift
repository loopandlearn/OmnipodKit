//
//  ReservoirFillAmountSettingsView.swift
//  OmnipodKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKitUI

/// Fill amounts used to show an approximate reservoir level while the pod reads 50+ U:
/// one for the current pod and a default copied to each new pod when pairing.
struct ReservoirFillAmountSettingsView: View {

    var reservoirFillAmount: Int // 0 when not set

    var defaultReservoirFillAmount: Int // 0 when not set

    let hasActivePod: Bool

    var onSaveReservoirFillAmount: ((_ selectedValue: Int) -> Void)?

    var onSaveDefaultReservoirFillAmount: ((_ selectedValue: Int) -> Void)?

    @State private var currentPodEditIsShown: Bool = false

    @State private var defaultEditIsShown: Bool = false

    var body: some View {
        RoundedCardScrollView {
            RoundedCard<EmptyView>(
                title: LocalizedString("Approximate Reservoir", comment: "Title for the approximate reservoir description"),
                footer: LocalizedString("A Pod only measures its reservoir once 50 U or less remain, and shows 50+ U until then.\n\nWith a fill amount set, the insulin the Pod has used since activation, including priming and cannula insertion, is subtracted from it to show an approximate amount, for example ~145 U. Once the Pod measures 50 U or less, its own reading is always shown.\n\nThe approximation is only as accurate as the fill amount. It is for display only and is not used for dosing or alerts.", comment: "Description text for the approximate reservoir level")
            )

            if hasActivePod {
                RoundedCard(
                    footer: LocalizedString("Fill amount for the current Pod.", comment: "Footer text for the current Pod reservoir fill amount row")
                ) {
                    NavigationLink(
                        destination: ReservoirFillAmountView(
                            setDefault: false,
                            initialValue: reservoirFillAmount,
                            onSave: onSaveReservoirFillAmount,
                            onFinish: { currentPodEditIsShown = false }
                        ),
                        isActive: $currentPodEditIsShown
                    ) {
                        RoundedCardValueRow(
                            label: LocalizedString("Current Pod", comment: "Label for the current Pod reservoir fill amount row"),
                            value: formatReservoirFillAmount(reservoirFillAmount),
                            highlightValue: false,
                            disclosure: true
                        )
                    }
                }
            }

            RoundedCard(
                footer: LocalizedString("The default fill amount to configure when pairing a new Pod.", comment: "Footer text for the default reservoir fill amount row")
            ) {
                NavigationLink(
                    destination: ReservoirFillAmountView(
                        setDefault: true,
                        initialValue: defaultReservoirFillAmount,
                        onSave: onSaveDefaultReservoirFillAmount,
                        onFinish: { defaultEditIsShown = false }
                    ),
                    isActive: $defaultEditIsShown
                ) {
                    RoundedCardValueRow(
                        label: LocalizedString("Default Fill Amount", comment: "Label for the default reservoir fill amount row"),
                        value: formatReservoirFillAmount(defaultReservoirFillAmount),
                        highlightValue: false,
                        disclosure: true
                    )
                }
            }
        }
        .navigationTitle(
            LocalizedString("Reservoir Fill Amount", comment: "navigation title for reservoir fill amount settings")
        )
    }
}

/// Picks a fill amount, or Off, for the current pod or for new pods.
struct ReservoirFillAmountView: View {
    /// Off, then the amounts a pod can be filled with
    private static let allowedValues = [0] + ReservoirEstimate.allowedFillAmounts

    private let initialValue: Int
    private let title: String
    private let prompt: String

    var onSave: ((_ selectedValue: Int) -> Void)?
    var onFinish: (() -> Void)?

    @State private var selectedValue: Int

    init(
        setDefault: Bool,
        initialValue: Int,
        onSave: ((_ selectedValue: Int) -> Void)? = nil,
        onFinish: (() -> Void)? = nil
    ) {
        let value = Self.allowedValues.contains(initialValue) ? initialValue : 0
        self.initialValue = value
        self._selectedValue = State(initialValue: value)
        self.onSave = onSave
        self.onFinish = onFinish

        if setDefault {
            self.title = LocalizedString("Default Fill Amount", comment: "Title for the default reservoir fill amount picker")
            self.prompt = LocalizedString("Set the amount of insulin you usually fill a new Pod with. It is configured for each Pod you pair, to show an approximate reservoir level while the Pod reads 50+ U.\n\nChoose Off to show 50+ U.", comment: "Description text for the default reservoir fill amount picker")
        } else {
            self.title = LocalizedString("Current Pod Fill Amount", comment: "Title for the current Pod reservoir fill amount picker")
            self.prompt = LocalizedString("Set the amount of insulin the current Pod was filled with, to show an approximate reservoir level while the Pod reads 50+ U.\n\nChoose Off to show 50+ U.", comment: "Description text for the current Pod reservoir fill amount picker")
        }
    }

    var body: some View {
        GuidePage(content: {
            VStack(alignment: .leading, spacing: 8) {
                Text(prompt)
                Divider()
                HStack {
                    Text(title)
                    Spacer()
                    Text(formatReservoirFillAmount(selectedValue))
                }
                picker
            }
        }) {
            VStack {
                Button(action: saveTapped) {
                    Text(LocalizedString("Save", comment: "button title for saving the reservoir fill amount"))
                        .actionButtonStyle()
                        .padding()
                }
                .disabled(selectedValue == initialValue)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.automatic)
    }

    private var picker: some View {
        Picker(String(""), selection: $selectedValue) {
            ForEach(Self.allowedValues, id: \.self) { value in
                Text(formatReservoirFillAmount(value))
            }
        }.pickerStyle(WheelPickerStyle())
    }

    private func saveTapped() {
        onSave?(selectedValue)
        onFinish?()
    }
}

// Display a 0 reservoir fill amount as "Off"
func formatReservoirFillAmount(_ value: Int) -> String {
    if value == 0 {
        return LocalizedString("Off", comment: "Value text when no reservoir fill amount is set")
    }
    return String(format: LocalizedString("%1$@ U", comment: "Format string for a reservoir fill amount (1: number of units)"), String(value))
}

struct ReservoirFillAmountSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ReservoirFillAmountSettingsView(
                reservoirFillAmount: 180,
                defaultReservoirFillAmount: 200,
                hasActivePod: true
            )
        }
    }
}
