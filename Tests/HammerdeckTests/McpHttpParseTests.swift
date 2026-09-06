// McpHttpParseTests -- the MCP listener's HTTP framing, without a socket.
//
// McpHttpAccumulator was reachable only through a live NWConnection, so every
// refusal it encodes (oversized, chunked, malformed) was asserted by nothing:
// a regression here surfaces as an agent that hangs or 500s, on a port that is
// off by default and therefore rarely exercised by hand.

import XCTest
@testable import HammerdeckKit

final class McpHttpParseTests: XCTestCase {

    private func feed(_ chunks: [String]) -> McpHttpParse {
        let acc = McpHttpAccumulator()
        var last: McpHttpParse = .needMore
        for c in chunks { last = acc.append(Data(c.utf8)) }
        return last
    }

    private func post(body: String, headers: String = "") -> String {
        "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + headers
            + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
    }

    // MARK: - The happy shape

    func testParsesAWholeRequest() {
        guard case .request(let r) = feed([post(body: #"{"id":1}"#)]) else {
            return XCTFail("a complete POST must parse")
        }
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/mcp")
        XCTAssertEqual(String(data: r.body, encoding: .utf8), #"{"id":1}"#)
    }

    func testHeaderKeysAreLowercasedAndValuesTrimmed() {
        guard case .request(let r) = feed([post(body: "{}", headers: "AuThOrIzAtIoN:   Bearer tok\r\n")])
        else { return XCTFail("must parse") }
        // Lookup sites spell the key one way; HTTP lets a client spell it any
        // way. Lowercasing at the parse edge is what keeps `headers["authorization"]`
        // -- the token check -- from silently missing a valid request.
        XCTAssertEqual(r.headers["authorization"], "Bearer tok")
        XCTAssertNil(r.headers["AuThOrIzAtIoN"], "the original casing must not also be stored")
    }

    func testARequestSplitAcrossReadsIsAssembled() {
        let whole = post(body: #"{"a":123}"#)
        let cut = whole.index(whole.startIndex, offsetBy: 30)
        // TCP does not deliver messages, it delivers bytes -- a split mid-header
        // is the normal case, not an edge case.
        let acc = McpHttpAccumulator()
        if case .request = acc.append(Data(whole[..<cut].utf8)) {
            XCTFail("half a request must not parse")
        }
        guard case .request(let r) = acc.append(Data(whole[cut...].utf8)) else {
            return XCTFail("the second read must complete it")
        }
        XCTAssertEqual(String(data: r.body, encoding: .utf8), #"{"a":123}"#)
    }

    func testABodyArrivingAfterTheHeadersIsWaitedFor() {
        let acc = McpHttpAccumulator()
        guard case .needMore = acc.append(Data("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\n".utf8))
        else { return XCTFail("headers alone are not a request when a body is promised") }
        guard case .request(let r) = acc.append(Data("hello".utf8)) else {
            return XCTFail("the body completes it")
        }
        XCTAssertEqual(String(data: r.body, encoding: .utf8), "hello")
    }

    func testAGetWithNoContentLengthParsesImmediately() {
        guard case .request(let r) = feed(["GET /mcp HTTP/1.1\r\nHost: x\r\n\r\n"]) else {
            return XCTFail("an absent Content-Length means no body, not a bad request")
        }
        XCTAssertEqual(r.method, "GET")
        XCTAssertTrue(r.body.isEmpty)
    }

    // MARK: - The refusals

    func testChunkedIsRefusedWith411() {
        // Deliberately unsupported: the server is one-POST-per-connection. The
        // refusal must be explicit, because silently reading a chunked body as
        // literal bytes would hand the JSON parser the chunk framing.
        guard case .error(let status, _) =
                feed(["POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"])
        else { return XCTFail("chunked must be refused") }
        XCTAssertEqual(status, 411)
    }

    func testAnOversizedBodyIsRefusedBeforeItIsRead() {
        // The cap must be applied from the DECLARED length, not by accumulating
        // until it is exceeded -- otherwise the refusal costs the memory it exists
        // to refuse.
        guard case .error(let status, _) =
                feed(["POST /mcp HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n"])
        else { return XCTFail("a body over 1 MiB must be refused") }
        XCTAssertEqual(status, 413)
    }

    func testUnterminatedHeadersAreRefusedWith431() {
        let acc = McpHttpAccumulator()
        var result: McpHttpParse = .needMore
        // No CRLFCRLF ever arrives: without a cap this accumulates forever.
        for _ in 0..<3 { result = acc.append(Data(String(repeating: "x", count: 8 * 1024).utf8)) }
        guard case .error(let status, _) = result else {
            return XCTFail("unterminated headers must not accumulate without bound")
        }
        XCTAssertEqual(status, 431)
    }

    func testAMalformedRequestLineIsRefusedWith400() {
        guard case .error(let status, _) = feed(["NONSENSE\r\n\r\n"]) else {
            return XCTFail("a request line that is not `METHOD PATH VERSION` must be refused")
        }
        XCTAssertEqual(status, 400)
    }

    func testAHeaderLineWithoutAColonIsRefusedWith400() {
        guard case .error(let status, _) = feed(["GET /mcp HTTP/1.1\r\ngarbage\r\n\r\n"]) else {
            return XCTFail("a header line with no colon must be refused")
        }
        XCTAssertEqual(status, 400)
    }

    func testANonNumericContentLengthIsRefusedWith400() {
        // `Int(...) ?? -1` then `>= 0` is the guard. A negative or unparseable
        // length reaching `expectedBody` would make the accumulator wait forever
        // for a body that can never arrive.
        for bad in ["abc", "-1", "1 2"] {
            guard case .error(let status, _) =
                    feed(["POST /mcp HTTP/1.1\r\nContent-Length: \(bad)\r\n\r\n"])
            else { return XCTFail("Content-Length: \(bad) must be refused") }
            XCTAssertEqual(status, 400, "for Content-Length: \(bad)")
        }
    }

    // MARK: - Response building

    func testResponseAlwaysCarriesLengthAndClose() {
        let out = String(data: McpHttp.json(["ok": true]), encoding: .utf8) ?? ""
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK\r\n"), out)
        XCTAssertTrue(out.contains("Content-Type: application/json\r\n"), out)
        XCTAssertTrue(out.contains("Connection: close\r\n"), out)
        // A one-request-per-connection server that omits Content-Length leaves the
        // client waiting on a body it has already received.
        XCTAssertTrue(out.contains("Content-Length: \(#"{"ok":true}"#.utf8.count)\r\n"), out)
        XCTAssertTrue(out.hasSuffix(#"{"ok":true}"#), out)
    }

    func testAnUnencodableResultIsRefusedInsteadOfCrashingTheHost() {
        // JSONSerialization RAISES an ObjC exception for an invalid object --
        // `try?` does not catch it, so the pre-check is the only thing between a
        // malformed result and the app dying.
        //
        // The infinity case is the REACHABLE one, and it is why this matters:
        // `LuaState.any` maps every Lua number through `double()`, and Lua hands
        // out `math.huge` and `0/0` freely. A tool returning one crashed the host
        // outright before the pre-check -- `McpServer` boxes a tool result
        // straight into this call.
        //
        // A nil is deliberately NOT in this list: it bridges to NSNull and
        // encodes as `null`, so treating it as unencodable would be wrong.
        for bad: Any in [["n": Double.infinity] as [String: Any],
                         ["n": Double.nan] as [String: Any],
                         Date(), "a bare string", ["at": Date()] as [String: Any]] {
            let out = String(data: McpHttp.json(bad), encoding: .utf8) ?? ""
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 500 "), "for \(type(of: bad)): \(out)")
            XCTAssertTrue(out.contains("not encodable"), out)
        }
        // ...and a valid payload is untouched by the guard.
        let ok = String(data: McpHttp.json(["n": 1]), encoding: .utf8) ?? ""
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200 OK\r\n"), ok)
    }
}
