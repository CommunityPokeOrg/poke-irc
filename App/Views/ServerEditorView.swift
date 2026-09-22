import SwiftUI

/// Create/edit a server profile: host, port, TLS, identity, SASL, autojoin.
struct ServerEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var existing: ServerProfile?

    @State private var name = ""
    @State private var host = ""
    @State private var port = "6697"
    @State private var useTLS = true
    @State private var nickname = ""
    @State private var username = ""
    @State private var realname = ""
    @State private var saslAccount = ""
    @State private var saslPassword = ""
    @State private var autoJoin = ""

    init(existing: ServerProfile? = nil) {
        self.existing = existing
    }

    private var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !nickname.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(port) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Display name (optional)", text: $name)
                    TextField("Host", text: $host)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Toggle("Use TLS", isOn: $useTLS)
                        .accessibilityLabel("Connect with TLS encryption")
                }

                Section("Identity") {
                    TextField("Nickname", text: $nickname)
                    TextField("Username (optional)", text: $username)
                    TextField("Real name (optional)", text: $realname)
                }

                Section("Authentication (SASL)") {
                    TextField("Account name", text: $saslAccount)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Password (stored in Keychain)", text: $saslPassword)
                        .accessibilityLabel("SASL password, stored securely in the Keychain")
                }

                Section("Channels") {
                    TextField("Auto-join, comma separated (e.g. #chat, #dev)", text: $autoJoin)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
            }
            .navigationTitle(existing == nil ? "New Server" : "Edit Server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                        .accessibilityLabel("Save server")
                }
            }
            .onAppear(perform: loadExisting)
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    private func loadExisting() {
        guard let existing else { return }
        name = existing.name
        host = existing.host
        port = String(existing.port)
        useTLS = existing.useTLS
        nickname = existing.nickname
        username = existing.username
        realname = existing.realname
        saslAccount = existing.saslAccount
        autoJoin = existing.autoJoinChannels.joined(separator: ", ")
    }

    private func save() {
        var profile = existing ?? ServerProfile(name: "", host: "", nickname: "")
        profile.name = name.trimmingCharacters(in: .whitespaces)
        profile.host = host.trimmingCharacters(in: .whitespaces)
        profile.port = Int(port) ?? (useTLS ? 6697 : 6667)
        profile.useTLS = useTLS
        profile.nickname = nickname.trimmingCharacters(in: .whitespaces)
        profile.username = username.trimmingCharacters(in: .whitespaces)
        profile.realname = realname.trimmingCharacters(in: .whitespaces)
        profile.saslAccount = saslAccount.trimmingCharacters(in: .whitespaces)
        profile.autoJoinChannels = autoJoin
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        model.save(profile: profile, saslPassword: saslPassword)
        dismiss()
    }
}
