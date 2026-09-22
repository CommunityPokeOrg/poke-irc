import Foundation

/// A parsed IRC message per RFC 1459 with IRCv3 message-tag support.
///
/// Wire format: `@tag1=v1;tag2 :prefix COMMAND param1 param2 :trailing param`
public struct IRCMessage: Sendable, Equatable, Hashable {
    /// IRCv3 message tags. A tag with no `=value` is stored with a `nil` value.
    public var tags: [String: String?]
    /// Source prefix (`nick!user@host`, a server name, or nil for server-originated lines).
    public var prefix: IRCPrefix?
    /// Command verb (e.g. `PRIVMSG`, `JOIN`, `001`).
    public var command: String
    /// Positional parameters; the last element may have originated as a trailing parameter.
    public var parameters: [String]

    public init(
        tags: [String: String?] = [:],
        prefix: IRCPrefix? = nil,
        command: String,
        parameters: [String] = []
    ) {
        self.tags = tags
        self.prefix = prefix
        self.command = command
        self.parameters = parameters
    }

    /// Convenience: the sender nickname when the prefix is a user prefix.
    public var senderNick: String? {
        if case .user(let user) = prefix { return user.nick }
        return nil
    }

    /// True for numeric replies (three-digit commands).
    public var isNumeric: Bool {
        command.count == 3 && command.allSatisfy { $0.isNumber }
    }

    // MARK: - IRCv3 tag value escaping

    /// Escape a tag value for the wire (`;` → `\:`, space → `\s`, `\` → `\\`, CR/LF → `\r`/`\n`).
    public static func escapeTagValue(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case ";": out += "\\:"
            case " ": out += "\\s"
            case "\\": out += "\\\\"
            case "\r": out += "\\r"
            case "\n": out += "\\n"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Reverse `escapeTagValue`.
    public static func unescapeTagValue(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        var it = value.unicodeScalars.makeIterator()
        while let scalar = it.next() {
            if scalar == "\\", let next = it.next() {
                switch next {
                case ":": out.append(";")
                case "s": out.append(" ")
                case "\\": out.append("\\")
                case "r": out.append("\r")
                case "n": out.append("\n")
                default: out.unicodeScalars.append(next)
                }
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Serialize to a single wire line (no CRLF terminator).
    public func serialized() -> String {
        var line = ""
        if !tags.isEmpty {
            line += "@"
            line += tags
                .sorted { $0.key < $1.key }
                .map { key, value in
                    if let value { return "\(key)=\(IRCMessage.escapeTagValue(value))" }
                    return key
                }
                .joined(separator: ";")
            line += " "
        }
        if let prefix {
            line += ":\(prefix.serialized) "
        }
        line += command
        if !parameters.isEmpty {
            let last = parameters.last!
            for param in parameters.dropLast() {
                line += " \(param)"
            }
            // Middle params may not contain spaces or start with ':'; quote the
            // last as trailing whenever it needs it (or to force trailing form).
            if last.isEmpty || last.contains(" ") || last.hasPrefix(":") {
                line += " :\(last)"
            } else {
                line += " \(last)"
            }
        }
        return line
    }
}

/// The originator of an IRC message.
public enum IRCPrefix: Sendable, Equatable, Hashable {
    /// `nick!user@host` (user and host are optional when absent on the wire).
    case user(nick: String, user: String?, host: String?)
    /// A bare server name.
    case server(String)

    /// Parse a prefix string. Returns nil for empty input.
    public static func parse(_ raw: String) -> IRCPrefix? {
        guard !raw.isEmpty else { return nil }
        if raw.contains("!") || raw.contains("@") {
            var nickEnd = raw.endIndex
            var user: String?
            var host: String?
            if let bang = raw.firstIndex(of: "!") {
                nickEnd = bang
                let rest = raw[raw.index(after: bang)...]
                if let at = rest.firstIndex(of: "@") {
                    user = String(rest[rest.startIndex..<at])
                    host = String(rest[rest.index(after: at)...])
                } else {
                    user = String(rest)
                }
            } else if let at = raw.firstIndex(of: "@") {
                nickEnd = at
                host = String(raw[raw.index(after: at)...])
            }
            return .user(
                nick: String(raw[raw.startIndex..<nickEnd]),
                user: user,
                host: host
            )
        }
        return .server(raw)
    }

    public var serialized: String {
        switch self {
        case .user(let nick, let user, let host):
            var s = nick
            if let user { s += "!\(user)" }
            if let host { s += "@\(host)" }
            return s
        case .server(let name):
            return name
        }
    }
}
