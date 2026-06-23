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

-- Is this an AUTOMATED trigger -- one that fires on its own (a clock or a
-- system event) with no human present and no live UI context? schedule and
-- event are automated; hotkey and chord are MANUAL (a person presses keys, so
-- the current selection / focused window / clipboard is meaningful). The
-- registry uses this to keep context-dependent actions off automated triggers
-- (see the action `automatable` flag in manifest.lua).
---@param spec table a trigger spec
---@return boolean
function triggers.isAutomated(spec)
    return spec.type == "schedule" or spec.type == "event"
end

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

-- spec: trigger table; action: function to run when it fires. `label` (optional):
-- the action's human name, used only by chords for the which-key hint.
-- returns a handle with .stop()
function triggers.bind(spec, action, label)
    assert(type(spec) == "table" and spec.type, "trigger spec needs a type")

    if spec.type == "hotkey" then
        return adapter.bindHotkey(spec.mods or {}, spec.key, action)

    elseif spec.type == "chord" then
        return adapter.bindChord(spec.mods or {}, spec.key, spec.follows or {}, action, label)

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

-- Well-known macOS factory-default shortcuts. macOS only writes
-- com.apple.symbolichotkeys entries the user has CUSTOMIZED -- untouched
-- defaults (Spotlight, screenshots, Mission Control) are absent from the live
-- read, so we'd miss the most common collisions without this table. The live
-- read (adapter.systemHotkeys) takes precedence per-combo, so a user who
-- remapped one of these is matched by their real binding, not this default.
local MACOS_DEFAULT_HOTKEYS = {
    { mods = { "cmd" }, key = "space", name = "Spotlight" },
    { mods = { "cmd", "alt" }, key = "space", name = "Finder search" },
    { mods = { "ctrl", "cmd" }, key = "space", name = "Emoji & Symbols" },
    { mods = { "ctrl" }, key = "up", name = "Mission Control" },
    { mods = { "ctrl" }, key = "down", name = "Application Windows" },
    { mods = { "ctrl" }, key = "left", name = "Move one space left" },
    { mods = { "ctrl" }, key = "right", name = "Move one space right" },
    { mods = { "cmd", "shift" }, key = "3", name = "Screenshot (whole screen)" },
    { mods = { "cmd", "shift" }, key = "4", name = "Screenshot (selection)" },
    { mods = { "cmd", "shift" }, key = "5", name = "Screenshot and recording options" },
    { mods = { "ctrl", "cmd" }, key = "q", name = "Lock Screen" },
    { mods = { "cmd", "shift" }, key = "/", name = "Help menu" },
}

-- Near-universal app shortcuts. A global hotkey on one of these does not
-- "conflict" in the registry sense -- nothing else in Hammerdeck owns it -- but
-- a Carbon global hotkey INTERCEPTS the combo before the focused app, so the
-- binding silently shadows (say) Close Window everywhere. The editor warns; the
-- user may still want it. We cannot enumerate a specific app's shortcuts (no
-- public API), so this is a curated set of the ones that hurt most to lose.
local COMMON_APP_HOTKEYS = {
    { mods = { "cmd" }, key = "c", name = "Copy" },
    { mods = { "cmd" }, key = "v", name = "Paste" },
    { mods = { "cmd" }, key = "x", name = "Cut" },
    { mods = { "cmd" }, key = "z", name = "Undo" },
    { mods = { "cmd", "shift" }, key = "z", name = "Redo" },
    { mods = { "cmd" }, key = "a", name = "Select All" },
    { mods = { "cmd" }, key = "s", name = "Save" },
    { mods = { "cmd" }, key = "w", name = "Close Window" },
    { mods = { "cmd" }, key = "q", name = "Quit" },
    { mods = { "cmd" }, key = "n", name = "New" },
    { mods = { "cmd" }, key = "t", name = "New Tab" },
    { mods = { "cmd" }, key = "f", name = "Find" },
    { mods = { "cmd" }, key = "p", name = "Print" },
    { mods = { "cmd" }, key = "tab", name = "Switch App" },
    { mods = { "cmd" }, key = "`", name = "Switch Window" },
}

