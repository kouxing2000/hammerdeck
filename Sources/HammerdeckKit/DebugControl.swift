import Foundation

/// A debug-only control channel into the RUNNING app, for visual verification.
///
/// The in-process integration tests can drive and inspect panels, but they
/// cannot produce *pixels* -- and layout / truncation / icon / clipping bugs
/// only show in pixels. This channel lets an external agent (or a human) make
/// the live app show a UI, so a screenshot can be taken and checked. The flow:
///   1. scripts/app.sh start         (sets HAMMERDECK_CONTROL_DIR)
///   2. scripts/control.sh '<lua>'   (e.g. open the palette) -- this file evals it
///   3. scripts/shot.sh out.png      (screencapture)
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
@MainActor
enum DebugControl {
    private static var timer: Timer?

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
                do {
                    out = DebugControl.render(try lua.eval(code))
                } catch {
                    out = "ERROR: \(error)"
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
}
