import XCTest
@testable import IRCKit

final class IRCMessageSerializerTests: XCTestCase {

    func testSimple() {
        let message = IRCMessage(command: "PRIVMSG", parameters: ["#c", "hi there"])
        XCTAssertEqual(IRCMessageSerializer.serialize(message),
                       "PRIVMSG #c :hi there")
    }

    func testTrailingNotPrefixedWhenSimple() {
        let message = IRCMessage(command: "NICK", parameters: ["newnick"])
        XCTAssertEqual(IRCMessageSerializer.serialize(message), "NICK newnick")
    }

    func testEmptyTrailing() {
        let message = IRCMessage(command: "PRIVMSG", parameters: ["#c", ""])
        XCTAssertEqual(IRCMessageSerializer.serialize(message), "PRIVMSG #c :")
    }

    func testPrefixAndTags() {
        let message = IRCMessage(
            tags: ["b": "2", "a": "x;y z"],
            prefix: "n!u@h",
            command: "PRIVMSG",
            parameters: ["#c", "hi"]
        )
        // Tags are sorted; 'a' value is escaped.
        XCTAssertEqual(IRCMessageSerializer.serialize(message),
                       "@a=x\\:y\\sz;b=2 :n!u@h PRIVMSG #c hi")
    }

    func testRoundTrip() {
        let original = IRCMessage(
            tags: ["account": "poke", "flag": ""],
            prefix: "nick!user@host",
            command: "PRIVMSG",
            parameters: ["#chan", "a ; b  c"]
        )
        let line = IRCMessageSerializer.serialize(original)
        let parsed = IRCMessageParser.parse(line)
        XCTAssertEqual(parsed?.command, original.command)
        XCTAssertEqual(parsed?.prefix, original.prefix)
        XCTAssertEqual(parsed?.parameters, original.parameters)
        XCTAssertEqual(parsed?.tags["account"], "poke")
        XCTAssertEqual(parsed?.tags["flag"], "")
    }

    func testEscapeUnescape() {
        let value = "a;b c\\d\re\nf"
        let escaped = IRCMessageSerializer.escapeTagValue(value)
        XCTAssertEqual(escaped, "a\\:b\\sc\\\\d\\re\\nf")
        XCTAssertEqual(IRCMessageParser.unescapeTagValue(escaped), value)
    }
}
