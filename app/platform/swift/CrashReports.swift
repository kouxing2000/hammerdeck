import Foundation

/// The crash macOS wrote about us last time, turned into something a user can
/// choose to send.
///
/// Nothing here sends anything. It finds the newest report, summarises it with
/// the same no-user-content rule as `Diagnostics`, and remembers which crash the
/// user was already asked about -- so one crash is offered once, whichever
/// answer they gave.
///
/// macOS writes a report per crash to `~/Library/Logs/DiagnosticReports` as
/// `<process>-<date>.ips`: line 1 is a JSON header (`bundleID`, `timestamp`,
/// `bug_type`), the rest one JSON body. That directory also holds hang, spin and
/// `ExcUserFault_*` reports carrying the SAME bundle id, so a report counts only
/// when its file name starts with our process name AND its `bug_type` is 309
/// (a crash).
@MainActor
enum CrashReports {
    /// Timestamp of the newest crash the user has been asked about (or the
    /// install baseline). Crashes at or before it are never offered.
    static let lastSeenKey = "hammerdeck.crash.lastSeen"
    static let crashBugType = "309"

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    struct Header: Equatable {
        let bundleID: String
        let bugType: String
        let date: Date
    }

    /// `2026-09-20 13:28:34.00 -0700` -- local time with its offset, which is
    /// not ISO 8601, so a fixed formatter rather than ISO8601DateFormatter.
    private static let timestampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return f
    }()

    /// Split an .ips into its header object and body object.
    private static func parts(_ ips: String) -> (header: [String: Any], body: [String: Any]?)? {
        let lines = ips.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first,
              let header = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any]
        else { return nil }
        let body = lines.count > 1
            ? (try? JSONSerialization.jsonObject(with: Data(lines[1].utf8))) as? [String: Any]
            : nil
        return (header, body)
    }

    static func header(_ ips: String) -> Header? {
        guard let h = parts(ips)?.header,
              let bundleID = h["bundleID"] as? String,
              let stamp = h["timestamp"] as? String,
              let date = timestampFormat.date(from: stamp) else { return nil }
        return Header(bundleID: bundleID, bugType: (h["bug_type"] as? String) ?? "", date: date)
    }

    /// The newest crash of `bundleID` in `dir` strictly after `since`. Reads only
    /// the files whose name starts with `processName-`, and only their header.
    static func pending(in dir: URL, processName: String, bundleID: String,
                        since: Date) -> (url: URL, date: Date)? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var best: (url: URL, date: Date)?
        for name in names where name.hasPrefix(processName + "-") && name.hasSuffix(".ips") {
            let url = dir.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let h = header(text),
                  h.bundleID == bundleID, h.bugType == crashBugType, h.date > since
            else { continue }
            if best == nil || h.date > best!.date { best = (url, h.date) }
        }
        return best
    }

    /// A paste-able crash summary: version, macOS, what killed the process, the
    /// Swift runtime's own message (`asi` -- a `preconditionFailure` text is
    /// often the whole story), and the faulting thread's top frames as
    /// `image  symbol  +offset`. Image NAMES only, never paths; everything
    /// emitted passes through `Diagnostics.redactPaths`. The app image's UUID
    /// rides along so its frames can be symbolicated against the release dSYM.
    static func summary(_ ips: String, frames limit: Int = 12) -> String? {
        guard let (h, bodyOpt) = parts(ips), let body = bodyOpt else { return nil }
        var out: [String] = []
        let version = (h["app_version"] as? String) ?? "?"
        let build = (h["build_version"] as? String) ?? "?"
        out.append("crash: \(version) (\(build)) at \((h["timestamp"] as? String) ?? "?")")
        out.append("os: \((h["os_version"] as? String) ?? "?")")
        if let exc = body["exception"] as? [String: Any] {
            let type = (exc["type"] as? String) ?? "?"
            let signal = (exc["signal"] as? String).map { " (\($0))" } ?? ""
            out.append("exception: \(type)\(signal)")
        }
        if let term = body["termination"] as? [String: Any], let ind = term["indicator"] as? String {
            out.append("termination: \(ind)")
        }
        if let asi = body["asi"] as? [String: Any] {
            let lines = asi.values.compactMap { $0 as? [String] }.flatMap { $0 }
            for line in lines.prefix(4) { out.append("message: \(line.prefix(300))") }
        }

        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let proc = (body["procName"] as? String) ?? (h["name"] as? String) ?? ""
        if let app = images.first(where: { ($0["name"] as? String) == proc }),
           let uuid = app["uuid"] as? String {
            out.append("image: \(proc) \(uuid)")
        }
        if let threads = body["threads"] as? [[String: Any]],
           let idx = body["faultingThread"] as? Int, threads.indices.contains(idx),
           let frames = threads[idx]["frames"] as? [[String: Any]] {
            out.append("thread \(idx):")
            for f in frames.prefix(limit) {
                let i = f["imageIndex"] as? Int
                let image = i.flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil } ?? "?"
                let symbol = (f["symbol"] as? String) ?? "?"
                let offset = (f["imageOffset"] as? Int).map { "+\($0)" } ?? ""
                out.append("  \(image)  \(symbol)  \(offset)")
            }
        }
        return Diagnostics.redactPaths(out.joined(separator: "\n"))
    }
}
