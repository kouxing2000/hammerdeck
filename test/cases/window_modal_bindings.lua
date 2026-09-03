-- test/cases/window_modal_bindings.lua -- every Window Mode key, pressed once.
--
-- Why this case exists (audit 2026-09-02, finding F9). The narrative case
-- (window_modal.lua) walks a realistic session and proves the mode's LIFECYCLE --
-- enter, HUD, exit, toggle, undo/redo. Coverage showed the cost of that shape: 17
-- of the mode's bindings were never pressed by any test. A modal layer is a table
-- of key -> closure, and the failure mode of a table is an entry that is wrong in
-- a way nothing reads -- two keys wired to the same closure, a ratio transposed
-- (h/l, k/j), a sign flipped on a nudge. None of that shows up anywhere except
-- under the finger of whoever presses that key.
--
-- So this case is deliberately the OTHER shape: a flat sweep, one press per
-- binding, each against a freshly-placed window so the expectation is absolute
-- rather than a function of everything pressed before it. The two cases are
-- complementary and neither subsumes the other.
--
-- World: screen 1 is 1000x800 at the origin, screen 2 is 2000x1200 to its right,
-- and stepParts=10 makes the nudge/resize step exactly 100 x 80 on screen 1 --
-- the same setup the narrative case uses, so the two read as one world.
local START = { x = 200, y = 200, w = 400, h = 300, screenIndex = 1 }

---Put the window back at START so each binding is measured from one place.
---@param fake table
local function replace(fake)
    fake.focusedWindow = { x = START.x, y = START.y, w = START.w, h = START.h, screenIndex = 1 }
end

---The frame the press just recorded, or a hard failure naming the binding.
---A key wired to nothing records NO frame, and `lastFrame()` would then hand
---back either nil or -- worse -- the frame the PREVIOUS key left behind, which
---is a false pass. Failing here also narrows the optional away for frameEq.
---@param t Harness
---@param what string
---@return {x:number,y:number,w:number,h:number}
local function recorded(t, what)
    local f = t.lastFrame()
    if not f then error("FAIL: " .. what .. " -- the key recorded no frame at all", 2) end
    return f
end

return {
    id = "window_modal_bindings",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        registry.register(require("features.window_modal"))
        registry.setEnabled("window_modal", true)
        fake.settings["hammerdeck.opt.window_modal.stepParts"] = 10   -- step = 100 x 80
        fake.screenList = {
            { x = 0, y = 0, w = 1000, h = 800 },
            { x = 1000, y = 0, w = 2000, h = 1200 },
        }
        replace(fake)
        fake.pressHotkey("w", { "cmd", "alt", "ctrl" })
        ok(fake.liveHud() ~= nil, "the mode is live for the sweep")

        -- ABSOLUTE placements: a ratio rectangle of the window's own screen.
        -- Listed as data so a transposed pair (h vs l, k vs j) is visible HERE,
        -- next to the numbers, instead of being buried in a closure.
        local placements = {
            { key = "h", x = 0,   y = 0,   w = 500,  h = 800, what = "H fills the left half" },
            { key = "l", x = 500, y = 0,   w = 500,  h = 800, what = "L fills the right half" },
            { key = "k", x = 0,   y = 0,   w = 1000, h = 400, what = "K fills the top half" },
            { key = "j", x = 0,   y = 400, w = 1000, h = 400, what = "J fills the bottom half" },
            { key = "y", x = 0,   y = 0,   w = 500,  h = 400, what = "Y takes the top-left quadrant" },
            { key = "o", x = 500, y = 0,   w = 500,  h = 400, what = "O takes the top-right quadrant" },
            { key = "u", x = 0,   y = 400, w = 500,  h = 400, what = "U takes the bottom-left quadrant" },
            { key = "i", x = 500, y = 400, w = 500,  h = 400, what = "I takes the bottom-right quadrant" },
            { key = "f", x = 0,   y = 0,   w = 1000, h = 800, what = "F fills the screen" },
        }
        for _, p in ipairs(placements) do
            replace(fake)
            fake.pressHotkey(p.key, {})
            t.frameEq(recorded(t, p.what), p.x, p.y, p.w, p.h, p.what)
        end

        -- INCREMENTAL nudges: one step, in the named direction, size unchanged.
        local nudges = {
            { key = "a", x = 100, y = 200, what = "A nudges left one step" },
            { key = "d", x = 300, y = 200, what = "D nudges right one step" },
            { key = "w", x = 200, y = 120, what = "W nudges up one step" },
            { key = "s", x = 200, y = 280, what = "S nudges down one step" },
        }
        for _, n in ipairs(nudges) do
            replace(fake)
            fake.pressHotkey(n.key, {})
            t.frameEq(recorded(t, n.what), n.x, n.y, START.w, START.h, n.what)
        end

        -- RESIZE (shift): the origin is pinned, only the extent moves.
        local resizes = {
            { key = "h", w = 300, h = 300, what = "shift+H narrows by a step" },
            { key = "l", w = 500, h = 300, what = "shift+L widens by a step" },
            { key = "k", w = 400, h = 220, what = "shift+K shortens by a step" },
            { key = "j", w = 400, h = 380, what = "shift+J lengthens by a step" },
        }
        for _, r in ipairs(resizes) do
            replace(fake)
            fake.pressHotkey(r.key, { "shift" })
            t.frameEq(recorded(t, r.what), START.x, START.y, r.w, r.h, r.what)
        end

        -- INFLATE: one step on every side, so the CENTER is what stays fixed.
        replace(fake)
        fake.pressHotkey("=", {})
        t.frameEq(recorded(t, "="), 100, 120, 600, 460, "= grows one step on all four sides")
        replace(fake)
        fake.pressHotkey("-", {})
        t.frameEq(recorded(t, "-"), 300, 280, 200, 140, "- shrinks one step on all four sides")

        -- SCREEN MOVES. The rule is "nearest screen whose CENTER lies that way",
        -- not strict edge adjacency, and the difference is load-bearing here:
        -- screen 2 is 1200 tall against screen 1's 800, so its center sits BELOW
        -- screen 1's as well as to the right -- which makes `down` find it, and
        -- leaves only `left` and `up` with no target at all. That is worth
        -- pinning: someone "simplifying" this to edge adjacency would change
        -- which key reaches a taller neighbour, and nothing else would notice.
        for _, dir in ipairs({ "left", "up" }) do
            replace(fake)
            local framesBefore = #fake.windowFrames
            local alertsBefore = #fake.alerts
            fake.pressHotkey(dir, {})
            ok(#fake.windowFrames == framesBefore,
                dir .. " with no screen that way moves no window")
            ok(#fake.alerts == alertsBefore + 1,
                dir .. " with no screen that way says so, rather than failing silently")
        end

        for _, dir in ipairs({ "right", "down" }) do
            replace(fake)
            fake.pressHotkey(dir, {})
            ok(recorded(t, dir).x >= 1000,
                dir .. " reaches screen 2, whose center lies both right of and below screen 1")
        end
        replace(fake)
        fake.pressHotkey("space", {})
        ok(recorded(t, "space").x >= 1000, "space cycles to the next screen in physical order")

        fake.pressHotkey("escape", {})
        ok(fake.liveHud() == nil, "escape leaves the mode after the sweep")
        registry.setEnabled("window_modal", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
            "clean after the binding sweep")
    end,
}
