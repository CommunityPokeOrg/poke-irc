import Foundation

/// Everything needed to open a session to one network.
public struct IRCServerConfig: Sendable, Equatable, Codable {
    public var host: String
    public var port: UInt16
    public var useTLS: Bool

    public var nickname: String
    public var username: String
    public var realname: String

    /// Server password (PASS), optional.
    public var serverPassword: String?

    /// SASL account credentials, optional. When present and the server
    /// advertises `sasl`, authentication runs during registration.
    public var sasl: SASLCredentials?

    /// Capabilities to request when offered. Defaults to the standard set.
    public var desiredCapabilities: Set<String>

    public init(
        host: String,
        port: UInt16 = 6697,
        useTLS: Bool = true,
        nickname: String,
        username: String? = nil,
        realname: String? = nil,
        serverPassword: String? = nil,
        sasl: SASLCredentials? = nil,
        desiredCapabilities: Set<String>? = nil
    ) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.nickname = nickname
        self.username = username ?? nickname
        self.realname = realname ?? nickname
        self.serverPassword = serverPassword
        self.sasl = sasl
        var desired = desiredCapabilities ?? CapabilityNegotiator.defaultDesired
        if sasl == nil { desired.remove("sasl") }
        self.desiredCapabilities = desired
    }
}

