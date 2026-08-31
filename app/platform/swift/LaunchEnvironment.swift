import Foundation

/// Trims this process's environment to what a GUI launch gives an app, so the
/// apps Hammerdeck starts match what the Dock would have started.
///
/// Started from the Dock this is a no-op. Started from a terminal (`swift run`,
/// or `open` typed at a shell) the process carries the whole SHELL environment
/// instead -- exported credentials included -- and hands it to every app the App
/// Launcher opens and every `ctx.run` subprocess, since both LaunchServices and
/// `Process` inherit by default.
///
/// It has to be fixed here rather than per launch: `NSWorkspace`'s
/// `OpenConfiguration.environment` MERGES into the inherited set, so a per-launch
/// dictionary can add a key but never take one away.
enum LaunchEnvironment {

    /// Measured on a bundle launched by Finder; Dock, Spotlight and login items
    /// give the same set. Pinned by test in BOTH directions -- a keep-list can
    /// only leak by growing, and growth is otherwise invisible.
    static let guiKeys: Set<String> = [
        "COMMAND_MODE", "HOME", "LOGNAME", "OSLogRateLimit", "PATH", "SHELL",
        "SSH_AUTH_SOCK", "TMPDIR", "USER", "XPC_FLAGS", "XPC_SERVICE_NAME",
        "__CFBundleIdentifier", "__CF_USER_TEXT_ENCODING",
    ]

    /// `HAMMERDECK_*` are our own dev knobs and the reason a terminal launch
    /// happens at all, so dropping them would break the launch this cleans up.
    /// `XPC_*` / `__CF*` are launchd families that grow across macOS releases.
    /// One added prefix readmits everything beneath it, so this is pinned too.
    static let keptPrefixes = ["HAMMERDECK_", "XPC_", "__CF"]

    /// launchd's PATH for a GUI process. Rewritten rather than filtered: PATH is
    /// itself a GUI key, so filtering keeps the shell's value and the deck's apps
    /// would find toolchains a Dock-launched one cannot. Nothing here resolves
    /// through PATH -- `run_process` rejects a non-absolute executable.
    static let guiPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Pure: the environment a GUI launch would have produced from `env`.
    static func guiEnvironment(from env: [String: String]) -> [String: String] {
        var out = env.filter { key, _ in
            guiKeys.contains(key) || keptPrefixes.contains { key.hasPrefix($0) }
        }
        out["PATH"] = guiPath
        return out
    }

    /// Apply it. `hammerdeckMain` calls this first, before `NSApplication.shared`:
    /// `setenv`/`unsetenv` mutate `environ` in place and are not thread-safe, and
    /// AppKit starts worker threads that call `getenv`.
    static func normalize() {
        let current = ProcessInfo.processInfo.environment
        let target = guiEnvironment(from: current)
        for key in current.keys where target[key] == nil { unsetenv(key) }
        for (key, value) in target where current[key] != value { setenv(key, value, 1) }
        // A Dock launch that removed nothing and a keep-list wrong on some future
        // macOS that stripped what the system needed read identically otherwise.
        // NSLog, not print: app.sh redirects stdout, where print is block-buffered
        // and a boot-time crash discards the line written to explain it.
        NSLog("[hammerdeck] launch env: kept %d of %d", target.count, current.count)
    }
}
