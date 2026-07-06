-- platform/window_ops.lua
--
-- Live FOCUSED-window operations that reach the adapter directly -- the stateful
-- core peer that ctx.window delegates to (NOT a leaf util; it `require`s the
-- adapter). Today it owns one policy: "Pointer Follows Moved Window".
--
-- "Pointer Follows Moved Window" (the pointer_follows_window feature): when its
-- toggle is on, repositioning the FOCUSED window carries the pointer along,
-- preserving its RELATIVE position inside the window (it was 30% from the left
-- edge -> still 30% from the left edge after the move). Implemented here, at the
-- single focused-window-move seam (ctx.window.setFrame), so every feature that
-- moves the FOCUSED window (window_snap, Window Mode, window_to_next_screen, ...)
-- gets it for free with no per-feature code.
--
-- SCOPE: the FOCUSED-window seam only. The rules engine moves windows BY ID via
-- adapter.setWindowFrame (effects.lua, layout / move-to-display) on a separate
-- path that intentionally bypasses pointer-follow -- carrying the pointer would be
-- wrong for a batch layout -- so those do NOT route through here.
--
-- The "is pointer-follow on?" predicate is INJECTED via configure() by the
-- composition root (registry), which owns enabled-state. This keeps window_ops
-- feature-agnostic and resolves the old ctx -> registry -> ctx require-cycle
-- workaround at the root: window_ops never names the pointer_follows_window
-- feature (no stringly-typed enabled-key read) -- the registry does.

local adapter = require("platform.adapter")
local history = require("platform.window_history")   -- CORE peer; records before-frames

local M = {}

-- Whether to carry the pointer with a focused-window move. The registry installs
-- the real predicate from configure() at ITS module-load -- which both the app
-- boot (hammerdeck.lua requires registry) and the test harness (test/run.lua
-- requires registry) trigger before any ctx is built, since a ctx is only ever
-- created via ctxlib.make, called only by the registry. So in practice this is
-- always wired first. The OFF default is the safety net for a hypothetical load
-- that builds a ctx WITHOUT requiring registry: it degrades to a plain setFrame
-- (no wrong pointer yank), never an error -- but pointer-follow would silently be
-- off, and the through-registry T24b test would not catch it. If you ever add
-- such a path, call window_ops.configure() explicitly there.
local pointerFollowEnabled = function() return false end

--- Composition-root wiring. Called once at boot by the registry.
---@param opts {pointerFollowEnabled: fun(): boolean} predicate for the live
---            pointer_follows_window enabled-state.
function M.configure(opts)
    if opts and opts.pointerFollowEnabled then
        pointerFollowEnabled = opts.pointerFollowEnabled
    end
end

--- Move the focused window to frame `f`. When pointer-follow is on AND the
--- pointer was inside the window being moved, carry it to the same relative spot.
---@param f {x:number,y:number,w:number,h:number}
---@return boolean ok
function M.setFrame(f)
    history.recordFocused()   -- snapshot the focused window's before-frame for undo
    if pointerFollowEnabled() ~= true then
        return adapter.setFocusedWindowFrame(f)
    end
    local old = adapter.focusedWindowFrame()
    local mp  = adapter.mousePosition()
    local ok  = adapter.setFocusedWindowFrame(f)
    -- Carry the pointer only when it was actually inside the window being moved
    -- (never yank a pointer parked elsewhere); guard degenerate / missing sizes.
    if ok and old and mp and old.w and old.h and old.w > 0 and old.h > 0
        and mp.x >= old.x and mp.x <= old.x + old.w
        and mp.y >= old.y and mp.y <= old.y + old.h then
        local rx = (mp.x - old.x) / old.w
        local ry = (mp.y - old.y) / old.h
        adapter.setMousePosition(f.x + rx * f.w, f.y + ry * f.h)
    end
    return ok
end

-- List windows, feeding the snapshot to window_history so a following setFrameFor
-- batch can resolve each moved window's before-frame WITHOUT a second list() (which
-- would invalidate the caller's ids). Rows returned unchanged.
---@return { id:integer, wid:integer?, x:number, y:number, w:number, h:number }[]
function M.list()
    local rows = adapter.listWindows()
    history.noteList(rows)
    return rows
end

--- Place a SPECIFIC listed window by id (batch layout). Records the before-frame
--- for undo, then writes WITHOUT pointer-follow -- a multi-window layout must never
--- yank the cursor to chase one of its members (same rule the rules engine follows).
---@param id integer
---@param f {x:number,y:number,w:number,h:number}
---@return boolean ok
function M.setFrameFor(id, f)
    history.recordById(id)
    return adapter.setWindowFrame(id, f)
end

--- Restore the most-recent window layout change (single-step). Returns the count
--- of windows moved back.
---@return integer restored
function M.undoLast() return history.undoLast() end

--- Turn window-layout history recording on/off (window_rewind toggles this).
---@param on boolean
function M.setHistoryEnabled(on) history.setEnabled(on) end

return M
