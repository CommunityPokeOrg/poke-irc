import Foundation
import Network

/// TCP/TLS line transport backed by `NWConnection` (Network.framework).
/// Works identically on iOS and macOS; TLS uses the system trust store.
public final class NWConnectionTransport: IRCTransport, @unchecked Sendable {

    public struct Configuration: Sendable {
        public var host: String
        public var port: UInt16
        public var useTLS: Bool
        /// Enforced per-line byte cap on the receive side.
        public var maxLineBytes: Int

        public init(host: String, port: UInt16 = 6697, useTLS: Bool = true,
                    maxLineBytes: Int = 16_384) {
            self.host = host
            self.port = port
            self.useTLS = useTLS
            self.maxLineBytes = maxLineBytes
        }
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "org.communitypoke.irckit.transport")
    private let lock = NSLock()

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var finished = false

    private let continuation: AsyncStream<TransportEvent>.Continuation
    public let events: AsyncStream<TransportEvent>

    public init(configuration: Configuration) {
        self.configuration = configuration
        var captured: AsyncStream<TransportEvent>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    public func connect() async throws {
        let host = NWEndpoint.Host(configuration.host)
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw IRCTransportError.sendFailed("invalid port \(configuration.port)")
        }

        let parameters: NWParameters
        if configuration.useTLS {
            // System defaults: SNI from host, platform trust evaluation.
            parameters = NWParameters(tls: NWProtocolTLS.Options())
        } else {
            parameters = NWParameters.tcp
        }

        let conn = NWConnection(host: host, port: port, using: parameters)
        lock.withLock { connection = conn }

        let gate = ResumeGate()
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            let resumeOnce: @Sendable (Result<Void, Error>) -> Void = { result in
                gate.resume(ready, with: result)
            }

            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.continuation.yield(.connected)
                    resumeOnce(.success(()))
                    self.startReceive()
                case .failed(let error):
                    resumeOnce(.failure(error))
                    self.finish(.closed(error: error.debugDescription))
                case .cancelled:
                    self.finish(.closed(error: nil))
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    public func send(_ line: String) async throws {
        guard let conn = lock.withLock({ connection }) else {
            throw IRCTransportError.notConnected
        }
        let data = Data((line + "\r\n").utf8)
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    done.resume(throwing: IRCTransportError.sendFailed(error.debugDescription))
                } else {
                    done.resume()
                }
            })
        }
    }

    public func close() async {
        finish(nil)
    }

    // MARK: - Receiving

    private func startReceive() {
        lock.withLock { connection }?.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.ingest(data)
            }
            if let error {
                self.finish(.closed(error: error.debugDescription))
                return
            }
            if isComplete {
                self.finish(.closed(error: nil))
                return
            }
            self.startReceive()
        }
    }

    /// Appends bytes and emits every complete line found (CRLF or LF).
    private func ingest(_ data: Data) {
        lock.withLock { receiveBuffer.append(data) }

        while true {
            var line: String?
            let overflowed = lock.withLock { () -> Bool in
                if let newline = receiveBuffer.firstIndex(of: 0x0A) {
                    var slice = receiveBuffer[receiveBuffer.startIndex..<newline]
                    if slice.last == 0x0D { slice.removeLast() }
                    receiveBuffer.removeSubrange(receiveBuffer.startIndex...newline)
                    line = String(decoding: slice, as: UTF8.self)
                } else if receiveBuffer.count > configuration.maxLineBytes {
                    return true
                }
                return false
            }

            if overflowed {
                finish(.closed(error: "line exceeded \(configuration.maxLineBytes) bytes"))
                return
            }
            guard let line else { return }
            continuation.yield(.line(line))
        }
    }

    /// Emits `event` (if given), tears down the socket, finishes the stream.
    private func finish(_ event: TransportEvent?) {
        let conn = lock.withLock { () -> NWConnection? in
            guard !finished else { return nil }
            finished = true
            let conn = connection
            connection = nil
            receiveBuffer.removeAll()
            return conn
        }
        guard conn != nil || event != nil else { return }
        conn?.stateUpdateHandler = nil
        conn?.cancel()
        if let event { continuation.yield(event) }
        continuation.finish()
    }
}

/// One-shot, thread-safe resume for a checked continuation.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func resume(_ continuation: CheckedContinuation<Void, Error>,
                with result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        continuation.resume(with: result)
    }
}
