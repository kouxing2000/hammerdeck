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
}
