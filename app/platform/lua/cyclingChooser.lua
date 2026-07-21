-- platform/cyclingChooser.lua
--
-- Shared mechanics for an alt-tab-style cycling chooser: release-to-pick
-- (poll a held modifier; pick the current row when it is let go).
-- window_switcher and tab_switcher both drive a ctx.chooser this way;
-- centralizing the fiddly part keeps a missed timer-stop from drifting
-- between the two copies. Row STEPPING is deliberately NOT here: a forward
-- cycle is a plain chooser.step(1) at the call site, backward is the panel's
-- own shift+tab / option+arrow keys, and the wrap math lives ONCE in the
-- panel (moveSelection, over the visible rows) -- every path shares it, so
-- the hotkey cycle and the in-panel keys cannot disagree.
--
-- LEAF UTIL (the layer map's leaf tier): ZERO `require`. The ctx, the chooser
-- handle, and the feature's own state table are passed in -- the same contract
-- platform.windows uses. Each feature keeps its own ARM POLICY (WHEN to start
-- release-to-pick -- both switchers arm on open when the trigger modifier is
-- still held, and on every cycle step); this owns the poll-loop body
-- and the timer's lifecycle (stored in `state.altTimer`).

local M = {}

-- Arm release-to-pick: poll `mod` every 0.1s and, once it is no longer held,
-- stop the timer and select the current row. A no-op when there is no modifier
-- or a poll is already armed -- so a caller can arm unconditionally and let this
-- self-gate. The timer handle lives in `state.altTimer`; M.stop clears it.
--
-- TYPING DISARMS: a non-empty search query means the user is filtering, so
-- releasing the modifier to reach the keyboard must NOT commit a pick -- the
-- poll checks the query BEFORE the modifier, so even "type then release inside
-- one tick" disarms rather than picks. (The panel accepts ctrl/alt-modified
-- printable keys as search text precisely so the first character can land
-- WHILE the modifier is still held.) Enter / a click then picks as usual.
--
-- TAP GRACE: `state.releaseGrace` (set by the caller BEFORE arming; nil = 0)
-- is how many initial poll ticks a release counts as a quick TAP rather than
-- a flick: released inside the grace -> quietly disarm and leave the panel
-- open (filter/browse mode); released after it -> pick. Arm-on-open passes 3
-- (~300ms -- a tap is released well inside, a deliberate see-panel-then-
-- release flick lands well after); an explicit CYCLE step sets it back to 0,
-- because stepping already expressed intent and release must commit at once.
---@param ctx table the scoped feature ctx
---@param chooser table a ctx.chooser handle
---@param state table the feature's state holder (uses state.altTimer / state.releaseGrace)
---@param mod string|nil the modifier to watch, or nil to skip
function M.armRelease(ctx, chooser, state, mod)
    if not mod or state.altTimer then return end
    local ticks = 0
    state.altTimer = ctx.everySeconds(0.1, function()
        ticks = ticks + 1
        if (chooser.getQuery() or "") ~= "" then M.stop(state); return end
        if not ctx.isModifierHeld(mod) then
            M.stop(state)
            if ticks <= (state.releaseGrace or 0) then return end   -- tap: stay open
            chooser.select(chooser.getSelectedRow())
        end
    end)
end

-- Stop and clear the release-to-pick timer (idempotent). Call from onHide /
-- onSelect and after a pick.
---@param state table the feature's state holder (uses state.altTimer)
function M.stop(state)
    if state.altTimer then state.altTimer.stop(); state.altTimer = nil end
end

return M
