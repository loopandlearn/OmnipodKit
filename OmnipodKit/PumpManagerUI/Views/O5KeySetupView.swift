//
//  O5KeySetupView.swift
//  OmnipodKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import UniformTypeIdentifiers
import LoopKit
import LoopKitUI

struct O5KeySetupView: View {

    @Environment(\.appName) private var appName

    @State private var o5KeypairsNotAvailable: Bool
    @State private var showingFetchSheet = false
    @State private var showingFileImporter = false
    @State private var fileImportError: String?
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
                        Text(LocalizedString("We need to briefly connect to the internet to download a certificate in order to pair Omnipod 5 pods. An internet connection won't be required after you complete this one-time step.", comment: "Description when O5 keypairs are not available"))
                        .padding(.vertical, 4)
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title2)
                            Text(LocalizedString("Ready to connect to an Omnipod 5 pod.", comment: "Description when O5 keypairs are available"))
                        }
                        .padding(.vertical, 4)
                    }
                }

                if o5KeypairsNotAvailable {
                    Section {
                        Button(action: { showingFileImporter = true }) {
                            Text(LocalizedString("Have an '.o5keypair' file to use instead?", comment: "Link to import an o5keypair file"))
                        }

                        if let fileImportError = fileImportError {
                            Text(fileImportError)
                                .foregroundColor(.red)
                                .font(.subheadline)
                        }
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
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.json, .item]) { result in
            fileImportError = nil
            switch result {
            case .success(let url):
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }

                guard let data = try? Data(contentsOf: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let registrationData = O5RegistrationData.fromJSON(json)
                else {
                    fileImportError = LocalizedString("The selected file is not a valid .o5keypair file.", comment: "Error when o5keypair file import fails")
                    return
                }
                O5RegistrationData.install(registrationData)
                o5KeypairsNotAvailable = false
            case .failure(let error):
                fileImportError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingFetchSheet) {
            NavigationView {
                O5KeyFetchView(
                    onKeypairReceived: { registrationData in
                        O5RegistrationData.install(registrationData)
                        o5KeypairsNotAvailable = false
                        showingFetchSheet = false
                    },
                    onCancel: {
                        showingFetchSheet = false
                    }
                )
                .navigationTitle(LocalizedString("Omnipod 5 Keys", comment: "Title for O5 key fetch view"))
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
