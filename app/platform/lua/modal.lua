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

    -- Bind one binding at a modifier set. `shadow` (for the sticky variant)
    -- makes it win over any global on the combo while the mode is live.
    local function bindAt(b, mods, shadow)
        if b.repeats then
            return adapter.bindHotkey(mods, b.key,
                function() pressRepeating(b) end,
                function() cancelRepeat(b) end, shadow)
        end
        return adapter.bindHotkey(mods, b.key, b.fn, nil, shadow)
    end

    -- `stickyMods`: the modifiers the leader held when the mode was entered (e.g.
    -- Hyper, injected by ctx.modal from the entering trigger). Each BARE key is
    -- ALSO bound under those modifiers, so the user can keep the leader held
    -- through the key (the Caps/Hyper motion) instead of releasing it first --
    -- and that sticky bind SHADOWS the global on the combo (e.g. a "Hyper+4 then
    -- 1" grid pick must beat a standalone "Hyper+1") for the mode's lifetime.
    local sticky = spec.stickyMods
    local hasSticky = type(sticky) == "table" and #sticky > 0
    -- The mode's own entry key (e.g. the "w" of a Hyper+w toggle) must NOT get a
    -- sticky twin: that twin would shadow the entry hotkey itself for the mode's
    -- lifetime, breaking a re-press of it (e.g. Window Mode's Hyper+w toggle-off).
    -- The entry hotkey stays reachable; only the OTHER bare keys twin.
    local exceptKey = type(spec.stickyExceptKey) == "string" and spec.stickyExceptKey:lower() or nil

    for _, b in ipairs(spec.bindings) do
        handles[#handles + 1] = bindAt(b, b.mods or {}, false)
        -- Only bare bindings get a sticky twin; one that already names its own
        -- modifiers is explicit and left alone, and the entry key is excluded.
        if hasSticky and (b.mods == nil or #b.mods == 0) and b.key:lower() ~= exceptKey then
            handles[#handles + 1] = bindAt(b, sticky, true)
        end
    end
    handles[#handles + 1] = adapter.bindHotkey({}, "escape", exit)
    if hasSticky then   -- leader-held Escape exits too
        handles[#handles + 1] = adapter.bindHotkey(sticky, "escape", exit, nil, true)
    end

    return {
        stop = exit,
        isActive = function() return active end,
        -- Re-render a structured HUD in place (no-op for a plain-banner mode).
        -- Lets a feature update the card mid-mode, e.g. window_grid highlighting
        -- the picked corner after the first keypress.
        updateHud = function(hud) if banner.update then banner.update(hud) end end,
    }
end

return modal
