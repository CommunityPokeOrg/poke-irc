import Foundation

/// Errors surfaced by transports and the connection actor.
public enum IRCError: Error, Sendable, Equatable {
    case notConnected
    case alreadyConnected
    case transportClosed
    case tlsUnsupported
    case dnsFailure(String)
    case connectFailed(String)
    case sendFailed(String)
    case parseFailure(String)
    case saslFailed(String)
    case nicknameInUse(String)
    case registrationFailed(String)
}

extension IRCError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the server."
        case .alreadyConnected: return "Already connected."
        case .transportClosed: return "The connection was closed."
        case .tlsUnsupported: return "TLS is not supported by this transport (development build)."
        case .dnsFailure(let host): return "Could not resolve \(host)."
        case .connectFailed(let why): return "Connection failed: \(why)"
        case .sendFailed(let why): return "Send failed: \(why)"
        case .parseFailure(let line): return "Could not parse server line: \(line)"
        case .saslFailed(let why): return "SASL authentication failed: \(why)"
        case .nicknameInUse(let nick): return "Nickname \(nick) is already in use."
        case .registrationFailed(let why): return "Registration failed: \(why)"
        }
    }
}

/// Byte transport abstraction: yields decoded IRC lines and accepts lines to send.
///
/// Apple platforms use ``NWConnectionTransport`` (TLS-capable); Linux dev builds
/// use ``PosixSocketTransport`` (plaintext only).
public protocol IRCTransport: Sendable {
    /// Stream of complete, CRLF-stripped lines. Finishes on orderly close and
    /// throws on transport error.
    var lines: AsyncThrowingStream<String, Error> { get }
    /// Open the connection and start the receive loop.
    func open() async throws
    /// Encode + write one line (CRLF appended by the implementation).
    func send(_ line: String) async throws
    /// Close the transport. Idempotent.
    func close() async
}

/// Picks the platform transport: `NWConnection` on Apple OSes, a POSIX socket
/// (plaintext, development only) elsewhere.
public enum IRCTransportFactory {
    public static func makeDefault(host: String, port: UInt16, useTLS: Bool) throws -> any IRCTransport {
        #if canImport(Network)
        return NWConnectionTransport(host: host, port: port, useTLS: useTLS)
        #else
        return PosixSocketTransport(host: host, port: port, useTLS: useTLS)
        #endif
    }
}
