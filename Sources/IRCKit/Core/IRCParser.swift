import Foundation

/// Splits wire bytes into lines and parses each line into an ``IRCMessage``.
public enum IRCParser {

    public enum ParseError: Error, Sendable, Equatable {
        case emptyLine
        case missingCommand
    }

    /// Parse one wire line (already stripped of CRLF) into an ``IRCMessage``.
    public static func parse(_ line: String) throws -> IRCMessage {
        var rest = line[...]
        guard !rest.isEmpty else { throw ParseError.emptyLine }

        var tags: [String: String?] = [:]
        if rest.hasPrefix("@") {
            guard let space = rest.firstIndex(of: " ") else {
                throw ParseError.missingCommand
            }
            let tagSection = rest[rest.index(after: rest.startIndex)..<space]
            for entry in tagSection.split(separator: ";") {
                if let eq = entry.firstIndex(of: "=") {
                    let key = String(entry[entry.startIndex..<eq])
                    let rawValue = String(entry[entry.index(after: eq)...])
                    tags[key] = IRCMessage.unescapeTagValue(rawValue)
                } else {
                    // Store a *present-but-valueless* tag: assign String?.none
                    // (literal nil would remove the key entirely).
                    tags[String(entry)] = String?.none
                }
            }
            rest = rest[rest.index(after: space)...]
        }

        var prefix: IRCPrefix?
        if rest.hasPrefix(":") {
            guard let space = rest.firstIndex(of: " ") else {
                throw ParseError.missingCommand
            }
            prefix = IRCPrefix.parse(String(rest[rest.index(after: rest.startIndex)..<space]))
            rest = rest[rest.index(after: space)...]
        }

        var parameters: [String] = []
        var command = ""
        while !rest.isEmpty {
            if rest.hasPrefix(":") {
                parameters.append(String(rest.dropFirst()))
                rest = rest[rest.endIndex...]
                break
            }
            if let space = rest.firstIndex(of: " ") {
                if command.isEmpty {
                    command = String(rest[rest.startIndex..<space])
                } else {
                    parameters.append(String(rest[rest.startIndex..<space]))
                }
                rest = rest[rest.index(after: space)...]
            } else {
                if command.isEmpty {
                    command = String(rest)
                } else {
                    parameters.append(String(rest))
                }
                rest = rest[rest.endIndex...]
            }
        }

        guard !command.isEmpty else { throw ParseError.missingCommand }
        return IRCMessage(
            tags: tags,
            prefix: prefix,
            command: command.uppercased(),
            parameters: parameters
        )
    }

    /// Split a received byte buffer on `\n`, returning complete lines and the
    /// unconsumed remainder. Lines are trimmed of a trailing `\r`.
    public static func extractLines(from buffer: inout [UInt8]) -> [String] {
        var lines: [String] = []
        var start = buffer.startIndex
        for i in buffer.indices where buffer[i] == 0x0A {
            var slice = buffer[start..<i]
            if slice.last == 0x0D { slice = slice.dropLast() }
            if let line = String(bytes: slice, encoding: .utf8) {
                lines.append(line)
            } else {
                lines.append(String(decoding: slice, as: UTF8.self))
            }
            start = buffer.index(after: i)
        }
        buffer.removeSubrange(buffer.startIndex..<start)
        return lines
    }
}
