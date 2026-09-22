import Foundation
import IRCKit

/// One rendered chat line — the contract consumed by both renderers
/// (WebKit theme engine and the native SwiftUI fallback) and serialized
/// to JSON for the theme JS API.
struct ChatMessage: Identifiable, Sendable, Codable {
    enum Kind: String, Sendable, Codable {
        case privmsg, notice, action, join, part, quit, nick, topic,
            mode, kick, system, error, highlight
    }

    var id: UUID = UUID()
    var kind: Kind
    var network: String
    var buffer: String          // channel name or "*status*"
    var sender: String?         // nickname (nil for system lines)
    var text: String
    var timestamp: Date
    var tags: [String: String] = [:]
    var isSelf: Bool = false
    var isHighlight: Bool = false

    /// JSON shape injected into the theme's JS (`PokeIRC.addMessage`).
    var jsonPayload: [String: Any] {
        var payload: [String: Any] = [
            "id": id.uuidString,
            "kind": kind.rawValue,
            "network": network,
            "buffer": buffer,
            "text": text,
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "self": isSelf,
            "highlight": isHighlight,
        ]
        if let sender { payload["sender"] = sender }
        if !tags.isEmpty { payload["tags"] = tags }
        return payload
    }
}

/// A chat buffer: status console, a channel, or a query.
final class ChatBuffer: ObservableObject, Identifiable {
    let id: String              // "<network>/<name>"
    let name: String            // "#chan", nick, or "*status*"
    let network: String
    @Published var messages: [ChatMessage] = []
    @Published var unread: Int = 0
    @Published var members: [String] = []   // channel member nicks (channels only)
    @Published var topic: String?

    init(network: String, name: String) {
        self.network = network
        self.name = name
        self.id = "\(network)/\(name.lowercased())"
    }

    var isChannel: Bool { name.hasPrefix("#") || name.hasPrefix("&") }

    func append(_ message: ChatMessage, selected: Bool) {
        messages.append(message)
        if !selected { unread += 1 }
    }
}
