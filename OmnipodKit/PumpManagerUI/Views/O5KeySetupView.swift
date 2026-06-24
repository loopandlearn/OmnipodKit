//
//  O5KeySetupView.swift
//  OmnipodKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI

struct O5KeySetupView: View {

    @Environment(\.appName) private var appName

    @State private var o5KeypairsNotAvailable: Bool
    @State private var showingFetchSheet = false
    private var didContinue: () -> Void
    private var didCancel: () -> Void

    init(o5KeypairsNotAvailable: Bool, didContinue: @escaping () -> Void, didCancel: @escaping () -> Void) {
        self._o5KeypairsNotAvailable = State(initialValue: o5KeypairsNotAvailable)
        self.didContinue = didContinue
        self.didCancel = didCancel
    }

    var body: some View {
        VStack(alignment: .leading) {
            List {
                Section {
                    if o5KeypairsNotAvailable {
                        Text(LocalizedString("Tap ‘Continue’ to download a certificate to be stored in order to pair with Omnipod 5 Pods.", comment: "Description when O5 keypairs are not available"))
                        .padding(.vertical, 4)
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title2)
                            Text(LocalizedString("Ready to pair with an Omnipod 5 Pod.", comment: "Description when O5 keypairs are available"))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .insetGroupedListStyle()

            Button(action: {
                if o5KeypairsNotAvailable {
                    showingFetchSheet = true
                } else {
                    didContinue()
                }
            }) {
                Text(LocalizedString("Continue", comment: "Text for Continue button on O5KeySetupView"))
                    .actionButtonStyle(.primary)
                    .padding()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(LocalizedString("Cancel", comment: "Cancel button title"), action: {
                    didCancel()
                })
            }
        }
        .sheet(isPresented: $showingFetchSheet) {
            NavigationView {
                O5KeyFetchView(
                    onKeypairReceived: { registrationData in
                        O5RegistrationData.install(registrationData, source: .downloaded)
                        try? O5CertificateKeychain.save(registrationData, source: .downloaded)
                        o5KeypairsNotAvailable = false
                        showingFetchSheet = false
                    },
                    onCancel: {
                        showingFetchSheet = false
                    }
                )
                .navigationTitle(LocalizedString("Omnipod 5 Setup", comment: "Title for O5 key fetch view"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(LocalizedString("Cancel", comment: "Cancel button for O5 key fetch")) {
                            showingFetchSheet = false
                        }
                    }
                }
            }
        }
    }
}
