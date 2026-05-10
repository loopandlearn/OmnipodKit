//
//  PodCertificatesView.swift
//  OmnipodKit
//
//  Displays the loaded O5 certificates and lets the user remove the saved ones
//  individually. Built-in certificates (compiled into the binary) are listed
//  read-only — they cannot be forgotten without rebuilding the app.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI

struct PodCertificatesView: View {

    private struct Row: Identifiable {
        let data: O5RegistrationData
        let source: O5RegistrationSource
        var id: UInt32 { data.controllerId }
    }

    @State private var rows: [Row] = []
    @State private var pendingForget: UInt32? = nil

    private let title = LocalizedString("Pod Certificate Details", comment: "navigation title for pod certificate details")
    private let confirmMessage = LocalizedString(
        "You will be unable to pair to an Omnipod 5 pod until you reconnect to the internet to download a new certificate.",
        comment: "Confirmation message when forgetting a saved O5 certificate"
    )

    var body: some View {
        List {
            if rows.isEmpty {
                Section {
                    Text(LocalizedString("No certificates loaded.", comment: "Empty state for the Pod Certificate Details view"))
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(rows) { row in
                    Section(header: Text(String(format: "Controller 0x%08X", row.data.controllerId))) {
                        Text(dump(for: row))
                            .font(Font.system(size: 12).monospaced())
                            .textSelection(.enabled)

                        if row.source != .builtIn {
                            Button(role: .destructive) {
                                pendingForget = row.data.controllerId
                            } label: {
                                Text(LocalizedString("Forget Saved Certificate", comment: "Destructive button to remove a saved O5 certificate"))
                            }
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
        // Make sure both built-in (dlsym) and Keychain-persisted certs are populated
        // before we read the registry — opening this view in the diagnostics screen
        // shouldn't depend on the pairing flow having run first.
        _ = O5CertificateStore.isEmpty

        rows = O5RegistrationData.allValues
            .sorted { $0.controllerId < $1.controllerId }
            .map { data in
                Row(data: data, source: O5RegistrationData.source(for: data.controllerId) ?? .imported)
            }
    }

    private func forget(controllerId: UInt32) {
        try? O5CertificateKeychain.delete(controllerId: controllerId)
        O5RegistrationData.remove(controllerId: controllerId)
        reload()
    }

    private func dump(for row: Row) -> String {
        var lines: [String] = []
        lines.append("## O5RegistrationData")
        lines.append("* source: \(label(for: row.source))")
        lines.append(String(format: "* controllerId: %u (0x%08X)", row.data.controllerId, row.data.controllerId))
        lines.append("* privateKey: \(row.data.privateKeyHex)")
        lines.append("* publicKey: \(row.data.publicKeyHex)")
        lines.append("* intermediateCA: \(row.data.intermediateCABase64)")
        lines.append("* tlsCertificate: \(row.data.tlsCertificateBase64)")
        return lines.joined(separator: "\n")
    }

    private func label(for source: O5RegistrationSource) -> String {
        switch source {
        case .builtIn:  return "Built-in (compiled into app)"
        case .imported: return "Imported (.o5keypair file)"
        case .fetched:  return "Fetched (downloaded from API)"
        }
    }
}
