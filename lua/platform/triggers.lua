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

local VALID_EVENTS = { sleep = true, wake = true, screenLock = true, screenUnlock = true }

-- Validate a trigger spec (used before persisting a user rebind). Throws on a
-- malformed spec; returns true on success.
function triggers.validate(spec)
    assert(type(spec) == "table", "trigger spec must be a table")
    if spec.type == "hotkey" then
        assert(type(spec.key) == "string" and #spec.key > 0, "hotkey trigger needs a key")
        assert(spec.mods == nil or type(spec.mods) == "table", "hotkey mods must be a table")
    elseif spec.type == "schedule" then
        assert(spec.everyMin or spec.at, "schedule trigger needs everyMin or at")
        if spec.everyMin then
            assert(tonumber(spec.everyMin) and tonumber(spec.everyMin) > 0,
                "schedule everyMin must be a positive number")
        end
        if spec.at then
            assert(tostring(spec.at):match("^%d%d?:%d%d$"), "schedule at must be HH:MM")
        end
    elseif spec.type == "event" then
        assert(VALID_EVENTS[spec.event], "unknown event '" .. tostring(spec.event) .. "'")
    else
        error("unknown trigger type '" .. tostring(spec.type) .. "'")
    end
    return true
end

-- Serialize a spec to a scalar string (the settings store holds bool/num/string
-- only -- no tables -- so a user's trigger override is stored encoded). Hotkey
-- mods are sorted so the encoding is canonical: alt+cmd == cmd+alt.
function triggers.encode(spec)
    triggers.validate(spec)
    if spec.type == "hotkey" then
        local mods = {}
        for _, m in ipairs(spec.mods or {}) do mods[#mods + 1] = m end
        table.sort(mods)
        return "hotkey|" .. table.concat(mods, ",") .. "|" .. spec.key
    elseif spec.type == "schedule" then
        if spec.everyMin then return "schedule|every|" .. tostring(spec.everyMin) end
        return "schedule|at|" .. tostring(spec.at)
    else -- event
        return "event|" .. spec.event
    end
end

-- Inverse of encode. Returns a spec table, or nil if the string is malformed
-- (treated as "no override" -> fall back to the manifest default).
function triggers.decode(str)
    if type(str) ~= "string" then return nil end
    local kind = str:match("^([^|]+)|")
    if kind == "hotkey" then
        local mods, key = str:match("^hotkey|([^|]*)|(.*)$")
        if not key or #key == 0 then return nil end
        local modlist = {}
        for m in mods:gmatch("[^,]+") do modlist[#modlist + 1] = m end
        return { type = "hotkey", mods = modlist, key = key }
    elseif kind == "schedule" then
        local mode, val = str:match("^schedule|([^|]+)|(.*)$")
        if mode == "every" and tonumber(val) then
            return { type = "schedule", everyMin = tonumber(val) }
        elseif mode == "at" and tostring(val):match("^%d%d?:%d%d$") then
            return { type = "schedule", at = val }
        end
        return nil
    elseif kind == "event" then
        local ev = str:match("^event|(.+)$")
        if ev and VALID_EVENTS[ev] then return { type = "event", event = ev } end
        return nil
    end
    return nil
end

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
