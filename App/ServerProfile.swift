import Foundation
import IRCKit

/// Persisted connection settings for one IRC network.
struct ServerProfile: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: Int = 6697
    var useTLS: Bool = true
    var nickname: String
    var username: String = ""
    var realname: String = ""
    var saslAccount: String = ""
    /// SASL password lives in the Keychain, never on disk.
    var autoJoinChannels: [String] = []

    var displayName: String {
        name.isEmpty ? host : name
    }

    var ircConfiguration: IRCConfiguration {
        IRCConfiguration(
            host: host,
            port: UInt16(clamping: port),
            useTLS: useTLS,
            nickname: nickname,
            username: username.isEmpty ? nickname : username,
            realname: realname.isEmpty ? nickname : realname,
            sasl: saslAccount.isEmpty ? nil : SASLCredentials(
                account: saslAccount,
                password: KeychainPasswordStore.read(account: saslAccount, host: host) ?? ""
            ),
            autoJoinChannels: autoJoinChannels
        )
    }
}

/// JSON file persistence under Application Support.
final class ServerProfileStore: Sendable {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.appendingPathComponent("PokeIRC", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("profiles.json")
        }
    }

    func load() -> [ServerProfile] {
        guard let data = try? Data(contentsOf: fileURL),
              let profiles = try? JSONDecoder().decode([ServerProfile].self, from: data)
        else { return [] }
        return profiles
    }

    func save(_ profiles: [ServerProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Thin Keychain wrapper for SASL credentials (Apple platforms only).
enum KeychainPasswordStore {
    #if canImport(Security)
    private static func query(account: String, host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.communitypoke.poke-irc.sasl.\(host)",
            kSecAttrAccount as String: account
        ]
    }

    static func read(account: String, host: String) -> String? {
        var q = query(account: account, host: host)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(account: String, host: String, password: String) -> Bool {
        let q = query(account: account, host: host)
        SecItemDelete(q as CFDictionary)
        guard !password.isEmpty else { return true }
        var insert = q
        insert[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String, host: String) {
        SecItemDelete(query(account: account, host: host) as CFDictionary)
    }
    #else
    static func read(account: String, host: String) -> String? { nil }
    @discardableResult
    static func write(account: String, host: String, password: String) -> Bool { false }
    static func delete(account: String, host: String) {}
    #endif
}
