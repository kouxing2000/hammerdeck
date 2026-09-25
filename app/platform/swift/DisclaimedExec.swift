// The trampoline half of the `run_process` binding (Native+Process.swift).
//
// macOS attributes a child process to the app that launched it for privacy (TCC)
// purposes, so a command Hammerdeck starts would inherit Hammerdeck's grants --
// Full Disk Access, Accessibility, Automation. `run_process` runs arbitrary user
// commands (a rule's runCommand effect, an extension's `ctx.run`), and anything
// that can write Hammerdeck's settings can plant one; inheriting would let it
// borrow grants it was never given. So `run_process` does not launch the command:
// it launches THIS binary as `Hammerdeck --exec-disclaimed <path> <args...>`, and
// the trampoline below replaces itself with <path> while disclaiming
// responsibility. The command becomes its own responsible process and gets only
// what macOS grants it directly -- a Full Disk Access read fails silently with
// EPERM, measured.
//
// Exec-in-place (POSIX_SPAWN_SETEXEC), not spawn-and-wait: the command keeps the
// pid, pipes, pinned stdin/cwd and watchdog that runProcessCore set up for the
// trampoline, and its exit status and signal death reach the caller unchanged.
// Hammerdeck's own curated scripting (runJXA) does not come through here -- it
// needs Hammerdeck's Automation grant.
//
// It fails CLOSED: if the disclaim cannot be applied, the command does not run.
// It covers child processes only: code running inside Hammerdeck -- an extension's
// `files` reads -- still uses Hammerdeck's grants (CLAUDE.md, the `exec` tier).

import Darwin
import Foundation

public enum DisclaimedExec {
    /// argv[1] that selects trampoline mode. Never rename it: it is the handshake
    /// between the running host and whatever binary sits at its executable path,
    /// which an in-place update can swap underneath it -- a binary that does not
    /// know the flag boots a second full Hammerdeck instead of running the command.
    public static let flag = "--exec-disclaimed"

    /// Starts the stderr line of every trampoline failure. `run_process` keys on it
    /// (with exit 127) to report "could not be launched" rather than an exit code.
    static let failurePrefix = "hammerdeck: "

    /// Called first thing in main, before any AppKit setup. In trampoline mode it
    /// never returns: the command replaces this process, or it exits 127 saying why.
    public static func runIfRequested(_ argv: [String] = CommandLine.arguments) {
        guard argv.count >= 2, argv[1] == flag else { return }
        guard argv.count >= 3 else { fail("no command given", refused: false) }
        let path = argv[2]

        // Resolved at run time rather than linked: it is private SPI (the same
        // call Chromium, LLDB and Qt Creator make). A macOS that drops it must
        // fail here with a reason; a hard link would abort in dyld instead, which
        // the caller would only ever see as an unexplained SIGABRT.
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let sym = dlsym(rtldDefault, "responsibility_spawnattrs_setdisclaim") else {
            fail("this macOS has no responsibility_spawnattrs_setdisclaim")
        }
        typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        let setDisclaim = unsafeBitCast(sym, to: SetDisclaim.self)

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { fail("posix_spawnattr_init failed") }
        guard posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC)) == 0 else {
            fail("could not request exec-in-place")
        }
        let rc = setDisclaim(&attr, 1)
        guard rc == 0 else { fail("responsibility_spawnattrs_setdisclaim returned \(rc)") }

        var cargs: [UnsafeMutablePointer<CChar>?] = argv[2...].map { strdup($0) } + [nil]
        var pid: pid_t = 0
        let err = posix_spawn(&pid, path, nil, &attr, &cargs, environ)
        // Only reached on failure: on success SETEXEC replaced this process.
        fail("could not start \(path): \(String(cString: strerror(err)))", refused: false)
    }

    /// Exit 127 with a `failurePrefix` line on stderr, which `run_process` turns into
    /// a nil status and writes to the daily log. `refused` marks the fail-closed cases
    /// -- the disclaim could not be applied -- so that line says the command was
    /// withheld on purpose, not that it was missing.
    private static func fail(_ why: String, refused: Bool = true) -> Never {
        let line = refused
            ? "\(failurePrefix)\(why) -- the command was not run, since it would have "
                + "inherited Hammerdeck's permissions\n"
            : "\(failurePrefix)\(why)\n"
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
        exit(127)
    }
}
