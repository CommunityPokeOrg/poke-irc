import Foundation

/// SASL credentials for account authentication during registration.
public struct SASLCredentials: Sendable, Equatable, Codable {
    /// Authorization identity (usually empty — same as authcid).
    public var authzid: String
    /// Authentication identity: the account name.
    public var authcid: String
    public var password: String

    public init(account: String, password: String, authzid: String = "") {
        self.authzid = authzid
        self.authcid = account
        self.password = password
    }
}

/// IRCv3 SASL authentication helpers. Only the PLAIN mechanism is supported —
/// the most widely deployed mechanism on IRC networks.
public enum SASLMechanism: String, Sendable {
    case plain = "PLAIN"
}

/// Produces `AUTHENTICATE` payloads for a SASL exchange.
public enum SASLAuthenticator {

    /// Maximum bytes per AUTHENTICATE message (per IRCv3 sasl spec).
    public static let chunkLength = 400

    /// Base64 PLAIN payload: `authzid \0 authcid \0 password`.
    public static func plainPayload(_ credentials: SASLCredentials) -> String {
        let raw = "\(credentials.authzid)\0\(credentials.authcid)\0\(credentials.password)"
        return Data(raw.utf8).base64EncodedString()
    }

    /// Splits a payload into ≤400-byte chunks as required by the spec.
    /// An exactly-400-byte-ending payload gets a trailing "+" chunk; an empty
    /// payload is a single "+".
    public static func chunks(for payload: String) -> [String] {
        if payload.isEmpty { return ["+"] }
        var chunks: [String] = []
        var index = payload.startIndex
        while index < payload.endIndex {
            let end = payload.index(index, offsetBy: chunkLength,
                                    limitedBy: payload.endIndex) ?? payload.endIndex
            chunks.append(String(payload[index..<end]))
            index = end
        }
        if let last = chunks.last, last.utf8.count == chunkLength {
            chunks.append("+")
        }
        return chunks
    }

    /// AUTHENTICATE argument sequence for a PLAIN exchange.
    public static func authenticateSequence(_ credentials: SASLCredentials) -> [String] {
        chunks(for: plainPayload(credentials))
    }
}

/// Numeric replies relevant to SASL (IRCv3 / RFC numerics).
public enum IRCNumeric: String, Sendable {
    case welcome = "001"
    case loggedIn = "900"          // RPL_LOGGEDIN
    case loggedOut = "901"         // RPL_LOGGEDOUT
    case nickLocked = "902"        // ERR_NICKLOCKED
    case saslSuccess = "903"       // RPL_SASLSUCCESS
    case saslFail = "904"          // ERR_SASLFAIL
    case saslTooLong = "905"       // ERR_SASLTOOLONG
    case saslAborted = "906"       // ERR_SASLABORTED
    case saslAlready = "907"       // ERR_SASLALREADY
    case saslMechs = "908"         // RPL_SASLMECHS
}
