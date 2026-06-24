//
//  O5KeyFetchView.swift
//  OmnipodKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI

struct O5KeyFetchView: View {

    @State private var errorMessage: String?
    @State private var errorDetail: String?
    @State private var currentStep: O5KeyFetchProgress?

    // Token prompt: shown only when the server reports access is gated behind a setup
    // token. The token is held in memory for the duration of the fetch and never persisted.
    @State private var showTokenPrompt = false
    @State private var token = ""
    @State private var tokenContinuation: ((String?) -> Void)?

    let onKeypairReceived: (O5RegistrationData) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack {
            Spacer()

            if let errorMessage = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.red)
                    Text("\(errorMessage)")
                        .foregroundColor(.red)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    if let errorDetail = errorDetail {
                        Text(errorDetail)
                            .foregroundColor(.red)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }

                    Button(action: { performFetch() }) {
                        Text(LocalizedString("Retry", comment: "O5 key fetch retry button"))
                            .actionButtonStyle(.primary)
                            .padding()
                    }
                }
            } else {
                VStack(spacing: 16) {
                    ProgressView(value: progressFraction)
                        .progressViewStyle(.linear)
                        .padding(.horizontal, 40)

                    if let step = currentStep {
                        Text(String(format: LocalizedString("Step %d of %d",
                                                            comment: "Step counter, e.g. 'Step 2 of 6'"),
                                    step.index,
                                    O5KeyFetchProgress.totalSteps))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(step.localizedDescription)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text(LocalizedString("Starting…", comment: "O5 key fetch initial loading text"))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()
        }
        .onAppear {
            performFetch()
        }
        .sheet(isPresented: $showTokenPrompt) {
            tokenPromptView
        }
    }

    private var tokenPromptView: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Text(LocalizedString("Enter the setup token for Omnipod 5 testing",
                                     comment: "O5 token prompt explanation"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                SecureField(LocalizedString("Setup token", comment: "O5 token field placeholder"),
                            text: $token)
                    .textContentType(.password)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
                    .textFieldStyle(.roundedBorder)

                Spacer()
            }
            .padding()
            .navigationTitle(LocalizedString("Setup Token", comment: "O5 token prompt title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedString("Cancel", comment: "O5 token prompt cancel button")) {
                        finishTokenPrompt(with: nil)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedString("Continue", comment: "O5 token prompt continue button")) {
                        finishTokenPrompt(with: token)
                    }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func finishTokenPrompt(with value: String?) {
        showTokenPrompt = false
        let continuation = tokenContinuation
        tokenContinuation = nil
        continuation?(value)
    }

    private var progressFraction: Double {
        guard let step = currentStep else { return 0 }
        return Double(step.index) / Double(O5KeyFetchProgress.totalSteps)
    }

    private func performFetch() {
        errorMessage = nil
        errorDetail = nil
        currentStep = nil

        O5AppAttestService().fetchKeypair(
            progress: { step in
                self.currentStep = step
            },
            requestToken: { provide in
                self.token = ""
                self.tokenContinuation = provide
                self.showTokenPrompt = true
            },
            completion: { result in
                switch result {
                case .success(let registrationData):
                    self.onKeypairReceived(registrationData)
                case .failure(let error):
                    self.errorMessage = error.message
                    self.errorDetail = error.recoverySuggestion
                }
            }
        )
    }
}
