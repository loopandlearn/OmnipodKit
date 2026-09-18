//
//  PodKeepAliveView.swift
//  OmnipodKit
//
//  Created by Joe Moran on 7/21/26.
//  Copyright © 2026 Joe Moran. All rights reserved.
//

import SwiftUI
import LoopKitUI

struct PodKeepAliveView: View {

    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>

    private var title: String
    private var initialValue: PodKeepAlive
    @State private var preference: PodKeepAlive

    private var onChange: ((_ selectedValue: PodKeepAlive) -> Void)?

    init(title: String,
        initialValue: PodKeepAlive,
        onChange: @escaping (_ selectedValue: PodKeepAlive) -> Void
    ){
        self.title = title
        self.initialValue = initialValue
        self._preference = State(initialValue: initialValue)
        self.onChange = onChange
    }

    var body: some View {
        contentWithCancel
    }

    var content: some View {
        VStack {
            List {
                Section {
                    VStack(alignment: .center, spacing: 4) {
                        Text("For use with iPhone 16 or iPhone 17e when used with InPlay BLE (Atlas) DASH pods; otherwise leave disabled.", comment: "Hardware which benefits from Pod Keep Alive")
                            .font(.body)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("When enabled, additional pod status requests are issued to minimize pod Bluetooth disconnects.", comment: "Summary of the Pod Keep Alive concept")
                            .font(.body)
                            .foregroundColor(.primary)
                    }
                }

                Section {
                    ForEach(PodKeepAlive.allCases, id: \.self) { preference in
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
                        .padding(.vertical, 10)
                    }
                }
                .buttonStyle(PlainButtonStyle()) // Disable row highlighting on selection
            }
            VStack {
                Button(action: {
                    onChange?(preference)
                    self.presentationMode.wrappedValue.dismiss()
                }) {
                    Text("Save", comment: "button title for saving pod keep alive")
                        .actionButtonStyle(.primary)
                }
                .padding()
                .disabled(!valueChanged)
            }
            .padding(self.horizontalSizeClass == .regular ? .bottom : [])
            .background(Color(UIColor.secondarySystemGroupedBackground).shadow(radius: 5))

        }
        .insetGroupedListStyle()
        .uikitNavigationTitle(title)
    }

    private var contentWithCancel: some View {
        if valueChanged {
            return AnyView(content
                .navigationBarBackButtonHidden(true)
                .navigationBarItems(leading: cancelButton)
            )
        }
        return AnyView(content)
    }

    private var cancelButton: some View {
        Button(action: { self.presentationMode.wrappedValue.dismiss() } ) {
            Text(LocalizedString("Cancel", comment: "Button title for cancelling pod keep alive edit"))
        }
    }

    private var valueChanged: Bool {
        return preference != initialValue
    }
}
