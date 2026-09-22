#if canImport(Network)
import Foundation
import Network

/// TLS-capable transport built on `NWConnection` (iOS, macOS).
public final class NWConnectionTransport: IRCTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "org.communitypoke.poke-irc.transport")
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var buffer: [UInt8] = []
    private var closed = false
    private var streamFinished = false

    public let lines: AsyncThrowingStream<String, Error>

    public init(host: String, port: UInt16, useTLS: Bool) {
        let params: NWParameters = useTLS ? .tls : .tcp
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: params
        )
        var cont: AsyncThrowingStream<String, Error>.Continuation!
        lines = AsyncThrowingStream { cont = $0 }
        continuation = cont
    }

    /// Start the connection and the receive loop.
    public func open() async throws {
        startInternal()
    }

    private func startInternal() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                self.fail(.connectFailed(error.localizedDescription))
            case .cancelled:
                self.finishStream()
            case .waiting(let error):
                self.fail(.connectFailed(error.localizedDescription))
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveNext()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                self.buffer.append(contentsOf: data)
                for line in IRCParser.extractLines(from: &self.buffer) {
                    self.continuation.yield(line)
                }
            }
            if let error {
                self.fail(.transportClosed)
                _ = error
                return
            }
            if isComplete {
                self.finishStream()
                return
            }
            self.receiveNext()
        }
    }

    public func send(_ line: String) async throws {
        guard !closed else { throw IRCError.transportClosed }
        let data = Data((line + "\r\n").utf8)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: IRCError.sendFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        connection.cancel()
        finishStream()
    }

    private func finishStream() {
        guard !streamFinished else { return }
        streamFinished = true
        closed = true
        continuation.finish()
    }

    private func fail(_ error: Error) {
        guard !streamFinished else { return }
        streamFinished = true
        closed = true
        continuation.finish(throwing: error)
        connection.cancel()
    }
}
#endif
