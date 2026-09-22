import Foundation

/// Tracked state for one channel.
public struct IRCChannelState: Sendable, Equatable {
    public var name: String
    public var topic: String?
    public var members: Set<String>
    public var modes: [String]

    public init(name: String) {
        self.name = name
        self.topic = nil
        self.members = []
        self.modes = []
    }
}

/// Mutable per-connection state: our nick, joined channels, members, topics.
/// Fed by inbound ``IRCMessage``s; consulted when rejoining after reconnect.
public actor IRCSessionState {
    public private(set) var nickname: String
    public private(set) var channels: [String: IRCChannelState] = [:]
    public private(set) var isRegistered = false

    private let caseMapping = IRCCaseMapping.rfc1459
    private var pendingNames: [String: [String]] = [:]

    public init(nickname: String) {
        self.nickname = nickname
    }

    private func key(for channel: String) -> String {
        caseMapping.lowercase(channel)
    }

    /// Apply one inbound message; returns transient data the caller may emit
    /// (e.g. end-of-NAMES member list).
    @discardableResult
    public func apply(_ message: IRCMessage) -> [String: [String]] {
        var namesDone: [String: [String]] = [:]
        let nick = message.senderNick ?? ""
        switch message.command {
        case "001":
            isRegistered = true
            if let assigned = message.parameters.first {
                nickname = assigned
            }
        case "JOIN":
            guard let channel = message.parameters.first else { break }
            let k = key(for: channel)
            if caseMapping.equal(nick, nickname) {
                var ch = channels[k] ?? IRCChannelState(name: channel)
                ch.members.insert(nickname)
                channels[k] = ch
            } else {
                channels[k]?.members.insert(nick)
            }
        case "PART", "KICK":
            let channel = message.parameters.first ?? ""
            let k = key(for: channel)
            if message.command == "KICK", message.parameters.count > 1 {
                let target = message.parameters[1]
                if caseMapping.equal(target, nickname) {
                    channels.removeValue(forKey: k)
                } else {
                    channels[k]?.members.remove(target)
                }
            } else if caseMapping.equal(nick, nickname) {
                channels.removeValue(forKey: k)
            } else {
                channels[k]?.members.remove(nick)
            }
        case "QUIT":
            for k in channels.keys {
                channels[k]?.members.remove(nick)
            }
        case "NICK":
            guard let newNick = message.parameters.first else { break }
            if caseMapping.equal(nick, nickname) {
                nickname = newNick
            }
            for k in channels.keys where channels[k]?.members.remove(nick) != nil {
                channels[k]?.members.insert(newNick)
            }
        case "TOPIC":
            guard message.parameters.count >= 2 else { break }
            let k = key(for: message.parameters[0])
            var ch = channels[k] ?? IRCChannelState(name: message.parameters[0])
            ch.topic = message.parameters[1]
            channels[k] = ch
        case "332": // RPL_TOPIC
            guard message.parameters.count >= 3 else { break }
            let k = key(for: message.parameters[1])
            var ch = channels[k] ?? IRCChannelState(name: message.parameters[1])
            ch.topic = message.parameters[2]
            channels[k] = ch
        case "353": // RPL_NAMREPLY: me (=/ * / @) channel :names
            guard message.parameters.count >= 4 else { break }
            let channel = message.parameters[2]
            let k = key(for: channel)
            var ch = channels[k] ?? IRCChannelState(name: channel)
            let names = message.parameters[3]
                .split(separator: " ")
                .map { raw -> String in
                    var s = String(raw)
                    while let first = s.first, "@+%~&".contains(first) {
                        s.removeFirst()
                    }
                    return s
                }
            pendingNames[k, default: []] += names
            ch.members.formUnion(names)
            channels[k] = ch
        case "366": // RPL_ENDOFNAMES
            guard message.parameters.count >= 2 else { break }
            let k = key(for: message.parameters[1])
            if let names = pendingNames.removeValue(forKey: k) {
                namesDone[channels[k]?.name ?? message.parameters[1]] = names
            }
        case "324": // RPL_CHANNELMODEIS
            guard message.parameters.count >= 3 else { break }
            let k = key(for: message.parameters[1])
            var ch = channels[k] ?? IRCChannelState(name: message.parameters[1])
            ch.modes = Array(message.parameters.dropFirst(2))
            channels[k] = ch
        default:
            break
        }
        return namesDone
    }

    /// Snapshot of joined channel names (for rejoin after reconnect).
    public var joinedChannels: [String] {
        channels.values.map(\.name)
    }

    public func reset() {
        channels = [:]
        pendingNames = [:]
        isRegistered = false
    }
}
