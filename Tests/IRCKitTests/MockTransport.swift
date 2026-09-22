import Foundation
@testable import IRCKit

/// Scriptable in-memory transport: tests feed inbound lines and capture sends.
final class MockTransport: IRCTransport, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    let lines: AsyncThrowingStream<String, Error>

    private(set) var sent: [String] = []
    private(set) var openCount = 0
    private(set) var closed = false

    init() {
        var cont: AsyncThrowingStream<String, Error>.Continuation!
        lines = AsyncThrowingStream { cont = $0 }
        continuation = cont
    }

    func open() async throws {
        openCount += 1
        closed = false
    }

    func send(_ line: String) async throws {
        sent.append(line)
    }

    func close() async {
        closed = true
        finish()
    }

    /// Server → client.
    func feed(_ line: String) {
        continuation.yield(line)
    }

    /// End the stream as if the server hung up.
    func hangUp() {
        finish()
    }

    private func finish() {
        continuation.finish()
    }

    /// Poll until at least `n` lines have been sent (test synchronization).
    func waitForSent(_ n: Int, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while sent.count < n {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }
}
