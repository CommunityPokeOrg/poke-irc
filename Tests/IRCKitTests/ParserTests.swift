import Foundation
import Testing
@testable import IRCKit

@Suite("IRC line parser")
struct ParserTests {
    @Test("parses a simple command")
    func simple() throws {
        let m = try IRCParser.parse("PING :irc.example.net")
        #expect(m.command == "PING")
        #expect(m.parameters == ["irc.example.net"])
        #expect(m.prefix == nil)
        #expect(m.tags.isEmpty)
    }

    @Test("parses prefix with nick!user@host")
    func prefix() throws {
        let m = try IRCParser.parse(":wolf!~wolf@host.example PRIVMSG #chan :hello there")
        #expect(m.command == "PRIVMSG")
        #expect(m.parameters == ["#chan", "hello there"])
        #expect(m.senderNick == "wolf")
        guard case .user(_, let user, let host)? = m.prefix else {
            Issue.record("expected user prefix")
            return
        }
        #expect(user == "~wolf")
        #expect(host == "host.example")
    }

    @Test("parses server prefix")
    func serverPrefix() throws {
        let m = try IRCParser.parse(":irc.libera.chat 001 nick :Welcome")
        #expect(m.prefix == .server("irc.libera.chat"))
        #expect(m.isNumeric)
    }

    @Test("trailing param keeps inner colons and spaces")
    func trailing() throws {
        let m = try IRCParser.parse(":a!b@c TOPIC #x :the topic: with colons")
        #expect(m.parameters == ["#x", "the topic: with colons"])
    }

    @Test("empty trailing param is preserved")
    func emptyTrailing() throws {
        let m = try IRCParser.parse(":s 372 m :-")
        #expect(m.parameters.last == "-")
    }

    @Test("rejects empty and commandless lines")
    func invalid() {
        #expect(throws: IRCParser.ParseError.self) { try IRCParser.parse("") }
        #expect(throws: IRCParser.ParseError.self) { try IRCParser.parse("@tags=only") }
        #expect(throws: IRCParser.ParseError.self) { try IRCParser.parse(":prefix-only") }
    }
}

@Suite("IRCv3 message tags")
struct TagTests {
    @Test("parses tags including valueless and server-time")
    func tags() throws {
        let m = try IRCParser.parse(
            "@time=2026-09-22T16:00:00.000Z;aaa=bbb;flag :s NOTICE * :hi"
        )
        #expect(m.tags["time"] ?? nil == "2026-09-22T16:00:00.000Z")
        #expect(m.tags["aaa"] ?? nil == "bbb")
        #expect(m.tags.keys.contains("flag"))
        #expect(m.tags["flag"]! == nil)
        #expect(m.command == "NOTICE")
    }

    @Test("unescapes tag values")
    func unescape() throws {
        let m = try IRCParser.parse("@x=hello\\sworld\\:semi\\\\back\\r\\n CMD")
        #expect(m.tags["x"] ?? nil == "hello world;semi\\back\r\n")
    }

    @Test("server-time parses to a Date")
    func serverTime() throws {
        let date = try #require(IRCTime.parse("2026-09-22T16:00:00.250Z"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect(comps.year == 2026 && comps.month == 9 && comps.day == 22
                && comps.hour == 16 && comps.minute == 0)
    }

    @Test("server-time without fractional seconds parses")
    func serverTimePlain() {
        #expect(IRCTime.parse("2026-09-22T16:00:00Z") != nil)
    }
}

@Suite("IRC serializer")
struct SerializerTests {
    @Test("round-trips a tagged privmsg")
    func roundTrip() throws {
        let m = IRCMessage(
            tags: ["time": "2026-09-22T00:00:00Z", "aaa": nil],
            prefix: .user(nick: "n", user: "u", host: "h"),
            command: "PRIVMSG",
            parameters: ["#chan", "hello world"]
        )
        let wire = m.serialized()
        let parsed = try IRCParser.parse(wire)
        #expect(parsed == m)
    }

    @Test("serializes tag escaping")
    func escaping() {
        let m = IRCMessage(tags: ["x": "a;b c\\d\ne"], command: "TAGMSG", parameters: ["*"])
        let wire = m.serialized()
        #expect(wire.contains("@x=a\\:b\\sc\\\\d\\ne"))
    }

    @Test("prefix serialization is exact")
    func prefixWire() {
        #expect(IRCPrefix.user(nick: "n", user: "u", host: "h").serialized == "n!u@h")
        #expect(IRCPrefix.parse("n!u@h") == .user(nick: "n", user: "u", host: "h"))
        #expect(IRCPrefix.parse("irc.net") == .server("irc.net"))
        #expect(IRCPrefix.parse("n@h") == .user(nick: "n", user: nil, host: "h"))
    }

    @Test("line splitter handles CRLF and partial lines")
    func splitter() {
        var buf = Array("PING :a\r\nJOIN #b\r\nPARTIAL".utf8)
        let lines = IRCParser.extractLines(from: &buf)
        #expect(lines == ["PING :a", "JOIN #b"])
        #expect(String(decoding: buf, as: UTF8.self) == "PARTIAL")
    }
}
