-- platform/modal.lua
--
-- Modal hotkey groups: enter a named keyboard mode that binds a set of
-- (mostly bare) hotkeys system-wide until exited -- the donor's ModalMgr
-- concept. Built entirely on existing primitives: each mode binding is an
-- ordinary Carbon hotkey registered for the mode's lifetime, Escape always
-- exits, and a banner shows the mode is active. No new native surface.
--
-- While a mode is active its keys are swallowed system-wide (that is the
-- point); exit returns the keyboard to normal. ctx.modal() wraps this with
-- scope tracking, so disabling the owning feature tears the mode down.

local adapter = require("platform.adapter")

local modal = {}

-- Auto-repeat tuning (seconds): how long a key must be held before it starts
-- repeating, and the interval between repeats once it does. Matches the feel of
-- the OS key-repeat defaults closely enough for window nudging.
local REPEAT_DELAY    = 0.3
local REPEAT_INTERVAL = 0.04

-- Enter a mode immediately. spec:
--   name     = banner title
--   hint     = short key legend appended to the banner (optional)
--   hud      = structured cheat-sheet card (optional); when present it REPLACES
--              the plain banner -- see adapter.hud for the shape (a spatial
--              key map + grouped legend rows, e.g. Window Mode).
--   bindings = { { mods = {...}|nil, key = "a", fn = function() end,
--                  repeats = false }, ... }
--               repeats=true: hold the key to fire fn repeatedly (Carbon gives
--               us no native repeat, so we build it off press+release edges).
--               Only worthwhile for INCREMENTAL actions (nudge/resize); a key
--               that snaps to an absolute frame gains nothing from repeating.
--   onExit   = function() end (optional; fires once, however the mode ends)
-- Returns a handle: { stop() (= exit), isActive() }.
function modal.enter(spec)
    assert(type(spec) == "table" and type(spec.bindings) == "table",
        "modal.enter: spec.bindings required")
    local handles = {}
    local active = true
    -- Live auto-repeat timers, keyed by binding. These run on raw adapter
    -- primitives (not ctx-scoped), so exit() is their SOLE teardown owner: it
    -- cancels every entry below before stopping the hotkey handles. ctx.modal()
    -- scope-tracks this modal's handle, so a feature-disable routes through
    -- m.stop() -> exit() and nothing leaks. Cancelled on key-up or exit.
    local repeating = {}

    -- A feature can supply a structured `hud` (a spatial cheat-sheet card);
    -- otherwise fall back to the plain full-width banner built from name + hint.
    local banner = spec.hud
        and adapter.hud(spec.hud)
        or adapter.banner(
            (spec.name or "Mode") .. (spec.hint and ("  --  " .. spec.hint) or "")
            .. "  (Esc exits)")

    local function cancelRepeat(b)
        local r = repeating[b]
        if not r then return end
        repeating[b] = nil
        if r.delay then pcall(r.delay.stop) end
        if r.tick  then pcall(r.tick.stop)  end
    end

    local function exit()
        if not active then return end
        active = false
        for b in pairs(repeating) do cancelRepeat(b) end
        for _, h in ipairs(handles) do pcall(h.stop) end
        banner.stop()
        if spec.onExit then pcall(spec.onExit) end
    end

    -- Press handler for a repeating binding: fire once now, then after the hold
    -- delay start a steady tick, all torn down when the key is released.
    local function pressRepeating(b)
        b.fn()
        cancelRepeat(b)                      -- defensive: drop any stale timers
        local r = {}
        repeating[b] = r
        r.delay = adapter.afterSeconds(REPEAT_DELAY, function()
            if not active or repeating[b] ~= r then return end
            r.tick = adapter.everySeconds(REPEAT_INTERVAL, function()
                if active then b.fn() end
            end)
        end)
    end

    for _, b in ipairs(spec.bindings) do
        if b.repeats then
            handles[#handles + 1] = adapter.bindHotkey(b.mods or {}, b.key,
                function() pressRepeating(b) end,
                function() cancelRepeat(b) end)
        else
            handles[#handles + 1] = adapter.bindHotkey(b.mods or {}, b.key, b.fn)
        end
    end
    handles[#handles + 1] = adapter.bindHotkey({}, "escape", exit)

    return {
        stop = exit,
        isActive = function() return active end,
    }
end

return modal
