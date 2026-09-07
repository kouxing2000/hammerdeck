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
    /// `at` names the bundle to reopen, which is NOT always our own: the
    /// install-location guard has just MOVED us, so the copy worth starting is the
    /// one at the new path and the one running is about to stop existing.
    ///
    /// `thenExit` picks how this process dies. `NSApp.terminate` is right once the
    /// run loop is up; the install guard runs BEFORE it starts, where terminate has
    /// nothing to service it and the process would sit there with no UI.
    /// Returns whether the helper actually spawned. `false` means this process is
    /// still alive and nothing was restarted -- the caller has already been told.
    @discardableResult
    static func restart(at bundlePath: String = Bundle.main.bundlePath,
                        thenExit: Bool = false) -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        // Pass pid/path as positional args ($0/$1), NOT interpolated into the
        // script body -- so a bundle path containing quotes/spaces can't break it.
        let script = "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$1\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, String(pid), bundlePath]
        do {
            try task.run()
        } catch {
            return reportFailedSpawn(error, at: bundlePath, moved: thenExit)
        }
        if thenExit { exit(0) }
        NSApp.terminate(nil)
        return true
    }

    /// The spawn failure used to be discarded, and this function ended the
    /// process either way -- so a helper that never launched read to the user as
    /// the app quitting on its own, with nothing in the log to say why. On the
    /// install-guard path that is worse than it sounds: the bundle has ALREADY
    /// moved, so the app vanished from the folder they launched it from.
    ///
    /// The two callers need opposite endings, which is what `moved` selects.
    private static func reportFailedSpawn(_ error: Error, at bundlePath: String,
                                          moved: Bool) -> Bool {
        Native.shared.seamLog("relaunch helper did not spawn: \(error.localizedDescription) "
                              + "-- bundle to reopen is \(bundlePath)")
        let alert = NSAlert()
        alert.messageText = Strings.t("relaunch.failed",
            default: "Could not restart Hammerdeck automatically")
        alert.informativeText = moved
            ? String(format: Strings.t("relaunch.failed.moved",
                default: "Hammerdeck has been moved to %@. Open it from there to continue."),
                     bundlePath)
            : Strings.t("relaunch.failed.inPlace",
                default: "Nothing was lost -- your settings are saved. Quit and open "
                       + "Hammerdeck again whenever you are ready.")
        alert.runModal()
        // Carrying on is only an option when we are still where we were started.
        // After the install guard's move, this process is running from a path
        // that no longer holds the bundle -- every later resource read (the Lua
        // tree, the i18n catalogs) would resolve against a directory that is
        // gone, so booting on would fail in ways that name nothing. The alert
        // above is what makes the exit explicable.
        if moved { exit(0) }
        return false
    }
}
