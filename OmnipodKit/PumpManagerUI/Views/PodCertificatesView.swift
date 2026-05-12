//
//  PodCertificatesView.swift
//  OmnipodKit
//
//  Lists the loaded O5 certificates one row per controller; tapping a row
//  navigates to a per-certificate detail view that holds the destructive
//  "Forget Saved Certificate" action. A "+" toolbar button imports a
//  .o5keypair file directly into the registry and Keychain.
//
//  Built-in certificates (compiled into the binary) are listed read-only —
//  they cannot be forgotten without rebuilding the app.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import UniformTypeIdentifiers
import LoopKit
import LoopKitUI

struct PodCertificatesView: View {

    private struct Row: Identifiable {
        let data: O5RegistrationData
        let source: O5RegistrationSource
        var id: UInt32 { data.controllerId }
    }

    @State private var rows: [Row] = []
    @State private var showingFileImporter = false
    @State private var importError: String?

    private let title = LocalizedString("Pod Certificate Details", comment: "navigation title for pod certificate details")

    var body: some View {
        List {
            if rows.isEmpty {
                Section {
                    Text(LocalizedString("No certificates loaded.", comment: "Empty state for the Pod Certificate Details view"))
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(rows) { row in
                    NavigationLink(destination: PodCertificateDetailView(
                        data: row.data,
                        source: row.source,
                        onForgotten: { reload() }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(format: "Controller 0x%08X", row.data.controllerId))
                                .foregroundColor(.primary)
                            Text(label(for: row.source))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            if let importError {
                Section {
                    Text(importError)
                        .foregroundColor(.red)
                        .font(.subheadline)
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    importError = nil
                    showingFileImporter = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(LocalizedString("Import .o5keypair file", comment: "Toolbar action to import an o5keypair file"))
            }
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.json, .item]) { result in
            handleImport(result)
        }
        .task { reload() }
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

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let registrationData = O5RegistrationData.fromJSON(json)
            else {
                importError = LocalizedString("The selected file is not a valid .o5keypair file.", comment: "Error when o5keypair file import fails")
                return
            }
            O5RegistrationData.install(registrationData, source: .imported)
            try? O5CertificateKeychain.save(registrationData, source: .imported)
            importError = nil
            reload()
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func label(for source: O5RegistrationSource) -> String {
        switch source {
        case .builtIn:  return LocalizedString("Built-in (compiled into app)", comment: "O5 cert source: built-in")
        case .imported: return LocalizedString("Imported (.o5keypair file)", comment: "O5 cert source: imported")
        case .fetched:  return LocalizedString("Fetched (downloaded from API)", comment: "O5 cert source: fetched")
        }
    }
}

struct PodCertificateDetailView: View {

    let data: O5RegistrationData
    let source: O5RegistrationSource
    let onForgotten: () -> Void

    @Environment(\.presentationMode) private var presentationMode
    @State private var pendingForget = false

    private let confirmMessage = LocalizedString(
        "You will be unable to pair to an Omnipod 5 pod until you reconnect to the internet to download a new certificate.",
        comment: "Confirmation message when forgetting a saved O5 certificate"
    )

    var body: some View {
        List {
            Section {
                Text(dump())
                    .font(Font.system(size: 12).monospaced())
                    .textSelection(.enabled)
            }

            if source != .builtIn {
                Section {
                    Button(role: .destructive) {
                        pendingForget = true
                    } label: {
                        Text(LocalizedString("Forget Saved Certificate", comment: "Destructive button to remove a saved O5 certificate"))
                    }
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(String(format: "Controller 0x%08X", data.controllerId))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            confirmMessage,
            isPresented: $pendingForget,
            titleVisibility: .visible
        ) {
            Button(LocalizedString("Forget Saved Certificate", comment: "Confirm destructive forget action"), role: .destructive) {
                forget()
            }
            Button(LocalizedString("Cancel", comment: "Cancel button"), role: .cancel) {}
        }
    }

    private func forget() {
        try? O5CertificateKeychain.delete(controllerId: data.controllerId)
        O5RegistrationData.remove(controllerId: data.controllerId)
        onForgotten()
        presentationMode.wrappedValue.dismiss()
    }

    private func dump() -> String {
        var lines: [String] = []
        lines.append("## O5RegistrationData")
        lines.append("* source: \(label(for: source))")
        lines.append(String(format: "* controllerId: %u (0x%08X)", data.controllerId, data.controllerId))
        //lines.append("* privateKey: \(data.privateKeyHex)")
        lines.append("* publicKey: \(data.publicKeyHex)")
        //lines.append("* intermediateCA: \(data.intermediateCABase64)")
        //lines.append("* tlsCertificate: \(data.tlsCertificateBase64)")
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
