// The opt-in local MCP endpoint: lets a coding agent (Claude Code et al.)
// drive the extension-authoring loop against the RUNNING app -- list/describe
// the catalog, reload + read load failures, test-fire an enabled action, tail
// the daily log, and fetch the authoring guide. HOST INFRA, not a seam slice:
// it CONSUMES the bridge via LuaState.call (data never enters Lua source) and
// adds no OS surface for Lua, so it lives beside StatusBar, not in Native+*.
//
// Ships in release (unlike DebugControl, which is #if DEBUG): the gate is the
// hammerdeck.mcp.enabled preference (off by default), a loopback-only bind,
// a bearer token minted on first enable, and an Origin check. Protocol shape
// is the MCP "streamable HTTP" transport in its minimal stateless form: one
// POST per connection, single JSON object responses (no SSE, no sessions --
// spec-legal, and what Claude Code's fetch-based client speaks).
//
// Concurrency: the listener + HTTP parsing run on a private queue; EVERY
// bridge call happens on the main actor (LuaState asserts main thread) --
// the queue hands the raw body Data across and gets a full response Data
// back, so nothing non-Sendable crosses the boundary.

import Foundation
import Network

@MainActor
final class McpServer: ObservableObject {
    static let shared = McpServer()

    enum Status: Equatable {
        case off
        case starting
        case running(UInt16)   // the BOUND port (differs from the asked-for one when 0)
        case failed(String)
    }

    @Published private(set) var status: Status = .off

    private var lua: LuaState?
    private var store: SettingsStore?
    private let queue = DispatchQueue(label: "hammerdeck.mcp")
    private var listener: NWListener?
    private let connections = McpConnectionBag()

    /// Wire the bridge + read model once at boot (Boot.swift), before any start().
    func configure(lua: LuaState, store: SettingsStore) {
        self.lua = lua
        self.store = store
    }

    /// Start from the stored preferences (boot / toggle-on path).
    func startFromPreferences() {
        start(port: McpPreference.port, token: McpPreference.mintTokenIfNeeded())
    }

    /// Start listening on 127.0.0.1:`port` (0 = ephemeral, for tests). Restarts
    /// cleanly if already running.
    func start(port: UInt16, token: String) {
        stop()
        status = .starting
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback ONLY. This is the whole network posture: nothing off-machine
        // can ever reach the listener, whatever the token situation.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            status = .failed("\(error)")
            Native.shared.seamLog("mcp: listener init failed: \(error)")
            return
        }
        self.listener = listener

