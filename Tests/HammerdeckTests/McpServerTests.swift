import XCTest
@testable import HammerdeckKit

// End-to-end tests for the MCP endpoint over a REAL loopback socket: NWListener
// bind, HTTP framing, the gate order (auth/method), the JSON-RPC handshake, and
// the tools riding the live Lua bridge (TestHost's real registry). URLSession
// runs off-main while the server dispatches on main, so waits PUMP the run loop
// rather than block it -- a semaphore here would deadlock the very dispatch the
// test is waiting for.

/// Thread-safe box for a value produced on a URLSession callback queue and read
/// on the main test thread (same shape as IntegrationTests' TestIntBox).
private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (status: Int, body: Data)?
    func set(_ v: (Int, Data)) { lock.lock(); value = v; lock.unlock() }
    func get() -> (status: Int, body: Data)? { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class McpServerTests: XCTestCase {
    var host: TestHost { TestHost.shared }
    // nonisolated so the `request` default argument (evaluated in varying
    // isolation contexts) can reference it; an immutable String is Sendable.
    private nonisolated static let token = "hammerdeck-test-token"

    // The async overrides are the shape a @MainActor XCTestCase may isolate
    // (IntegrationTests precedent); the sync ones must stay nonisolated and
    // then cannot touch `self`. The wait-until-ready lives in boundPort, on
    // the sync MainActor test path where run-loop pumping is safe.
    override func setUp() async throws {
        _ = host
        McpServer.shared.configure(lua: host.lua, store: host.store)
        McpServer.shared.start(port: 0, token: Self.token)   // 0 = ephemeral; read the bound port
    }

    override func tearDown() async throws {
        McpServer.shared.stop()
    }

    private var boundPort: UInt16 {
        waitFor { if case .running = McpServer.shared.status { return true }; return false }
        if case .running(let port) = McpServer.shared.status { return port }
        XCTFail("server not running: \(McpServer.shared.status)")
        return 0
    }

    /// Pump the main run loop until `cond` -- keeps the server's main-queue
    /// dispatch flowing while the test waits.
    private func waitFor(_ timeout: TimeInterval = 5, _ cond: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func request(method: String = "POST", body: String? = nil,
                         auth: String? = "Bearer \(McpServerTests.token)",
                         origin: String? = nil) -> (status: Int, body: Data) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(boundPort)/mcp")!)
        req.httpMethod = method
        if let body { req.httpBody = Data(body.utf8) }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let auth { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        if let origin { req.setValue(origin, forHTTPHeaderField: "Origin") }
        let box = ResponseBox()
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            box.set(((resp as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
        }.resume()
        waitFor { box.get() != nil }
        return box.get() ?? (0, Data())
    }

    private func rpc(_ method: String, params: String = "{}", id: Int = 1) -> (status: Int, json: [String: Any]) {
        let (status, body) = request(
            body: #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#)
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        return (status, json)
    }

    /// tools/call result -> the first text content block, parsed as JSON.
    private func toolJSON(_ name: String, args: String = "{}") -> (isError: Bool, value: Any?) {
        let (status, json) = rpc("tools/call", params: #"{"name":"\#(name)","arguments":\#(args)}"#)
        XCTAssertEqual(status, 200)
        guard let result = json["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            XCTFail("malformed tool result for \(name): \(json)")
            return (true, nil)
        }
        let isError = result["isError"] as? Bool ?? false
        return (isError, try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    func testRejectsWithoutToken() {
        XCTAssertEqual(request(body: "{}", auth: nil).status, 401)
        XCTAssertEqual(request(body: "{}", auth: "Bearer wrong").status, 401)
    }

    // The DNS-rebinding defense: a page on a site the user visited must not be
    // able to drive the endpoint from their own browser, EVEN with a token it
    // somehow learned. Rejected before any JSON is parsed.
    func testRejectsForeignOrigin() {
        XCTAssertEqual(request(body: "{}", origin: "https://evil.example").status, 403)
        // A local origin still passes the gate (it fails later, on JSON-RPC
        // grounds, not on Origin) -- so this is not blocking everything.
        XCTAssertNotEqual(request(body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
                                  origin: "http://localhost:3000").status, 403)
    }

    func testRejectsNonPost() {
        XCTAssertEqual(request(method: "GET").status, 405,
                       "no server-push stream is offered; GET must 405")
    }

    func testInitializeHandshake() {
        let (status, json) = rpc("initialize",
            params: #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}"#)
        XCTAssertEqual(status, 200)
        let result = json["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-06-18",
                       "a supported client version must be echoed back")
        let caps = result?["capabilities"] as? [String: Any]
        XCTAssertNotNil(caps?["tools"]); XCTAssertNotNil(caps?["resources"])

        // A notification is acknowledged with 202 and no body.
        let note = request(body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertEqual(note.status, 202)
        XCTAssertTrue(note.body.isEmpty)
    }

    func testMalformedBodyIsParseError() {
        let (status, body) = request(body: "{not json")
        XCTAssertEqual(status, 400)
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let code = (json?["error"] as? [String: Any])?["code"] as? Int
        XCTAssertEqual(code, -32700)
    }

    func testToolsListNamesTheFullSurface() {
        let (status, json) = rpc("tools/list")
        XCTAssertEqual(status, 200)
        let tools = ((json["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["list_features", "describe_feature", "get_extensions_dir",
                               "reload", "run_action", "read_log", "get_extension_guide"])
        for t in tools {
            XCTAssertNotNil(t["inputSchema"], "\(t["name"] ?? "?") is missing inputSchema")
        }
    }

    /// Every tool that takes a feature reference must spell it `feature_id`.
    /// Two tools naming the same thing differently (`id` here, `feature_id`
    /// there) is a contract an agent gets wrong on its first call and only
    /// learns from an error -- and the tool schema is the ONLY documentation it
    /// reads. A lint over the whole surface rather than a per-tool assertion:
    /// the defect is the inconsistency, so the next tool added is what it must
    /// catch.
    func testFeatureArgumentIsNamedConsistentlyAcrossTools() {
        let (_, json) = rpc("tools/list")
        let tools = ((json["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        XCTAssertFalse(tools.isEmpty, "tools/list returned nothing to check")
        for t in tools {
            let name = t["name"] as? String ?? "?"
            let schema = t["inputSchema"] as? [String: Any] ?? [:]
            let props = (schema["properties"] as? [String: Any]).map { Set($0.keys) } ?? []
            XCTAssertFalse(props.contains("id"),
                           "\(name) names a feature argument 'id'; use 'feature_id'")
        }
    }

    func testDescribeFeatureReadsOneRowByFeatureId() {
        let (isError, value) = toolJSON("describe_feature",
                                        args: #"{"feature_id":"display_off"}"#)
        XCTAssertFalse(isError)
        XCTAssertEqual((value as? [String: Any])?["id"] as? String, "display_off")
    }

    func testListFeaturesRidesTheLiveCatalog() {
        let (isError, value) = toolJSON("list_features")
        XCTAssertFalse(isError)
        let rows = value as? [[String: Any]] ?? []
        XCTAssertTrue(rows.contains { $0["id"] as? String == "display_off" },
                      "a known catalog feature must appear")
        XCTAssertTrue(rows.allSatisfy { $0["extension"] is Bool },
                      "every row carries the extension flag")
    }

    func testReloadReportsCountAndFailures() {
        let (isError, value) = toolJSON("reload")
        XCTAssertFalse(isError)
        let result = value as? [String: Any]
        XCTAssertEqual(result?["count"] as? Int, TestHost.diskFeatureCount)
        XCTAssertNotNil(result?["loadFailures"])
    }

    func testRunActionRefusesDisabledFeatureWithReason() {
        // Nothing is enabled in the test world by default, so the refusal path
        // (the one the guide teaches agents to expect) is what must speak.
        let (status, json) = rpc("tools/call",
            params: #"{"name":"run_action","arguments":{"feature_id":"display_off"}}"#)
        XCTAssertEqual(status, 200)
        let result = json["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("not enabled"), "the reason must name the cause: \(text)")
    }

    func testGuideIsServedAndValid() {
        let (status, json) = rpc("tools/call", params: #"{"name":"get_extension_guide","arguments":{}}"#)
        XCTAssertEqual(status, 200)
        let result = json["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, false)
        let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.hasPrefix("---\n"), "guide must carry skill frontmatter")
        XCTAssertTrue(text.contains("lua/init.lua"))
    }

    func testUnknownMethodAndUnknownResource() {
        let (_, unknown) = rpc("no/such/method")
        XCTAssertEqual(((unknown["error"] as? [String: Any])?["code"] as? Int), -32601)
        let (_, res) = rpc("resources/read", params: #"{"uri":"hammerdeck://nope"}"#)
        XCTAssertEqual(((res["error"] as? [String: Any])?["code"] as? Int), -32002)
    }
}
