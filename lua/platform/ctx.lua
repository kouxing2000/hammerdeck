-- platform/ctx.lua
--
-- Builds the scoped, curated `ctx` a feature receives -- the plugin API.
--
-- Two design rules:
--   1. CURATED: features never see the raw adapter. ctx mirrors exactly the
--      adapter surface features are allowed to use, which also enables
--      per-feature capability scoping later without a contract change.
--   2. SCOPED: every live handle a feature creates through ctx (hotkey, timer,
--      watcher, chooser, dialog, banner) is tracked in the feature's
--      enablement scope. Disabling the feature tears down everything it ever
--      created -- a feature CANNOT leak bindings, even if its own cleanup is
--      buggy or absent. stop() on the wrappers is idempotent.
--
-- Note: a feature that creates many short-lived handles without stopping them
-- (e.g. an afterSeconds per cycle) accumulates small dead entries in the scope
-- until disable. Stopping a handle removes it from the scope, so well-behaved
-- features stay lean; teardown is correct either way.

local adapter  = require("platform.adapter")
local manifest = require("platform.manifest")
local modal    = require("platform.modal")

local M = {}

local function optKey(id, k)   return "hammerdeck.opt." .. id .. "." .. k end
local function stateKey(id, k) return "hammerdeck.state." .. id .. "." .. k end

-- "Pointer Follows Moved Window" (the pointer_follows_window feature): when its
-- toggle is on, repositioning the focused window carries the pointer along,
-- preserving its RELATIVE position inside the window (it was 30% from the left
-- edge -> still 30% from the left edge after the move). Implemented here, at the
-- single window-move seam, so EVERY window feature (window_snap, Window Mode,
-- window_to_next_screen, ...) gets it for free with no per-feature code. The
-- toggle is just that feature's enabled-state; reading the one well-known key
-- avoids a require cycle back into the registry.
local POINTER_FOLLOWS_KEY = "hammerdeck.enabled.pointer_follows_window"

local function moveWindowMaybeFollowingPointer(f)
    if adapter.getSetting(POINTER_FOLLOWS_KEY, false) ~= true then
        return adapter.setFocusedWindowFrame(f)
    end
    local old = adapter.focusedWindowFrame()
    local mp  = adapter.mousePosition()
    local ok  = adapter.setFocusedWindowFrame(f)
    -- Carry the pointer only when it was actually inside the window being moved
    -- (never yank a pointer parked elsewhere); guard degenerate / missing sizes.
    if ok and old and mp and old.w and old.h and old.w > 0 and old.h > 0
        and mp.x >= old.x and mp.x <= old.x + old.w
        and mp.y >= old.y and mp.y <= old.y + old.h then
        local rx = (mp.x - old.x) / old.w
        local ry = (mp.y - old.y) / old.h
        adapter.setMousePosition(f.x + rx * f.w, f.y + ry * f.h)
    end
    return ok
end

