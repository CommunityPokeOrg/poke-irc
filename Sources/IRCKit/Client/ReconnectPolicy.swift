import Foundation

/// Exponential-backoff reconnect policy with jitter.
public struct ReconnectPolicy: Sendable, Equatable {
    /// Delay before the first retry, in seconds.
    public var baseDelay: TimeInterval
    /// Upper bound for any single delay.
    public var maxDelay: TimeInterval
    /// Growth factor per attempt.
    public var multiplier: Double
    /// Fraction of the delay randomized away (0...1).
    public var jitter: Double
    /// Maximum retry attempts; `nil` retries forever.
    public var maxAttempts: Int?

    public init(
        baseDelay: TimeInterval = 2,
        maxDelay: TimeInterval = 120,
        multiplier: Double = 1.8,
        jitter: Double = 0.25,
        maxAttempts: Int? = nil
    ) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.jitter = jitter
        self.maxAttempts = maxAttempts
    }

    public static let `default` = ReconnectPolicy()

    /// Whether attempt `n` (1-based) is permitted.
    public func permits(attempt: Int) -> Bool {
        guard let maxAttempts else { return true }
        return attempt <= maxAttempts
    }

    /// Deterministic delay for attempt `n` before jitter.
    public func baseDelay(forAttempt n: Int) -> TimeInterval {
        let n = max(0, n - 1)
        return min(maxDelay, baseDelay * pow(multiplier, Double(n)))
    }

    /// Delay for attempt `n` including random jitter.
    public func delay(forAttempt n: Int, random: Double = Double.random(in: 0...1)) -> TimeInterval {
        let base = baseDelay(forAttempt: n)
        let spread = base * jitter
        return max(0, base - spread + (2 * spread * random))
    }
}
