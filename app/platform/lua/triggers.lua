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
--   { type = "state",    signal = "frontmostApp", becomes = "Safari" }
--                                                   -- rules-engine only (see TYPES.state)
--
-- Every adapter binding returns a normalized handle with .stop(), so bind()
-- just forwards it.
--
-- Each type is ONE ROW in the TYPES registry below; the public functions are
-- thin dispatchers over it. See the registry's header for why.

local adapter = require("platform.adapter")
local i18n    = require("platform.i18n")

local triggers = {}

local VALID_EVENTS = {
    sleep = true, wake = true, screenLock = true, screenUnlock = true,
    screenChanged = true,   -- display added/removed/rearranged
}

-- The modifier names the native seam accepts -- read FROM the seam
-- (adapter.validModifiers, backed by KeyModifier.swift, the one authority),
-- so validate can never drift from what bind_hotkey would reject. The Swift
-- parsers used to DROP an unknown name silently, so {"cmmd","alt"}+k bound
-- plain alt+k and hijacked it -- reject at validate time, before a bad spec
-- ever persists or binds. Built lazily on first use (after the test fake has
-- preempted the adapter).
local VALID_MODS
local function validMods()
    if not VALID_MODS then
        VALID_MODS = {}
        for _, m in ipairs(adapter.validModifiers()) do VALID_MODS[m] = true end
    end
    return VALID_MODS
end

local function assertValidMods(mods, what)
    for _, m in ipairs(mods or {}) do
        assert(type(m) == "string" and validMods()[m:lower()],
            what .. " has unknown modifier '" .. tostring(m) .. "'")
    end
end

-- Parse an "HH:MM" daily time: 1-or-2-digit hour, 2-digit minute, range-checked
-- to a real clock time (00:00-23:59). Returns the hour and minute as numbers, or
-- nil for anything malformed or out of range ("29:99", "8", "8:5", ""). The one
-- place HH:MM is parsed -- callers needing only a yes/no use it as a predicate
-- (`if triggers.parseTimeOfDay(s) then`). Mirrors the Swift HHMM util.
---@param str any
---@return integer|nil hour, integer|nil minute
function triggers.parseTimeOfDay(str)
    local hh, mm = tostring(str):match("^(%d%d?):(%d%d)$")
    if not hh then return nil end
    local h, m = tonumber(hh), tonumber(mm)
    if h > 23 or m > 59 then return nil end
    return h, m
end

