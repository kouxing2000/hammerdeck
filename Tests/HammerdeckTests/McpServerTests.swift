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
                               "reload", "run_action", "validate_extension", "list_api",
                               "set_enabled", "read_log", "get_extension_guide"])
        for t in tools {
            XCTAssertNotNil(t["inputSchema"], "\(t["name"] ?? "?") is missing inputSchema")
        }
    }

    /// The guide is the ONLY documentation an agent reads before it starts
    /// calling, and `get_extension_guide` serves it from disk -- so a tool the
    /// guide never mentions is a tool nothing will call, and a tool the guide
    /// describes but the server dropped is an instruction that fails. Neither
    /// shows up in any other check: the guide's own parity gate
    /// (agent_guide.lua) covers the capability and option vocabularies, and
    /// cannot see the Swift tool table at all.
    func testEveryToolIsNamedInTheAuthoringGuide() throws {
        let guideText = try String(contentsOfFile: McpServer.guidePath, encoding: .utf8)
        XCTAssertTrue(guideText.contains("authoring loop over MCP"),
                      "the guide was not read -- an empty haystack matches nothing")
        let (_, json) = rpc("tools/list")
        let tools = ((json["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        XCTAssertFalse(tools.isEmpty)
        for t in tools {
            let name = t["name"] as? String ?? "?"
            XCTAssertTrue(guideText.contains("`\(name)`"),
                          "the guide never mentions the \(name) tool")
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

    // validate_extension is for the USER's own code. Pointed at a built-in it
    // must refuse by name rather than quietly scanning app/features and
    // reporting on something the caller cannot edit.
    func testValidateExtensionRefusesABuiltIn() {
        let (status, json) = rpc("tools/call",
            params: #"{"name":"validate_extension","arguments":{"feature_id":"display_off"}}"#)
        XCTAssertEqual(status, 200)
        let result = json["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true, "a built-in is not a valid target")
        let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("built-in"), "the refusal must name the cause: \(text)")
    }

    // list_api's whole value is the SPLIT: a withheld method is a raising stub,
    // so the ctx table has the key either way and an agent probing at runtime
    // learns nothing. Asserted against a feature whose declaration is known
    // (display_off declares power and nothing else), plus the invariant that the
    // two sides never overlap -- which is what would break if the report were
    // ever assembled from anything other than the built ctx.
    func testListApiSplitsAvailableFromWithheld() {
        let (isError, value) = toolJSON("list_api", args: #"{"feature_id":"display_off"}"#)
        XCTAssertFalse(isError)
        let report = value as? [String: Any] ?? [:]
        let available = Set(report["available"] as? [String] ?? [])
        let withheld = report["withheld"] as? [String: String] ?? [:]
        XCTAssertFalse(available.isEmpty, "no surface was reported -- the tool did not run")

        XCTAssertTrue(available.contains("lockScreen"), "a DECLARED tier's method is available")
        XCTAssertEqual(withheld["httpGet"], "network",
                       "an undeclared tier is withheld, named with the capability")
        XCTAssertTrue(available.isDisjoint(with: Set(withheld.keys)),
                      "available and withheld must never name the same method")
        XCTAssertEqual(report["granted"] as? [String] ?? [], ["power"])
        XCTAssertTrue(available.contains("window.setFrame"),
                      "the ctx.window.* sub-surface is expanded, not hidden behind its parent")
    }

    func testListApiRefusesAnUnknownFeature() {
        let (status, json) = rpc("tools/call",
            params: #"{"name":"list_api","arguments":{"feature_id":"no_such_thing"}}"#)
        XCTAssertEqual(status, 200)
        let result = json["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
    }

    // set_enabled exists to unblock exactly this sequence: run_action refuses a
    // disabled feature, so an agent that just wrote an extension could not
    // test-fire it without a human clicking Settings. The test drives the whole
    // sequence rather than asserting the flag, because the flag was never the
    // point.
    func testSetEnabledUnblocksRunAction() {
        // count_down deliberately: it declares no `requires`, so the result has
        // no `warning` key and the assertions below stay identical on a granted
        // machine and on CI, where nothing is granted. Enabling is one policy --
        // an AX-requiring feature enables too -- but its result carries the extra
        // key, which is a second shape this test has no reason to straddle.
        let id = "count_down"
        func enabled() -> Bool {
            host.store.features.first { $0.id == id }?.enabled == true
        }
        let wasEnabled = enabled()
        defer { host.store.setEnabled(id, wasEnabled) }

        host.store.setEnabled(id, false)
        let (blocked, _) = toolJSON("run_action", args: #"{"feature_id":"\#(id)"}"#)
        XCTAssertTrue(blocked, "run_action must refuse a disabled feature -- the premise")

        let (isError, value) = toolJSON("set_enabled",
                                        args: #"{"feature_id":"\#(id)","enabled":true}"#)
        XCTAssertFalse(isError)
        XCTAssertEqual((value as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertTrue(enabled(), "the tool must move the SAME state Settings reads")
    }

    // set_enabled's Accessibility WARNING reads `requires` straight off the
    // describe row. The warning BRANCH cannot be asserted here -- it depends on
    // whether this machine has granted Accessibility -- so what must be pinned
    // is the read: if that key ever stopped decoding as [String], the warning
    // would silently never fire and an agent would be told nothing about why a
    // feature it just enabled does nothing when fired.
    func testDescribeRowCarriesRequiresAsStrings() {
        let (isError, value) = toolJSON("describe_feature",
                                        args: #"{"feature_id":"window_switcher"}"#)
        XCTAssertFalse(isError)
        let requires = (value as? [String: Any])?["requires"] as? [String]
        XCTAssertNotNil(requires, "requires must decode as [String] -- set_enabled's guard reads it")
        XCTAssertEqual(requires, ["accessibility"],
                       "window_switcher is the guard's worked example; if this changed, "
                       + "re-point the test rather than deleting it")
    }

    func testSetEnabledRefusesAnUnknownFeature() {
        let (status, json) = rpc("tools/call",
            params: #"{"name":"set_enabled","arguments":{"feature_id":"no_such_thing","enabled":true}}"#)
        XCTAssertEqual(status, 200)
        let result = json["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true, "an unknown id is the caller's mistake")
        let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("no such feature"), "the refusal must name the cause: \(text)")
    }

    // set_enabled discriminates a load FAILURE (a synthetic describe row with no
    // entry in the registry's feature table) from a healthy one by `kind`. The
    // refusal branch itself needs a broken extension on disk and is not exercised
    // here; what is pinned is that the discriminator cannot MISFIRE -- if any
    // real feature ever reported kind "failed", the tool would start refusing to
    // enable working features.
    func testNoHealthyFeatureReportsTheFailedKind() {
        let (isError, value) = toolJSON("list_features")
        XCTAssertFalse(isError)
        let rows = value as? [[String: Any]] ?? []
        XCTAssertFalse(rows.isEmpty, "an empty catalog would pass this vacuously")
        for row in rows where row["failed"] as? Bool != true {
            XCTAssertNotEqual(row["kind"] as? String, "failed",
                              "\(row["id"] ?? "?") is healthy but claims kind=failed")
        }
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

    // read_log's `lines` arrives as untrusted JSON, and JSONSerialization hands
    // any unsuffixed number back as a Double. `Int(someDouble)` TRAPS outside
    // Int's range, so converting before clamping made one authenticated request
    // -- {"lines": 1e100} -- kill the whole host process with SIGTRAP, taking
    // every running feature with it. The clamp has to happen in Double space.
    //
    // Driven through the real MCP dispatch rather than against the expression,
    // because the defect was in the ORDER of two operations that both still
    // exist: a unit test on a clamp helper would pass either way. A crash here
    // takes the test runner down with it, so a failure is unmissable.
    //
    // 200 and 400 are both PASSES: a literal past Double's own range (9.9e308,
    // 1e400) is rejected by the JSON parser before dispatch ever sees it, which
    // is the parser doing its job. The only failure mode this test hunts is the
    // one that produces no status at all.
    func testReadLogSurvivesOutOfRangeLineCounts() {
        let hostile = ["1e100", "-1e100", "9.9e308", "-9.9e308", "1e400", "-1e400",
                       "1e19", "-1e19", "0.5", "-0.5", "0", "-1",
                       "1", "2000", "2001", "1.5e3"]
        for raw in hostile {
            let (status, json) = rpc("tools/call",
                params: "{\"name\":\"read_log\",\"arguments\":{\"lines\":\(raw)}}")
            XCTAssertTrue(status == 200 || status == 400,
                          "read_log lines=\(raw) answered \(status)")
            if status == 200 {
                // A log, or "no log file yet" -- both are answers. The point is
                // that the process is still alive to give one.
                XCTAssertNotNil(json["result"], "read_log lines=\(raw) produced no result")
            }
        }
        // The positive landmark. Without it the loop above would pass just as
        // well against a socket that had stopped answering, since an assertion
        // that only accepts two statuses cannot tell a live server from a dead
        // one it never reached.
        let (status, json) = rpc("tools/call",
                                 params: #"{"name":"read_log","arguments":{"lines":10}}"#)
        XCTAssertEqual(status, 200, "the endpoint stopped serving after the hostile inputs")
        XCTAssertNotNil(json["result"])
    }

    func testUnknownMethodAndUnknownResource() {
        let (_, unknown) = rpc("no/such/method")
        XCTAssertEqual(((unknown["error"] as? [String: Any])?["code"] as? Int), -32601)
        let (_, res) = rpc("resources/read", params: #"{"uri":"hammerdeck://nope"}"#)
        XCTAssertEqual(((res["error"] as? [String: Any])?["code"] as? Int), -32002)
    }
}
