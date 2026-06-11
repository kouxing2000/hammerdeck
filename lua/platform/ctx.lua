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

local M = {}

local function optKey(id, k)   return "hammerdeck.opt." .. id .. "." .. k end
local function stateKey(id, k) return "hammerdeck.state." .. id .. "." .. k end

-- Build ctx + scope for a validated manifest m.
-- scope.adopt(rawHandle)  -- track an externally created handle (registry uses
--                            this for the trigger binding of action features)
-- scope.teardown()        -- stop every live handle
-- scope.liveCount()       -- live handles (used by tests to assert no leaks)
function M.make(m)
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
    function ctx.bindHotkey(mods, key, fn) return track(adapter.bindHotkey(mods, key, fn)) end
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

    -- windows / apps -----------------------------------------------------------
    function ctx.listWindows()      return adapter.listWindows() end
    function ctx.focusWindow(id)    return adapter.focusWindow(id) end
    function ctx.appIcon(bundleID)  return adapter.appIcon(bundleID) end

    -- clipboard ----------------------------------------------------------------
    function ctx.pasteboardRead()      return adapter.pasteboardRead() end
    function ctx.pasteboardWrite(text) adapter.pasteboardWrite(text) end

    -- network / files / wallpaper -----------------------------------------------
    function ctx.httpGet(url, headers, cb)     adapter.httpGet(url, headers, cb) end
    function ctx.downloadFile(url, path, cb)   adapter.downloadFile(url, path, cb) end
    function ctx.setWallpaper(path)            return adapter.setWallpaper(path) end
    function ctx.cacheDir()                    return adapter.cacheDir() end

    -- input / system state / system actions ------------------------------------
    function ctx.now()               return adapter.now() end
    function ctx.isModifierHeld(mod) return adapter.isModifierHeld(mod) end
    function ctx.idleSeconds()       return adapter.idleSeconds() end
    function ctx.systemSleep()       adapter.systemSleep() end
    function ctx.lockScreen()        adapter.lockScreen() end
    function ctx.displaySleep()      adapter.displaySleep() end
    function ctx.startScreensaver()  adapter.startScreensaver() end

    return ctx, scope
end

return M
