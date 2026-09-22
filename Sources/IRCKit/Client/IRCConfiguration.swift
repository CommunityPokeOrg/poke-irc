import Foundation

/// Static configuration for one IRC server connection.
public struct IRCConfiguration: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var useTLS: Bool
    public var nickname: String
    public var username: String
    public var realname: String
    /// Server password (PASS), if the network requires one.
    public var serverPassword: String?
    /// SASL PLAIN credentials. Sent only when the server ACKs the `sasl` cap.
    public var sasl: SASLCredentials?
    /// IRCv3 capabilities to request on top of the client's defaults.
    public var requestedCapabilities: [String]
    /// Channels joined automatically after registration.
    public var autoJoinChannels: [String]
    /// Time between client-initiated PINGs to keep the NAT/session alive.
    public var pingInterval: TimeInterval
    /// How long to wait for a PONG before treating the link as dead.
    public var pingTimeout: TimeInterval
    public var reconnect: ReconnectPolicy

    public init(
        host: String,
        port: UInt16? = nil,
        useTLS: Bool = true,
        nickname: String,
        username: String? = nil,
        realname: String? = nil,
        serverPassword: String? = nil,
        sasl: SASLCredentials? = nil,
        requestedCapabilities: [String] = [],
        autoJoinChannels: [String] = [],
        pingInterval: TimeInterval = 60,
        pingTimeout: TimeInterval = 30,
        reconnect: ReconnectPolicy = .default
    ) {
        self.host = host
        self.port = port ?? (useTLS ? 6697 : 6667)
        self.useTLS = useTLS
        self.nickname = nickname
        self.username = username ?? nickname
        self.realname = realname ?? nickname
        self.serverPassword = serverPassword
        self.sasl = sasl
        self.requestedCapabilities = requestedCapabilities
        self.autoJoinChannels = autoJoinChannels
        self.pingInterval = pingInterval
        self.pingTimeout = pingTimeout
        self.reconnect = reconnect
    }
}

/// SASL PLAIN (and future mechanisms) credentials.
public struct SASLCredentials: Sendable, Equatable {
    public enum Mechanism: String, Sendable {
        case plain = "PLAIN"
    }

    public var mechanism: Mechanism
    public var account: String
    public var password: String
    /// Optional authzid; defaults to the account name.
    public var authorizationIdentity: String?

    public init(account: String, password: String, authorizationIdentity: String? = nil) {
        self.mechanism = .plain
        self.account = account
        self.password = password
        self.authorizationIdentity = authorizationIdentity
    }

    /// Base64 of `authzid \0 authcid \0 passwd`.
    public var plainChallenge: String {
        let authzid = authorizationIdentity ?? account
        let raw = "\(authzid)\u{0}\(account)\u{0}\(password)"
        return Data(raw.utf8).base64EncodedString()
    }
}

/// IRCv3 capability set negotiated by the client.
public enum IRCCapability {
    /// Capabilities the client always asks for when offered.
    public static let defaultDesired: Set<String> = [
        "message-tags",
        "server-time",
        "echo-message",
        "away-notify",
        "account-tag",
        "extended-join",
        "multi-prefix",
        "userhost-in-names",
        "chghost"
    ]

    /// Caps the client only requests when it has SASL credentials.
    public static let sasl = "sasl"
}
