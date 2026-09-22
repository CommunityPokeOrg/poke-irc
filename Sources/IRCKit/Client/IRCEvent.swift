import Foundation

/// A chat-oriented message derived from PRIVMSG/NOTICE (or CTCP ACTION).
public struct IRCChatMessage: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case message
        case notice
        case action
    }

    public let id: UUID
    /// Channel name for channel traffic, or the peer nick for direct messages.
    public let conversationKey: String
    public let sender: String
    public let text: String
    /// `server-time` when present, else receipt time.
    public let timestamp: Date
    /// True when this is our own message echoed back (echo-message) or sent locally.
    public let isOutgoing: Bool
    public let kind: Kind
    /// IRCv3 account tag of the sender when present.
    public let account: String?

    public init(
        id: UUID = UUID(),
        conversationKey: String,
        sender: String,
        text: String,
        timestamp: Date = Date(),
        isOutgoing: Bool = false,
        kind: Kind,
        account: String? = nil
    ) {
        self.id = id
        self.conversationKey = conversationKey
        self.sender = sender
        self.text = text
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.kind = kind
        self.account = account
    }
}

/// Lifecycle + traffic events emitted by ``IRCConnection``.
public enum IRCEvent: Sendable {
    public enum Phase: Sendable, Equatable {
        case idle
        case connecting
        case registering
        case online
        case reconnecting(attempt: Int, delay: TimeInterval)
        case disconnected
        case failed(String)
    }

    /// Connection lifecycle transition.
    case phaseChanged(Phase)
    /// Channel or direct PRIVMSG.
    case message(IRCChatMessage)
    /// A NOTICE (kind carried on the chat message).
    case notice(IRCChatMessage)
    /// CTCP ACTION (`/me`).
    case action(IRCChatMessage)
    /// We joined a channel (bySelf) or another user joined.
    case userJoined(channel: String, nick: String, bySelf: Bool)
    /// A user parted or was kicked (or quit, when channel is nil).
    case userLeft(channel: String?, nick: String, reason: String?)
    /// Our own or another user's nick changed.
    case nickChanged(from: String, to: String)
    /// Topic set/learned for a channel.
    case topicChanged(channel: String, topic: String)
    /// NAMES reply accumulated for a channel (fires once at end of NAMES).
    case namesReply(channel: String, names: [String])
    /// Capability negotiation result.
    case capabilities(available: [String], enabled: [String])
    /// SASL outcome.
    case saslStatus(success: Bool, detail: String)
    /// Server numerics and other unhandled lines, for the server log view.
    case serverLine(IRCMessage)
    /// A send or transport error worth surfacing to the user.
    case error(IRCError)
}
