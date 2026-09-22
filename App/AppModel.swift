import Foundation
import IRCKit

/// Root app state: saved profiles, live connections, and the currently
/// selected server.
@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [ServerProfile] = []
    @Published private(set) var controllers: [UUID: ConnectionController] = [:]
    @Published var selectedProfileID: ServerProfile.ID?
    @Published var editingProfile: ServerProfile?
    @Published var showingNewServer = false

    private let profileStore = ServerProfileStore()

    init() {
        profiles = profileStore.load()
    }

    // MARK: - Profiles

    func save(profile: ServerProfile, saslPassword: String = "") {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        profileStore.save(profiles)
        if !saslPassword.isEmpty {
            KeychainPasswordStore.write(
                account: profile.saslAccount,
                host: profile.host,
                password: saslPassword
            )
        }
    }

    func delete(profile: ServerProfile) {
        if let controller = controllers[profile.id] {
            Task { await controller.disconnect() }
        }
        controllers.removeValue(forKey: profile.id)
        profiles.removeAll { $0.id == profile.id }
        profileStore.save(profiles)
        if selectedProfileID == profile.id {
            selectedProfileID = nil
        }
        if !profile.saslAccount.isEmpty {
            KeychainPasswordStore.delete(account: profile.saslAccount, host: profile.host)
        }
    }

    // MARK: - Connections

    func controller(for profile: ServerProfile) -> ConnectionController {
        if let existing = controllers[profile.id] { return existing }
        let controller = ConnectionController(profile: profile)
        controllers[profile.id] = controller
        return controller
    }

    func connect(_ profile: ServerProfile) async {
        selectedProfileID = profile.id
        await controller(for: profile).connect()
    }

    func disconnect(_ profile: ServerProfile) async {
        await controller(for: profile).disconnect()
    }
}
