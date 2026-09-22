import Foundation
import SwiftUI
import IRCKit

/// One configured network entry (persisted).
struct SavedServer: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String            // display label, e.g. "Libera"
    var host: String
    var port: UInt16 = 6697
    var useTLS: Bool = true
    var nickname: String
    var realname: String = ""
    var saslAccount: String = ""
    var saslPassword: String = ""
    var autoJoin: [String] = []
}

/// A live network connection: owns an `IRCSession`, keeps buffers,
/// and translates protocol events into `ChatMessage`s.
@MainActor
final class ServerConnection: ObservableObject, Identifiable {
    let id: UUID
    @Published var state: IRCSessionState = .disconnected
    @Published var nickname: String
    @Published var capabilities: Set<String> = []
    @Published var buffers: [ChatBuffer] = []
    @Published var statusError: String?

    let saved: SavedServer
    private var session: IRCSession?
    private var pumpTask: Task<Void, Never>?
    private var bufferIndex: [String: ChatBuffer] = [:]

    var networkName: String { saved.name }

    init(saved: SavedServer) {
        self.saved = saved
        self.id = saved.id
        self.nickname = saved.nickname
        _ = buffer(named: "*status*")   // always exists
    }

    var statusBuffer: ChatBuffer { buffer(named: "*status*") }

    func buffer(named name: String) -> ChatBuffer {
        if let existing = bufferIndex[name.lowercased()] { return existing }
        let created = ChatBuffer(network: networkName, name: name)
        bufferIndex[name.lowercased()] = created
        buffers.append(created)
        return created
    }

    func connect() {
        guard session == nil else { return }
        let sasl: SASLCredentials? = saved.saslAccount.isEmpty ? nil : SASLCredentials(
            account: saved.saslAccount, password: saved.saslPassword)
        let config = IRCServerConfig(
            host: saved.host, port: saved.port, useTLS: saved.useTLS,
            nickname: saved.nickname,
            realname: saved.realname.isEmpty ? saved.nickname : saved.realname,
            sasl: sasl)
        let session = IRCSession(config: config)
        self.session = session
        pumpTask = Task { [weak self] in
            await self?.pump(session: session)
        }
        Task {
            do { try await session.connect() }
            catch {
                self.statusError = "\(error)"
                self.post(.system, "*status*", "Connect failed: \(error)")
            }
        }
    }

    func disconnect() {
        pumpTask?.cancel()
        Task { await session?.disconnect() }
    }

    func send(_ text: String, to buffer: ChatBuffer) {
        guard let session else { return }
        if text.hasPrefix("/") {
            handleSlashCommand(text, buffer: buffer, session: session)
            return
        }
        Task { try? await session.privmsg(buffer.name, text) }
        post(.privmsg, buffer.name, text, sender: nickname, self: true)
    }

    // MARK: - Event pump

    private func pump(session: IRCSession) async {
        for await event in session.events {
            switch event {
            case .stateChanged(let newState):
                state = newState
                if newState == .online {
                    for channel in saved.autoJoin {
                        Task { try? await session.join(channel) }
                    }
                }
            case .capabilities(let caps):
                capabilities = caps
            case .registered(let nick):
                nickname = nick
                post(.system, "*status*", "Connected as \(nick)")
            case .message(let message):
                route(message, session: session)
            case .closed(let error):
                state = .disconnected
                statusError = error
                post(.system, "*status*", error.map { "Disconnected: \($0)" } ?? "Disconnected")
            }
        }
    }

    // MARK: - Routing

