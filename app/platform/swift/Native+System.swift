// Native.swift split: this file is one domain slice of the `Native`
// seam (see Native.swift for the class, shared state, and installBindings).
// Feature discovery, system shortcuts, app-focus tracking, data files, app icons / favicons.

import AppKit
import CLua
import SQLite3

extension Native {
    // Returns the bare names of feature modules in `dir`: a "<name>/init.lua"
    // subdirectory or a flat "<name>.lua" file each yields "<name>". The
    // registry prefixes "features." and loads them. Drives autodiscovery +
    // hot-plug (reload re-scans).
    func discoverFeatures(_ L: OpaquePointer?) -> Int32 {
        guard let dir = LuaState.string(L, 1) else { return luaError(L, "discover_features: dir required") }
        let fm = FileManager.default
        var names = Set<String>()
        if let entries = try? fm.contentsOfDirectory(atPath: dir) {
            for entry in entries where !entry.hasPrefix(".") {
                let full = (dir as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: full, isDirectory: &isDir)
                // Co-located layout: a feature is a folder whose Lua entry point
                // lives at <id>/lua/init.lua (the sibling swift/ is the native UI).
                if isDir.boolValue,
                   fm.fileExists(atPath: (full as NSString).appendingPathComponent("lua/init.lua")) {
                    names.insert(entry)
                }
            }
        }
        lua_createtable(L, Int32(names.count), 0)
        for (i, name) in names.sorted().enumerated() {
            lua_pushstring(L, name)
            lua_rawseti(L, -2, lua_Integer(i + 1))
        }
        return 1
    }

    // MARK: - System shortcuts (read-only)

    // system_hotkeys(): the user's currently-enabled macOS system shortcuts,
    // returned as hotkey-shaped specs { mods = {...}, key = "...", name = "..." }
    // so the config UI can warn before a binding collides with Spotlight,
    // input-source switching, Mission Control, etc. macOS owns these
    // (com.apple.symbolichotkeys) -- we only READ them, never rebind.
    func systemHotkeys(_ L: OpaquePointer?) -> Int32 {
        let entries = Native.readSymbolicHotkeys()
        lua_createtable(L, Int32(entries.count), 0)
        for (i, e) in entries.enumerated() {
            lua_createtable(L, 0, 3)
            lua_createtable(L, Int32(e.mods.count), 0)
            for (j, m) in e.mods.enumerated() {
                lua_pushstring(L, m)
                lua_rawseti(L, -2, lua_Integer(j + 1))
            }
            lua_setfield(L, -2, "mods")
            lua_pushstring(L, e.key);  lua_setfield(L, -2, "key")
            lua_pushstring(L, e.name); lua_setfield(L, -2, "name")
            lua_rawseti(L, -2, lua_Integer(i + 1))
        }
        return 1
    }

