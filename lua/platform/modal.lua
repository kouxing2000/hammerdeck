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

-- Enter a mode immediately. spec:
--   name     = banner title
--   hint     = short key legend appended to the banner (optional)
--   bindings = { { mods = {...}|nil, key = "a", fn = function() end }, ... }
--   onExit   = function() end (optional; fires once, however the mode ends)
-- Returns a handle: { stop() (= exit), isActive() }.
function modal.enter(spec)
    assert(type(spec) == "table" and type(spec.bindings) == "table",
        "modal.enter: spec.bindings required")
    local handles = {}
    local active = true

    local banner = adapter.banner(
        (spec.name or "Mode") .. (spec.hint and ("  --  " .. spec.hint) or "")
        .. "  (Esc exits)")

    local function exit()
        if not active then return end
        active = false
        for _, h in ipairs(handles) do pcall(h.stop) end
        banner.stop()
        if spec.onExit then pcall(spec.onExit) end
    end

    for _, b in ipairs(spec.bindings) do
        handles[#handles + 1] = adapter.bindHotkey(b.mods or {}, b.key, b.fn)
    end
    handles[#handles + 1] = adapter.bindHotkey({}, "escape", exit)

    return {
        stop = exit,
        isActive = function() return active end,
    }
end

return modal
