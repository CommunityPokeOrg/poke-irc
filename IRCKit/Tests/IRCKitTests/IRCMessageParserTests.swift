import XCTest
@testable import IRCKit

final class IRCMessageParserTests: XCTestCase {

    func testSimpleCommand() {
        let message = IRCMessageParser.parse("PING :server.example.com")
        XCTAssertEqual(message?.command, "PING")
        XCTAssertEqual(message?.parameters, ["server.example.com"])
        XCTAssertNil(message?.prefix)
        XCTAssertTrue(message?.tags.isEmpty ?? false)
    }

    func testPrefixAndParams() {
        let message = IRCMessageParser.parse(":nick!user@host PRIVMSG #chan :hello world")
        XCTAssertEqual(message?.prefix, "nick!user@host")
        XCTAssertEqual(message?.nickname, "nick")
        XCTAssertEqual(message?.command, "PRIVMSG")
        XCTAssertEqual(message?.parameters, ["#chan", "hello world"])
    }

    func testNumeric() {
        let message = IRCMessageParser.parse(":irc.example.com 001 nick :Welcome")
        XCTAssertEqual(message?.command, "001")
        XCTAssertEqual(message?.isNumeric, true)
        XCTAssertEqual(message?.parameters, ["nick", "Welcome"])
    }

    func testTags() {
        let message = IRCMessageParser.parse(
            "@time=2026-09-22T16:54:00.123Z;account=poke :n!u@h PRIVMSG #c :hi"
        )
        XCTAssertEqual(message?.tags["time"], "2026-09-22T16:54:00.123Z")
        XCTAssertEqual(message?.tags["account"], "poke")
        XCTAssertEqual(message?.command, "PRIVMSG")
    }

    func testTagWithoutValue() {
        let message = IRCMessageParser.parse("@flagonly PING x")
        XCTAssertEqual(message?.tags["flagonly"], "")
    }

    func testTagEscapes() {
        // \: = ';'  \s = ' '  \\ = '\'  \r / \n
        let message = IRCMessageParser.parse("@msg=a\\:b\\sc\\\\d PING x")
        XCTAssertEqual(message?.tags["msg"], "a;b c\\d")
        let rn = IRCMessageParser.parse("@m=x\\ry\\nz PING x")
        XCTAssertEqual(rn?.tags["m"], "x\ry\nz")
    }

    func testServerTime() {
        let message = IRCMessageParser.parse(
            "@server-time=2026-09-22T16:54:00.123Z :s 001 n :w"
        )
        XCTAssertNotNil(message?.serverTime)
        if let t = message?.serverTime {
            XCTAssertEqual(t.timeIntervalSince1970,
                           Date(timeIntervalSince1970: 0).distance(to: t))
        }
    }

    func testEmptyAndMalformed() {
        XCTAssertNil(IRCMessageParser.parse(""))
        XCTAssertNil(IRCMessageParser.parse("\r\n"))
        // '@' tags with no following space → malformed
        XCTAssertNil(IRCMessageParser.parse("@onlytags"))
    }

    func testCRLFStripped() {
        XCTAssertNotNil(IRCMessageParser.parse("PING x\r\n"))
        XCTAssertNotNil(IRCMessageParser.parse("PING x\n"))
    }
}
