import XCTest
@testable import IRCKit

final class SASLAuthenticatorTests: XCTestCase {

    func testPlainPayload() {
        let credentials = SASLCredentials(account: "poke", password: "hunter2")
        // base64("\0poke\0hunter2")
        XCTAssertEqual(SASLAuthenticator.plainPayload(credentials),
                       "AHBva2UAaHVudGVyMg==")
    }

    func testPlainPayloadWithAuthzid() {
        let credentials = SASLCredentials(account: "poke", password: "pw",
                                          authzid: "admin")
        let decoded = String(decoding: Data(
            base64Encoded: SASLAuthenticator.plainPayload(credentials))!,
            as: UTF8.self)
        XCTAssertEqual(decoded, "admin\0poke\0pw")
    }

    func testChunking() {
        // 400-byte payload → 1 chunk + trailing "+".
        let exact = String(repeating: "a", count: 400)
        XCTAssertEqual(SASLAuthenticator.chunks(for: exact), [exact, "+"])
        // 401 → 400 + 1.
        let over = String(repeating: "b", count: 401)
        let chunks = SASLAuthenticator.chunks(for: over)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, 400)
        XCTAssertEqual(chunks[1], "b")
        // Empty → ["+"]
        XCTAssertEqual(SASLAuthenticator.chunks(for: ""), ["+"])
        // Under limit → single chunk, no "+".
        XCTAssertEqual(SASLAuthenticator.chunks(for: "abc"), ["abc"])
    }
}

final class CapabilityNegotiatorTests: XCTestCase {

    func testLSAccumulates() {
        var negotiator = CapabilityNegotiator(desired: ["sasl", "batch"])
        negotiator.recordLS(["multi-prefix", "sasl=PLAIN,EXTERNAL"],
                            isContinuation: true)
        XCTAssertTrue(negotiator.lsInProgress)
        XCTAssertEqual(negotiator.nextRequest(), [])  // still waiting
        negotiator.recordLS(["batch", "server-time"], isContinuation: false)
        XCTAssertFalse(negotiator.lsInProgress)
        let request = negotiator.nextRequest()
        XCTAssertEqual(request, ["sasl", "batch"])   // desired ∩ available
        XCTAssertEqual(negotiator.value(of: "sasl"), "PLAIN,EXTERNAL")
        XCTAssertTrue(negotiator.supports("server-time"))
    }

    func testACKandNAK() {
        var negotiator = CapabilityNegotiator(desired: ["sasl", "zzz"])
        negotiator.recordLS(["sasl", "zzz"], isContinuation: false)
        _ = negotiator.nextRequest()
        XCTAssertEqual(negotiator.pending, ["sasl", "zzz"])
        negotiator.recordACK(["sasl"])
        negotiator.recordNAK(["zzz"])
        XCTAssertEqual(negotiator.acknowledged, ["sasl"])
        XCTAssertEqual(negotiator.rejected, ["zzz"])
        XCTAssertTrue(negotiator.isComplete)
    }

    func testNothingDesiredAvailable() {
        var negotiator = CapabilityNegotiator(desired: ["sasl"])
        negotiator.recordLS(["multi-prefix"], isContinuation: false)
        XCTAssertEqual(negotiator.nextRequest(), [])
        XCTAssertTrue(negotiator.isComplete)
    }

    func testDashPrefixStripped() {
        var negotiator = CapabilityNegotiator(desired: ["sasl"])
        negotiator.recordLS(["-sasl", "batch"], isContinuation: false)
        XCTAssertTrue(negotiator.supports("sasl"))
    }
}