-- Build ctx + scope for a validated manifest m.
-- scope.adopt(rawHandle)  -- track an externally created handle (registry uses
--                            this for the trigger binding of action features)
-- scope.teardown()        -- stop every live handle
-- scope.liveCount()       -- live handles (used by tests to assert no leaks)
-- resolveTrigger(actionId) -- optional; injected by the registry so
--                             ctx.actionTrigger can report an action's
--                             currently-bound trigger without a require cycle
-- extra -- optional table of capability-gated methods (e.g. commands /
--          runCommand) the registry injects ONLY for features that declared the
--          matching capability; copied verbatim onto ctx (see manifest.lua).
function M.make(m, resolveTrigger, extra)
    local live = {}   -- set: wrapper -> true

    local function track(raw)
        local w = {}
        for k, v in pairs(raw) do w[k] = v end
        w.stop = function()
            if live[w] then
                live[w] = nil
                raw.stop()
            end
        end
        live[w] = true
        return w
    end

    local scope = {}
    function scope.adopt(raw) return track(raw) end
    function scope.teardown()
        local ws = {}
        for w in pairs(live) do ws[#ws + 1] = w end
        for _, w in ipairs(ws) do pcall(w.stop) end
    end
    function scope.liveCount()
        local n = 0
        for _ in pairs(live) do n = n + 1 end
        return n
    end

    local ctx = {}
    ctx.featureId = m.id

    -- The trigger spec currently bound to one of this feature's actions
    -- (user override or declared default; nil for none / unknown action).
    -- Lets behavior follow the binding -- e.g. window/tab switchers derive
    -- which modifier their release-to-jump should watch from the actual
    -- hotkey instead of asking the user twice.
    function ctx.actionTrigger(actionId)
        return resolveTrigger and resolveTrigger(actionId) or nil
    end

    -- options (typed, user-overridable, manifest default fallback) ----------
    function ctx.opt(key)
        return adapter.getSetting(optKey(m.id, key), manifest.defaultFor(m, key))
    end

    -- feature-scoped persistent state ----------------------------------------
    function ctx.getState(key, default)
        return adapter.getSetting(stateKey(m.id, key), default)
    end
    function ctx.setState(key, value)
        adapter.setSetting(stateKey(m.id, key), value)
    end

    -- logging / notifications -------------------------------------------------
    function ctx.log(...) adapter.log("[" .. m.id .. "]", ...) end
    function ctx.notify(title, text) adapter.notify(title, text) end
    function ctx.alert(text) adapter.alert(text) end
    function ctx.locateMouse(seconds) adapter.locateMouse(seconds) end

    -- bindings (all scope-tracked) --------------------------------------------
    function ctx.bindHotkey(mods, key, fn, onRelease) return track(adapter.bindHotkey(mods, key, fn, onRelease)) end
    function ctx.everySeconds(n, fn)       return track(adapter.everySeconds(n, fn)) end
    function ctx.afterSeconds(n, fn)       return track(adapter.afterSeconds(n, fn)) end
    function ctx.dailyAt(timeStr, fn)      return track(adapter.dailyAt(timeStr, fn)) end
    function ctx.onSystemEvent(event, fn)  return track(adapter.onSystemEvent(event, fn)) end

    -- UI (scope-tracked) -------------------------------------------------------
    function ctx.chooser(opts)   return track(adapter.chooser(opts)) end
    function ctx.askChoice(opts) return track(adapter.askChoice(opts)) end
    function ctx.askText(opts)   return track(adapter.askText(opts)) end
    function ctx.banner(text)    return track(adapter.banner(text)) end
    function ctx.progressBar()   return track(adapter.progressBar()) end
    function ctx.usageWidget(screenIndex) return track(adapter.usageWidget(screenIndex)) end
    -- enter a modal hotkey group (see platform/modal.lua); stop() exits
    function ctx.modal(spec)     return track(modal.enter(spec)) end

    -- windows / apps -----------------------------------------------------------
    function ctx.listWindows()      return adapter.listWindows() end
    function ctx.focusWindow(id)    return adapter.focusWindow(id) end
    function ctx.appIcon(bundleID)  return adapter.appIcon(bundleID) end
    function ctx.frontmostApp()     return adapter.frontmostApp() end
    function ctx.onAppActivated(fn) return track(adapter.onAppActivated(fn)) end
    function ctx.axTrusted()        return adapter.axTrusted() end
    function ctx.axPrompt()         return adapter.axPrompt() end
    function ctx.focusedWindowFrame()          return adapter.focusedWindowFrame() end
    function ctx.focusedWindowTitle()          return adapter.focusedWindowTitle() end
    function ctx.setFocusedWindowFrame(f)      return moveWindowMaybeFollowingPointer(f) end
    function ctx.setFocusedWindowFullscreen(b) return adapter.setFocusedWindowFullscreen(b) end
    function ctx.screenFrames()                return adapter.screenFrames() end
    function ctx.mousePosition()               return adapter.mousePosition() end
    function ctx.setMousePosition(x, y)        adapter.setMousePosition(x, y) end

    -- data files (durable feature-owned storage) ---------------------------------
    function ctx.dataDir()                return adapter.dataDir() end
    function ctx.mkdir(path)              return adapter.mkdir(path) end
    function ctx.removeDataPath(rel)      return adapter.removeDataPath(rel) end
    function ctx.fileRead(path)           return adapter.fileRead(path) end
    function ctx.fileWrite(path, text)    return adapter.fileWrite(path, text) end
    function ctx.fileAppend(path, line)   return adapter.fileAppend(path, line) end
    function ctx.fileExists(path)         return adapter.fileExists(path) end

    -- clipboard ----------------------------------------------------------------
    function ctx.pasteboardRead()      return adapter.pasteboardRead() end
    function ctx.pasteboardWrite(text) adapter.pasteboardWrite(text) end
    function ctx.pasteboardInfo()      return adapter.pasteboardInfo() end

    -- network / files / wallpaper -----------------------------------------------
    function ctx.httpGet(url, headers, cb)     adapter.httpGet(url, headers, cb) end
    function ctx.downloadFile(url, path, cb)   adapter.downloadFile(url, path, cb) end
    function ctx.setWallpaper(path, mode)      return adapter.setWallpaper(path, mode) end
    function ctx.cacheDir()                    return adapter.cacheDir() end

    -- input / system state / system actions ------------------------------------
    function ctx.now()               return adapter.now() end
    function ctx.isModifierHeld(mod) return adapter.isModifierHeld(mod) end
    function ctx.keyStroke(mods, key) adapter.keyStroke(mods, key) end
    function ctx.typeText(text)       adapter.typeText(text) end
    function ctx.openURL(url)         return adapter.openURL(url) end
    function ctx.activateApp(name)    return adapter.activateApp(name) end
    function ctx.focusBrowserTab(pattern, fallbackURL)
        return adapter.focusBrowserTab(pattern, fallbackURL)
    end
    function ctx.isAppRunning(name)  return adapter.isAppRunning(name) end
    function ctx.browserListTabs(app, cb)  adapter.browserListTabs(app, cb) end
    function ctx.browserFocusTab(app, winId, tabIndex, cb)
        adapter.browserFocusTab(app, winId, tabIndex, cb)
    end
    function ctx.browserActiveURL(app) return adapter.browserActiveURL(app) end
    function ctx.extractFavicons(outDir, domains, cb)
        adapter.extractFavicons(outDir, domains, cb)
    end
    function ctx.idleSeconds()       return adapter.idleSeconds() end
    function ctx.systemSleep()       adapter.systemSleep() end
    function ctx.lockScreen()        adapter.lockScreen() end
    function ctx.displaySleep()      adapter.displaySleep() end
    function ctx.startScreensaver()  adapter.startScreensaver() end

    -- capability-gated extras (stateless; no scope handle to track) ------------
    if extra then
        for k, v in pairs(extra) do
            assert(ctx[k] == nil, "capability method '" .. k .. "' shadows a core ctx method")
            ctx[k] = v
        end
    end

    return ctx, scope
end

return M
