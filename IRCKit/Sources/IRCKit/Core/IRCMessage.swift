import Foundation

/// A single IRC protocol message: optional IRCv3 message tags, optional
/// source prefix, a command (verb or numeric), and ordered parameters.
public struct IRCMessage: Sendable, Equatable, Hashable {
    /// IRCv3 message tags. Values are unescaped; a tag with no value maps to "".
    public var tags: [String: String]
    /// Optional message source ("nick!user@host" or server name).
    public var prefix: String?
    /// The command verb (e.g. "PRIVMSG") or three-digit numeric (e.g. "001").
    public var command: String
    /// Ordered command parameters; the last element is the trailing parameter
    /// when it was colon-prefixed on the wire.
    public var parameters: [String]

    public init(
        tags: [String: String] = [:],
        prefix: String? = nil,
        command: String,
        parameters: [String] = []
    ) {
        self.tags = tags
        self.prefix = prefix
        self.command = command
        self.parameters = parameters
    }
}

public extension IRCMessage {
    /// Nick portion of the prefix, when the prefix is a hostmask.
    var nickname: String? {
        guard let prefix else { return nil }
        return prefix.split(separator: "!").first.map(String.init) ?? prefix
    }

    /// Value of the `server-time` tag parsed as a Date (IRCv3 server-time).
    /// The tag is an ISO-8601 timestamp like `2026-09-22T16:54:00.123Z`.
    var serverTime: Date? {
        guard let raw = tags["server-time"] else { return nil }
        return IRCFormat.parseServerTime(raw)
    }

    /// Whether the command is a three-digit numeric reply.
    var isNumeric: Bool {
        command.count == 3 && command.allSatisfy(\.isNumber)
    }

    /// The trailing parameter, if present.
    var trailing: String? { parameters.last }
}

/// Shared formatting helpers.
public enum IRCFormat {
    /// Parses an IRCv3 `server-time` value (ISO-8601, always UTC).
    public static func parseServerTime(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        // Some servers omit fractional seconds.
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    /// Formats a Date as an IRCv3 `server-time` value.
    public static func formatServerTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
