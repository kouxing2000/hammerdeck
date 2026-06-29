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

local adapter    = require("platform.adapter")
local manifest   = require("platform.manifest")
local modal      = require("platform.modal")
local i18n       = require("platform.i18n")
local window_ops = require("platform.window_ops")

local M = {}

local function optKey(id, k)   return "hammerdeck.opt." .. id .. "." .. k end
local function stateKey(id, k) return "hammerdeck.state." .. id .. "." .. k end

-- The focused-window move + "Pointer Follows Moved Window" policy lives in
-- platform/window_ops.lua now (ctx.window.setFrame delegates to it). That keeps
-- the cross-feature policy out of this boundary builder and resolves the old
-- registry back-door (window_ops takes an injected enabled-state predicate).

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

    -- The user-visible app display name (single source of truth, from the seam).
    -- A value, not a function: it never changes during a run. Features inject it
    -- into messages ("<app> needs Accessibility"), never hardcode the brand.
    ctx.appName = adapter.appName()

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

    -- secrets (Keychain-backed; read-only here -- the user sets them in
    -- Settings). Namespaced per feature, so a feature reads only its own.
    -- Returns the stored string or nil; NEVER a manifest default (a `secret`
    -- option must not declare a plaintext default).
    function ctx.secret(key)
        return adapter.secretGet(optKey(m.id, key))
    end

    -- feature-scoped persistent state ----------------------------------------
    function ctx.getState(key, default)
        return adapter.getSetting(stateKey(m.id, key), default)
    end
    function ctx.setState(key, value)
        adapter.setSetting(stateKey(m.id, key), value)
    end

    -- localization ------------------------------------------------------------
    -- ctx.t(key, default): localize a feature string. Resolves the feature's own
    -- catalog first, then the shared global catalog, then the inline English
    -- `default`. Interpolate with string.format over the result (placeholders
    -- stay identical across locales). ctx.plural picks a one/other template.
    function ctx.t(key, default)        return i18n.tFeature(m.id, key, default) end
    function ctx.plural(key, count, forms) return i18n.plural(key, count, forms, m.id) end

    -- logging / notifications -------------------------------------------------
    function ctx.log(...) adapter.log("[" .. m.id .. "]", ...) end
    function ctx.notify(title, text) adapter.notify(title, text) end
    function ctx.alert(text) adapter.alert(text) end

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

    -- apps (Phase 3 will namespace these into ctx.app.*) -----------------------
    function ctx.appIcon(bundleID)  return adapter.appIcon(bundleID) end
    function ctx.frontmostApp()     return adapter.frontmostApp() end
    function ctx.onAppActivated(fn) return track(adapter.onAppActivated(fn)) end
    -- Accessibility permission gate -- stays TOP-LEVEL (a gate, not a domain).
    function ctx.axTrusted()        return adapter.axTrusted() end
    function ctx.axPrompt()         return adapter.axPrompt() end

    -- window / screen / mouse domains -----------------------------------------
    -- Namespaced sub-tables (was a flat ctx.<verb>Window... surface). ctx.window
    -- .setFrame routes through window_ops (focused-window move + pointer-follow);
    -- the rest are thin adapter pass-throughs. New pure-Lua window helpers
    -- (tiling/grid, ported onto platform.windows math) will surface here too.
    ctx.window = {}
    function ctx.window.list()           return adapter.listWindows() end
    function ctx.window.focus(id)        return adapter.focusWindow(id) end
    function ctx.window.frame()          return adapter.focusedWindowFrame() end
    function ctx.window.title()          return adapter.focusedWindowTitle() end
    function ctx.window.setFrame(f)      return window_ops.setFrame(f) end
    function ctx.window.setFullscreen(b) return adapter.setFocusedWindowFullscreen(b) end

    ctx.screen = {}
    function ctx.screen.frames()         return adapter.screenFrames() end

    ctx.mouse = {}
    function ctx.mouse.position()        return adapter.mousePosition() end
    function ctx.mouse.setPosition(x, y) adapter.setMousePosition(x, y) end
    function ctx.mouse.locate(seconds)   adapter.locateMouse(seconds) end

    -- data files (durable feature-owned storage) ---------------------------------
    function ctx.dataDir()                return adapter.dataDir() end
    function ctx.homeDir()                return adapter.homeDir() end
    function ctx.mkdir(path)              return adapter.mkdir(path) end
    function ctx.removeSubdir(base, rel)  return adapter.removeSubdir(base, rel) end
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
    function ctx.httpPost(url, headers, body, cb) adapter.httpPost(url, headers, body, cb) end
    function ctx.httpRequest(url, method, headers, body, cb)
        adapter.httpRequest(url, method, headers, body, cb)
    end
    function ctx.downloadFile(url, path, cb)   adapter.downloadFile(url, path, cb) end
    function ctx.setWallpaper(path, mode)      return adapter.setWallpaper(path, mode) end
    function ctx.cacheDir()                    return adapter.cacheDir() end

    -- input / system state / system actions ------------------------------------
    function ctx.now()               return adapter.now() end
    -- Cryptographically secure uniform integer in [min,max] (CSPRNG via the
    -- host) -- use this, never math.random, for anything security-sensitive.
    function ctx.randomInt(min, max) return adapter.randomInt(min, max) end
    function ctx.isModifierHeld(mod) return adapter.isModifierHeld(mod) end
    function ctx.keyStroke(mods, key) adapter.keyStroke(mods, key) end
    function ctx.typeText(text)       adapter.typeText(text) end
    function ctx.openURL(url)         return adapter.openURL(url) end
    function ctx.activateApp(name)    return adapter.activateApp(name) end
    function ctx.launchOrFocusApp(id) return adapter.launchOrFocusApp(id) end
    function ctx.focusBrowserTab(pattern, fallbackURL)
        return adapter.focusBrowserTab(pattern, fallbackURL)
    end
    function ctx.focusSafariTab(pattern, fallbackURL)
        return adapter.focusSafariTab(pattern, fallbackURL)
    end
    function ctx.defaultBrowser()    return adapter.defaultBrowser() end
    function ctx.openSiteApp(pattern, url)
        return adapter.openSiteApp(pattern, url)
    end
    function ctx.openSite(bundleId, profile, app, url)
        return adapter.openSite(bundleId, profile, app, url)
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
    function ctx.setAppearance(mode) return adapter.setAppearance(mode) end
    function ctx.adjustVolume(delta) return adapter.adjustVolume(delta) end
    function ctx.toggleMute()        return adapter.toggleMute() end
    function ctx.mediaKey(name)      adapter.mediaKey(name) end

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
