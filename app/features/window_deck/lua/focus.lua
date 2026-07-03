-- features/window_deck/focus.lua
--
-- PURE decision core for reconcile. Given the deck's mode and the focus event
-- (already resolved to plain booleans by the effectful shell), classify what the
-- deck should DO. No side effects, no require -- so the whole decision table is
-- unit-testable directly and the outcomes are NAMED instead of living implicitly
-- in the order of reconcile's early-returns.
--
-- SCOPE: this runs AFTER the shell has (a) short-circuited settling echoes -- an
-- echo must skip presence bookkeeping too, so it can't be just another row here
-- -- and (b) done presence bookkeeping (resolveIds + gone flags + dropping a
-- vanished hero). So `isHero` / `listed` already reflect that post-bookkeeping
-- truth. The shell then applies the returned outcome.
--
-- Outcomes (the order of the checks IS the precedence):
--   "peek"      -- no deck window is focused (a non-deck window took front):
--                  stay, hide chrome, sink it at the next beat.
--   "return"    -- the CURRENT hero regained front: re-show chrome, raise nothing
--                  (the user's own click already fronted it; a raise would blink).
--   "ignore"    -- a deck window is focused but not yet in our list (a race): wait.
--   "gridFocus" -- Hero-off mode: a deck window focused, but we don't zoom -- stay flat.
--   "promote"   -- a non-hero deck window focused in Hero mode: play the promote beat.

local M = {}

---@class DeckFocusEvent
---@field hasMember boolean  a deck window is the focused window
---@field isHero boolean     the focused window is the current hero
---@field listed boolean     the focused window appears in the fresh window list
---@field heroMode boolean   Hero (zoom-on-focus) mode is on

---@param e DeckFocusEvent
---@return "peek"|"return"|"ignore"|"gridFocus"|"promote"
function M.classify(e)
    if not e.hasMember then return "peek" end
    if e.isHero then return "return" end
    if not e.listed then return "ignore" end
    if not e.heroMode then return "gridFocus" end
    return "promote"
end

return M
