import Foundation

/// A debug-only control channel into the RUNNING app, for visual verification.
///
/// The in-process integration tests can drive and inspect panels, but they
/// cannot produce *pixels* -- and layout / truncation / icon / clipping bugs
/// only show in pixels. This channel lets an external agent (or a human) make
/// the live app show a UI, so a screenshot can be taken and checked. The flow:
///   1. scripts/app.sh start         (sets HAMMERDECK_CONTROL_DIR)
///   2. scripts/control.sh '<lua>'   (e.g. open the palette) -- this file evals it
///   3. scripts/shot.sh out.png      (whole-screen screencapture, for panels)
///
/// For the SwiftUI Settings window specifically, prefer `@shot:<path>` over
/// screencapture: it asks the app to render its OWN detail form to a PNG
/// in-process (see DebugShot) -- no Screen Recording, no frontmost/occlusion
/// dependence, and it captures the scroll view's FULL content height, so nothing
/// below the fold is missed. The `@settings` / `@home` / `@tour` / `@shot`
/// commands below are host-UI hooks the Lua eval channel can't reach.
///
/// When `HAMMERDECK_CONTROL_DIR` is set, a main-thread timer polls
/// `<dir>/cmd.lua`; on finding one it consumes it, evaluates the Lua via the
/// bridge (so the FULL platform is reachable -- registry.runAction,
/// setEnabled, opt writes, queries), and writes the result to
/// `<dir>/result.txt`. The waiter (control.sh) deletes result.txt first and
/// polls for it, so its appearance signals a fresh, complete answer.
///
/// This is HOST infrastructure (a peer of Boot.swift), NOT a feature API: it
/// never grows the adapter/ctx seam, so features gain nothing from it -- the
/// same least-privilege stance as the test-only Native introspection. It is
/// OFF unless the env var is set; normal `swift run` users never get it.
///
/// DEBUG-only: the entire eval channel is compiled out of release builds, so a
/// shipped/notarized binary physically cannot eval arbitrary Lua even if the env
/// var were present. The visual-check workflow (scripts/app.sh) uses `swift run`,
/// which is a debug build, so it is unaffected.
@MainActor
enum DebugControl {
#if DEBUG
    private static var timer: Timer?

    /// Deep-link into the SwiftUI Settings window, which the Lua eval channel
    /// can't reach (it's host UI, not the platform). Set by Boot; invoked when a
    /// control command is the magic string "@settings[:<featureId>]". Lets the
    /// screenshot flow verify the config UI, not just the native panels.
    static var openSettings: ((String?) -> Void)?

    /// Switch the Homepage to a tab ("@home[:features|timeline|shortcuts|home]")
    /// and present the first-run Feature Tour ("@tour"). Host UI the Lua eval
    /// channel can't reach -- lets the screenshot flow verify the Gallery grouping
    /// and the onboarding Tour without resetting the user's defaults.
    static var openHome: ((String?) -> Void)?
    static var presentTour: (() -> Void)?

    static func startIfRequested(_ lua: LuaState) {
        guard let dir = ProcessInfo.processInfo.environment["HAMMERDECK_CONTROL_DIR"],
              !dir.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cmdPath = (dir as NSString).appendingPathComponent("cmd.lua")
        let resPath = (dir as NSString).appendingPathComponent("result.txt")
        try? fm.removeItem(atPath: cmdPath)   // drop a command stranded by a crash
        print("[hammerdeck] debug control listening at \(dir)")

        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard fm.fileExists(atPath: cmdPath),
                      let code = try? String(contentsOfFile: cmdPath, encoding: .utf8)
                else { return }
                try? fm.removeItem(atPath: cmdPath)   // consume exactly once
                let out: String
                if code == "@settings" || code.hasPrefix("@settings:") {
                    // Host-UI deep link (see openSettings) -- not Lua.
                    let id = String(code.dropFirst("@settings".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: ": \n\t"))
                    DebugControl.openSettings?(id.isEmpty ? nil : id)
                    out = "opened settings\(id.isEmpty ? "" : ":" + id)"
                } else if code == "@shot" || code.hasPrefix("@shot:") || code.hasPrefix("@shot ") {
                    // In-process self-capture (see DebugShot) -- no Screen
                    // Recording / frontmost / scrolling needed.
                    let path = String(code.dropFirst("@shot".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: ": \n\t"))
                    out = DebugShot.capture(to: path.isEmpty ? "/tmp/hammerdeck-shot.png" : path)
                } else if code.trimmingCharacters(in: .whitespacesAndNewlines) == "@chordhint" {
                    // Preview the chord which-key hint card (pixels only).
                    ChordCenter.shared.debugPreviewHint()
                    out = "showed chord hint"
                } else if code.trimmingCharacters(in: .whitespacesAndNewlines) == "@tour" {
                    DebugControl.presentTour?()
                    out = "presented tour"
                } else if code == "@home" || code.hasPrefix("@home:") {
                    let dest = String(code.dropFirst("@home".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: ": \n\t"))
                    DebugControl.openHome?(dest.isEmpty ? nil : dest)
                    out = "opened home\(dest.isEmpty ? "" : ":" + dest)"
                } else {
                    do {
                        out = DebugControl.render(try lua.eval(code))
                    } catch {
                        out = "ERROR: \(error)"
                    }
                }
                // Atomic write: the waiter never sees a partial result.
                try? out.write(toFile: resPath, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Render an eval result as a single line for result.txt.
    private static func render(_ v: Any?) -> String {
        switch v {
        case nil: return "nil"
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let d as Double: return d == d.rounded() ? String(Int(d)) : String(d)
        default: return String(describing: v!)
        }
    }
#else
    /// Release builds compile out the eval channel entirely -- no env var can
    /// turn it on, so a shipped binary cannot eval arbitrary Lua.
    static func startIfRequested(_ lua: LuaState) {}
#endif
}
