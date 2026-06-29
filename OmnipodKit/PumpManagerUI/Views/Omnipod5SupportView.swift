//
//  Omnipod5SupportView.swift
//  OmnipodKit
//
//  Shows the Omnipod 5 connectivity status driven by the loaded O5 certificate(s).
//
//  When a certificate is present we show a green "ready" state describing how to
//  pair an O5 pod relative to the currently-configured pod type. When no
//  certificate is present we show a warning and a "Continue" button that runs the
//  same App Attest download flow used by the pairing setup wizard.
//
//  The overflow ("…") menu offers "Load custom certificate" (only when no cert is
//  loaded) and "Delete saved certificate" with a deletable (non compiled-in) cert.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import UniformTypeIdentifiers
import LoopKit
import LoopKitUI


struct Omnipod5SupportView: View {

    let podType: PodType
    let controllerId: UInt32
    let hasActivePod: Bool
    let refreshO5IdsFromCertStore: () -> Void
    let onCertStoreChanged: () -> Void

    @Environment(\.guidanceColors) private var guidanceColors
    @Environment(\.presentationMode) private var presentationMode

    // Resolve the host app name (Trio/Loop) directly from the bundle rather than
    // the appName environment, which isn't injected on the settings nav path.
    private var appName: String { Bundle.main.bundleDisplayName }

    @State private var certLoaded = !O5RegistrationData.isEmpty
    @State private var deletableCert = O5RegistrationData.deletableCert
    @State private var showingFetchSheet = false
    @State private var showingFileImporter = false
    @State private var importError: String?
    @State private var pendingDelete = false
    @State private var pendingDeleteFinalConfirm = false

    private var menuHasOptions: Bool {
        if !certLoaded { return true }          // "Load custom certificate"
        if deletableCert != nil { return true } // "Delete saved certificate"
        return false
    }