        let bag = connections
        let rpc = makeRpcHandler()
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            // On the mcp queue; status writes hop to main.
            switch state {
            case .ready:
                let bound = listener?.port?.rawValue ?? 0
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.listener === listener else { return }
                        self.status = .running(bound)
                        Native.shared.seamLog("mcp: listening on 127.0.0.1:\(bound)")
                    }
                }
            case .failed(let error):
                // The port-in-use surface (EADDRINUSE) among others.
                listener?.cancel()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.listener === listener else { return }
                        self.listener = nil
                        self.status = .failed("\(error)")
                        Native.shared.seamLog("mcp: listener failed: \(error)")
                    }
                }
            default:
                break
            }
        }
        let queue = self.queue
        listener.newConnectionHandler = { conn in
            bag.add(conn)
            conn.stateUpdateHandler = { st in
                switch st {
                case .failed, .cancelled: bag.remove(conn)
                default: break
                }
            }
            conn.start(queue: queue)
            Self.receive(conn, McpHttpAccumulator(), token: token, rpc: rpc, bag: bag)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.cancelAll()
        if status != .off {
            status = .off
            Native.shared.seamLog("mcp: stopped")
        }
    }

    // MARK: - Queue side (nonisolated: HTTP framing + gates that need no Lua)

    /// Body-in, full-HTTP-response-out, across the queue/main boundary. Only
    /// Sendable Data crosses; JSON parsing and every Lua call happen on main.
    private typealias RpcHandler = @Sendable (_ body: Data, _ reply: @escaping @Sendable (Data) -> Void) -> Void

    private func makeRpcHandler() -> RpcHandler {
        return { [weak self] body, reply in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let response = self?.handleRpcBody(body)
                        ?? McpHttp.response(status: 503, reason: "Service Unavailable")
                    reply(response)
                }
            }
        }
    }

    private nonisolated static func receive(_ conn: NWConnection, _ acc: McpHttpAccumulator,
                                            token: String, rpc: @escaping RpcHandler,
                                            bag: McpConnectionBag) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                switch acc.append(data) {
                case .needMore:
                    if error == nil && !isComplete {
                        receive(conn, acc, token: token, rpc: rpc, bag: bag)
                    } else {
                        conn.cancel(); bag.remove(conn)
                    }
                case .error(let status, let reason):
                    sendAndClose(conn, McpHttp.response(status: status, reason: reason), bag: bag)
                case .request(let req):
                    handle(req, on: conn, token: token, rpc: rpc, bag: bag)
                }
            } else if error != nil || isComplete {
                conn.cancel(); bag.remove(conn)
            } else {
                receive(conn, acc, token: token, rpc: rpc, bag: bag)
            }
        }
    }

    /// Gate order matters: Origin (DNS-rebinding defense, a spec MUST) -> path
    /// -> method -> token -> only then does the body reach the JSON layer.
    private nonisolated static func handle(_ req: McpHttpRequest, on conn: NWConnection,
                                           token: String, rpc: @escaping RpcHandler,
                                           bag: McpConnectionBag) {
        if let origin = req.headers["origin"], !isLocalOrigin(origin) {
            return sendAndClose(conn, McpHttp.response(status: 403, reason: "Forbidden"), bag: bag)
        }
        guard req.path == "/mcp" || req.path.hasPrefix("/mcp?") else {
            return sendAndClose(conn, McpHttp.response(status: 404, reason: "Not Found"), bag: bag)
        }
        guard req.method == "POST" else {
            // GET is the server-push stream we don't offer; DELETE ends sessions
            // we don't have. 405 + Allow is the spec-sanctioned "no stream" answer.
            return sendAndClose(conn, McpHttp.response(status: 405, reason: "Method Not Allowed",
                                                       headers: [("Allow", "POST")]), bag: bag)
        }
        guard let authorization = req.headers["authorization"],
              constantTimeEqual(authorization, "Bearer \(token)") else {
            return sendAndClose(conn, McpHttp.response(status: 401, reason: "Unauthorized",
                                                       headers: [("WWW-Authenticate", "Bearer")]), bag: bag)
        }
        rpc(req.body) { response in
            sendAndClose(conn, response, bag: bag)
        }
    }

    /// Compare two ASCII strings without an early exit on the first differing
    /// byte. On a loopback listener guarding a 122-bit UUID the timing channel is
    /// theoretical, but a token compare is the one place a reviewer looks for
    /// this, and the honest form costs four lines. Length still differs early --
    /// that is the standard bound, and it leaks nothing about the token's bytes.
    private nonisolated static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<lhs.count { difference |= lhs[i] ^ rhs[i] }
        return difference == 0
    }

    private nonisolated static func isLocalOrigin(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private nonisolated static func sendAndClose(_ conn: NWConnection, _ data: Data,
                                                 bag: McpConnectionBag) {
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
            bag.remove(conn)
        })
    }

    // MARK: - Main side (JSON-RPC dispatch; every Lua touch lives below here)

    private struct RpcError: Error {
        let code: Int
        let message: String
    }

    private func handleRpcBody(_ body: Data) -> Data {
        guard let parsed = try? JSONSerialization.jsonObject(with: body) else {
            return McpHttp.json(status: 400, reason: "Bad Request",
                                rpcError(id: NSNull(), code: -32700, message: "Parse error"))
        }
        guard let request = parsed as? [String: Any] else {
            // A JSON array is a batch; batching left the spec in 2025-06-18.
            return McpHttp.json(rpcError(id: NSNull(), code: -32600,
                                         message: "Batch requests are not supported"))
        }
        let method = request["method"] as? String ?? ""
        guard let id = request["id"] else {
            // A notification (initialized, cancelled, ...): acknowledge, no body.
            return McpHttp.response(status: 202, reason: "Accepted")
        }
        let params = request["params"] as? [String: Any] ?? [:]
        do {
            let result = try dispatch(method: method, params: params)
            return McpHttp.json(["jsonrpc": "2.0", "id": id, "result": result])
        } catch let error as RpcError {
            return McpHttp.json(rpcError(id: id, code: error.code, message: error.message))
        } catch {
            return McpHttp.json(rpcError(id: id, code: -32603, message: "\(error)"))
        }
    }

    private func rpcError(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func dispatch(method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            // Stateless by construction: no Mcp-Session-Id is ever issued, and
            // MCP-Protocol-Version headers on later requests are ignored.
            let supported: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]
            let asked = params["protocolVersion"] as? String ?? ""
            let version = supported.contains(asked) ? asked : "2025-06-18"
            let bundle = AppInfo.version
            return [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any](), "resources": [String: Any]()],
                "serverInfo": ["name": "hammerdeck", "version": bundle ?? "dev"],
                "instructions": "Hammerdeck extension authoring. Call get_extension_guide first -- it carries the full contract and the write/reload/verify loop.",
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": Self.toolDefinitions]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            return try callTool(name: name, args: args)
        case "resources/list":
            return ["resources": [
                ["uri": Self.guideURI, "name": "Extension authoring guide",
                 "description": "How to author a Hammerdeck user extension (SKILL.md).",
                 "mimeType": "text/markdown"],
                ["uri": Self.diagnosticsURI, "name": "Diagnostics",
                 "description": "App/permissions/feature state snapshot.",
                 "mimeType": "text/plain"],
            ]]
        case "resources/read":
            let uri = params["uri"] as? String ?? ""
            switch uri {
            case Self.guideURI:
                return ["contents": [["uri": uri, "mimeType": "text/markdown",
                                      "text": try guideText()]]]
            case Self.diagnosticsURI:
                guard let store else { throw RpcError(code: -32603, message: "store not configured") }
                return ["contents": [["uri": uri, "mimeType": "text/plain",
                                      "text": Diagnostics.report(store)]]]
            default:
                throw RpcError(code: -32002, message: "unknown resource: \(uri)")
            }
        default:
            throw RpcError(code: -32601, message: "method not found: \(method)")
        }
    }

    // MARK: - Tools

    private static let guideURI = "hammerdeck://guide/extension-authoring"
    private static let diagnosticsURI = "hammerdeck://diagnostics"
    static let guidePath = defaultLuaDir() + "/docs/hammerdeck-extension-skill.md"

    private static let toolDefinitions: [[String: Any]] = {
        func tool(_ name: String, _ description: String,
                  _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required]]
        }
        return [
            tool("list_features",
                 "Every feature in the live catalog (built-in + user extensions): id, kind, enabled, extension flag, failure state, actions."),
            tool("describe_feature",
                 "The full config-model row for one feature: options, actions with triggers, schedule.",
                 ["feature_id": ["type": "string", "description": "feature id"]],
                 required: ["feature_id"]),
            tool("get_extensions_dir",
                 "The user's extensions folder (where extension source lives). Null when unset -- then ask the user to pick one in Settings > General > Extensions; never set it yourself."),
            tool("reload",
                 "Reload all features from disk (re-scans the extensions folder) and report every load/start failure with its error. The core write->verify step."),
            tool("run_action",
                 "Run one action of an ENABLED feature (test-fire). Fails with a reason if the feature is disabled -- ask the user to enable it in Settings.",
                 ["feature_id": ["type": "string"],
                  "action_id": ["type": "string", "description": "omit for single-action features"]],
                 required: ["feature_id"]),
            tool("validate_extension",
                 "Check ONE user extension's feature.json capabilities against what its code "
                 + "actually calls, without running it. Reports underDeclared (a latent crash on "
                 + "whichever branch reaches the gated call), overDeclared (a claim nothing "
                 + "backs), rawReach (standard-library calls that reach the OS around ctx, with "
                 + "the tier each needs) and withdrawn (a call to a name this interpreter no "
                 + "longer has, with its replacement -- no declaration fixes one of these; "
                 + "rewrite the call). Run this after reload and before handing the extension "
                 + "over.",
                 ["feature_id": ["type": "string", "description": "extension id"]],
                 required: ["feature_id"]),
            tool("list_api",
                 "Every ctx member this feature actually receives, and every one WITHHELD for "
                 + "want of a capability (with the capability that unlocks each). A withheld "
                 + "method is a raising stub rather than a missing key, so probing ctx at "
                 + "runtime cannot tell you this. Read it before writing code against ctx.",
                 ["feature_id": ["type": "string", "description": "feature id"]],
                 required: ["feature_id"]),
            tool("set_enabled",
                 "Enable or disable one feature. run_action refuses a disabled feature, so "
                 + "enable the extension you just wrote before test-firing it. Enabling a "
                 + "SERVICE runs its start(ctx). A feature needing the Accessibility grant "
                 + "still enables; the result carries a `warning` when the grant is missing, "
                 + "and its actions will onboard the grant instead of running.",
                 ["feature_id": ["type": "string"],
                  "enabled": ["type": "boolean", "description": "true to enable"]],
                 required: ["feature_id", "enabled"]),
            tool("read_log",
                 "Tail of today's Hammerdeck log (ctx.log traces, seam errors, fire failures).",
                 ["lines": ["type": "integer", "description": "how many trailing lines (default 100, max 2000)"]]),
            tool("get_extension_guide",
                 "The full extension-authoring guide (manifest contract, ctx rules, capabilities, the MCP loop). Read this before writing an extension."),
        ]
    }()

    /// A tool failure an agent should read and react to is an isError RESULT,
    /// not a protocol error -- protocol errors are for malformed calls.
    private func toolResult(_ payload: Any) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .sortedKeys])
        return ["content": [["type": "text", "text": String(data: data, encoding: .utf8) ?? ""]],
                "isError": false]
    }

    private func toolFailure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    /// One registry call, first return value, double-optional flattened
    /// ([Any?].first is Any?? -- flatten once so `as?` casts read sanely).
    private func registryCall(_ fn: String, _ args: [LuaArg] = [],
                              results: Int32 = 1) throws -> [Any?] {
        guard let lua else { throw RpcError(code: -32603, message: "bridge not configured") }
        return try lua.call("platform.registry", fn, args, results: results)
    }

    private func registryFirst(_ fn: String, _ args: [LuaArg] = []) throws -> Any? {
        try registryCall(fn, args).first.flatMap { $0 }
    }

    private func callTool(name: String, args: [String: Any]) throws -> [String: Any] {
        switch name {
        case "list_features":
            let rows = (try registryFirst("describe") as? [Any]) ?? []
            let trimmed: [[String: Any]] = rows.compactMap { row in
                guard let r = row as? [String: Any] else { return nil }
                var out: [String: Any] = [:]
                for key in ["id", "name", "kind", "category", "context",
                            "enabled", "extension", "failed", "error"] {
                    if let v = r[key] { out[key] = v }
                }
                if let actions = r["actions"] as? [Any] {
                    out["actions"] = actions.compactMap { a -> [String: Any]? in
                        guard let a = a as? [String: Any] else { return nil }
                        return ["id": a["id"] ?? "", "label": a["label"] ?? ""]
                    }
                }
                return out
            }
            return try toolResult(trimmed)
        case "describe_feature":
            guard let id = args["feature_id"] as? String else {
                throw RpcError(code: -32602, message: "feature_id required")
            }
            let rows = (try registryFirst("describe") as? [Any]) ?? []
            guard let row = rows.first(where: { ($0 as? [String: Any])?["id"] as? String == id }) else {
                return toolFailure("no such feature: \(id)")
            }
            return try toolResult(row)
        case "get_extensions_dir":
            let dir = try registryFirst("extensionsDir") as? String
            return try toolResult([
                "dir": dir ?? NSNull() as Any,
                "setting": "hammerdeck.extensionsDir",
                "hint": "The user picks this folder in Settings > General > Extensions; do not set it yourself.",
            ])
        case "reload":
            // reload() returns { count, failures = <NUMBER of load failures> };
            // the detailed records live behind registry.failures().
            let summary = (try registryFirst("reload") as? [String: Any]) ?? [:]
            let detail = (try registryFirst("failures") as? [String: Any]) ?? [:]
            store?.refresh()   // keep the Settings/menubar UI in step with the reload
            return try toolResult([
                "count": summary["count"] ?? 0,
                "loadFailures": detail["load"] ?? [Any](),
                "startFailures": detail["start"] ?? [String: Any](),
            ])
        case "run_action":
            guard let featureId = args["feature_id"] as? String else {
                throw RpcError(code: -32602, message: "feature_id required")
            }
            var callArgs: [LuaArg] = [.string(featureId)]
            if let actionId = args["action_id"] as? String { callArgs.append(.string(actionId)) }
            let out = try registryCall("runAction", callArgs, results: 2)
            if out.first.flatMap({ $0 }) as? Bool == true { return try toolResult(["ok": true]) }
            let reason = out.count > 1 ? (out[1] as? String ?? "failed") : "failed"
            return toolFailure(reason)
        case "validate_extension":
            guard let id = args["feature_id"] as? String else {
                throw RpcError(code: -32602, message: "feature_id required")
            }
            guard let report = try registryFirst("validateExtension", [.string(id)])
                    as? [String: Any] else {
                return toolFailure("validate_extension: no report for \(id)")
            }
            // A refusal (unknown id, or a built-in) is the caller's mistake and
            // reads as a tool error; a clean scan that FOUND problems is a
            // successful answer, so it comes back as an ordinary result.
            if let why = report["error"] as? String { return toolFailure(why) }
            return try toolResult(report)
        case "list_api":
            guard let id = args["feature_id"] as? String else {
                throw RpcError(code: -32602, message: "feature_id required")
            }
            guard let report = try registryFirst("apiSurface", [.string(id)])
                    as? [String: Any] else {
                return toolFailure("list_api: no surface for \(id)")
            }
            if let why = report["error"] as? String { return toolFailure(why) }
            return try toolResult(report)
        case "set_enabled":
            guard let id = args["feature_id"] as? String else {
                throw RpcError(code: -32602, message: "feature_id required")
            }
            guard let on = args["enabled"] as? Bool else {
                throw RpcError(code: -32602, message: "enabled (boolean) required")
            }
            // registry.setEnabled ASSERTS on an unknown id; that would cross the
            // bridge as a Lua error instead of a reason the agent can act on.
            let rows = (try registryFirst("describe") as? [Any]) ?? []
            guard let row = rows.first(where: { ($0 as? [String: Any])?["id"] as? String == id })
                    as? [String: Any] else {
                return toolFailure("no such feature: \(id)")
            }
            // describe() also emits a synthetic row per module that failed to
            // LOAD (registry_view: kind = "failed"), and those ids are absent
            // from the registry's feature table -- so the existence check above
            // passes and registry.setEnabled's assert would cross the bridge as
            // a protocol error. This is the id an agent is MOST likely to send:
            // it just wrote an extension, reload reported the failure, and the
            // next move is to try enabling it. `kind` is the discriminator, not
            // `failed` -- a feature that loaded and threw in start(ctx) is also
            // marked failed, and enabling THAT is a legitimate retry.
            if row["kind"] as? String == "failed" {
                let why = row["error"] as? String ?? "it failed to load"
                return toolFailure("\(id) cannot be enabled -- \(why). Fix it and reload.")
            }
            // A missing Accessibility grant WARNS, it does not refuse. Enabling is
            // one policy across every path (Settings toggle, Essentials button,
            // `defaultEnabled` at boot), and the grant is onboarded lazily at first
            // use -- so refusing only here would report failure for the same call
            // that succeeds in the UI. The agent still needs to know, because its
            // next move is `run_action` and the inertness would look like a bug in
            // the feature; it goes in the RESULT rather than as an error.
            // Fail LOUD when there is no store to ask: `store? ... == false` reads
            // nil as granted, so spell the nil case out as ungranted.
            let axMissing = on
                && (row["requires"] as? [String])?.contains("accessibility") == true
                && !(store?.accessibilityTrusted() ?? false)
            _ = try registryCall("setEnabled", [.string(id), .bool(on)], results: 0)
            store?.refresh()   // the Settings toggle and menubar must not lag this
            // Enabling a SERVICE runs start(ctx), and a throw there is quarantined
            // into startFailures -- without this the tool reports a clean enable
            // for a feature that is not actually running. Only on the enable path:
            // a stale entry must not make a disable look like a failure.
            // The AX note rides BOTH exits. An AX-requiring SERVICE on an
            // ungranted machine is the likeliest thing to throw in start(ctx), so
            // reporting only the throw would hand the agent the symptom with its
            // cause stripped -- the one case where the note is worth most.
            let axNote = axMissing
                ? " \(id) also requires the Accessibility grant, which this app does not have; "
                + "its actions will onboard the grant instead of running until the user grants it."
                : ""
            if on, let why = ((try registryFirst("failures") as? [String: Any])?["start"]
                                as? [String: Any])?[id] as? String {
                return toolFailure("enabled \(id), but it failed to start: \(why).\(axNote)")
            }
            if axMissing {
                return try toolResult(["id": id, "enabled": on, "warning": String(axNote.dropFirst())])
            }
            return try toolResult(["id": id, "enabled": on])
        case "read_log":
            // Clamp as a Double FIRST. `Int(someDouble)` traps when the value is
            // outside Int's range, so converting before clamping hands an
            // authenticated client a one-word crash of the whole host: read_log
            // with {"lines": 1e100} took the process down with SIGTRAP.
            // NaN survives neither comparison, hence the explicit fallback.
            let asked: Int
            if let i = args["lines"] as? Int {
                asked = i
            } else if let d = args["lines"] as? Double, d.isFinite {
                asked = Int(min(max(d, 1), 2000))
            } else {
                asked = 100
            }
            let lines = max(1, min(asked, 2000))
            guard let text = Self.tailOfNewestLog(lines: lines) else {
                return toolFailure("no log file yet")
            }
            return ["content": [["type": "text", "text": text]], "isError": false]
        case "get_extension_guide":
            return ["content": [["type": "text", "text": try guideText()]], "isError": false]
        default:
            throw RpcError(code: -32602, message: "unknown tool: \(name)")
        }
    }

    func guideText() throws -> String {
        guard let text = try? String(contentsOfFile: Self.guidePath, encoding: .utf8) else {
            throw RpcError(code: -32603, message: "guide missing at \(Self.guidePath)")
        }
        return text
    }

    private nonisolated static func tailOfNewestLog(lines: Int) -> String? {
        let dir = Native.logsDir
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        // Filename order IS date order (yyyy-MM-dd.log), so the max is today.
        guard let newest = names.filter({ $0.hasSuffix(".log") }).sorted().last else { return nil }
        guard let text = try? String(contentsOf: dir.appendingPathComponent(newest), encoding: .utf8) else { return nil }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return "[\(newest)]\n" + all.suffix(lines).joined(separator: "\n")
    }
}

/// Live connections, so stop() can cut them. Lock-protected because add/remove
/// run on the mcp queue while stop() calls in from the main actor.
final class McpConnectionBag: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ObjectIdentifier: NWConnection] = [:]

    func add(_ c: NWConnection) {
        lock.lock(); items[ObjectIdentifier(c)] = c; lock.unlock()
    }

    func remove(_ c: NWConnection) {
        lock.lock(); items.removeValue(forKey: ObjectIdentifier(c)); lock.unlock()
    }

    func cancelAll() {
        lock.lock(); let live = Array(items.values); items.removeAll(); lock.unlock()
        for c in live { c.cancel() }
    }
}
