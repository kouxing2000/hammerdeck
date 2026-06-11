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
-- Every adapter binding returns a normalized handle with .stop(), so bind()
-- just forwards it.

local adapter = require("platform.adapter")

local triggers = {}

-- spec: trigger table; action: function to run when it fires.
-- returns a handle with .stop()
function triggers.bind(spec, action)
    assert(type(spec) == "table" and spec.type, "trigger spec needs a type")

    if spec.type == "hotkey" then
        return adapter.bindHotkey(spec.mods or {}, spec.key, action)

    elseif spec.type == "schedule" then
        if spec.everyMin then
            return adapter.everySeconds(spec.everyMin * 60, action)
        elseif spec.at then
            return adapter.dailyAt(spec.at, action)
        end
        error("schedule trigger needs everyMin or at")

    elseif spec.type == "event" then
        return adapter.onSystemEvent(spec.event, action)
    end

    error("unknown trigger type '" .. tostring(spec.type) .. "'")
end

return triggers
