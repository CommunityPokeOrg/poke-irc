import Foundation

/// An async, cancellation-safe IRC client connection.
///
/// Drives CAP negotiation (incl. `sasl`), registration, auto-rejoin and
/// reconnect with exponential backoff. All inbound lines are parsed and
/// surfaced as ``IRCEvent``s on `events`.
public actor IRCConnection {
    public typealias Phase = IRCEvent.Phase

    /// Injectable transport factory (used by tests with a mock transport).
    public typealias TransportFactory = @Sendable () -> any IRCTransport

    public let config: IRCConfiguration
    public let state: IRCSessionState
    public nonisolated let events: AsyncStream<IRCEvent>

    private let continuation: AsyncStream<IRCEvent>.Continuation
    private let makeTransport: TransportFactory

    private var transport: (any IRCTransport)?
    private var runTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var shouldRun = false
    private var attempt = 0
    private var phase: Phase = .idle
    private var lastActivity = Date()

    // Registration handshake state.
    private var offeredCaps: Set<String> = []
    private var enabledCaps: Set<String> = []
    private var pendingCapReq: Set<String> = []
    private var saslInFlight = false
    private var capEnded = false

    public init(
        config: IRCConfiguration,
        transportFactory: TransportFactory? = nil
    ) {
        self.config = config
        self.state = IRCSessionState(nickname: config.nickname)
        self.makeTransport = transportFactory ?? {
            // Force-unwrap is safe: factory throws only via call sites that catch.
            (try? IRCTransportFactory.makeDefault(
                host: config.host, port: config.port, useTLS: config.useTLS
            )) ?? BrokenTransport()
        }
        var cont: AsyncStream<IRCEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    // MARK: - Public API

    /// Connect and run until `stop()` is called; reconnects per policy.
    public func start() async {
        guard !shouldRun else { return }
        shouldRun = true
        attempt = 0
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Disconnect permanently (no reconnect).
    public func stop() async {
        shouldRun = false
        pingTask?.cancel()
        if let transport {
            try? await transport.send("QUIT :bye")
            await transport.close()
        }
        transport = nil
        runTask?.cancel()
        setPhase(.disconnected)
        await state.reset()
    }

    /// Write a raw line (no CRLF).
    public func send(raw line: String) async throws {
        guard let transport else { throw IRCError.notConnected }
        try await transport.send(line)
    }

    public func join(_ channel: String) async throws {
        try await send(raw: "JOIN \(channel)")
    }

    public func part(_ channel: String, reason: String? = nil) async throws {
        if let reason {
            try await send(raw: "PART \(channel) :\(reason)")
        } else {
            try await send(raw: "PART \(channel)")
        }
    }

    public func privmsg(to target: String, text: String) async throws {
        try await send(raw: "PRIVMSG \(target) :\(text)")
        let nick = await state.nickname
        continuation.yield(.message(IRCChatMessage(
            conversationKey: target,
            sender: nick,
            text: text,
            isOutgoing: true,
            kind: .message
        )))
    }

    public func notice(to target: String, text: String) async throws {
        try await send(raw: "NOTICE \(target) :\(text)")
    }

    public func action(to target: String, text: String) async throws {
        try await send(raw: "PRIVMSG \(target) :\(IRCCTCP.encode("ACTION", argument: text))")
        let nick = await state.nickname
        continuation.yield(.action(IRCChatMessage(
            conversationKey: target,
            sender: nick,
            text: text,
            isOutgoing: true,
            kind: .action
        )))
    }

    public func nick(_ newNick: String) async throws {
        try await send(raw: "NICK \(newNick)")
    }

    public func quit(_ reason: String? = nil) async throws {
        try await send(raw: "QUIT\(reason.map { " :\($0)" } ?? "")")
        await stop()
    }

    // MARK: - Run loop

    private func runLoop() async {
        while shouldRun {
            attempt += 1
            do {
                try await runOnce()
            } catch {
                guard shouldRun else { break }
                if let err = error as? IRCError {
                    continuation.yield(.error(err))
                } else {
                    continuation.yield(.error(.connectFailed(String(describing: error))))
                }
            }
            guard shouldRun else { break }
            guard config.reconnect.permits(attempt: attempt) else {
                setPhase(.failed("Reconnect attempts exhausted"))
                break
            }
            let delay = config.reconnect.delay(forAttempt: attempt)
            setPhase(.reconnecting(attempt: attempt, delay: delay))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        if shouldRun == false {
            setPhase(.disconnected)
        }
    }

    /// One connect → register → read session. Returns/throws when it ends.
    private func runOnce() async throws {
        setPhase(.connecting)
        let transport = makeTransport()
        self.transport = transport
        defer { self.transport = nil }

        try await transport.open()
        await state.reset()
        resetHandshake()

        // Begin registration.
        setPhase(.registering)
        if let password = config.serverPassword {
            try await transport.send("PASS \(password)")
        }
        try await transport.send("CAP LS 302")
        try await transport.send("NICK \(config.nickname)")
        try await transport.send("USER \(config.username) 0 * :\(config.realname)")

        startPingTimer()

        for try await line in transport.lines {
            lastActivity = Date()
            try await handle(line: line, transport: transport)
            try Task.checkCancellation()
        }
        throw IRCError.transportClosed
    }

    // MARK: - Line handling

    private func handle(line: String, transport: any IRCTransport) async throws {
        guard let message = try? IRCParser.parse(line) else {
            continuation.yield(.error(.parseFailure(line)))
            return
        }

        switch message.command {
        case "PING":
            if let token = message.parameters.first {
                try await transport.send("PONG :\(token)")
            }
            return
        case "PONG":
            return
        case "CAP":
            try await handleCap(message, transport: transport)
            return
        case "AUTHENTICATE":
            try await handleAuthenticate(message, transport: transport)
            return
        case "001":
            await state.apply(message)
            attempt = 0
            setPhase(.online)
            // Rejoin channels the user was in (post-reconnect) or autojoins.
            let channels = await state.joinedChannels
            let wanted = channels.isEmpty ? config.autoJoinChannels : channels
            for channel in wanted where !channel.isEmpty {
                try? await transport.send("JOIN \(channel)")
            }
            continuation.yield(.serverLine(message))
            return
        case "433": // ERR_NICKNAMEINUSE
            let taken = message.parameters.dropFirst().first ?? config.nickname
            if !(await state.isRegistered) {
                let fallback = taken + "_"
                continuation.yield(.error(.nicknameInUse(taken)))
                try await transport.send("NICK \(fallback)")
            } else {
                continuation.yield(.error(.nicknameInUse(taken)))
            }
            return
        case "ERROR":
            let detail = message.parameters.last ?? "connection closed"
            continuation.yield(.error(.connectFailed(detail)))
            await transport.close()
            return
        case "903": // RPL_SASLSUCCESS
            saslInFlight = false
            continuation.yield(.saslStatus(success: true, detail: message.parameters.last ?? ""))
            try await transport.send("CAP END")
            capEnded = true
            return
        case "904", "905", "906", "907": // SASL failures
            saslInFlight = false
            let detail = message.parameters.last ?? "SASL failed"
            continuation.yield(.saslStatus(success: false, detail: detail))
            continuation.yield(.error(.saslFailed(detail)))
            try await transport.send("CAP END")
            capEnded = true
            return
        case "900", "901", "902":
            continuation.yield(.serverLine(message))
            return
        default:
            break
        }

        // State tracking + chat events.
        let namesDone = await state.apply(message)
        for (channel, names) in namesDone {
            continuation.yield(.namesReply(channel: channel, names: names))
        }

        switch message.command {
        case "PRIVMSG", "NOTICE":
            await handleChat(message)
        case "JOIN":
            if let channel = message.parameters.first {
                let myNick = await state.nickname
                let bySelf = message.senderNick.map {
                    IRCCaseMapping.rfc1459.equal($0, myNick)
                } ?? false
                continuation.yield(.userJoined(
                    channel: channel,
                    nick: message.senderNick ?? "",
                    bySelf: bySelf
                ))
            }
            continuation.yield(.serverLine(message))
        case "PART":
            continuation.yield(.userLeft(
                channel: message.parameters.first,
                nick: message.senderNick ?? "",
                reason: message.parameters.dropFirst().first
            ))
        case "KICK":
            let target = message.parameters.count > 1 ? message.parameters[1] : ""
            continuation.yield(.userLeft(
                channel: message.parameters.first,
                nick: target,
                reason: message.parameters.last
            ))
        case "QUIT":
            continuation.yield(.userLeft(
                channel: nil,
                nick: message.senderNick ?? "",
                reason: message.parameters.first
            ))
        case "NICK":
            continuation.yield(.nickChanged(
                from: message.senderNick ?? "",
                to: message.parameters.first ?? ""
            ))
        case "TOPIC", "332":
            let channel = message.command == "332"
                ? message.parameters.dropFirst().first ?? ""
                : message.parameters.first ?? ""
            let topic = message.parameters.last ?? ""
            continuation.yield(.topicChanged(channel: channel, topic: topic))
        default:
            if message.isNumeric {
                continuation.yield(.serverLine(message))
            }
        }
    }

    private func handleChat(_ message: IRCMessage) async {
        guard message.parameters.count >= 2 else {
            continuation.yield(.serverLine(message))
            return
        }
        let target = message.parameters[0]
        var text = message.parameters[1]
        let sender = message.senderNick ?? message.prefix?.serialized ?? "server"

        let timestamp = message.tags["time"]?.flatMap { IRCTime.parse($0) } ?? Date()
        let account = message.tags["account"] ?? nil

        let myNick = await state.nickname
        let isSelfEcho = IRCCaseMapping.rfc1459.equal(sender, myNick)
        // DMs: key by the *other* party — sender for inbound, target for echo.
        let isChannel = target.hasPrefix("#") || target.hasPrefix("&")
        let key = isChannel ? target : (isSelfEcho ? target : sender)

        var kind: IRCChatMessage.Kind = message.command == "NOTICE" ? .notice : .message
        if kind == .message, let ctcp = IRCCTCP.payload(in: text) {
            if ctcp.command == "ACTION", let arg = ctcp.argument {
                text = arg
                kind = .action
            } else {
                // Non-ACTION CTCP (VERSION etc.) — surface as server line.
                continuation.yield(.serverLine(message))
                return
            }
        }

        let chat = IRCChatMessage(
            conversationKey: key,
            sender: sender,
            text: text,
            timestamp: timestamp,
            isOutgoing: isSelfEcho,
            kind: kind,
            account: account
        )
        switch kind {
        case .message: continuation.yield(.message(chat))
        case .notice: continuation.yield(.notice(chat))
        case .action: continuation.yield(.action(chat))
        }
    }

    // MARK: - CAP / SASL

    private func resetHandshake() {
        offeredCaps = []
        enabledCaps = []
        pendingCapReq = []
        saslInFlight = false
        capEnded = false
    }

    private func handleCap(_ message: IRCMessage, transport: any IRCTransport) async throws {
        // CAP * <sub> [...] :cap list
        guard message.parameters.count >= 2 else { return }
        let subcommand = message.parameters[1].uppercased()
        let capList = (message.parameters.last ?? "")
            .split(separator: " ")
            .map { raw -> String in
                // Strip =value form for matching (e.g. sasl=PLAIN).
                String(raw.split(separator: "=", maxSplits: 1).first ?? raw)
            }

        switch subcommand {
        case "LS":
            offeredCaps.formUnion(capList)
            var wanted = offeredCaps.intersection(IRCCapability.defaultDesired)
            wanted.formUnion(offeredCaps.intersection(Set(config.requestedCapabilities)))
            if config.sasl != nil, offeredCaps.contains(IRCCapability.sasl) {
                wanted.insert(IRCCapability.sasl)
            }
            pendingCapReq = wanted
            if wanted.isEmpty {
                try await transport.send("CAP END")
                capEnded = true
            } else {
                try await transport.send("CAP REQ :\(wanted.sorted().joined(separator: " "))")
            }
            continuation.yield(.capabilities(available: capList, enabled: []))
        case "ACK":
            enabledCaps.formUnion(capList)
            pendingCapReq.subtract(capList)
            continuation.yield(.capabilities(available: [], enabled: capList))
            if enabledCaps.contains(IRCCapability.sasl), let sasl = config.sasl, !saslInFlight {
                saslInFlight = true
                try await transport.send("AUTHENTICATE \(sasl.mechanism.rawValue)")
            } else if pendingCapReq.isEmpty && !saslInFlight && !capEnded {
                capEnded = true
                try await transport.send("CAP END")
            }
        case "NAK":
            pendingCapReq.subtract(capList)
            continuation.yield(.serverLine(message))
            if pendingCapReq.isEmpty && !saslInFlight && !capEnded {
                capEnded = true
                try await transport.send("CAP END")
            }
        default:
            continuation.yield(.serverLine(message))
        }
    }

    private func handleAuthenticate(_ message: IRCMessage, transport: any IRCTransport) async throws {
        guard message.parameters.first == "+", let sasl = config.sasl else { return }
        let encoded = sasl.plainChallenge
        // SASL responses are chunked at 400 bytes; a "+" terminates when the
        // payload length is an exact multiple.
        var remaining = encoded
        while remaining.count > 400 {
            try await transport.send("AUTHENTICATE \(remaining.prefix(400))")
            remaining = String(remaining.dropFirst(400))
        }
        try await transport.send("AUTHENTICATE \(remaining)")
        if encoded.count % 400 == 0 {
            try await transport.send("AUTHENTICATE +")
        }
    }

    // MARK: - Keepalive

    private func startPingTimer() {
        pingTask?.cancel()
        let interval = config.pingInterval
        let timeout = config.pingTimeout
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.pingCheck(timeout: timeout)
            }
        }
    }

    private func pingCheck(timeout: TimeInterval) async {
        guard let transport else { return }
        if Date().timeIntervalSince(lastActivity) > intervalSafe(timeout + config.pingInterval) {
            await transport.close()
            return
        }
        try? await transport.send("PING :\(Int(Date().timeIntervalSince1970))")
    }

    private func intervalSafe(_ t: TimeInterval) -> TimeInterval { t }

    private func setPhase(_ phase: Phase) {
        self.phase = phase
        continuation.yield(.phaseChanged(phase))
    }
}

/// Placeholder transport that always fails — used when no platform transport exists.
private struct BrokenTransport: IRCTransport {
    var lines: AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: IRCError.connectFailed("no transport")) }
    }
    func open() async throws { throw IRCError.connectFailed("no transport") }
    func send(_ line: String) async throws { throw IRCError.notConnected }
    func close() async {}
}
