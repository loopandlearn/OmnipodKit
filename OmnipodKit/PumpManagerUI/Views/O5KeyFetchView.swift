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
                    Text("An error occurred: \(errorMessage)")
                        .foregroundColor(.red)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button(action: { performFetch() }) {
                        Text(LocalizedString("Retry", comment: "O5 key fetch retry button"))
                            .actionButtonStyle(.primary)
                            .padding()
                    }
                }
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text(LocalizedString("Downloading certificate...", comment: "O5 key fetch loading text"))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .onAppear {
            performFetch()
        }
    }

    private func performFetch() {
        errorMessage = nil

        O5AppAttestService().fetchKeypair { result in
            switch result {
            case .success(let registrationData):
                self.onKeypairReceived(registrationData)
            case .failure(let error):
                self.errorMessage = error.message
            }
        }
    }
}
