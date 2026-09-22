import SwiftUI

/// Sheet for adding a network.
struct ServerEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = "Libera.Chat"
    @State private var host = "irc.libera.chat"
    @State private var port = "6697"
    @State private var useTLS = true
    @State private var nickname = ""
    @State private var realname = ""
    @State private var saslAccount = ""
    @State private var saslPassword = ""
    @State private var autoJoin = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Network") {
                    TextField("Label", text: $name)
                    TextField("Host", text: $host)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("Port", text: $port)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Toggle("TLS", isOn: $useTLS)
                }
                Section("Identity") {
                    TextField("Nickname", text: $nickname)
                    TextField("Real name", text: $realname)
                }
                Section("SASL (optional)") {
                    TextField("Account", text: $saslAccount)
                    SecureField("Password", text: $saslPassword)
                }
                Section("Auto-join (comma-separated)") {
                    TextField("#channel, #other", text: $autoJoin)
                }
            }
            .navigationTitle("Add Network")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { save() }
                        .disabled(host.isEmpty || nickname.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 480)
        #endif
    }

    private func save() {
        let saved = SavedServer(
            name: name.isEmpty ? host : name,
            host: host,
            port: UInt16(port) ?? (useTLS ? 6697 : 6667),
            useTLS: useTLS,
            nickname: nickname,
            realname: realname,
            saslAccount: saslAccount,
            saslPassword: saslPassword,
            autoJoin: autoJoin
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
        store.addServer(saved)
        dismiss()
    }
}
