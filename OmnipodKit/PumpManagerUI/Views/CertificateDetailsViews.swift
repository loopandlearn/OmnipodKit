//
//  CertificateDetailsView.swift
//  OmnipodKit
//
//  Shows the loaded O5 certificate(s). For the common single-cert case the
//  detail content is rendered inline; with multiple certs we fall back to a
//  list-of-rows with per-cert navigation. A "+" toolbar button imports an
//  o5keypair file directly into the registry and Keychain.
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

struct CertificateDetailsView: View {

    private struct Row: Identifiable {
        let data: O5RegistrationData
        let source: O5RegistrationSource
        var id: UInt32 { data.controllerId }
    }

    @State private var rows: [Row] = []
    @State private var showingFileImporter = false
    @State private var importError: String?

    let title: String
    let hasActivePod: Bool
    let myId: UInt32
    let refreshO5IdsFromCertStore: () -> Void

    var body: some View {
        List {
            if rows.isEmpty {
                Section {
                    Text(LocalizedString("No certificates loaded", comment: "Empty state for the Pod Certificate view"))
                        .foregroundColor(.secondary)
                }
            } else if rows.count == 1 {
                certificateContent(
                    data: rows[0].data,
                    source: rows[0].source,
                    hasActivePod: hasActivePod,
                    myId: myId,
                    onForgotten: { reload() },
                    refreshO5IdsFromCertStore: refreshO5IdsFromCertStore
                )
            } else {
                ForEach(rows) { row in
                    NavigationLink(destination: PodCertificateDetailView(
                        data: row.data,
                        source: row.source,
                        hasActivePod: hasActivePod,
                        myId: myId,
                        onForgotten: { reload() },
                        refreshO5IdsFromCertStore: refreshO5IdsFromCertStore
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            // Mark an active certificate, only seen & relevant if there's more than one
                            let isActiveStr = row.data.controllerId == myId ? "^" : ""
                            Text(String(format: "Controller 0x%08X%@", row.data.controllerId, isActiveStr))
                                .foregroundColor(.primary)
                            Text(label(for: row.source))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
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
                .accessibilityLabel(LocalizedString("Import o5keypair file", comment: "Toolbar action to import an o5keypair file"))
            }
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.json, .item]) { result in
            handleImport(result)
        }
        .alert(
            LocalizedString("Import Failed", comment: "Title of o5keypair import-failed alert"),
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            ),
            presenting: importError
        ) { _ in
            Button(LocalizedString("OK", comment: "OK button for import-failed alert")) {
                importError = nil
            }
        } message: { message in
            Text(message)
        }
        .task { reload() }
    }

    private func reload() {
        // Make sure both built-in (dlsym) and Keychain-persisted certs are populated
        // before we read the registry — opening this view shouldn't depend on the
        // pairing flow having run first.
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
                importError = LocalizedString("The selected file is not a valid o5keypair file.", comment: "Error when o5keypair file import fails")
                return
            }
            O5RegistrationData.install(registrationData, source: .imported)
            try? O5CertificateKeychain.save(registrationData, source: .imported)
            importError = nil
            reload()
            if myId == 0 {
                refreshO5IdsFromCertStore() // pickup the new O5 certificate now
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func label(for source: O5RegistrationSource) -> String {
        switch source {
        case .builtIn:  return LocalizedString("Built-in (compiled into app)", comment: "O5 cert source: built-in")
        case .imported: return LocalizedString("Imported (o5keypair file)", comment: "O5 cert source: imported")
        case .downloaded:  return LocalizedString("Downloaded (in O5 Setup)", comment: "O5 cert source: downloaded")
        }
    }
}

struct PodCertificateDetailView: View {

    let data: O5RegistrationData
    let source: O5RegistrationSource
    let hasActivePod: Bool
    let myId: UInt32
    let onForgotten: () -> Void
    let refreshO5IdsFromCertStore: () -> Void

    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        List {
            certificateContent(
                data: data,
                source: source,
                hasActivePod: hasActivePod,
                myId: myId,
                onForgotten: {
                    onForgotten()
                    presentationMode.wrappedValue.dismiss()
                },
                refreshO5IdsFromCertStore: refreshO5IdsFromCertStore
            )
        }
        .insetGroupedListStyle()
        .navigationTitle(String(format: "Controller 0x%08X", data.controllerId))
        .navigationBarTitleDisplayMode(.inline)
    }
}

@ViewBuilder
fileprivate func certificateContent(
    data: O5RegistrationData,
    source: O5RegistrationSource,
    hasActivePod: Bool,
    myId: UInt32,
    onForgotten: @escaping () -> Void,
    refreshO5IdsFromCertStore: @escaping () -> Void
) -> some View {
    Section {
        Text(dump(data: data, source: source))
            .font(Font.system(size: 12).monospaced())
            .textSelection(.enabled)
    }

    if source != .builtIn {
        Section {
            ForgetCertificateButton(
                controllerId: data.controllerId,
                myId: myId,
                hasActivePod: hasActivePod,
                onForgotten: onForgotten,
                refreshO5IdsFromCertStore: refreshO5IdsFromCertStore
            )
        }
    }
}

private struct ForgetCertificateButton: View {

