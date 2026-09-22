import Foundation
import IRCKit

/// Bridges one ``IRCConnection`` + ``IRCConversationStore`` into ObservableObject
/// state for SwiftUI.
@MainActor
final class ConnectionController: ObservableObject, Identifiable {
    let profile: ServerProfile
    let connection: IRCConnection
    let store = IRCConversationStore()

    @Published private(set) var phase: IRCEvent.Phase = .idle
    @Published private(set) var conversations: [IRCConversation] = []
    @Published var selectedConversationID = "server"

    private var eventTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?

    var selectedConversation: IRCConversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    var statusText: String {
        switch phase {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .registering: return "Registering…"
        case .online: return "Connected"
        case .reconnecting(let attempt, let delay):
            return "Reconnecting in \(Int(delay))s (attempt \(attempt))…"
        case .disconnected: return "Disconnected"
        case .failed(let why): return "Failed: \(why)"
        }
    }

    var isConnected: Bool {
        if case .online = phase { return true }
        return false
    }

    init(profile: ServerProfile) {
        self.profile = profile
        self.connection = IRCConnection(config: profile.ircConfiguration)
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.connection.events {
                await self.ingest(event)
            }
        }
        updateTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in self.store.updates {
                self.conversations = snapshot
            }
        }
    }

    private func ingest(_ event: IRCEvent) async {
        if case .phaseChanged(let phase) = event {
            self.phase = phase
        }
        await store.ingest(event)
    }

    func connect() async {
        await connection.start()
    }

    func disconnect() async {
        await connection.stop()
    }

    /// Route a composer line: `/join`, `/msg`, `/me`, `/part`, `/nick`,
    /// `/notice`, `/raw`, or plain text to the current conversation.
    func submit(_ input: String, to conversationID: String) async {
        let target = conversationTarget(conversationID)
        do {
            if input.hasPrefix("/") {
                try await handleSlashCommand(input, fallbackTarget: target)
            } else if let target {
                try await connection.privmsg(to: target, text: input)
            }
        } catch {
            await store.ingest(.error(.sendFailed(String(describing: error))))
        }
    }

    private func conversationTarget(_ id: String) -> String? {
        conversations.first { $0.id == id }.map { $0.title }
    }

    private func handleSlashCommand(_ input: String, fallbackTarget: String?) async throws {
        let parts = input.dropFirst().split(separator: " ", maxSplits: 2)
        guard let cmd = parts.first?.lowercased() else { return }
        let arg1 = parts.count > 1 ? String(parts[1]) : nil
        let rest = parts.count > 2 ? String(parts[2]) : nil

        switch cmd {
        case "join", "j":
            if let arg1 { try await connection.join(arg1) }
        case "part", "leave":
            try await connection.part(arg1 ?? fallbackTarget ?? "", reason: rest)
        case "msg", "query":
            if let arg1, let rest { try await connection.privmsg(to: arg1, text: rest) }
        case "notice":
            if let arg1, let rest { try await connection.notice(to: arg1, text: rest) }
        case "me":
            if let fallbackTarget, let text = [arg1, rest].compactMap({ $0 }).joined(separator: " ") as String?,
               !text.isEmpty {
                try await connection.action(to: fallbackTarget, text: text)
            }
        case "nick":
            if let arg1 { try await connection.nick(arg1) }
        case "topic":
            if let channel = arg1 ?? fallbackTarget, let rest {
                try await connection.send(raw: "TOPIC \(channel) :\(rest)")
            }
        case "quit":
            try await connection.quit(arg1)
        case "raw", "quote":
            if let rest = [arg1, rest].compactMap({ $0 }).joined(separator: " ") as String?,
               !rest.isEmpty {
                try await connection.send(raw: rest)
            }
        default:
            await store.ingest(.error(.sendFailed("Unknown command /\(cmd)")))
        }
    }

    func markConversationRead(_ id: String) async {
        await store.markRead(id)
        conversations = await store.snapshot
    }
}
