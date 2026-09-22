import Foundation

/// Serializes `IRCMessage` values into wire-format lines.
public enum IRCMessageSerializer {

    /// Maximum wire length in bytes (excluding CRLF), per RFC 1459.
    /// Messages carrying tags may exceed this when `message-tags` was negotiated.
    public static let maxLineBytes = 510

    /// Serializes a message to a single line (no CRLF terminator).
    /// The last parameter is colon-prefixed when it contains spaces,
    /// is empty, or starts with ':'.
    public static func serialize(_ message: IRCMessage) -> String {
        var parts: [String] = []

        if !message.tags.isEmpty {
            let tagString = message.tags
                .sorted { $0.key < $1.key }
                .map { key, value in value.isEmpty ? key : "\(key)=\(escapeTagValue(value))" }
                .joined(separator: ";")
            parts.append("@\(tagString)")
        }

        if let prefix = message.prefix, !prefix.isEmpty {
            parts.append(":\(prefix)")
        }

        parts.append(message.command)

        var parameters = message.parameters
        if let last = parameters.last,
           last.isEmpty || last.contains(" ") || last.hasPrefix(":") {
            parameters[parameters.count - 1] = ":\(last)"
        }
        parts.append(contentsOf: parameters)

        return parts.joined(separator: " ")
    }

    /// Serializes and appends the CRLF terminator.
    public static func serializeLine(_ message: IRCMessage) -> String {
        serialize(message) + "\r\n"
    }

    /// Encodes IRCv3 tag-value escapes.
    public static func escapeTagValue(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case ";": result.append("\\:")
            case " ": result.append("\\s")
            case "\\": result.append("\\\\")
            case "\r": result.append("\\r")
            case "\n": result.append("\\n")
            default: result.append(character)
            }
        }
        return result
    }
}
