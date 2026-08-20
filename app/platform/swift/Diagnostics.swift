import AppKit

/// The report a user attaches to "it doesn't work".
///
/// Written after a debugging session where three unrelated causes -- a missing
/// Accessibility grant, a stale app bundle, and synthesized keystrokes inheriting
/// held-down modifiers -- all presented as *nothing happens*, and none of the
/// three left a trace a user could have sent us. Telling them apart needed the
/// log AND the source AND a screenshot. A reporter would have written "insert
/// date time doesn't work" and we would have had nothing.
///
/// So this captures STATE, not just events: the log records what happened, this
/// records the conditions it happened under. Those are different questions, and
/// the second one is the one a bug report cannot reconstruct later.
///
/// Deliberately free of user content -- no clipboard text, no window titles, no
/// file paths outside the app's own. Feature ids and their triggers are
/// configuration, not data.
@MainActor
enum Diagnostics {

    /// Human-readable, paste-able, and small enough for a mail body.
    static func report(_ store: SettingsStore) -> String {
        var out: [String] = []

        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let bundleID = Bundle.main.bundleIdentifier
        out.append("\(AppInfo.displayName) \(v ?? "dev") (\(build ?? "-"))")
        // nil bundle id means an unbundled `swift run`, which is a different app
        // from the signed .app in every way that matters here: separate defaults
        // domain, separate TCC identity, no Sparkle feed.
        out.append("bundle: \(bundleID ?? "none -- running unbundled (swift run)")")
        out.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("arch: \(Native.machineArchitecture())")

        // The permission that gates 13 features. Read through the store (which
        // goes through the seam) rather than calling the OS here.
        out.append("accessibility: \(store.accessibilityTrusted() ? "granted" : "NOT GRANTED")")
        out.append("updater: \(Updater.shared.isAvailable ? "active" : "unavailable (no feed)")")

        let feats = store.features
        let on = feats.filter(\.enabled)
        out.append("features: \(on.count) enabled of \(feats.count)")

        // Third-party code on the machine, and whether the agent door is open:
        // both are conditions the log cannot reconstruct, and both change what
        // "it doesn't work" can mean (a broken extension looks like a broken
        // app). The extensions FOLDER is deliberately NOT printed -- it is a
        // user-chosen path outside the app, which the no-user-content rule
        // above excludes; whether one is set, and how many loaded, carries the
        // diagnostic weight without the path.
        let exts = feats.filter(\.isExtension)
        if !exts.isEmpty || ExtensionsPreference.dir != nil {
            out.append("extensions: \(exts.count) loaded"
                       + (ExtensionsPreference.dir == nil ? " (no folder set)" : " (folder set)"))
        }
        out.append("agent access (MCP): \(mcpState())")

        // Broken plugins first -- if one failed to load, that is usually the whole
        // story and it must not be buried under the enabled list.
        let broken = feats.filter(\.failed)
        if !broken.isEmpty {
            out.append("")
            out.append("BROKEN:")
            for f in broken {
                out.append("  \(f.id): \(f.errorMessage.prefix(160))")
            }
        }

        if !on.isEmpty {
            out.append("")
            out.append("enabled:")
            // Capped: a mail body has a practical length limit, and the full
            // picture is in the log anyway. Truncating silently would misreport
            // the user's setup, so the remainder is counted out loud.
            let shown = on.prefix(40)
            for f in shown {
                let trig = f.triggerDesc.isEmpty ? "no trigger" : f.triggerDesc
                let needs = f.requires.isEmpty ? "" : "  [needs \(f.requires.joined(separator: ","))]"
                out.append("  \(f.id) -- \(trig)\(needs)")
            }
            if on.count > shown.count {
                out.append("  ... and \(on.count - shown.count) more")
            }
        }

        out.append("")
        // Tilde-abbreviated: the raw path embeds the account's short name, and this
        // report is written to be pasted into a public issue. The reader needs to
        // know WHERE the log lives, not who the user is.
        out.append("log: \((Native.logsDir.path as NSString).abbreviatingWithTildeInPath)")
        return out.joined(separator: "\n")
    }

    /// The MCP endpoint's state for the report. Never the token -- this text is
    /// written to be pasted into a public issue, and the token is the only
    /// thing standing between a local process and the agent tools.
    private static func mcpState() -> String {
        switch McpServer.shared.status {
        case .off:                return McpPreference.enabled ? "enabled, not listening" : "off"
        case .starting:           return "starting"
        case .running(let port):  return "listening on 127.0.0.1:\(port)"
        case .failed(let reason): return "FAILED (\(reason.prefix(80)))"
        }
    }
}
