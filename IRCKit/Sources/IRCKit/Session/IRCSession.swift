import Foundation

/// Connection lifecycle states.
public enum IRCSessionState: String, Sendable {
    case disconnected
    case connecting
    /// Socket up, CAP negotiation / SASL / NICK+USER in flight.
    case registering
    /// Received 001 — fully registered.
    case online
    case disconnecting
}

/// Everything the session surfaces to the UI layer.
public enum IRCSessionEvent: Sendable {
    case stateChanged(IRCSessionState)
    /// Every parsed inbound message (after PING has been auto-answered).
    case message(IRCMessage)
    /// Registration finished with this nickname (may differ from requested).
    case registered(nickname: String)
    /// Negotiated capabilities once CAP ends.
    case capabilities(Set<String>)
    case closed(error: String?)
}

/// A single IRC network connection: transport + registration state machine.
/// Start it, consume `events`, and send commands with `send`/`join`/`privmsg`.
public actor IRCSession {

    public private(set) var state: IRCSessionState = .disconnected
    public private(set) var currentNickname: String
    public private(set) var activeCapabilities: Set<String> = []

    private let config: IRCServerConfig
    private let transport: any IRCTransport
    private var negotiator = CapabilityNegotiator(desired: [])

    /// SASL exchange in flight (ACK received, awaiting 903/failure).
    private var saslInFlight = false
    private var saslCompleted = false
    private var capEnded = false

    private var eventTask: Task<Void, Never>?

    private let continuation: AsyncStream<IRCSessionEvent>.Continuation
    public nonisolated let events: AsyncStream<IRCSessionEvent>

    /// Designated initializer taking a transport (mockable for tests).
    public init(config: IRCServerConfig, transport: any IRCTransport) {
        self.config = config
        self.transport = transport
        self.currentNickname = config.nickname
        var captured: AsyncStream<IRCSessionEvent>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    /// Convenience initializer wiring a TCP/TLS transport for `config`.
    public init(config: IRCServerConfig) {
        self.init(
            config: config,
            transport: NWConnectionTransport(
                configuration: .init(host: config.host,
                                     port: config.port,
                                     useTLS: config.useTLS)
            )
        )
    }

    // MARK: - Lifecycle

    /// Connects and runs registration. Returns immediately after the socket
    /// is ready; watch `events` for progress.
    public func connect() async throws {
        guard state == .disconnected else { return }
        transition(to: .connecting)

        negotiator = CapabilityNegotiator(desired: config.desiredCapabilities)
        saslInFlight = false
        saslCompleted = false
        capEnded = false

        do {
            try await transport.connect()
        } catch {
            transition(to: .disconnected)
            continuation.yield(.closed(error: "\(error)"))
            throw error
        }

        transition(to: .registering)
        eventTask = Task { await self.consumeEvents() }
        try await beginRegistration()
    }

    /// Cleanly disconnects (QUIT then socket close).
    public func disconnect(quitMessage: String = "PokeIRC") async {
        guard state == .online || state == .registering else { return }
        transition(to: .disconnecting)
        try? await transport.send("QUIT :\(quitMessage)")
        await transport.close()
    }

    // MARK: - Sending

    /// Sends a raw command line (single line, no CRLF).
    public func send(raw line: String) async throws {
        try await transport.send(line)
    }

    public func send(_ message: IRCMessage) async throws {
        try await transport.send(IRCMessageSerializer.serialize(message))
    }

    public func join(_ channel: String, key: String? = nil) async throws {
        if let key { try await send(raw: "JOIN \(channel) \(key)") }
        else { try await send(raw: "JOIN \(channel)") }
    }

    public func part(_ channel: String) async throws {
        try await send(raw: "PART \(channel)")
    }

    public func privmsg(_ target: String, _ text: String) async throws {
        try await send(raw: "PRIVMSG \(target) :\(text)")
    }

    public func notice(_ target: String, _ text: String) async throws {
        try await send(raw: "NOTICE \(target) :\(text)")
    }

    public func nick(_ newNick: String) async throws {
        try await send(raw: "NICK \(newNick)")
    }

    // MARK: - Registration

    private func beginRegistration() async throws {
        if let password = config.serverPassword {
            try await transport.send("PASS \(password)")
        }
        try await transport.send("CAP LS 302")
        try await transport.send("NICK \(config.nickname)")
        try await transport.send("USER \(config.username) 0 * :\(config.realname)")
    }

    private func maybeEndCap() async throws {
        guard !capEnded, negotiator.isComplete, saslResolved else { return }
        capEnded = true
        activeCapabilities = negotiator.acknowledged
        try await transport.send("CAP END")
        continuation.yield(.capabilities(activeCapabilities))
    }

    /// SASL is settled when no credentials were configured, the exchange
    /// finished (success or failure), or the server never offered it.
    private var saslResolved: Bool {
        guard config.sasl != nil else { return true }
        if saslCompleted { return true }
        // LS finished and sasl was neither ACKed nor left pending —
        // the server can't do it.
        return !negotiator.lsInProgress
            && !negotiator.pending.contains("sasl")
            && !negotiator.acknowledged.contains("sasl")
            && !saslInFlight
    }

    // MARK: - Inbound processing

    private func consumeEvents() async {
        for await event in transport.events {
            switch event {
            case .connected:
                break
            case .line(let line):
                await handle(line: line)
            case .closed(let error):
                await handleClosed(error: error)
            }
        }
    }

    private func handle(line: String) async {
        guard let message = IRCMessageParser.parse(line) else { return }

        switch message.command {
        case "PING":
            if let token = message.parameters.last {
                try? await transport.send("PONG :\(token)")
            }

        case "CAP":
            await handleCAP(message)

        case "AUTHENTICATE":
            await handleAuthenticate(message)

        case IRCNumeric.saslSuccess.rawValue:
            saslCompleted = true
            saslInFlight = false
            try? await maybeEndCap()

        case IRCNumeric.saslFail.rawValue,
             IRCNumeric.saslTooLong.rawValue,
             IRCNumeric.saslAborted.rawValue:
            saslCompleted = true
            saslInFlight = false
            try? await maybeEndCap()

        case IRCNumeric.saslAlready.rawValue:
            saslCompleted = true
            try? await maybeEndCap()

        case IRCNumeric.welcome.rawValue:
            if let nick = message.parameters.first {
                currentNickname = nick
            }
            if !capEnded {
                // RFC: 001 implicitly ends negotiation; recover gracefully.
                capEnded = true
                activeCapabilities = negotiator.acknowledged
                continuation.yield(.capabilities(activeCapabilities))
            }
            transition(to: .online)
            continuation.yield(.registered(nickname: currentNickname))

        case "NICK":
            if message.nickname == currentNickname,
               let newNick = message.parameters.first {
                currentNickname = newNick
            }

        case "ERROR":
            transition(to: .disconnected)

        default:
            break
        }

        continuation.yield(.message(message))
    }

    /// `CAP <nick> <subcommand> [*] :<caps>`
    private func handleCAP(_ message: IRCMessage) async {
        guard message.parameters.count >= 2 else { return }
        let sub = message.parameters[1].uppercased()
        let multiline = message.parameters.count >= 3 && message.parameters[2] == "*"
        let capList = (message.trailing ?? "")
            .split(separator: " ")
            .map(String.init)

        switch sub {
        case "LS":
            negotiator.recordLS(capList, isContinuation: multiline)
            let request = negotiator.nextRequest()
            if !request.isEmpty {
                try? await transport.send("CAP REQ :\(request.sorted().joined(separator: " "))")
            } else {
                try? await maybeEndCap()
            }

        case "ACK":
            let acked = negotiator.recordACK(capList)
            if acked.contains("sasl"), let sasl = config.sasl {
                saslInFlight = true
                try? await transport.send("AUTHENTICATE \(SASLMechanism.plain.rawValue)")
                _ = sasl
            }
            try? await maybeEndCap()

        case "NAK":
            negotiator.recordNAK(capList)
            try? await maybeEndCap()

        default:
            break
        }
    }

    private func handleAuthenticate(_ message: IRCMessage) async {
        guard saslInFlight, let sasl = config.sasl else { return }
        // Server prompts with `AUTHENTICATE +` — send chunked payload.
        for chunk in SASLAuthenticator.authenticateSequence(sasl) {
            try? await transport.send("AUTHENTICATE \(chunk)")
        }
    }

    private func handleClosed(error: String?) async {
        transition(to: .disconnected)
        continuation.yield(.closed(error: error))
    }

    private func transition(to newState: IRCSessionState) {
        state = newState
        continuation.yield(.stateChanged(newState))
    }
}
