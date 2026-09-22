import SwiftUI

/// Root state: saved networks, live connections, sidebar selection.
@MainActor
final class AppStore: ObservableObject {
    @Published var servers: [ServerConnection] = []
    @Published var selection: String?        // ChatBuffer.id
    @Published var showServerEditor = false

    private let defaultsKey = "savedServers.v1"

    init() {
        for saved in loadSaved() {
            servers.append(ServerConnection(saved: saved))
        }
    }

    // MARK: - Selection

    var selectedBuffer: ChatBuffer? {
        guard let selection else { return nil }
        for server in servers {
            if let buffer = server.buffers.first(where: { $0.id == selection }) {
                return buffer
            }
        }
        return nil
    }

    var selectedServer: ServerConnection? {
        guard let buffer = selectedBuffer else { return nil }
        return servers.first { $0.networkName == buffer.network }
    }

    func select(_ buffer: ChatBuffer) {
        selection = buffer.id
        buffer.unread = 0
    }

    // MARK: - Server management

    func addServer(_ saved: SavedServer, connect: Bool = true) {
        let conn = ServerConnection(saved: saved)
        servers.append(conn)
        persist()
        if connect { conn.connect() }
        select(conn.statusBuffer)
    }

    func removeServer(_ conn: ServerConnection) {
        conn.disconnect()
        servers.removeAll { $0.id == conn.id }
        persist()
    }

    func connectAll() {
        for conn in servers where conn.state == .disconnected {
            conn.connect()
        }
    }

    // MARK: - Persistence (saved server list only — no credentials of
    // third parties; SASL password lives here for the scaffold, a
    // Keychain store is the planned follow-up.)

    private func loadSaved() -> [SavedServer] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode([SavedServer].self, from: data)
        else { return [] }
        return saved
    }

    private func persist() {
        let saved = servers.map(\.saved)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