    var body: some View {
        VStack {
            Spacer()

            if certLoaded {
                loadedContent
            } else {
                needsCertContent
            }

            Spacer()

            if certLoaded {
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    Text(LocalizedString("OK", comment: "Button to dismiss the Omnipod 5 Support screen"))
                        .actionButtonStyle(.primary)
                        .padding()
                }
            } else {
                Button(action: { showingFetchSheet = true }) {
                    Text(LocalizedString("Continue", comment: "Button to start the O5 certificate download"))
                        .actionButtonStyle(.primary)
                        .padding()
                }
            }
        }
        .navigationTitle(LocalizedString("Omnipod 5 Support", comment: "Title for the Omnipod 5 Support screen"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { overflowMenu }
        .sheet(isPresented: $showingFetchSheet) {
            fetchSheet
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
        .confirmationDialog(
            deleteMessage,
            isPresented: $pendingDelete,
            titleVisibility: .visible
        ) {
            Button(deleteSavedCertificateString, role: .destructive) {
                pendingDeleteFinalConfirm = true
            }
            Button(LocalizedString("Cancel", comment: "Cancel button"), role: .cancel) {}
        }
        .alert(
            deleteSavedCertificateString,
            isPresented: $pendingDeleteFinalConfirm
        ) {
            Button(LocalizedString("Cancel", comment: "Cancel button"), role: .cancel) {}
            Button(LocalizedString("Continue", comment: "Confirm destructive delete action on the final confirmation alert"), role: .destructive) {
                deleteCertificate()
            }
        } message: {
            Text(finalDeleteMessage)
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundColor(.green)
            Text(loadedMessage)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var needsCertContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(guidanceColors.warning)
            Text(needsCertMessage)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal)
    }

    @ToolbarContentBuilder
    private var overflowMenu: some ToolbarContent {
        // The conditional lives inside the ToolbarItem's view builder (valid on
        // iOS 15); a ToolbarContentBuilder `if` would require iOS 16. When there
        // are no options the item renders empty, so no button appears.
        ToolbarItem(placement: .navigationBarTrailing) {
            if menuHasOptions {
                Menu {
                    if !certLoaded {
                        Button {
                            importError = nil
                            showingFileImporter = true
                        } label: {
                            Label(LocalizedString("Load custom certificate", comment: "Menu action to import an o5keypair file"), systemImage: "square.and.arrow.down")
                        }
                    }
                    if O5RegistrationData.deletableCert != nil {
                        Button(role: .destructive) {
                            pendingDelete = true
                        } label: {
                            Label(deleteSavedCertificateString, systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var fetchSheet: some View {
        NavigationView {
            O5KeyFetchView(
                onKeypairReceived: { registrationData in
                    O5RegistrationData.install(registrationData, source: .downloaded)
                    try? O5CertificateKeychain.save(registrationData, source: .downloaded)
                    showingFetchSheet = false
                    certLoaded = true
                    refreshO5IdsFromCertStore()
                    onCertStoreChanged()
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

    // MARK: - Messages

    private var deleteSavedCertificateString: String {
        if let deletableCert = O5RegistrationData.deletableCert {
            return String(format: LocalizedString("Delete saved certificate %1$@",
                comment: "Title of the final O5 certificate delete confirmation alert (1: certificate number)"),
                          String(format: "0x%08X", deletableCert.controllerId))
        } else {
            return LocalizedString("Delete saved certificate", comment: "Confirm destructive delete action")
        }
    }

    private var loadedMessage: String {
        String(format: LocalizedString("%1$@ is able to connect to Omnipod 5 Pods.",
            comment: "Heading shown when a valid O5 certificate is loaded (1: app name)"), appName)
    }

    private var needsCertMessage: String {
        let warning = String(format: LocalizedString("%1$@ needs to download and store a certificate from the Internet to connect to Omnipod 5 Pods.",
            comment: "Warning shown when no O5 certificate is loaded (1: app name)"), appName)
        let action = LocalizedString("Press Continue to download a certificate now and enable support for Omnipod 5 on your next Pod change.",
            comment: "Instruction to download an O5 certificate")
        return warning + "\n\n" + action
    }

    private var deleteMessage: String {
        let ncerts = O5RegistrationData.allValues.count
        var activeO5PodMessage = ""
        var baseMessage = ""
        if hasActivePod && podType.isO5 {
            activeO5PodMessage = LocalizedString("Your current Omnipod 5 Pod session will not be affected. ",
                comment: "Confirmation message when forgetting a saved O5 certificate while a pod session is active"
            )
        }
        if ncerts == 1 {
            baseMessage = LocalizedString("You will be unable to pair with a new Omnipod 5 Pod until you reconnect to the Internet to download a new certificate.",
                comment: "Confirmation message when a new certificate will need to be downloaded"
            )
        } else if O5RegistrationData.source(for: controllerId) != nil {
            baseMessage = LocalizedString("A new certificate will be used for the next Omnipod 5 Pod pairing.",
                comment: "Confirmation message when a new certificate will be used"
            )
        } else if activeO5PodMessage.isEmpty {
            baseMessage = LocalizedString("This certificate will be permanently deleted.",
                comment: "Confirmation message when forgetting a saved O5 certificate"
            )
        }

        return activeO5PodMessage + baseMessage
    }

    private var finalDeleteMessage: String {
        deleteMessage + "\n\n" + LocalizedString("Deleting the certificate is not needed to switch another pod or pump type. Are you sure you want to continue?",
            comment: "Final confirmation message before deleting a saved O5 certificate")
    }

    private func sourceText(_ source: O5RegistrationSource) -> String {
        switch source {
        case .compiled:   return LocalizedString("Compiled", comment: "O5 cert source: compiled")
        case .imported:   return LocalizedString("Imported", comment: "O5 cert source: imported")
        case .downloaded: return LocalizedString("Downloaded", comment: "O5 cert source: downloaded")
        }
    }

    // MARK: - Actions

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
            certLoaded = true
            refreshO5IdsFromCertStore()
            onCertStoreChanged()
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func deleteCertificate() {
        // Remove every deletable (non-compiled-in) certificate so the store is fully reset.
        for cert in O5RegistrationData.allValues where O5RegistrationData.source(for: cert.controllerId) != .compiled {
            try? O5CertificateKeychain.delete(controllerId: cert.controllerId)
            O5RegistrationData.remove(controllerId: cert.controllerId)
        }
        refreshO5IdsFromCertStore() // a no-op if non O5
        certLoaded = !O5RegistrationData.isEmpty
        onCertStoreChanged()
    }
}
