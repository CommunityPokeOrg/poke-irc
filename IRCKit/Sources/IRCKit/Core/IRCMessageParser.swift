import Foundation

/// Parses raw IRC lines into `IRCMessage` values.
///
/// Wire format: `@tags :prefix COMMAND param param :trailing`
/// Tag escapes: `\:` -> ';', `\s` -> ' ', `\\` -> '\', `\r` -> CR, `\n` -> LF.
public enum IRCMessageParser {

    /// Parses one CRLF-terminated line (already stripped) into an IRCMessage.
    /// Returns nil for empty/malformed lines.
    public static func parse(_ raw: String) -> IRCMessage? {
        var line = raw
        if line.hasSuffix("\r\n") { line = String(line.dropLast(2)) }
        else if line.hasSuffix("\n") || line.hasSuffix("\r") { line = String(line.dropLast()) }
        guard !line.isEmpty else { return nil }

        var tags: [String: String] = [:]
        var prefix: String?

        if line.hasPrefix("@") {
            guard let spaceIndex = line.firstIndex(of: " ") else { return nil }
            let tagSection = line[line.index(after: line.startIndex)..<spaceIndex]
            tags = parseTags(String(tagSection))
            line = String(line[line.index(after: spaceIndex)...])
        }

        if line.hasPrefix(":") {
            guard let spaceIndex = line.firstIndex(of: " ") else {
                return IRCMessage(tags: tags, prefix: String(line.dropFirst()),
                                  command: "", parameters: [])
            }
            prefix = String(line[line.index(after: line.startIndex)..<spaceIndex])
            line = String(line[line.index(after: spaceIndex)...])
        }

        var parameters: [String] = []
        var command = ""

        while !line.isEmpty {
            if line.hasPrefix(":") {
                parameters.append(String(line.dropFirst()))
                break
            }
            guard let spaceIndex = line.firstIndex(of: " ") else {
                if command.isEmpty { command = line } else { parameters.append(line) }
                break
            }
            let token = String(line[line.startIndex..<spaceIndex])
            if command.isEmpty { command = token } else { parameters.append(token) }
            var next = line.index(after: spaceIndex)
            while next < line.endIndex && line[next] == " " { next = line.index(after: next) }
            line = String(line[next...])
        }

        guard !command.isEmpty else { return nil }
        return IRCMessage(tags: tags, prefix: prefix, command: command, parameters: parameters)
    }

    /// Parses a `key=value;key=value` tag section (without the leading '@').
    public static func parseTags(_ section: String) -> [String: String] {
        var tags: [String: String] = [:]
        for pair in section.split(separator: ";", omittingEmptySubsequences: true) {
            if let eq = pair.firstIndex(of: "=") {
                let key = String(pair[pair.startIndex..<eq])
                let value = String(pair[pair.index(after: eq)...])
                tags[key] = unescapeTagValue(value)
            } else {
                tags[String(pair)] = ""
            }
        }
        return tags
    }

    /// Decodes IRCv3 tag-value escapes in place order.
    public static func unescapeTagValue(_ raw: String) -> String {
        guard raw.contains("\\") else { return raw }
        var result = ""
        result.reserveCapacity(raw.count)
        var iterator = raw.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let escaped = iterator.next() else {
                if character == "\\" { break } // trailing lone backslash: drop
                result.append(character)
                continue
            }
            switch escaped {
            case ":": result.append(";")
            case "s": result.append(" ")
            case "\\": result.append("\\")
            case "r": result.append("\r")
            case "n": result.append("\n")
            default:
                // Unknown escapes keep their literal character per spec.
                result.append(escaped)
            }
        }
        return result
    }
}