    let controllerId: UInt32
    let myId: UInt32
    let hasActivePod: Bool
    let onForgotten: () -> Void
    let refreshO5IdsFromCertStore: () -> Void

    @State private var pendingForget = false

    let ncerts = O5RegistrationData.allValues.count

    private var confirmMessage: String {
        var activePodMessage = ""
        var baseMessage = ""
        if hasActivePod {
            activePodMessage = LocalizedString("Your current Omnipod 5 Pod session will not be affected. ",
                comment: "Confirmation message when forgetting a saved O5 certificate while a pod session is active"
            )
        }
        if ncerts == 1 {
            baseMessage = LocalizedString("You will be unable to pair with a new Omnipod 5 Pod until you reconnect to the Internet to download a new certificate.",
                comment: "Confirmation message when a new certificate will need to be downloaded"
            )
        } else if myId == controllerId {
            baseMessage = LocalizedString("A new certificate will be used for the next Omnipod 5 Pod pairing.",
                comment: "Confirmation message when a new certificate will be used"
            )
        } else if activePodMessage.isEmpty {
            baseMessage = LocalizedString("This certificate will be permanently deleted.",
                comment: "Confirmation message when forgetting a saved O5 certificate"
            )
        }

        return activePodMessage + baseMessage
    }

    var body: some View {
        Button(role: .destructive) {
            pendingForget = true
        } label: {
            Text(LocalizedString("Forget Saved Certificate", comment: "Destructive button to remove a saved O5 certificate"))
        }
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
        try? O5CertificateKeychain.delete(controllerId: controllerId)
        O5RegistrationData.remove(controllerId: controllerId)
        if controllerId == myId {
            // Just deleted the currently used certificate, so refresh to
            // pickup another one immediately if pod not currently active.
            refreshO5IdsFromCertStore()
        }
        onForgotten()
    }
}

fileprivate func dump(data: O5RegistrationData, source: O5RegistrationSource) -> String {
    var lines: [String] = []
    lines.append("## O5RegistrationData")
    lines.append("* source: \(sourceLabel(source))")
    lines.append(String(format: "* controllerId: %u (0x%08X)", data.controllerId, data.controllerId))
    lines.append("* publicKey: \(data.publicKeyHex)")
    return lines.joined(separator: "\n")
}

fileprivate func sourceLabel(_ source: O5RegistrationSource) -> String {
    switch source {
    case .builtIn:  return "Built-in (compiled into app)"
    case .imported: return "Imported (o5keypair file)"
    case .downloaded:  return "Downloaded (in O5 Setup)"
    }
}
