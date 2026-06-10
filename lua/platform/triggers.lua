-- platform/triggers.lua
--
-- The universal trigger layer: ANY trigger can fire ANY feature action.
-- This is the heart of "shortcut + schedule do anything". Triggers are
-- declarative specs; this module turns a spec into a live binding via the
-- adapter (and only the adapter).
--
-- Trigger spec types:
--   { type = "hotkey",   mods = {"cmd","alt"}, key = "h" }
--   { type = "schedule", everyMin = 25 }            -- repeating interval
--   { type = "schedule", at = "00:30" }             -- daily at HH:MM
--   { type = "event",    event = "wake" }           -- sleep|wake|screenLock|screenUnlock
--
-- bind() returns a handle with :stop() so the registry can unbind on disable.

local adapter = require("platform.adapter")

local triggers = {}

local function stopHotkey(h) h:delete() end
local function stopTimer(h)  h:stop()   end
local function stopWatcher(h) h:stop()  end

-- spec: trigger table; action: function to run when it fires.
-- returns { stop = function() ... end }
function triggers.bind(spec, action)
    assert(type(spec) == "table" and spec.type, "trigger spec needs a type")

    if spec.type == "hotkey" then
        local h = adapter.bindHotkey(spec.mods or {}, spec.key, action)
        return { stop = function() stopHotkey(h) end }

    elseif spec.type == "schedule" then
        if spec.everyMin then
            local h = adapter.everySeconds(spec.everyMin * 60, action)
            return { stop = function() stopTimer(h) end }
        elseif spec.at then
            local h = adapter.dailyAt(spec.at, action)
            return { stop = function() stopTimer(h) end }
        end
        error("schedule trigger needs everyMin or at")

    elseif spec.type == "event" then
        local h = adapter.onSystemEvent(spec.event, action)
        return { stop = function() stopWatcher(h) end }
    end

    error("unknown trigger type '" .. tostring(spec.type) .. "'")
end

return triggers
