-- platform/triggers.lua
--
-- The universal trigger layer: ANY trigger can fire ANY feature action.
-- This is the heart of "shortcut + schedule do anything". Triggers are
-- declarative specs; this module turns a spec into a live binding via the
-- adapter (and only the adapter).
--
-- Trigger spec types:
--   { type = "hotkey",   mods = {"cmd","alt"}, key = "h" }
--   { type = "chord",    mods = {"cmd","shift"}, key = "a", follows = {"b"} }
--                                                   -- a prefix hotkey (mods+key)
--                                                   -- arms a transient mode; the
--                                                   -- follow key(s) pressed in
--                                                   -- sequence fire the action
--                                                   -- (cmd+shift+a, then b)
--   { type = "schedule", everyMin = 25 }            -- repeating interval
--   { type = "schedule", at = "00:30" }             -- daily at HH:MM
--   { type = "event",    event = "wake" }           -- sleep|wake|screenLock|screenUnlock
--
-- Every adapter binding returns a normalized handle with .stop(), so bind()
-- just forwards it.

local adapter = require("platform.adapter")

local triggers = {}

local VALID_EVENTS = {
    sleep = true, wake = true, screenLock = true, screenUnlock = true,
    screenChanged = true,   -- display added/removed/rearranged
}

-- Validate a trigger spec (used before persisting a user rebind). Throws on a
-- malformed spec; returns true on success.
function triggers.validate(spec)
    assert(type(spec) == "table", "trigger spec must be a table")
    if spec.type == "hotkey" then
        assert(type(spec.key) == "string" and #spec.key > 0, "hotkey trigger needs a key")
        assert(spec.mods == nil or type(spec.mods) == "table", "hotkey mods must be a table")
    elseif spec.type == "chord" then
        assert(type(spec.key) == "string" and #spec.key > 0, "chord trigger needs a prefix key")
        assert(spec.mods == nil or type(spec.mods) == "table", "chord mods must be a table")
        assert(type(spec.follows) == "table" and #spec.follows >= 1,
            "chord trigger needs at least one follow key")
        for _, f in ipairs(spec.follows) do
            assert(type(f) == "string" and #f > 0, "chord follow keys must be non-empty strings")
            local lf = f:lower()
            -- escape always cancels an armed chord, so it can't double as a follow.
            assert(lf ~= "escape" and lf ~= "esc",
                "escape cannot be a chord follow key (it always cancels the chord)")
        end
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
    elseif spec.type == "chord" then
        local mods = {}
        for _, m in ipairs(spec.mods or {}) do mods[#mods + 1] = m end
        table.sort(mods)
        -- follow keys are an ORDERED sequence -- never sorted.
        return "chord|" .. table.concat(mods, ",") .. "|" .. spec.key
            .. "|" .. table.concat(spec.follows, ",")
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
    elseif kind == "chord" then
        local mods, key, follows = str:match("^chord|([^|]*)|([^|]*)|(.*)$")
        if not key or #key == 0 then return nil end
        if not follows or #follows == 0 then return nil end
        local modlist = {}
        for m in mods:gmatch("[^,]+") do modlist[#modlist + 1] = m end
        local followlist = {}
        for f in follows:gmatch("[^,]+") do followlist[#followlist + 1] = f end
        if #followlist == 0 then return nil end
        return { type = "chord", mods = modlist, key = key, follows = followlist }
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

    elseif spec.type == "chord" then
        return adapter.bindChord(spec.mods or {}, spec.key, spec.follows or {}, action)

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

-- Canonical "mods|key" of a hotkey, or of a chord's PREFIX hotkey -- the
-- physical key combo that gets registered with the OS.
local function combo(spec)
    local mods = {}
    for _, m in ipairs(spec.mods or {}) do mods[#mods + 1] = m end
    table.sort(mods)
    return table.concat(mods, ",") .. "|" .. tostring(spec.key)
end

-- Is sequence `a` equal to, or a prefix of, sequence `b`?
local function seqIsPrefix(a, b)
    if #a > #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- Do two trigger specs contend for the same physical input? Only hotkey/chord
-- specs can conflict (schedules and events may freely overlap). Rules:
--   hotkey vs hotkey  -- conflict iff the same combo.
--   hotkey vs chord   -- conflict iff the hotkey equals the chord's prefix combo
--                        (a plain global hotkey would steal the chord's prefix).
--   chord  vs chord   -- conflict ONLY when they share a prefix AND one follow
--                        sequence equals or is a prefix of the other. Different
--                        follow keys off a SHARED prefix is the whole point of
--                        chords (cmd+shift+a -> b vs -> c) -- not a conflict.
function triggers.conflicts(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    local hk = { hotkey = true, chord = true }
    if not (hk[a.type] and hk[b.type]) then return false end
    if a.type == "chord" and b.type == "chord" then
        if combo(a) ~= combo(b) then return false end
        return seqIsPrefix(a.follows or {}, b.follows or {})
            or seqIsPrefix(b.follows or {}, a.follows or {})
    end
    -- at least one plain hotkey: they collide iff the combos match.
    return combo(a) == combo(b)
end

return triggers
