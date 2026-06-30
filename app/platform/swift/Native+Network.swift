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
            Native.fireCallback(ref) { L in
                lua_pushinteger(L, lua_Integer(status))
                if let body { lua_pushstring(L, body) } else { lua_pushnil(L) }
                return 2
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
            Native.fireCallback(ref) { L in
                lua_pushinteger(L, lua_Integer(status))
                if let body { lua_pushstring(L, body) } else { lua_pushnil(L) }
                return 2
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
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ok: Bool
            if let tmp, (200..<300).contains(status) {
                let fm = FileManager.default
                try? fm.removeItem(atPath: path)
                ok = (try? fm.moveItem(at: tmp, to: URL(fileURLWithPath: path))) != nil
            } else {
                ok = false
            }
            Native.fireCallback(ref) { L in
                lua_pushboolean(L, ok ? 1 : 0)
                return 1
            }
        }.resume()
        return 0
    }

    func setWallpaper(_ L: OpaquePointer?) -> Int32 {
        guard let path = LuaState.string(L, 1) else {
            return luaError(L, "set_wallpaper: path required")
        }
        let mode = LuaState.string(L, 2)
        let url = URL(fileURLWithPath: path)
        let ws = NSWorkspace.shared
        let targets = wallpaperTargets(mode)
        var ok = !targets.isEmpty
        for screen in targets {
            if (try? ws.setDesktopImageURL(url, for: screen)) == nil { ok = false }
        }
        lua_pushboolean(L, ok ? 1 : 0)
        return 1
    }

    // Paint a SOLID color across the chosen displays. Args: hex "#RRGGBB", mode
    // (see wallpaperTargets). NSWorkspace can only point a screen at an image
    // FILE, so we render a tiny solid-color PNG into the app cache and stretch it
    // to fill (a flat color has no detail to distort). The companion to
    // set_wallpaper: that paints a photo, this paints a flat color -- e.g. white
    // on a paper-like / e-ink monitor to cut glare and ghosting.
    func setWallpaperColor(_ L: OpaquePointer?) -> Int32 {
        guard let hex = LuaState.string(L, 1), let color = Native.colorFromHex(hex) else {
            return luaError(L, "set_wallpaper_color: a \"#RRGGBB\" color is required")
        }
        let mode = LuaState.string(L, 2)
        guard let url = Native.solidColorImageURL(color, hex: hex) else {
            return luaError(L, "set_wallpaper_color: could not render the solid color image")
        }
        let ws = NSWorkspace.shared
        // scaleAxesIndependently stretches the swatch to cover the screen exactly;
        // fillColor backs any pixel the image somehow doesn't reach. Both make a
        // flat fill robust regardless of the screen's previously-chosen scaling.
        let opts: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleAxesIndependently.rawValue),
            .allowClipping: true,
            .fillColor: color,
        ]
        let targets = wallpaperTargets(mode)
        var ok = !targets.isEmpty
        for screen in targets {
            if (try? ws.setDesktopImageURL(url, for: screen, options: opts)) == nil { ok = false }
        }
        lua_pushboolean(L, ok ? 1 : 0)
        return 1
    }

    // Resolve a wallpaper target mode to the screens it names:
    //   "all"/nil/""     -> every screen (the safe default: a multi-display setup
    //                       otherwise leaves the other monitors on their old image)
    //   "primary"/"main" -> the main display only
    //   "external"       -> every NON-built-in display (the laptop panel keeps
    //                       its own wallpaper -- what a "display connects" rule
    //                       for an external monitor wants)
    //   <anything else>  -> the display with that exact localizedName (e.g.
    //                       "Paperlike H D") -- so a rule can paint just the
    //                       monitor that connected. Empty if it isn't connected,
    //                       so a now-absent display paints NOTHING, not every screen.
    private func wallpaperTargets(_ mode: String?) -> [NSScreen] {
        switch mode {
        case nil, "", "all":
            return NSScreen.screens
        case "primary", "main":
            return NSScreen.main.map { [$0] } ?? []
        case "external":
            return NSScreen.screens.filter { !Native.isBuiltinScreen($0) }
        default:
            return NSScreen.screens.filter { $0.localizedName == mode }
        }
    }

    private static func isBuiltinScreen(_ s: NSScreen) -> Bool {
        let num = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                   as? NSNumber)?.uint32Value ?? 0
        return CGDisplayIsBuiltin(num) != 0
    }

    // Parse "#RRGGBB" (or "RRGGBB") into an sRGB color; nil on a malformed value.
    private static func colorFromHex(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green:   CGFloat((v >> 8) & 0xFF) / 255,
                       blue:    CGFloat(v & 0xFF) / 255,
                       alpha:   1)
    }

    // Render (and cache, keyed by hex) a small solid-color PNG in the app cache
    // dir; returns its file URL. Reused across calls for the same color.
    private static func solidColorImageURL(_ color: NSColor, hex: String) -> URL? {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Hammerdeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let url = dir.appendingPathComponent("solid-\(safe).png")

        let size = NSSize(width: 64, height: 64)
        let img = NSImage(size: size)
        img.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        do { try png.write(to: url) } catch { return nil }
        return url
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
