import Foundation
import Testing
@testable import IRCKit

/// Collects events from an IRCConnection for assertions.
actor EventCollector {
    private(set) var events: [IRCEvent] = []

    func append(_ event: IRCEvent) {
        events.append(event)
    }

    func start(_ connection: IRCConnection) -> Task<Void, Never> {
        Task { [weak self] in
            for await event in connection.events {
                await self?.append(event)
            }
        }
    }

    func contains(where pred: (IRCEvent) -> Bool) -> Bool {
        events.contains(where: pred)
    }

    func snapshot() -> [IRCEvent] {
        events
    }
}

@Suite("IRCConnection registration")
struct RegistrationTests {
    private func makeConnection(
        mock: MockTransport,
        sasl: SASLCredentials? = nil
    ) -> IRCConnection {
        IRCConnection(
            config: IRCConfiguration(
                host: "irc.test",
                useTLS: false,
                nickname: "tester",
                sasl: sasl,
                pingInterval: 3600,
                pingTimeout: 3600
            ),
            transportFactory: { mock }
        )
    }

    @Test("sends CAP LS, NICK and USER on connect")
    func registrationStart() async throws {
        let mock = MockTransport()
        let conn = makeConnection(mock: mock)
        let collector = EventCollector()
        _ = await collector.start(conn)
        await conn.start()
        #expect(await mock.waitForSent(3))
        #expect(mock.sent[0] == "CAP LS 302")
        #expect(mock.sent[1] == "NICK tester")
        #expect(mock.sent[2].hasPrefix("USER tester 0 * :"))
        await conn.stop()
    }

    @Test("requests desired caps from the LS list")
    func capNegotiation() async throws {
        let mock = MockTransport()
        let conn = makeConnection(mock: mock)
        await conn.start()
        #expect(await mock.waitForSent(3))
        mock.feed(":srv CAP * LS :multi-prefix sasl server-time message-tags echo-message")
        #expect(await mock.waitForSent(4))
        let req = mock.sent[3]
        #expect(req.hasPrefix("CAP REQ :"))
        #expect(req.contains("server-time"))
        #expect(req.contains("message-tags"))
        #expect(!req.contains("sasl"))  // no credentials configured
        mock.feed(":srv CAP * ACK :server-time message-tags multi-prefix echo-message")
        #expect(await mock.waitForSent(5))
        #expect(mock.sent[4] == "CAP END")
        await conn.stop()
    }

