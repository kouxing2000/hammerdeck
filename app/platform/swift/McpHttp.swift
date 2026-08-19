// Minimal HTTP/1.1 plumbing for the MCP server (McpServer.swift) -- just enough
// to serve the streamable-HTTP MCP shape: one POST per connection, JSON in,
// JSON out, `Connection: close`. Deliberately NOT a general HTTP server: no
// keep-alive, no chunked bodies (411), no pipelining. Pure functions + a small
// accumulator, so the parsing is unit-testable without a socket.

import Foundation

/// One parsed request. Header keys are lowercased (HTTP headers are
/// case-insensitive; lowercasing once at the parse edge keeps every lookup
/// site honest).
struct McpHttpRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

enum McpHttpParse {
    case needMore
    case request(McpHttpRequest)
    /// Protocol-level refusal decided during parsing (oversized, chunked, ...).
    case error(status: Int, reason: String)
}

/// Accumulates raw TCP bytes into one HTTP request. Confined by convention to
/// the MCP listener queue (every touch happens in NWConnection callbacks on
/// that queue) -- same discipline as the queue-confined state in DebugControl's
/// timer and the tests' TestIntBox.
final class McpHttpAccumulator: @unchecked Sendable {
    private var buffer = Data()
    private var head: (method: String, path: String, headers: [String: String])?
    private var expectedBody = 0

    // Caps: headers 16 KiB, body 1 MiB. Every legitimate MCP request is far
    // smaller; anything bigger is a mistake or a hostile local process.
    private static let headerCap = 16 * 1024
    private static let bodyCap = 1024 * 1024

    func append(_ data: Data) -> McpHttpParse {
        buffer.append(data)
        if head == nil {
            guard let sep = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                return buffer.count > Self.headerCap
                    ? .error(status: 431, reason: "Request Header Fields Too Large")
                    : .needMore
            }
            guard let parsed = Self.parseHead(buffer.subdata(in: buffer.startIndex..<sep.lowerBound)) else {
                return .error(status: 400, reason: "Bad Request")
            }
            if parsed.headers["transfer-encoding"] != nil {
                return .error(status: 411, reason: "Length Required")
            }
            let length = Int(parsed.headers["content-length"] ?? "0") ?? -1
            guard length >= 0 else { return .error(status: 400, reason: "Bad Request") }
            guard length <= Self.bodyCap else { return .error(status: 413, reason: "Content Too Large") }
            head = parsed
            expectedBody = length
            buffer.removeSubrange(buffer.startIndex..<sep.upperBound)
        }
        guard let head else { return .needMore }
        if buffer.count < expectedBody { return .needMore }
        let body = buffer.prefix(expectedBody)
        return .request(McpHttpRequest(method: head.method, path: head.path,
                                       headers: head.headers, body: Data(body)))
    }

    private static func parseHead(_ data: Data) -> (method: String, path: String, headers: [String: String])? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return (String(requestLine[0]), String(requestLine[1]), headers)
    }
}

enum McpHttp {
    /// Build a complete response. Always Content-Length + Connection: close --
    /// the server is strictly one-request-per-connection.
    static func response(status: Int, reason: String,
                         headers: [(String, String)] = [],
                         body: Data = Data(),
                         contentType: String? = nil) -> Data {
        var out = "HTTP/1.1 \(status) \(reason)\r\n"
        if let contentType { out += "Content-Type: \(contentType)\r\n" }
        for (k, v) in headers { out += "\(k): \(v)\r\n" }
        out += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(out.utf8)
        data.append(body)
        return data
    }

    static func json(status: Int = 200, reason: String = "OK", _ object: Any) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys])) ?? Data()
        return response(status: status, reason: reason, body: body,
                        contentType: "application/json")
    }
}