    private func route(_ m: IRCMessage, session: IRCSession) {
        switch m.command {
        case "PRIVMSG", "NOTICE":
            guard let target = m.parameters.first, let text = m.trailing else { return }
            let isPrivate = !target.hasPrefix("#") && !target.hasPrefix("&")
            let bufferName = isPrivate ? (m.nickname ?? target) : target
            let kind: ChatMessage.Kind = m.command == "NOTICE" ? .notice
                : (text.hasPrefix("\u{1}ACTION") ? .action : .privmsg)
            let clean = kind == .action
                ? text.replacingOccurrences(of: "\u{1}", with: "")
                    .replacingOccurrences(of: "ACTION ", with: "")
                : text
            let highlight = clean.localizedCaseInsensitiveContains(nickname)
            post(kind, bufferName, clean, sender: m.nickname,
                 tags: m.tags, highlight: highlight, timestamp: m.serverTime)

        case "JOIN":
            guard let channel = m.trailing ?? m.parameters.first else { return }
            if m.nickname == nickname {
                post(.join, channel, "You joined \(channel)", sender: nil,
                     timestamp: m.serverTime)
            } else {
                post(.join, channel, "\(m.nickname ?? "?") joined", sender: m.nickname,
                     timestamp: m.serverTime)
            }
            addMember(m.nickname, to: channel)

        case "PART":
            guard let channel = m.parameters.first else { return }
            post(.part, channel, "\(m.nickname ?? "?") left", sender: m.nickname,
                 timestamp: m.serverTime)
            removeMember(m.nickname, from: channel)

        case "QUIT":
            for b in buffers where b.members.contains(m.nickname ?? "") {
                post(.quit, b.name, "\(m.nickname ?? "?") quit", sender: m.nickname,
                     timestamp: m.serverTime)
            }

        case "NICK":
            guard let newNick = m.trailing else { return }
            if m.nickname == nickname { nickname = newNick }
            for b in buffers {
                if let idx = b.members.firstIndex(of: m.nickname ?? "") {
                    b.members[idx] = newNick
                }
            }

        case "TOPIC":
            guard let channel = m.parameters.first else { return }
            let topic = m.trailing ?? ""
            buffer(named: channel).topic = topic
            post(.topic, channel, "Topic: \(topic)", sender: m.nickname,
                 timestamp: m.serverTime)

        case "KICK":
            guard let channel = m.parameters.first, let victim = m.parameters.dropFirst().first
            else { return }
            post(.kick, channel, "\(victim) was kicked by \(m.nickname ?? "?")",
                 sender: m.nickname, timestamp: m.serverTime)
            removeMember(victim, from: channel)

        case "353":  // RPL_NAMREPLY — names list
            if let channel = m.parameters.dropLast().last {
                let names = (m.trailing ?? "")
                    .split(separator: " ")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "@%+&~")) }
                buffer(named: channel).members.append(contentsOf: names)
            }

        case "332":  // RPL_TOPIC
            if let channel = m.parameters.dropLast().last {
                buffer(named: channel).topic = m.trailing
            }

        case "MODE", "324":
            if let target = m.parameters.first {
                post(.mode, target, m.parameters.dropFirst().joined(separator: " "),
                     sender: m.nickname, timestamp: m.serverTime)
            }

        case "ERROR":
            post(.error, "*status*", m.trailing ?? "Server error",
                 timestamp: m.serverTime)

        case "CAP", "AUTHENTICATE", "PONG":
            break  // handled by the engine / noise

        default:
            if m.isNumeric {
                let text = m.parameters.dropFirst().joined(separator: " ")
                post(.system, "*status*", "[\(m.command)] \(text)", timestamp: m.serverTime)
            } else {
                post(.system, "*status*", "\(m.command) \(m.parameters.joined(separator: " "))",
                     timestamp: m.serverTime)
            }
        }
    }

    private func addMember(_ nick: String?, to channel: String) {
        guard let nick, !nick.isEmpty else { return }
        let b = buffer(named: channel)
        if !b.members.contains(nick) { b.members.append(nick) }
    }

    private func removeMember(_ nick: String?, from channel: String) {
        guard let nick else { return }
        buffer(named: channel).members.removeAll { $0 == nick }
    }

    private func handleSlashCommand(_ text: String, buffer: ChatBuffer,
                                    session: IRCSession) {
        let parts = text.dropFirst().split(separator: " ", maxSplits: 1)
        let cmd = parts.first?.lowercased() ?? ""
        let rest = parts.count > 1 ? String(parts[1]) : ""
        Task {
            switch cmd {
            case "join", "j": try? await session.join(rest)
            case "part": try? await session.part(rest.isEmpty ? buffer.name : rest)
            case "msg", "query":
                let kv = rest.split(separator: " ", maxSplits: 1)
                if kv.count == 2 {
                    try? await session.privmsg(String(kv[0]), String(kv[1]))
                    post(.privmsg, String(kv[0]), String(kv[1]), sender: nickname, self: true)
                }
            case "me":
                try? await session.privmsg(buffer.name, "\u{1}ACTION \(rest)\u{1}")
                post(.action, buffer.name, rest, sender: nickname, self: true)
            case "nick": try? await session.nick(rest)
            case "topic": try? await session.send(raw: "TOPIC \(buffer.name) :\(rest)")
            case "quit": await session.disconnect(quitMessage: rest.isEmpty ? "PokeIRC" : rest)
            case "raw", "quote": try? await session.send(raw: rest)
            default:
                post(.error, buffer.name, "Unknown command /\(cmd)")
            }
        }
    }

    private func post(_ kind: ChatMessage.Kind, _ bufferName: String, _ text: String,
                      sender: String? = nil, tags: [String: String] = [:],
                      highlight: Bool = false, self isSelf: Bool = false,
                      timestamp: Date? = nil) {
        let message = ChatMessage(
            kind: highlight ? .highlight : kind,
            network: networkName, buffer: bufferName, sender: sender, text: text,
            timestamp: timestamp ?? Date(), tags: tags,
            isSelf: isSelf, isHighlight: highlight)
        buffer(named: bufferName).append(message, selected: false)
    }
}