    @Test("full SASL PLAIN flow")
    func saslFlow() async throws {
        let mock = MockTransport()
        let creds = SASLCredentials(account: "me", password: "hunter2")
        let conn = makeConnection(mock: mock, sasl: creds)
        let collector = EventCollector()
        _ = await collector.start(conn)
        await conn.start()
        #expect(await mock.waitForSent(3))
        mock.feed(":srv CAP * LS :sasl server-time")
        #expect(await mock.waitForSent(4))
        #expect(mock.sent[3].contains("sasl"))
        mock.feed(":srv CAP * ACK :sasl server-time")
        #expect(await mock.waitForSent(5))
        #expect(mock.sent[4] == "AUTHENTICATE PLAIN")
        mock.feed("AUTHENTICATE +")
        #expect(await mock.waitForSent(6))
        let challenge = mock.sent[5]
        #expect(challenge.hasPrefix("AUTHENTICATE "))
        let decoded = String(data: Data(
            base64Encoded: String(challenge.dropFirst("AUTHENTICATE ".count)))!,
            encoding: .utf8)!
        #expect(decoded == "me\u{0}me\u{0}hunter2")
        mock.feed(":srv 903 tester :SASL authentication successful")
        #expect(await mock.waitForSent(7))
        #expect(mock.sent[6] == "CAP END")
        mock.feed(":srv 001 tester :Welcome")
        // Allow the event loop a tick.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await collector.contains { event in
            if case .saslStatus(let ok, _) = event { return ok }
            return false
        })
        #expect(await collector.contains { event in
            if case .phaseChanged(let p) = event { return p == .online }
            return false
        })
        await conn.stop()
    }

    @Test("SASL failure still ends negotiation and emits error")
    func saslFailure() async throws {
        let mock = MockTransport()
        let conn = makeConnection(mock: mock, sasl: SASLCredentials(account: "a", password: "b"))
        let collector = EventCollector()
        _ = await collector.start(conn)
        await conn.start()
        #expect(await mock.waitForSent(3))
        mock.feed(":srv CAP * LS :sasl")
        #expect(await mock.waitForSent(4))
        mock.feed(":srv CAP * ACK :sasl")
        #expect(await mock.waitForSent(5))
        mock.feed("AUTHENTICATE +")
        #expect(await mock.waitForSent(6))
        mock.feed(":srv 904 tester :SASL authentication failed")
        #expect(await mock.waitForSent(7))
        #expect(mock.sent[6] == "CAP END")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await collector.contains { event in
            if case .saslStatus(let ok, _) = event { return !ok }
            return false
        })
        await conn.stop()
    }

    @Test("433 before registration retries with underscore nick")
    func nickInUse() async throws {
        let mock = MockTransport()
        let conn = makeConnection(mock: mock)
        await conn.start()
        #expect(await mock.waitForSent(3))
        mock.feed(":srv 433 * tester :Nickname is already in use")
        #expect(await mock.waitForSent(4))
        #expect(mock.sent[3] == "NICK tester_")
        await conn.stop()
    }

    @Test("PING gets a PONG")
    func pingPong() async throws {
        let mock = MockTransport()
        let conn = makeConnection(mock: mock)
        await conn.start()
        #expect(await mock.waitForSent(3))
        mock.feed("PING :abc123")
        #expect(await mock.waitForSent(4))
        #expect(mock.sent[3] == "PONG :abc123")
        await conn.stop()
    }

    @Test("inbound privmsg becomes a message event keyed to the channel")
    func privmsgEvent() async throws {
        let mock = MockTransport()
        let conn = makeConnection(mock: mock)
        let collector = EventCollector()
        _ = await collector.start(conn)
        await conn.start()
        #expect(await mock.waitForSent(3))
        mock.feed(":srv 001 tester :Welcome")
        mock.feed("@time=2026-09-22T16:00:00.000Z :w!u@h PRIVMSG #c :hey there")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await collector.contains { event in
            guard case .message(let m) = event else { return false }
            return m.conversationKey == "#c" && m.text == "hey there" && m.sender == "w"
                && !m.isOutgoing
        })
        await conn.stop()
    }

    @Test("CTCP ACTION becomes an action event")
    func ctcpAction() async throws {
        let mock = MockTransport()
        let conn = makeConnection(mock: mock)
        let collector = EventCollector()
        _ = await collector.start(conn)
        await conn.start()
        #expect(await mock.waitForSent(3))
        mock.feed(":w!u@h PRIVMSG tester :\u{01}ACTION waves\u{01}")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await collector.contains { event in
            guard case .action(let m) = event else { return false }
            return m.text == "waves" && m.conversationKey == "w"
        })
        await conn.stop()
    }

    @Test("transport hang-up triggers reconnect per policy")
    func reconnect() async throws {
        let mock = MockTransport()
        let conn = IRCConnection(
            config: IRCConfiguration(
                host: "irc.test", useTLS: false, nickname: "t",
                pingInterval: 3600, pingTimeout: 3600,
                reconnect: ReconnectPolicy(baseDelay: 0.01, maxAttempts: 2)
            ),
            transportFactory: { mock }
        )
        let collector = EventCollector()
        _ = await collector.start(conn)
        await conn.start()
        #expect(await mock.waitForSent(3))
        mock.hangUp()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await collector.contains { event in
            if case .phaseChanged(let p) = event,
               case .reconnecting = p { return true }
            return false
        })
        await conn.stop()
    }
}

@Suite("ReconnectPolicy")
struct ReconnectTests {
    @Test("backoff grows exponentially and clamps at max")
    func backoff() {
        let p = ReconnectPolicy(baseDelay: 2, maxDelay: 30, multiplier: 2, jitter: 0)
        #expect(p.baseDelay(forAttempt: 1) == 2)
        #expect(p.baseDelay(forAttempt: 2) == 4)
        #expect(p.baseDelay(forAttempt: 3) == 8)
        #expect(p.baseDelay(forAttempt: 10) == 30)
    }

    @Test("jitter stays within ±jitter band")
    func jitterBand() {
        let p = ReconnectPolicy(baseDelay: 10, maxDelay: 100, multiplier: 1, jitter: 0.5)
        #expect(p.delay(forAttempt: 1, random: 0) == 5)
        #expect(p.delay(forAttempt: 1, random: 1) == 15)
        #expect(p.delay(forAttempt: 1, random: 0.5) == 10)
    }