-- Sorted, comma-joined modifier list -- the canonical half of a hotkey/chord
-- encoding, so alt+cmd and cmd+alt encode identically.
local function sortedMods(spec)
    local mods = {}
    for _, m in ipairs(spec.mods or {}) do mods[#mods + 1] = m end
    table.sort(mods)
    return table.concat(mods, ",")
end

-- Split a comma-separated list back into an array (the inverse of the above and
-- of a follows list; empty string -> empty table).
local function splitList(s)
    local out = {}
    for item in tostring(s):gmatch("[^,]+") do out[#out + 1] = item end
    return out
end

-- Compact glyph helpers (used by the TYPES rows' `glyph`). "⇧⌘V" / "every 180m"
-- -- the form the command palette shows in its right-flush shortcut column,
-- where the verbose describe() would just truncate. The one Lua glyph copy;
-- KeyGlyphs.swift is the one Swift copy, and IntegrationTests asserts they agree.
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

-- ---------------------------------------------------------------------------
-- The trigger-type registry: ONE row per type.
--
-- WHY (CODE-11): every type used to be spelled out in SEVEN parallel if-chains
-- over `spec.type` -- isAutomated, validate, encode, decode, bind, describe,
-- glyph. Nothing tied them together, so adding a type meant finding all seven,
-- and missing one failed SILENTLY, differently each time: no `decode` and every
-- stored override of that type quietly reverts to the manifest default on the
-- next load; no `glyph` and the palette's shortcut column goes blank; no
-- `automated` and a context-dependent action can be scheduled to fire at 3am
-- with no window focused.
--
-- A type is now one row here plus its Swift editor. Most fields are REQUIRED
-- (automated, validate, bind, describe, glyph); only `encode`/`decode` are
-- optional, and their absence is MEANINGFUL rather than an oversight -- it
-- declares "this type is not scalar-encodable". The guard
-- (test/cases/_integration/platform/trigger_types.lua) enforces both halves:
-- every required field present, and encode/decode present or absent together.
--
-- Swift knows these type names too, but only to EDIT and DRAW a spec
-- (`TriggerSpec` in SettingsModels.swift; `shortcutGlyph` in FeatureChrome.swift).
-- This table is the authority for behavior -- a new type needs a row here and an
-- editor there, and only the row decides what the trigger actually does.
---@class TriggerType
---@field automated boolean fires with nobody present, so no live UI context
---@field validate fun(spec: table) throws on a malformed spec
---@field encode nil|fun(spec: table): string spec -> scalar; absent = not scalar-encodable
---@field decode nil|fun(str: string): table|nil scalar -> spec; absent = never decodes
---@field bind fun(spec: table, action: function, label: string?, icon: string?): table REQUIRED; a type bound elsewhere supplies a stub that says where
---@field describe fun(spec: table): string a verbose human line
---@field glyph fun(spec: table): string|nil a compact menubar-style glyph
-- ---------------------------------------------------------------------------

---@type table<string, TriggerType>
local TYPES = {}

-- MANUAL: a person presses keys, so the live selection / focused window /
-- clipboard is meaningful. Bound straight to a Carbon global hotkey.
TYPES.hotkey = {
    automated = false,
    validate = function(spec)
        assert(type(spec.key) == "string" and #spec.key > 0, "hotkey trigger needs a key")
        assert(spec.mods == nil or type(spec.mods) == "table", "hotkey mods must be a table")
        assertValidMods(spec.mods, "hotkey trigger")
    end,
    encode = function(spec)
        return "hotkey|" .. sortedMods(spec) .. "|" .. spec.key
    end,
    decode = function(str)
        local mods, key = str:match("^hotkey|([^|]*)|(.*)$")
        if not key or #key == 0 then return nil end
        return { type = "hotkey", mods = splitList(mods), key = key }
    end,
    bind = function(spec, action)
        return adapter.bindHotkey(spec.mods or {}, spec.key, action)
    end,
    describe = function(spec)
        return i18n.format("trigger.hotkey", "hotkey: %s",
            table.concat(spec.mods or {}, "+") .. "+" .. tostring(spec.key))
    end,
    glyph = function(spec)
        return modGlyphs(spec.mods) .. keyGlyph(spec.key)
    end,
}

-- MANUAL: a prefix hotkey arms a transient modal layer; the follow key(s)
-- pressed in sequence fire the action (cmd+shift+a, then b).
TYPES.chord = {
    automated = false,
    validate = function(spec)
        assert(type(spec.key) == "string" and #spec.key > 0, "chord trigger needs a prefix key")
        assert(spec.mods == nil or type(spec.mods) == "table", "chord mods must be a table")
        assertValidMods(spec.mods, "chord trigger")
        assert(type(spec.follows) == "table" and #spec.follows >= 1,
            "chord trigger needs at least one follow key")
        for _, f in ipairs(spec.follows) do
            assert(type(f) == "string" and #f > 0, "chord follow keys must be non-empty strings")
            local lf = f:lower()
            -- escape always cancels an armed chord, so it can't double as a follow.
            assert(lf ~= "escape" and lf ~= "esc",
                "escape cannot be a chord follow key (it always cancels the chord)")
        end
    end,
    encode = function(spec)
        -- follow keys are an ORDERED sequence -- never sorted.
        return "chord|" .. sortedMods(spec) .. "|" .. spec.key
            .. "|" .. table.concat(spec.follows, ",")
    end,
    decode = function(str)
        local mods, key, follows = str:match("^chord|([^|]*)|([^|]*)|(.*)$")
        if not key or #key == 0 then return nil end
        if not follows or #follows == 0 then return nil end
        local followlist = splitList(follows)
        if #followlist == 0 then return nil end
        return { type = "chord", mods = splitList(mods), key = key, follows = followlist }
    end,
    bind = function(spec, action, label, icon)
        return adapter.bindChord(spec.mods or {}, spec.key, spec.follows or {}, action, label, icon)
    end,
    describe = function(spec)
        local prefix = table.concat(spec.mods or {}, "+") .. "+" .. tostring(spec.key)
        return i18n.format("trigger.chord", "chord: %1$s then %2$s", prefix,
            table.concat(spec.follows or {}, " "))
    end,
    glyph = function(spec)
        local follows = {}
        for _, f in ipairs(spec.follows or {}) do follows[#follows + 1] = keyGlyph(f) end
        return modGlyphs(spec.mods) .. keyGlyph(spec.key) .. " " .. table.concat(follows, " ")
    end,
}

-- AUTOMATED: a clock. Either a repeating interval or a daily wall-clock time.
TYPES.schedule = {
    automated = true,
    validate = function(spec)
        assert(spec.everyMin or spec.at, "schedule trigger needs everyMin or at")
        if spec.everyMin then
            assert(tonumber(spec.everyMin) and tonumber(spec.everyMin) > 0,
                "schedule everyMin must be a positive number")
        end
        if spec.at then
            assert(triggers.parseTimeOfDay(spec.at),
                "schedule at must be a valid HH:MM (00:00-23:59)")
        end
    end,
    encode = function(spec)
        if spec.everyMin then return "schedule|every|" .. tostring(spec.everyMin) end
        return "schedule|at|" .. tostring(spec.at)
    end,
    decode = function(str)
        local mode, val = str:match("^schedule|([^|]+)|(.*)$")
        if mode == "every" and tonumber(val) then
            return { type = "schedule", everyMin = tonumber(val) }
        elseif mode == "at" and triggers.parseTimeOfDay(val) then
            return { type = "schedule", at = val }
        end
        return nil
    end,
    bind = function(spec, action)
        if spec.everyMin then
            return adapter.everySeconds(spec.everyMin * 60, action)
        elseif spec.at then
            return adapter.dailyAt(spec.at, action)
        end
        error("schedule trigger needs everyMin or at")
    end,
    describe = function(spec)
        if spec.everyMin then
            return i18n.format("trigger.scheduleEvery", "schedule: every %d min", spec.everyMin)
        end
        return i18n.format("trigger.scheduleAt", "schedule: daily at %s", tostring(spec.at))
    end,
    glyph = function(spec)
        -- {n}/{v} tokens (not %s/%d) so the SAME catalog template serves both Lua
        -- here and Swift shortcutGlyph (Lua string.format=%s, Swift String(format:)=%@
        -- can't share one template). Function replacement guards a `%` in the value.
        if spec.everyMin then
            local n = tostring(spec.everyMin)
            return (i18n.t("glyph.every", "every {n}m"):gsub("{n}", function() return n end))
        end
        local at = tostring(spec.at)
        return (i18n.t("glyph.at", "at {v}"):gsub("{v}", function() return at end))
    end,
}

-- AUTOMATED: a system event (sleep/wake/lock/unlock/display change).
TYPES.event = {
    automated = true,
    validate = function(spec)
        assert(VALID_EVENTS[spec.event], "unknown event '" .. tostring(spec.event) .. "'")
    end,
    encode = function(spec) return "event|" .. spec.event end,
    decode = function(str)
        local ev = str:match("^event|(.+)$")
        if ev and VALID_EVENTS[ev] then return { type = "event", event = ev } end
        return nil
    end,
    bind = function(spec, action)
        return adapter.onSystemEvent(spec.event, action)
    end,
    describe = function(spec)
        return i18n.format("trigger.event", "event: %s", tostring(spec.event))
    end,
    glyph = function(spec)
        local ev = tostring(spec.event)
        return (i18n.t("glyph.on", "on {v}"):gsub("{v}", function() return ev end))
    end,
}

-- AUTOMATED, and RULES-ENGINE ONLY. A state trigger fires when a state signal
-- crosses a value: `becomes` (false->true) or `leaves` (true->false).
--
-- Deliberately has NO encode/decode: state triggers persist as JSON through the
-- rules engine, not through the scalar per-action codec.
--
-- It DOES carry a `bind`, but one that only raises. Every row supplies `bind`
-- (the dispatcher calls it unconditionally, and the guard requires it), so a
-- type bound elsewhere says WHERE in its own stub rather than falling through to
-- a generic "not bindable" message. Nothing reaches this in practice --
-- rules.lua:254 `bindOne` special-cases state before triggers.bind is consulted
-- -- so it is a defensive signpost, not a live path.
TYPES.state = {
    automated = true,
    validate = function(spec)
        -- The signal NAME is validated by the rules engine (it owns the signal
        -- registry); here we only enforce shape.
        assert(type(spec.signal) == "string" and #spec.signal > 0, "state trigger needs a signal")
        local hasBecomes, hasLeaves = spec.becomes ~= nil, spec.leaves ~= nil
        assert(hasBecomes ~= hasLeaves, "state trigger needs exactly one of becomes/leaves")
        -- The crossed VALUE must be a usable target, or the rule binds happily and
        -- then never fires (sig.match never matches "" or a number against any
        -- string-valued signal) -- a silent dead rule the UI gives no clue about.
        -- Every signal today is string-valued; widen this if a boolean/number
        -- signal is ever added (see bindOne's note on a future `becomes = false`).
        local target
        if hasBecomes then target = spec.becomes else target = spec.leaves end
        assert(type(target) == "string" and #target > 0,
            "state trigger value must be a non-empty string")
    end,
    bind = function()
        error("state triggers are bound by the rules engine, not triggers.bind")
    end,
    describe = function(spec)
        local enter = spec.becomes ~= nil
        local val
        if enter then val = spec.becomes else val = spec.leaves end
        return i18n.format("trigger.state", "state: %1$s %2$s %3$s", tostring(spec.signal),
            enter and i18n.t("trigger.becomes", "becomes") or i18n.t("trigger.leaves", "leaves"),
            tostring(val))
    end,
    glyph = function(spec)
        local val
        if spec.becomes ~= nil then val = spec.becomes else val = spec.leaves end
        return "→ " .. tostring(val)
    end,
}

-- The registry, exported so guards can enumerate it (the same idiom as
-- manifest.CAPABILITY_METHODS). Read-only by convention -- nothing mutates it.
triggers.TYPES = TYPES

-- ---------------------------------------------------------------------------
-- Dispatchers. Each states what an ABSENT row (unknown type) or an absent field
-- means -- those fallbacks are the contract, not an accident.
-- ---------------------------------------------------------------------------

-- Is this an AUTOMATED trigger -- one that fires on its own (a clock or a
-- system event) with no human present and no live UI context? The registry uses
-- this to keep context-dependent actions off automated triggers (see the action
-- `automatable` flag in manifest.lua). An unknown type is NOT automated: the
-- safe answer, since it gates whether an action may fire unattended.
---@param spec table a trigger spec
---@return boolean
function triggers.isAutomated(spec)
    local row = TYPES[spec.type]
    return row ~= nil and row.automated == true
end

-- Validate a trigger spec (used before persisting a user rebind). Throws on a
-- malformed spec; returns true on success.
function triggers.validate(spec)
    assert(type(spec) == "table", "trigger spec must be a table")
    local row = TYPES[spec.type]
    if not row then error("unknown trigger type '" .. tostring(spec.type) .. "'") end
    row.validate(spec)
    return true
end

-- Serialize a spec to a scalar string (the settings store holds bool/num/string
-- only -- no tables -- so a user's trigger override is stored encoded). Hotkey
-- mods are sorted so the encoding is canonical: alt+cmd == cmd+alt. A type with
-- no `encode` row is not scalar-encodable (today: `state`, which persists as
-- JSON through the rules engine).
function triggers.encode(spec)
    triggers.validate(spec)          -- also rejects an unknown type
    local row = TYPES[spec.type]
    if not row.encode then
        error("trigger type '" .. tostring(spec.type) .. "' is not encodable")
    end
    return row.encode(spec)
end

-- Inverse of encode. Returns a spec table, or nil if the string is malformed
-- (treated as "no override" -> fall back to the manifest default). Never throws:
-- a stored override is untrusted input, and a bad one must degrade to the
-- default rather than break the whole feature's load.
function triggers.decode(str)
    if type(str) ~= "string" then return nil end
    local kind = str:match("^([^|]+)|")
    if not kind then return nil end
    local row = TYPES[kind]
    if not row or not row.decode then return nil end
    return row.decode(str)
end

-- spec: trigger table; action: function to run when it fires. `label` (optional):
-- the action's human name; `icon` (optional): its SF Symbol name -- both used
-- only by chords, for the which-key hint (the icon is the same glyph the command
-- palette / menubar show for this action).
-- returns a handle with .stop()
function triggers.bind(spec, action, label, icon)
    assert(type(spec) == "table" and spec.type, "trigger spec needs a type")
    local row = TYPES[spec.type]
    if not row then error("unknown trigger type '" .. tostring(spec.type) .. "'") end
    -- Called unconditionally: `bind` is required on every row, and a type bound
    -- elsewhere supplies a stub that raises with its own reason (see TYPES.state).
    -- There is deliberately no generic "not bindable" fallback here -- it would be
    -- a second mechanism for the same thing, unreachable and therefore untested.
    return row.bind(spec, action, label, icon)
end

-- ---------------------------------------------------------------------------
-- Presentation: a spec -> human-readable string. Lives here (with the rest of
-- spec knowledge) rather than in the registry so the lifecycle core stays free
-- of view-layer formatting; the registry/UI just call these.
-- ---------------------------------------------------------------------------

-- A verbose, self-describing line for a spec (the Settings trigger column). An
-- unknown type degrades to its bare name rather than throwing -- this renders a
-- settings row, and a stored spec from a newer version must not blank the UI.
---@param spec table|nil a trigger spec, or nil for an unbound action
---@return string
function triggers.describe(spec)
    if not spec then return i18n.t("trigger.none", "no trigger") end
    local row = TYPES[spec.type]
    if not row then return tostring(spec.type) end
    return row.describe(spec)
end

-- Compact, menubar-style glyphs for a spec (e.g. "⇧⌘V", "every 180m") -- the
-- form the command palette shows in its right-flush shortcut column, where the
-- verbose describe() would just truncate. nil for an unknown type: the column
-- is optional chrome, so showing nothing beats showing a raw type name.
---@param spec table|nil a trigger spec
---@return string|nil glyph string, or nil for nil/unknown specs
function triggers.glyph(spec)
    if not spec then return nil end
    local row = TYPES[spec.type]
    if not row then return nil end
    return row.glyph(spec)
end

-- ---------------------------------------------------------------------------
-- Conflict detection (hotkey/chord only -- schedules and events may overlap).
-- ---------------------------------------------------------------------------

-- Canonical "mods|key" of a hotkey, or of a chord's PREFIX hotkey -- the
-- physical key combo that gets registered with the OS.
local function combo(spec)
    return sortedMods(spec) .. "|" .. tostring(spec.key)
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

return triggers
