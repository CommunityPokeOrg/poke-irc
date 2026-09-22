import Foundation

/// Events produced by a transport: lifecycle plus decoded lines.
public enum TransportEvent: Sendable {
    /// The connection is ready for writes.
    case connected
    /// One complete line (CRLF-stripped).
    case line(String)
    /// The connection closed; `error` is nil on clean close.
    case closed(error: String?)
}

/// A bidirectional line transport (TCP or TLS) between the session and a server.
public protocol IRCTransport: Sendable {
    /// Stream of transport events. Consumed once by the session.
    var events: AsyncStream<TransportEvent> { get }

    /// Opens the connection. Returns when the socket is ready (the
    /// `.connected` event is also emitted).
    func connect() async throws

    /// Sends one line; the CRLF terminator is added by the transport.
    func send(_ line: String) async throws

    /// Closes the connection.
    func close() async
}

public enum IRCTransportError: Error, Sendable {
    case notConnected
    case closed(String?)
    case sendFailed(String)
}