    /// Parse ~/Library/Preferences/com.apple.symbolichotkeys.plist into the
    /// enabled shortcuts we can represent (mods + a key our keyCodes map knows).
    /// Each plist entry is { enabled, value = { parameters = (char, keyCode,
    /// modifierMask) } }; modifierMask uses the Cocoa NSEvent flag bits.
    static func readSymbolicHotkeys() -> [(mods: [String], key: String, name: String)] {
        guard let raw = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                                  "com.apple.symbolichotkeys" as CFString)
                as? [String: Any] else { return [] }
        var out: [(mods: [String], key: String, name: String)] = []
        for (idStr, v) in raw {
            guard let entry = v as? [String: Any] else { continue }
            let enabled: Bool = (entry["enabled"] as? Bool)
                ?? ((entry["enabled"] as? NSNumber)?.intValue != 0 ? true : false)
            guard enabled,
                  let value = entry["value"] as? [String: Any],
                  let params = value["parameters"] as? [Any], params.count >= 3,
                  let keyCode = (params[1] as? NSNumber)?.intValue,
                  let mask = (params[2] as? NSNumber)?.intValue,
                  let keyName = Native.codeToKeyName[keyCode]
            else { continue }
            var mods: [String] = []
            if mask & 0x100000 != 0 { mods.append("cmd") }
            if mask & 0x080000 != 0 { mods.append("alt") }
            if mask & 0x040000 != 0 { mods.append("ctrl") }
            if mask & 0x020000 != 0 { mods.append("shift") }
            let name = Native.symbolicHotkeyNames[Int(idStr) ?? -1] ?? "a macOS system shortcut"
            out.append((mods: mods, key: keyName, name: name))
        }
        return out
    }

    /// Reverse of HotkeyCenter.keyCodes (positional code -> a key name our
    /// trigger specs use). Canonical spellings win over their aliases so the
    /// emitted key string matches what the editor stores (e.g. "return", not
    /// "enter") for the conflict comparison.
    static let codeToKeyName: [Int: String] = {
        let preferred: Set<String> = ["return", "delete", "escape", "space", "tab",
                                      "left", "right", "up", "down"]
        var map: [Int: String] = [:]
        for (name, code) in HotkeyCenter.keyCodes {
            if let cur = map[code] {
                if preferred.contains(name) && !preferred.contains(cur) { map[code] = name }
            } else {
                map[code] = name
            }
        }
        return map
    }()

    /// Friendly names for the well-known symbolic-hotkey ids, for the warning
    /// text. Detection works without these (id absent -> generic wording); they
    /// only make the message specific ("Spotlight" vs "a macOS system shortcut").
    static let symbolicHotkeyNames: [Int: String] = [
        32: "Mission Control",
        33: "Application Windows",
        36: "Show Desktop",
        28: "Save screenshot to file",
        29: "Copy screenshot to clipboard",
        30: "Save screenshot of area to file",
        31: "Copy screenshot of area to clipboard",
        60: "Select previous input source",
        61: "Select next input source",
        64: "Spotlight",
        65: "Spotlight (Finder window)",
        79: "Move to space on the left",
        81: "Move to space on the right",
        118: "Switch to Desktop 1",
        160: "Launchpad",
        162: "Quick Note",
        175: "Notification Center",
        184: "Screenshot and recording options",
    ]

    // focus_window(id): raise the window and activate its app. The id must
    // come from the most recent list_windows() call.
    // MARK: - App focus tracking

    func frontmostApp(_ L: OpaquePointer?) -> Int32 {
        if let name = NSWorkspace.shared.frontmostApplication?.localizedName {
            lua_pushstring(L, name)
        } else {
            lua_pushnil(L)
        }
        return 1
    }

    // on_app_activated(fn): fn(appName) fires whenever an application becomes
    // frontmost. NSWorkspace notification -- no Accessibility needed.
    func onAppActivated(_ L: OpaquePointer?) -> Int32 {
        let ref = lua.makeRef(at: 1)
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                       object: nil, queue: .main) { note in
            let name = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication)?.localizedName
            MainActor.assumeIsolated {
                Native.shared.lua.callRef(ref) { L in
                    if let name { lua_pushstring(L, name) } else { lua_pushnil(L) }
                    return 1
                }
            }
        }
        let id = registerResource { center.removeObserver(token); Native.shared.lua.releaseRef(ref) }
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    // appearance() -> "dark" | "light" -- the system interface style. The global
    // AppleInterfaceStyle pref is "Dark" only in dark mode (absent = light). Read
    // via CFPreferences on the global domain (NOT UserDefaults.standard, whose
    // cached snapshot can lag the appearanceChanged notification that re-reads this).
    func appearance(_ L: OpaquePointer?) -> Int32 {
        let style = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString,
                                              kCFPreferencesAnyApplication) as? String
        let dark = (style ?? "").lowercased() == "dark"
        lua_pushstring(L, dark ? "dark" : "light")
        return 1
    }

    // running_apps() -> [appName] -- localized names of the regular (user-facing)
    // running apps. Backs the `runningApps` set signal; the appsChanged event
    // (launch/quit) re-reads it. Filters out background daemons/agents.
    func runningApps(_ L: OpaquePointer?) -> Int32 {
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
        lua_createtable(L, Int32(names.count), 0)
        for (i, n) in names.enumerated() {
            lua_pushstring(L, n)
            lua_rawseti(L, -2, lua_Integer(i + 1))
        }
        return 1
    }

    // app_name() -> the user-visible app display name. Single source of truth
    // shared with Lua (features build "<app> needs Accessibility" messages off
    // it via ctx.appName). See AppInfo for where the value comes from.
    func appName(_ L: OpaquePointer?) -> Int32 {
        lua_pushstring(L, AppInfo.displayName)
        return 1
    }

    // locale() -> the resolved UI locale code (e.g. "en", "zh-Hans"). Single
    // authority for both layers; Lua reads it via adapter.locale().
    func locale(_ L: OpaquePointer?) -> Int32 {
        lua_pushstring(L, LocaleResolver.current)
        return 1
    }

    // MARK: - Data files (Application Support)

    // App-owned durable data directory (distinct from cache_dir: the OS may
    // purge caches; usage logs and other feature data must survive).
    func dataDir(_ L: OpaquePointer?) -> Int32 {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Hammerdeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lua_pushstring(L, dir.path)
        return 1
    }

    // The user's home directory -- features build their durable-storage paths
    // off this (e.g. usage_stats' configurable ~/.computer-usage folder), so
    // the seam stays the only thing that reads the OS environment.
    func homeDir(_ L: OpaquePointer?) -> Int32 {
        lua_pushstring(L, NSHomeDirectory())
        return 1
    }

    func mkdir(_ L: OpaquePointer?) -> Int32 {
        guard let path = LuaState.string(L, 1) else { return luaError(L, "mkdir: path required") }
        let ok = (try? FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)) != nil
        lua_pushboolean(L, ok ? 1 : 0)
        return 1
    }

    // remove_subdir(base, relpath) -> bool. CURATED delete: removes base/relpath
    // only when `base` resolves INSIDE the user's home tree and `relpath` is a
    // safe relative path (non-empty, no leading slash, no `..`). The retention
    // sweep's tool, never a general rm -- a base outside home (e.g. an external
    // backup volume) is refused, so the sweep simply no-ops there rather than
    // risk deleting a system path. Subsumes the old dataDir-only delete: callers
    // pass dataDir (or any configured durable dir under home) as `base`.
    func removeSubdir(_ L: OpaquePointer?) -> Int32 {
        guard let base = LuaState.string(L, 1), let rel = LuaState.string(L, 2),
              base.hasPrefix("/"), !base.contains(".."),
              !rel.isEmpty, !rel.hasPrefix("/"), !rel.contains("..") else {
            return luaError(L, "remove_subdir: absolute base + safe relative path required")
        }
        // Resolve symlinks on BOTH sides before the containment test -- a lexical
        // (standardized-only) check would let a base symlinked out of home (e.g.
        // ~/.computer-usage -> /Volumes/ext) pass and then delete off-tree.
        let home = URL(fileURLWithPath: NSHomeDirectory())
            .resolvingSymlinksInPath().standardizedFileURL.path
        let baseURL = URL(fileURLWithPath: base)
            .resolvingSymlinksInPath().standardizedFileURL
        guard baseURL.path == home || baseURL.path.hasPrefix(home + "/") else {
            lua_pushboolean(L, 0)   // base outside home: refuse, no-op
            return 1
        }
        let target = baseURL.appendingPathComponent(rel)
        let ok = (try? FileManager.default.removeItem(at: target)) != nil
        lua_pushboolean(L, ok ? 1 : 0)
        return 1
    }

    func appIcon(_ L: OpaquePointer?) -> Int32 {
        if let bundleID = LuaState.string(L, 1) {
            lua_pushstring(L, "appicon:" + bundleID)
        } else {
            lua_pushnil(L)
        }
        return 1
    }

    // extract_favicons(outDir, domains, cb): pull REAL site icons from
    // Chrome's local Favicons sqlite DB (the donor's extract_favicons.py,
    // ported to Swift -- no python). The DB is copied first (Chrome holds a
    // lock), the largest PNG per domain wins, PNG magic verified. Works
    // offline and covers <link rel> icons the sites never serve at
    // /favicon.ico. cb(savedDomains[]). Existing files are not overwritten.
    func extractFavicons(_ L: OpaquePointer?) -> Int32 {
        guard let outDir = LuaState.string(L, 1) else {
            return luaError(L, "extract_favicons: outDir required")
        }
        let domains = LuaState.stringArray(L, 2)
        let ref = lua.makeRef(at: 3)
        DispatchQueue.global(qos: .utility).async {
            let saved = Self.extractFaviconsSync(outDir: outDir, domains: domains)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Native.shared.lua.callRef(ref) { L in
                        lua_createtable(L, Int32(saved.count), 0)
                        for (i, d) in saved.enumerated() {
                            lua_pushstring(L, d)
                            lua_rawseti(L, -2, lua_Integer(i + 1))
                        }
                        return 1
                    }
                    Native.shared.lua.releaseRef(ref)
                }
            }
        }
        return 0
    }

    /// The donor's extract_favicons.py, in-process: copy the DB (Chrome holds
    /// a lock), largest PNG per domain, magic verified. Pure helper, any queue.
    private nonisolated static func extractFaviconsSync(outDir: String,
                                                        domains: [String]) -> [String] {
        let fm = FileManager.default
        let dbPath = NSHomeDirectory()
            + "/Library/Application Support/Google/Chrome/Default/Favicons"
        guard fm.fileExists(atPath: dbPath) else { return [] }
        // UUID, not pid: two overlapping extractions in this process must not
        // share (and defer-delete) each other's DB copy.
        let tmp = NSTemporaryDirectory() + "hammerdeck-favicons-\(UUID().uuidString).db"
        defer { try? fm.removeItem(atPath: tmp) }
        do { try fm.copyItem(atPath: dbPath, toPath: tmp) } catch { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        // The host must END at the domain (next char "/" / ":" / end-of-url),
        // so "github.com" never matches a lookalike like github.com.evil.io.
        let sql = """
        SELECT fb.image_data FROM icon_mapping im
        JOIN favicons f ON im.icon_id = f.id
        JOIN favicon_bitmaps fb ON f.id = fb.icon_id
        WHERE im.page_url LIKE ? OR im.page_url LIKE ? OR im.page_url LIKE ?
        ORDER BY fb.width * fb.height DESC LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        var saved: [String] = []
        for domain in domains {
            let out = outDir + "/" + domain + ".png"
            guard !fm.fileExists(atPath: out) else { continue }
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, "%://\(domain)/%", -1, transient)
            sqlite3_bind_text(stmt, 2, "%://\(domain):%", -1, transient)
            sqlite3_bind_text(stmt, 3, "%://\(domain)", -1, transient)
            if sqlite3_step(stmt) == SQLITE_ROW,
               let blob = sqlite3_column_blob(stmt, 0) {
                let n = Int(sqlite3_column_bytes(stmt, 0))
                let data = Data(bytes: blob, count: n)
                if n > 8, data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]),
                   (try? data.write(to: URL(fileURLWithPath: out))) != nil {
                    saved.append(domain)
                }
            }
        }
        return saved
    }
}
