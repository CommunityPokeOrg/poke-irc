import Foundation

/// Tracks IRCv3 capability negotiation state (CAP LS/REQ/ACK/NAK).
/// Pure value type — the session drives it and reads the decisions.
public struct CapabilityNegotiator: Sendable, Equatable {

    /// Capabilities advertised by the server: name → optional value
    /// (e.g. `"sasl" -> "PLAIN,EXTERNAL"`, `"multi-prefix" -> nil`).
    public private(set) var available: [String: String?] = [:]

    /// Capabilities we asked for, received an ACK for.
    public private(set) var acknowledged: Set<String> = []

    /// Capabilities the server refused.
    public private(set) var rejected: Set<String> = []

    /// REQ sent, awaiting ACK/NAK.
    public private(set) var pending: Set<String> = []

    /// Capabilities we want when the server offers them.
    public let desired: Set<String>

    /// Whether the LS listing is still being received (multiline `*` marker).
    public private(set) var lsInProgress = true

    public init(desired: Set<String> = CapabilityNegotiator.defaultDesired) {
        self.desired = desired
    }

    /// Caps requested when the server offers them and the caller supplies
    /// the matching prerequisites (e.g. sasl requires credentials —
    /// filter before constructing).
    public static let defaultDesired: Set<String> = [
        "server-time",
        "multi-prefix",
        "away-notify",
        "account-tag",
        "account-notify",
        "extended-join",
        "chghost",
        "echo-message",
        "batch",
        "labeled-response",
        "message-tags",
        "setname",
        "sasl",
    ]

    /// Records one `CAP * LS` line. `caps` is the trailing parameter's
    /// space-separated list; `isContinuation` mirrors the `*` marker param.
    public mutating func recordLS(_ caps: [String], isContinuation: Bool) {
        for entry in caps {
            let (name, value) = Self.parseCapEntry(entry)
            available[name] = value
        }
        lsInProgress = isContinuation
    }

    /// The next REQ batch once LS completes: desired ∩ available, minus
    /// anything already ACK/NAK'd. Empty when negotiation is finished.
    public mutating func nextRequest() -> Set<String> {
        guard !lsInProgress else { return [] }
        let wanted = desired.intersection(Set(available.keys))
        let outstanding = wanted.subtracting(acknowledged)
            .subtracting(rejected)
            .subtracting(pending)
        pending.formUnion(outstanding)
        return outstanding
    }

    /// Records an ACK; returns the newly acknowledged names.
    @discardableResult
    public mutating func recordACK(_ names: [String]) -> Set<String> {
        let acked = Set(names)
        acknowledged.formUnion(acked)
        pending.subtract(acked)
        return acked
    }

    /// Records a NAK; returns the rejected names.
    @discardableResult
    public mutating func recordNAK(_ names: [String]) -> Set<String> {
        let nacked = Set(names)
        rejected.formUnion(nacked)
        pending.subtract(nacked)
        return nacked
    }

    /// True when LS finished and no REQs are outstanding.
    public var isComplete: Bool {
        !lsInProgress && pending.isEmpty
    }

    /// Whether the server advertised a capability.
    public func supports(_ name: String) -> Bool {
        available.keys.contains(name)
    }

    /// The advertised value of a capability (nil = flag cap / unknown).
    public func value(of name: String) -> String? {
        available[name] ?? nil
    }

    /// Parses `name=value` or `name` into (lowercased name, optional value).
    static func parseCapEntry(_ entry: String) -> (String, String?) {
        if let eq = entry.firstIndex(of: "=") {
            return (String(entry[entry.startIndex..<eq]).lowercased(),
                    String(entry[entry.index(after: eq)...]))
        }
        // A leading '-' marks "capability removed" in LS; strip it.
        var name = entry
        if name.hasPrefix("-") { name.removeFirst() }
        return (name.lowercased(), nil)
    }
}
