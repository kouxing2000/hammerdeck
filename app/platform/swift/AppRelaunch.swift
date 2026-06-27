import AppKit

// Relaunch the app -- used after the user confirms a language change. A fresh
// boot re-resolves the locale and rebuilds all UI from scratch, so no live
// re-render plumbing is needed (and nothing can silently go stale).
//
// Mechanism: spawn a detached /bin/sh that waits for THIS process to exit, then
// reopens the bundle -- so `open` doesn't just refocus the dying instance.
// Best-effort: in a dev `swift run` (no .app bundle) the reopen may not apply,
// but the preference is already saved, so the next manual start picks it up.
@MainActor
enum AppRelaunch {
    static func restart() {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        // Pass pid/path as positional args ($0/$1), NOT interpolated into the
        // script body -- so a bundle path containing quotes/spaces can't break it.
        let script = "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$1\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, String(pid), bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
