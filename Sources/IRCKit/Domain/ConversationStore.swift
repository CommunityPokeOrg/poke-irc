import Foundation

/// One rendered line in a conversation.
public struct ChatLine: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case message
        case notice
        case action
        case event       // joins/parts/nicks/topics
        case error
        case status      // connection lifecycle notes
    }

    public let id: UUID
    public let timestamp: Date
    public let sender: String
    public let text: String
    public let kind: Kind
    public let isOutgoing: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sender: String,
        text: String,
        kind: Kind,
        isOutgoing: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sender = sender
        self.text = text
        self.kind = kind
        self.isOutgoing = isOutgoing
    }
}

/// A channel buffer, a DM, or the server log.
public struct IRCConversation: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case server
        case channel
        case direct
    }

    /// Stable identity: `server`, a case-normalized channel name, or peer nick.
    public let id: String
    public var title: String
    public var kind: Kind
    public var lines: [ChatLine]
    public var unreadCount: Int
    public var topic: String?
    public var members: [String]

    public init(id: String, title: String, kind: Kind) {
        self.id = id
        self.title = title
        self.kind = kind
        self.lines = []
        self.unreadCount = 0
        self.topic = nil
        self.members = []
    }
}

/// Turns ``IRCEvent``s into an ordered conversation list — the testable
/// view-model layer between the engine and SwiftUI.
public actor IRCConversationStore {
    private let caseMapping = IRCCaseMapping.rfc1459
    private var conversations: [String: IRCConversation] = [:]
    private var order: [String] = []
    private var selfNick = ""

    /// Stream of snapshot updates (emitted after each ingested event).
    public let updates: AsyncStream<[IRCConversation]>
    private let continuation: AsyncStream<[IRCConversation]>.Continuation

    public init() {
        var cont: AsyncStream<[IRCConversation]>.Continuation!
        updates = AsyncStream { cont = $0 }
        continuation = cont
        conversations["server"] = IRCConversation(id: "server", title: "Server", kind: .server)
        order = ["server"]
    }

    public var snapshot: [IRCConversation] {
        order.compactMap { conversations[$0] }
    }

    public func conversation(id: String) -> IRCConversation? {
        conversations[id]
    }

    public func markRead(_ id: String) {
        conversations[id]?.unreadCount = 0
    }

    public func ingest(_ event: IRCEvent) {
        switch event {
        case .phaseChanged(let phase):
            let text: String
            switch phase {
            case .connecting: text = "Connecting…"
            case .registering: text = "Registering…"
            case .online: text = "Connected."
            case .reconnecting(let attempt, let delay):
                text = "Connection lost — reconnecting in \(Int(delay))s (attempt \(attempt))"
            case .disconnected: text = "Disconnected."
            case .failed(let why): text = "Failed: \(why)"
            case .idle: return
            }
            append(to: "server", line: ChatLine(sender: "", text: text, kind: .status))

        case .message(let m):
            appendChat(m, kind: .message)
        case .notice(let m):
            appendChat(m, kind: .notice)
        case .action(let m):
            appendChat(m, kind: .action)

        case .userJoined(let channel, let nick, let bySelf):
            let key = channelKey(channel)
            ensure(id: key, title: channel, kind: .channel)
            if !nick.isEmpty {
                var conv = conversations[key]!
                if !conv.members.contains(nick) { conv.members.append(nick) }
                conv.members.sort()
                conversations[key] = conv
            }
            append(to: key, line: ChatLine(
                sender: nick,
                text: bySelf ? "you joined \(channel)" : "\(nick) joined",
                kind: .event
            ))

        case .userLeft(let channel, let nick, let reason):
            if let channel {
                let key = channelKey(channel)
                conversations[key]?.members.removeAll { caseMapping.equal($0, nick) }
                append(to: key, line: ChatLine(
                    sender: nick,
                    text: "\(nick) left\(reason.map { " (\($0))" } ?? "")",
                    kind: .event
                ))
            } else {
                append(to: "server", line: ChatLine(
                    sender: nick,
                    text: "\(nick) quit\(reason.map { " (\($0))" } ?? "")",
                    kind: .event
                ))
            }

        case .nickChanged(let from, let to):
            if caseMapping.equal(from, selfNick) { selfNick = to }
            for id in conversations.keys {
                if var conv = conversations[id], conv.members.contains(from) {
                    conv.members.removeAll { caseMapping.equal($0, from) }
                    conv.members.append(to)
                    conv.members.sort()
                    conversations[id] = conv
                    append(to: id, line: ChatLine(
                        sender: from, text: "\(from) is now \(to)", kind: .event
                    ))
                }
            }
            if selfNick.isEmpty { selfNick = to }

        case .topicChanged(let channel, let topic):
            let key = channelKey(channel)
            conversations[key]?.topic = topic
            append(to: key, line: ChatLine(
                sender: "", text: "Topic: \(topic)", kind: .event
            ))

        case .namesReply(let channel, let names):
            let key = channelKey(channel)
            conversations[key]?.members = names.sorted()

        case .capabilities(let available, let enabled):
            var parts: [String] = []
            if !available.isEmpty { parts.append("available: \(available.joined(separator: ", "))") }
            if !enabled.isEmpty { parts.append("enabled: \(enabled.joined(separator: ", "))") }
            append(to: "server", line: ChatLine(
                sender: "", text: "Caps \(parts.joined(separator: "; "))", kind: .status
            ))

        case .saslStatus(let success, let detail):
            append(to: "server", line: ChatLine(
                sender: "",
                text: success ? "SASL authenticated." : "SASL failed: \(detail)",
                kind: success ? .status : .error
            ))

        case .serverLine(let message):
            append(to: "server", line: ChatLine(
                sender: message.prefix?.serialized ?? "",
                text: ([message.command] + message.parameters).joined(separator: " "),
                kind: .status
            ))

        case .error(let error):
            append(to: "server", line: ChatLine(
                sender: "", text: error.localizedDescription, kind: .error
            ))
        }
        continuation.yield(snapshot)
    }

    // MARK: - Helpers

    private func channelKey(_ channel: String) -> String {
        "channel:\(caseMapping.lowercase(channel))"
    }

    private func dmKey(_ nick: String) -> String {
        "dm:\(caseMapping.lowercase(nick))"
    }

    private func ensure(id: String, title: String, kind: IRCConversation.Kind) {
        if conversations[id] == nil {
            conversations[id] = IRCConversation(id: id, title: title, kind: kind)
            order.append(id)
        }
    }

    private func appendChat(_ m: IRCChatMessage, kind: ChatLine.Kind) {
        let isChannel = m.conversationKey.hasPrefix("#") || m.conversationKey.hasPrefix("&")
        let id = isChannel ? channelKey(m.conversationKey) : dmKey(m.conversationKey)
        ensure(id: id, title: m.conversationKey, kind: isChannel ? .channel : .direct)
        append(to: id, line: ChatLine(
            timestamp: m.timestamp,
            sender: m.sender,
            text: m.text,
            kind: kind,
            isOutgoing: m.isOutgoing
        ))
        if !m.isOutgoing {
            conversations[id]?.unreadCount += 1
        }
    }

    private func append(to id: String, line: ChatLine) {
        if conversations[id] == nil {
            ensure(id: id, title: id, kind: id == "server" ? .server : .channel)
        }
        conversations[id]?.lines.append(line)
    }
}
