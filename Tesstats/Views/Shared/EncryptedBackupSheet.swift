import SwiftUI

/// Create a password-encrypted configuration backup. The password never leaves the device
/// and is never stored — without it the resulting file cannot be decrypted by anyone.
struct EncryptedBackupSheet: View {
    /// Built lazily so the freshest secrets are read at generation time.
    let makeBackup: () -> ConfigBackup

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var fileURL: URL?
    @State private var error: String?
    @State private var working = false

    private var passwordTooShort: Bool { !password.isEmpty && password.count < 6 }
    private var mismatch: Bool { !confirm.isEmpty && confirm != password }
    private var canGenerate: Bool { password.count >= 6 && password == confirm && !working }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background.ignoresSafeArea()
                Form {
                    Section {
                        // Deliberately NOT .newPassword: the user must choose and remember this
                        // password to restore on another device, so no auto-generated suggestion.
                        SecureField(L("Password"), text: $password)
                            .autocorrectionDisabled()
                        SecureField(L("Confirm password"), text: $confirm)
                            .autocorrectionDisabled()
                        if passwordTooShort {
                            Label(L("Use at least 6 characters."), systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(Brand.warning)
                        }
                        if mismatch {
                            Label(L("Passwords don't match."), systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(Brand.warning)
                        }
                    } header: {
                        Text(L("Encryption password"))
                    } footer: {
                        Text(L("Choose a strong password. It's required to restore the backup and can't be recovered — there's no way back in without it."))
                    }

                    if let fileURL {
                        Section {
                            ShareLink(item: fileURL) {
                                Label(L("Share encrypted backup"), systemImage: "lock.doc")
                                    .foregroundStyle(Brand.crimson)
                            }
                        } footer: {
                            Text(L("Encrypted with AES-256. Anyone restoring it will be asked for this password."))
                        }
                    } else {
                        Section {
                            Button {
                                generate()
                            } label: {
                                HStack {
                                    Label(L("Create encrypted backup"), systemImage: "lock.shield")
                                    Spacer()
                                    if working { ProgressView().tint(Brand.action) }
                                }
                            }
                            .disabled(!canGenerate)
                            .tint(Brand.action)
                        }
                    }

                    if let error {
                        Section { Text(error).font(.caption).foregroundStyle(Brand.danger) }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(L("Encrypted backup"))
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .onChange(of: password) { _, _ in fileURL = nil }
            .onChange(of: confirm) { _, _ in fileURL = nil }
        }
        .tint(Brand.action)
    }

    private func generate() {
        working = true
        error = nil
        let backup = makeBackup()
        let pwd = password
        // PBKDF2 (210k iterations) is deliberately slow — run it off the main actor.
        Task.detached {
            let outcome: Result<URL?, Error>
            do {
                let data = try backup.encryptedData(password: pwd)
                outcome = .success(ExportService.encryptedBackupFile(data))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                switch outcome {
                case .success(let url):
                    if let url { fileURL = url } else { error = L("Couldn't write the backup file.") }
                case .failure(let e):
                    error = e.localizedDescription
                }
                working = false
            }
        }
    }
}
