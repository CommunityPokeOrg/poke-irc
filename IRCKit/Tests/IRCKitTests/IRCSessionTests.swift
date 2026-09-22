import XCTest
@testable import IRCKit

/// Scripted transport: records sent lines and replays inbound events.
final class MockTransport: IRCTransport, @unchecked Sendable {
    private(set) var sent: [String] = []
    private var continuation: AsyncStream<TransportEvent>.Continuation!
    let events: AsyncStream<TransportEvent>
    private let lock = NSLock()

    init() {
        var captured: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
    }

    func connect() async throws {
        continuation.yield(.connected)
    }

    func send(_ line: String) async throws {
        lock.withLock { sent.append(line) }
    }

    func close() async {
        continuation.yield(.closed(error: nil))
        continuation.finish()
    }

    func feed(_ line: String) { continuation.yield(.line(line)) }
    func drop(error: String? = nil) {
        continuation.yield(.closed(error: error))
        continuation.finish()
    }
    func sentLines() -> [String] { lock.withLock { sent } }
}

final class IRCSessionTests: XCTestCase {

    private func makeConfig(sasl: SASLCredentials? = nil) -> IRCServerConfig {
        IRCServerConfig(host: "irc.test", port: 6697, useTLS: true,
                        nickname: "tester", realname: "Test User",
                        sasl: sasl,
                        desiredCapabilities: ["sasl", "server-time", "multi-prefix"])
    }


    func testRegistrationWithoutSASL() async throws {
        let transport = MockTransport()
        let session = IRCSession(config: makeConfig(), transport: transport)

        let collector = Task {
            await collectEvents(from: session.events) { event in
                if case .registered = event { return true }
                return false
            }
        }

        try await session.connect()
        try await Task.sleep(for: .milliseconds(50))

        // CAP LS → advertise (no sasl), single line.
        transport.feed(":irc.test CAP tester LS :server-time multi-prefix batch")
        try await Task.sleep(for: .milliseconds(50))
        transport.feed(":irc.test CAP tester ACK :server-time multi-prefix")
        try await Task.sleep(for: .milliseconds(50))
        transport.feed(":irc.test 001 tester :Welcome")
        try await Task.sleep(for: .milliseconds(50))

        let events = await collector.value
        let sent = transport.sentLines()

        XCTAssertTrue(sent.contains("CAP LS 302"))
        XCTAssertTrue(sent.contains("NICK tester"))
        XCTAssertTrue(sent.contains("USER tester 0 * :Test User"))
        // Should REQ exactly the offered∩desired set — no sasl.
        XCTAssertTrue(sent.contains("CAP REQ :multi-prefix server-time"))
        XCTAssertTrue(sent.contains("CAP END"))
        XCTAssertFalse(sent.contains { $0.hasPrefix("AUTHENTICATE") })

        guard case .registered(let nick) = events.last else {
            return XCTFail("expected .registered, got \(String(describing: events.last))")
        }
        XCTAssertEqual(nick, "tester")
        let state = await session.state
        XCTAssertEqual(state, .online)
        let caps = await session.activeCapabilities
        XCTAssertEqual(caps, ["server-time", "multi-prefix"])
    }

    func testRegistrationWithSASL() async throws {
        let transport = MockTransport()
        let sasl = SASLCredentials(account: "tester", password: "hunter2")
        let session = IRCSession(config: makeConfig(sasl: sasl), transport: transport)

        let collector = Task {
            await collectEvents(from: session.events) { event in
                if case .registered = event { return true }
                return false
            }
        }

        try await session.connect()
        try await Task.sleep(for: .milliseconds(50))
        transport.feed(":irc.test CAP tester LS :sasl server-time")
        try await Task.sleep(for: .milliseconds(50))
        transport.feed(":irc.test CAP tester ACK :sasl server-time")
        try await Task.sleep(for: .milliseconds(50))
        transport.feed("AUTHENTICATE +")
        try await Task.sleep(for: .milliseconds(50))
        transport.feed(":irc.test 903 tester :SASL authentication successful")
        try await Task.sleep(for: .milliseconds(50))
        transport.feed(":irc.test 001 tester :Welcome")

        _ = await collector.value
        let sent = transport.sentLines()

        XCTAssertTrue(sent.contains("CAP REQ :sasl server-time"))
        XCTAssertTrue(sent.contains("AUTHENTICATE PLAIN"))
        XCTAssertTrue(sent.contains("AUTHENTICATE AHRlc3RlcgBodW50ZXIy"))
        // CAP END only after 903.
        let capEndIndex = sent.firstIndex(of: "CAP END")
        let saslOKIndex = sent.firstIndex(of: "AUTHENTICATE AHRlc3RlcgBodW50ZXIy")
        XCTAssertNotNil(capEndIndex)
        XCTAssertNotNil(saslOKIndex)
        if let capEndIndex, let saslOKIndex {
            XCTAssertGreaterThan(capEndIndex, saslOKIndex)
        }
    }

    func testPingAutoPong() async throws {
        let transport = MockTransport()
        let session = IRCSession(config: makeConfig(), transport: transport)
        let collector = Task {
            await collectEvents(from: session.events) { event in
                if case .message(let m) = event, m.command == "PRIVMSG" { return true }
                return false
            }
        }
        try await session.connect()
        transport.feed(":irc.test CAP tester LS :")
        transport.feed("PING :abc123")
        transport.feed(":n!u@h PRIVMSG tester :hi")
        _ = await collector.value
        XCTAssertTrue(transport.sentLines().contains("PONG :abc123"))
    }

    func testServerTimeTagPropagates() async throws {
        let transport = MockTransport()
        let session = IRCSession(config: makeConfig(), transport: transport)
        let collector = Task {
            await collectEvents(from: session.events) { event in
                if case .message(let m) = event, m.command == "PRIVMSG" { return true }
                return false
            }
        }
        try await session.connect()
        transport.feed("@server-time=2026-09-22T16:00:00.000Z :n!u@h PRIVMSG tester :hi")
        let events = await collector.value
        guard case .message(let msg) = events.last else {
            return XCTFail("no message event")
        }
        XCTAssertNotNil(msg.serverTime)
    }

    func testDisconnect() async throws {
        let transport = MockTransport()
        let session = IRCSession(config: makeConfig(), transport: transport)
        try await session.connect()
        transport.feed(":irc.test CAP tester LS :")
        transport.feed(":irc.test 001 tester :Welcome")
        try await Task.sleep(for: .milliseconds(50))
        await session.disconnect()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(transport.sentLines().contains("QUIT :PokeIRC"))
        let state = await session.state
        XCTAssertEqual(state, .disconnected)
    }
}

/// Collects session events until `stop` fires.
private func collectEvents(
    from events: AsyncStream<IRCSessionEvent>,
    until stop: @escaping (IRCSessionEvent) -> Bool
) async -> [IRCSessionEvent] {
    var collected: [IRCSessionEvent] = []
    for await event in events {
        collected.append(event)
        if stop(event) { break }
    }
    return collected
}