    @Test("maxAttempts gates retries")
    func maxAttempts() {
        let p = ReconnectPolicy(maxAttempts: 3)
        #expect(p.permits(attempt: 3))
        #expect(!p.permits(attempt: 4))
        #expect(ReconnectPolicy().permits(attempt: 1000))
    }
}

@Suite("IRCSessionState")
struct SessionStateTests {
    @Test("join, names, part and quit track members")
    func membership() async {
        let state = IRCSessionState(nickname: "me")
        await state.apply(IRCMessage(command: "001", parameters: ["me"]))
        await state.apply(IRCMessage(prefix: .user(nick: "me", user: nil, host: nil), command: "JOIN", parameters: ["#c"]))
        await state.apply(IRCMessage(command: "353", parameters: ["me", "=", "#c", "me @op +voiced"]))
        let done = await state.apply(IRCMessage(command: "366", parameters: ["me", "#c", "End"]))
        #expect(done["#c"] == ["me", "op", "voiced"])
        var ch = await state.channels["#c"]
        #expect(ch?.members.contains("op") == true)
        await state.apply(IRCMessage(prefix: .user(nick: "op", user: nil, host: nil), command: "PART", parameters: ["#c", "bye"]))
        ch = await state.channels["#c"]
        #expect(ch?.members.contains("op") == false)
        #expect(await state.joinedChannels == ["#c"])
    }

    @Test("own nick change updates identity and member lists")
    func nickChange() async {
        let state = IRCSessionState(nickname: "me")
        await state.apply(IRCMessage(command: "001", parameters: ["me"]))
        await state.apply(IRCMessage(prefix: .user(nick: "me", user: nil, host: nil), command: "JOIN", parameters: ["#c"]))
        await state.apply(IRCMessage(command: "353", parameters: ["me", "=", "#c", "me you"]))
        await state.apply(IRCMessage(prefix: .user(nick: "me", user: nil, host: nil), command: "NICK", parameters: ["me2"]))
        #expect(await state.nickname == "me2")
        #expect(await state.channels["#c"]?.members.contains("me2") == true)
    }

    @Test("kick of self removes the channel")
    func kick() async {
        let state = IRCSessionState(nickname: "me")
        await state.apply(IRCMessage(command: "001", parameters: ["me"]))
        await state.apply(IRCMessage(prefix: .user(nick: "me", user: nil, host: nil), command: "JOIN", parameters: ["#c"]))
        await state.apply(IRCMessage(prefix: .user(nick: "op", user: nil, host: nil), command: "KICK", parameters: ["#c", "me", "out"]))
        #expect(await state.joinedChannels.isEmpty)
    }
}

@Suite("IRCConversationStore")
struct ConversationStoreTests {
    @Test("channel messages accumulate and bump unread")
    func channelFlow() async {
        let store = IRCConversationStore()
        await store.ingest(.message(IRCChatMessage(
            conversationKey: "#c", sender: "w", text: "hi", kind: .message
        )))
        await store.ingest(.message(IRCChatMessage(
            conversationKey: "#c", sender: "me", text: "yo", isOutgoing: true, kind: .message
        )))
        let snap = await store.snapshot
        let chan = snap.first { $0.id == "channel:#c" }
        #expect(chan?.lines.count == 2)
        #expect(chan?.unreadCount == 1)
        await store.markRead("channel:#c")
        #expect(await store.conversation(id: "channel:#c")?.unreadCount == 0)
    }

    @Test("DMs key by the peer nick")
    func dmFlow() async {
        let store = IRCConversationStore()
        await store.ingest(.message(IRCChatMessage(
            conversationKey: "wolf", sender: "wolf", text: "psst", kind: .message
        )))
        let conv = await store.conversation(id: "dm:wolf")
        #expect(conv?.kind == .direct)
        #expect(conv?.lines.first?.text == "psst")
    }

    @Test("server phase changes become status lines")
    func statusLines() async {
        let store = IRCConversationStore()
        await store.ingest(.phaseChanged(.connecting))
        await store.ingest(.phaseChanged(.online))
        let server = await store.conversation(id: "server")
        #expect(server?.lines.count == 2)
        #expect(server?.lines.last?.text == "Connected.")
    }
}
