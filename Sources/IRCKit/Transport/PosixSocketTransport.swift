#if !canImport(Network)
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Minimal POSIX-socket transport for non-Apple platforms (development/testing).
/// Plaintext only — TLS is not supported here; production builds use NWConnection.
public final class PosixSocketTransport: IRCTransport, @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let useTLS: Bool
    private var fd: Int32 = -1
    private var buffer: [UInt8] = []
    private var closed = false
    private var streamFinished = false
    private var readTask: Task<Void, Never>?

    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    public let lines: AsyncThrowingStream<String, Error>

    public init(host: String, port: UInt16, useTLS: Bool) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        var cont: AsyncThrowingStream<String, Error>.Continuation!
        lines = AsyncThrowingStream { cont = $0 }
        continuation = cont
    }

    public func open() async throws {
        guard !useTLS else { throw IRCError.tlsUnsupported }
        let socketFD = try Self.connect(host: host, port: port)
        fd = socketFD
        readTask = Task.detached { [weak self] in
            self?.readLoop()
        }
    }

    private static func connect(host: String, port: UInt16) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)

        var info: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &info)
        guard rc == 0, let first = info else {
            throw IRCError.dnsFailure(host)
        }
        defer { freeaddrinfo(info) }

        var lastError: Int32 = 0
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let addr = cursor?.pointee {
            let candidate = socket(addr.ai_family, addr.ai_socktype, addr.ai_protocol)
            if candidate >= 0 {
                if Glibc.connect(candidate, addr.ai_addr, addr.ai_addrlen) == 0 {
                    return candidate
                }
                lastError = errno
                _ = Glibc.close(candidate)
            }
            cursor = addr.ai_next
        }
        throw IRCError.connectFailed(lastError == 0 ? "no address" : String(cString: strerror(lastError)))
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 32 * 1024)
        while !Task.isCancelled {
            let n = chunk.withUnsafeMutableBytes { ptr in
                recv(fd, ptr.baseAddress, ptr.count, 0)
            }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                for line in IRCParser.extractLines(from: &buffer) {
                    continuation.yield(line)
                }
            } else if n == 0 {
                finish()
                return
            } else {
                if errno == EINTR { continue }
                fail()
                return
            }
        }
    }

    public func send(_ line: String) async throws {
        guard !closed, fd >= 0 else { throw IRCError.transportClosed }
        let data = Array((line + "\r\n").utf8)
        try data.withUnsafeBytes { ptr in
            var sent = 0
            while sent < data.count {
                let n = Glibc.send(fd, ptr.baseAddress!.advanced(by: sent), data.count - sent, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw IRCError.sendFailed(String(cString: strerror(errno)))
                }
                sent += n
            }
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        readTask?.cancel()
        if fd >= 0 {
            _ = Glibc.close(fd)
            fd = -1
        }
        finish()
    }

    private func finish() {
        guard !streamFinished else { return }
        streamFinished = true
        closed = true
        continuation.finish()
    }

    private func fail() {
        guard !streamFinished else { return }
        streamFinished = true
        closed = true
        continuation.finish(throwing: IRCError.transportClosed)
    }

}
#endif
