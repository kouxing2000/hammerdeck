// Native.swift split: this file is one domain slice of the `Native`
// seam (see Native.swift for the class, shared state, and installBindings).
// Network / files / wallpaper + mouse locator.

import AppKit
import CLua

extension Native {
    // MARK: - Network / files / wallpaper

    // Async GET; callback gets (status, body|nil). Body is decoded as UTF-8
    // text (this surface is for JSON/HTML APIs -- binary payloads go through
    // download_file, which never round-trips bytes into a Lua string).
    func httpGet(_ L: OpaquePointer?) -> Int32 {
        guard let url = LuaState.string(L, 1), let u = URL(string: url) else {
            return luaError(L, "http_get: url required")
        }
        let headers = (LuaState.any(L, 2) as? [String: Any]) ?? [:]
        let ref = lua.makeRef(at: 3)
        var req = URLRequest(url: u)
        for (k, v) in headers {
            if let s = v as? String { req.setValue(s, forHTTPHeaderField: k) }
        }
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Native.shared.lua.callRef(ref) { L in
                        lua_pushinteger(L, lua_Integer(status))
                        if let body { lua_pushstring(L, body) } else { lua_pushnil(L) }
                        return 2
                    }
                    Native.shared.lua.releaseRef(ref)
                }
            }
        }.resume()
        return 0
    }

    // Async request with an explicit method/body; callback gets (status, body|nil),
    // body decoded as UTF-8 text (same contract as httpGet). Args: url, method
    // (default "GET"), headers table, optional body string, callback. Lets
    // features POST JSON (e.g. OpenAI) with custom headers (Authorization: Bearer).
    func httpRequest(_ L: OpaquePointer?) -> Int32 {
        guard let url = LuaState.string(L, 1), let u = URL(string: url) else {
            return luaError(L, "http_request: url required")
        }
        let method = LuaState.string(L, 2) ?? "GET"
        let headers = (LuaState.any(L, 3) as? [String: Any]) ?? [:]
        let body = LuaState.string(L, 4)
        let ref = lua.makeRef(at: 5)
        var req = URLRequest(url: u)
        req.httpMethod = method
        for (k, v) in headers {
            if let s = v as? String { req.setValue(s, forHTTPHeaderField: k) }
        }
        if let body { req.httpBody = body.data(using: .utf8) }
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Native.shared.lua.callRef(ref) { L in
                        lua_pushinteger(L, lua_Integer(status))
                        if let body { lua_pushstring(L, body) } else { lua_pushnil(L) }
                        return 2
                    }
                    Native.shared.lua.releaseRef(ref)
                }
            }
        }.resume()
        return 0
    }

    func downloadFile(_ L: OpaquePointer?) -> Int32 {
        guard let url = LuaState.string(L, 1), let u = URL(string: url),
              let path = LuaState.string(L, 2) else {
            return luaError(L, "download_file: url and path required")
        }
        let ref = lua.makeRef(at: 3)
        URLSession.shared.downloadTask(with: u) { tmp, resp, _ in
            var ok = false
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let tmp, (200..<300).contains(status) {
                let fm = FileManager.default
                try? fm.removeItem(atPath: path)
                ok = (try? fm.moveItem(at: tmp, to: URL(fileURLWithPath: path))) != nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Native.shared.lua.callRef(ref) { L in
                        lua_pushboolean(L, ok ? 1 : 0)
                        return 1
                    }
                    Native.shared.lua.releaseRef(ref)
                }
            }
        }.resume()
        return 0
    }

    func setWallpaper(_ L: OpaquePointer?) -> Int32 {
        guard let path = LuaState.string(L, 1) else {
            return luaError(L, "set_wallpaper: path required")
        }
        // mode "primary" => only the main display; anything else (incl. nil)
        // => every screen. Default is all -- a multi-display setup otherwise
        // leaves the other monitors on their old wallpaper.
        let mode = LuaState.string(L, 2)
        let url = URL(fileURLWithPath: path)
        let ws = NSWorkspace.shared
        let targets = (mode == "primary")
            ? (NSScreen.main.map { [$0] } ?? [])
            : NSScreen.screens
        var ok = !targets.isEmpty
        for screen in targets {
            if (try? ws.setDesktopImageURL(url, for: screen)) == nil { ok = false }
        }
        lua_pushboolean(L, ok ? 1 : 0)
        return 1
    }

    func cacheDir(_ L: OpaquePointer?) -> Int32 {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Hammerdeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lua_pushstring(L, dir.path)
        return 1
    }

    // MARK: - Mouse locator (fire-and-forget, like alert)

    func locateMouse(_ L: OpaquePointer?) -> Int32 {
        let seconds = LuaState.double(L, 1) ?? 3
        mouseLocator?.close()                       // re-invoke replaces the live one
        mouseLocator = MouseLocatorPanel(seconds: seconds) {
            Native.shared.mouseLocator = nil
        }
        return 0
    }
}
