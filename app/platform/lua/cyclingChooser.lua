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
-- release-to-pick -- window_switcher arms only while cycling; tab_switcher arms
-- on open too, gated on the modifier being held); this owns the poll-loop body
-- and the timer's lifecycle (stored in `state.altTimer`).

local M = {}

-- Arm release-to-pick: poll `mod` every 0.1s and, once it is no longer held,
-- stop the timer and select the current row. A no-op when there is no modifier
-- or a poll is already armed -- so a caller can arm unconditionally and let this
-- self-gate. The timer handle lives in `state.altTimer`; M.stop clears it.
---@param ctx table the scoped feature ctx
---@param chooser table a ctx.chooser handle
---@param state table the feature's state holder (uses state.altTimer)
---@param mod string|nil the modifier to watch, or nil to skip
function M.armRelease(ctx, chooser, state, mod)
    if not mod or state.altTimer then return end
    state.altTimer = ctx.everySeconds(0.1, function()
        if not ctx.isModifierHeld(mod) then
            M.stop(state)
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
