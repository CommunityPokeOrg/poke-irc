import Foundation

/// Parsing for IRCv3 `server-time` timestamps (`YYYY-MM-DDThh:mm:ss.sssZ`).
public enum IRCTime {
    /// ISO8601DateFormatter is not Sendable; build one per call.
    public static func parse(_ tagValue: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: tagValue) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: tagValue)
    }
}
