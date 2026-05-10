//
//  PodCertificatesView.swift
//  OmnipodKit
//
//  Displays the persisted O5 certificates and lets the user remove them
//  individually. Removal is destructive: until the user reconnects to the
//  internet to re-fetch a certificate, pairing to an Omnipod 5 pod will fail.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI

struct PodCertificatesView: View {

    @State private var certificates: [O5RegistrationData] = []
    @State private var pendingForget: UInt32? = nil

    private let title = LocalizedString("Pod Certificate Details", comment: "navigation title for pod certificate details")
    private let confirmMessage = LocalizedString(
        "You will be unable to pair to an Omnipod 5 pod until you reconnect to the internet to download a new certificate.",
        comment: "Confirmation message when forgetting a saved O5 certificate"
    )

    var body: some View {
        List {
            if certificates.isEmpty {
                Section {
                    Text(LocalizedString("No saved certificates", comment: "Empty state for the Pod Certificates view"))
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(certificates, id: \.controllerId) { data in
                    Section(header: Text(String(format: "Controller 0x%08X", data.controllerId))) {
                        Text(dump(for: data))
                            .font(Font.system(size: 12).monospaced())
                            .textSelection(.enabled)

                        Button(role: .destructive) {
                            pendingForget = data.controllerId
                        } label: {
                            Text(LocalizedString("Forget Saved Certificate", comment: "Destructive button to remove a saved O5 certificate"))
                        }
                    }
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .confirmationDialog(
            confirmMessage,
            isPresented: Binding(
                get: { pendingForget != nil },
                set: { if !$0 { pendingForget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(LocalizedString("Forget Saved Certificate", comment: "Confirm destructive forget action"), role: .destructive) {
                if let controllerId = pendingForget {
                    forget(controllerId: controllerId)
                }
                pendingForget = nil
            }
            Button(LocalizedString("Cancel", comment: "Cancel button"), role: .cancel) {
                pendingForget = nil
            }
        }
    }

    private func reload() {
        certificates = O5CertificateKeychain.loadAll()
            .sorted { $0.controllerId < $1.controllerId }
    }

    private func forget(controllerId: UInt32) {
        try? O5CertificateKeychain.delete(controllerId: controllerId)
        O5RegistrationData.remove(controllerId: controllerId)
        reload()
    }

    private func dump(for data: O5RegistrationData) -> String {
        var lines: [String] = []
        lines.append("## O5RegistrationData")
        lines.append(String(format: "* controllerId: %u (0x%08X)", data.controllerId, data.controllerId))
        lines.append("* privateKey: \(data.privateKeyHex)")
        lines.append("* publicKey: \(data.publicKeyHex)")
        lines.append("* intermediateCA: \(data.intermediateCABase64)")
        lines.append("* tlsCertificate: \(data.tlsCertificateBase64)")
        return lines.joined(separator: "\n")
    }
}
