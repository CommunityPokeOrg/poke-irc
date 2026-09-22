import Foundation

/// CTCP (\x01-delimited) message helpers.
public enum IRCCTCP {
    public static let delimiter: Character = "\u{01}"

    /// A decoded CTCP payload inside a PRIVMSG/NOTICE body.
    public struct Payload: Sendable, Equatable {
        public var command: String
        public var argument: String?
    }

    /// Extract a CTCP payload if `text` is a single \x01-wrapped message.
    /// Returns nil for plain text.
    public static func payload(in text: String) -> Payload? {
        guard text.hasPrefix("\u{01}"), text.hasSuffix("\u{01}"), text.count >= 2 else {
            return nil
        }
        let inner = text.dropFirst().dropLast()
        guard let command = inner.split(separator: " ", maxSplits: 1).first else {
            return nil
        }
        let rest = inner.dropFirst(command.count).drop(while: { $0 == " " })
        return Payload(
            command: String(command).uppercased(),
            argument: rest.isEmpty ? nil : String(rest)
        )
    }

    /// Wrap a payload in CTCP delimiters for sending.
    public static func encode(_ command: String, argument: String? = nil) -> String {
        if let argument, !argument.isEmpty {
            return "\u{01}\(command) \(argument)\u{01}"
        }
        return "\u{01}\(command)\u{01}"
    }
}

/// IRC case mapping for nickname/channel comparisons (RFC 1459: `{}|^` are
/// lowercase of `[]\\~`). `strict-rfc1459` drops the `^`/`~` mapping.
public enum IRCCaseMapping: Sendable {
    case rfc1459
    case strictRFC1459
    case ascii

    public func lowercase(_ string: String) -> String {
        switch self {
        case .rfc1459:
            return String(string.map { ch in
                switch ch {
                case "[": return "{"
                case "]": return "}"
                case "\\": return "|"
                case "~": return "^"
                default: return Character(ch.lowercased())
                }
            })
        case .strictRFC1459:
            return String(string.map { ch in
                switch ch {
                case "[": return "{"
                case "]": return "}"
                case "\\": return "|"
                default: return Character(ch.lowercased())
                }
            })
        case .ascii:
            return string.lowercased()
        }
    }

    public func equal(_ a: String, _ b: String) -> Bool {
        lowercase(a) == lowercase(b)
    }
}
