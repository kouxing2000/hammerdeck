-- platform/adapter.lua
--
-- THE SEAM. This is the only file in the project allowed to touch `hs.*`.
-- Every feature and every other platform module calls `adapter.*` instead.
--
-- Why this matters: today the adapter forwards to stock Hammerspoon. If this
-- ever graduates to a standalone product, "fork Hammerspoon" vs "native Swift
-- shell with embedded Lua" becomes a swap of THIS ONE FILE's backend -- not a
-- rewrite of the platform. Keep the surface small; only add what a feature
-- genuinely needs. Each method maps to a tiny, stable macOS API:
--
--   bindHotkey      -> hs.hotkey            (Carbon RegisterEventHotKey)
--   everySeconds    -> hs.timer.doEvery     (NSTimer / GCD)
--   dailyAt         -> hs.timer.doAt        (NSTimer)
--   onSystemEvent   -> hs.caffeinate.watcher(NSWorkspace + screenIsLocked notif)
--   getSetting/set  -> hs.settings          (NSUserDefaults)
--   notify          -> hs.notify            (NSUserNotification)
--   log             -> print                (Console / log file)

local adapter = {}

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

-- mods: table like {"cmd","alt"}; key: string like "h"; fn: function
-- returns a handle with :disable()/:enable()/:delete()
function adapter.bindHotkey(mods, key, fn)
    return hs.hotkey.bind(mods, key, fn)
end

-- run fn every n seconds; returns a timer handle (:stop())
function adapter.everySeconds(n, fn)
    return hs.timer.doEvery(n, fn)
end

-- run fn once per day at "HH:MM"; returns a timer handle (:stop())
function adapter.dailyAt(timeStr, fn)
    return hs.timer.doAt(timeStr, "1d", fn)
end

-- Subscribe to a system event. Supported: "sleep","wake","screenLock","screenUnlock".
-- Returns a handle with :stop().
function adapter.onSystemEvent(event, fn)
    local map = {
        sleep        = hs.caffeinate.watcher.systemWillSleep,
        wake         = hs.caffeinate.watcher.systemDidWake,
        screenLock   = hs.caffeinate.watcher.screensDidLock,
        screenUnlock = hs.caffeinate.watcher.screensDidUnlock,
    }
    local want = map[event]
    assert(want, "adapter.onSystemEvent: unknown event '" .. tostring(event) .. "'")
    local w = hs.caffeinate.watcher.new(function(e)
        if e == want then fn() end
    end)
    w:start()
    return w
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function adapter.getSetting(key, default)
    local v = hs.settings.get(key)
    if v == nil then return default end
    return v
end

function adapter.setSetting(key, value)
    hs.settings.set(key, value)
end

-- ---------------------------------------------------------------------------
-- Output
-- ---------------------------------------------------------------------------

function adapter.notify(title, text)
    hs.notify.new({ title = title, informativeText = text }):send()
end

function adapter.log(...)
    print("[hammerdeck]", ...)
end

return adapter