-- Soft, ADVISORY conflicts for a would-be hotkey/chord binding -- collisions
-- with things OUTSIDE Hammerdeck's own registry (registry.triggerConflict
-- handles the hard, in-app ones and is the only hard block). Returns a list of
-- human-readable warning strings (empty when clear), from two sources:
--   * the user's enabled macOS system shortcuts (read live via the adapter)
--   * the curated near-universal app shortcuts this binding would shadow
-- Advisory only -- the caller still lets the user apply the binding.
function triggers.advisories(spec)
    local out = {}
    if type(spec) ~= "table" or not (spec.type == "hotkey" or spec.type == "chord") then
        return out
    end
    -- Compare case-insensitively on the key (the editor stores keys as typed,
    -- e.g. "J"; system/curated keys are canonical lowercase).
    local norm = { type = spec.type, mods = spec.mods,
                   key = tostring(spec.key):lower(), follows = spec.follows }

    -- macOS system shortcuts: the user's customized ones (live read) first, so
    -- their combos win over the factory-default table; then the well-known
    -- defaults the live read omits. Dedup by combo so a combo never warns twice.
    local seen = {}
    local function noteSystem(h)
        local other = { type = "hotkey", mods = h.mods, key = h.key }
        local k = combo(other)
        if seen[k] then return end
        if triggers.conflicts(norm, other) then
            seen[k] = true
            out[#out + 1] = "Used by macOS: " .. (h.name or "system shortcut")
        end
    end

    local okSys, sys = pcall(adapter.systemHotkeys)
    if okSys and type(sys) == "table" then
        for _, h in ipairs(sys) do noteSystem(h) end
    end
    for _, h in ipairs(MACOS_DEFAULT_HOTKEYS) do noteSystem(h) end

    for _, h in ipairs(COMMON_APP_HOTKEYS) do
        if triggers.conflicts(norm, { type = "hotkey", mods = h.mods, key = h.key }) then
            out[#out + 1] = "Shadows " .. h.name .. " (most apps)"
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Presentation: a spec -> human-readable string. Lives here (with the rest of
-- spec knowledge) rather than in the registry so the lifecycle core stays free
-- of view-layer formatting; the registry/UI just call these.
-- ---------------------------------------------------------------------------

-- A verbose, self-describing line for a spec (the Settings trigger column).
---@param spec table|nil a trigger spec, or nil for an unbound action
---@return string
function triggers.describe(spec)
    if not spec then return "no trigger" end
    if spec.type == "hotkey" then
        return "hotkey: " .. table.concat(spec.mods or {}, "+") .. "+" .. tostring(spec.key)
    elseif spec.type == "chord" then
        local prefix = table.concat(spec.mods or {}, "+") .. "+" .. tostring(spec.key)
        return "chord: " .. prefix .. " then " .. table.concat(spec.follows or {}, " ")
    elseif spec.type == "schedule" then
        if spec.everyMin then return "schedule: every " .. spec.everyMin .. " min" end
        return "schedule: daily at " .. tostring(spec.at)
    elseif spec.type == "event" then
        return "event: " .. tostring(spec.event)
    end
    return tostring(spec.type)
end

-- Compact, menubar-style glyphs for a spec (e.g. "⇧⌘V", "every 180m") -- the
-- form the command palette shows in its right-flush shortcut column, where the
-- verbose describe() would just truncate. The one Lua glyph copy; KeyGlyphs.swift
-- is the one Swift copy, and IntegrationTests asserts the two agree (REFACTOR #1).
local function modGlyphs(mods)
    local has = {}
    for _, m in ipairs(mods or {}) do has[m:lower()] = true end
    local s = ""
    if has.ctrl or has.control then s = s .. "⌃" end
    if has.alt or has.option then s = s .. "⌥" end
    if has.shift then s = s .. "⇧" end
    if has.cmd or has.command then s = s .. "⌘" end
    return s
end

local KEY_GLYPHS = {
    tab = "⇥", ["return"] = "↩", enter = "↩", space = "␣",
    delete = "⌫", backspace = "⌫", escape = "⎋", esc = "⎋",
    left = "←", right = "→", up = "↑", down = "↓",
}
local function keyGlyph(key)
    key = tostring(key)
    local g = KEY_GLYPHS[key:lower()]
    if g then return g end
    return #key == 1 and key:upper() or key
end

---@param spec table|nil a trigger spec
---@return string|nil glyph string, or nil for nil/unknown specs
function triggers.glyph(spec)
    if not spec then return nil end
    if spec.type == "hotkey" then
        return modGlyphs(spec.mods) .. keyGlyph(spec.key)
    elseif spec.type == "chord" then
        local follows = {}
        for _, f in ipairs(spec.follows or {}) do follows[#follows + 1] = keyGlyph(f) end
        return modGlyphs(spec.mods) .. keyGlyph(spec.key) .. " " .. table.concat(follows, " ")
    elseif spec.type == "schedule" then
        if spec.everyMin then return "every " .. spec.everyMin .. "m" end
        return "at " .. tostring(spec.at)
    elseif spec.type == "event" then
        return "on " .. tostring(spec.event)
    end
    return nil
end

return triggers
