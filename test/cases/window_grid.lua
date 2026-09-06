-- test/cases/window_grid.lua -- window_grid: Hyper+N shows a numbered grid HUD (oriented
-- to the screen's aspect); the first cell press places that cell AND arms the mode, a
-- second down-right cell fills the rectangle (place-and-extend, directional "no turn
-- back"), same-cell commits, and the arm window lapsing auto-dismisses. Covers the entry
-- grids (3x3/2x2/6-oriented), the sticky-modifier shadow (Hyper held through the digit
-- shadows a standalone Hyper+combo for the mode's life), re-pick handle hygiene, HUD state
-- tags + previews, and mid-grid disable teardown.
--
-- Migrated from run.lua T25e (entry) + T25e2 (two-corner placement) (RUN_LUA_SPLIT_SPEC
-- Phase 2). One feature, two blocks: T25e2 leaned on T25e's registration (both run
-- window_grid enabled), so the case registers + enables it once up top and the disable +
-- clean assertion lives at the end. freshWorld() + handle tripwire keep it isolated.

return {
    id = "window_grid",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry
        local HYP = { "cmd", "alt", "ctrl" }

        registry.register(require("features.window_grid"))
        registry.setEnabled("window_grid", true)

        -- ===== T25e: ENTRY -- Hyper+N shows the numbered grid; the FIRST cell press
        -- places that single cell immediately AND arms the mode (no longer single-shot).
        do
            fake.screenList = { { x = 0, y = 0, w = 1200, h = 900 } }
            fake.focusedWindow = { x = 0, y = 0, w = 100, h = 100, screenIndex = 1 }
            local gf

            -- 3x3: Hyper+9 shows the numbered HUD; the first digit (2) lands the window
            -- top-middle (cell 2 = row0,col1 -> 400,0,400x300) IMMEDIATELY and ARMS.
            fake.pressHotkey("9", HYP)
            ok(fake.liveHud() ~= nil and fake.liveHud().title == "3×3 Grid",
                "Hyper+9 shows the 3x3 grid HUD")
            fake.pressHotkey("2", {})
            gf = fake.windowFrames[#fake.windowFrames]
            ok(gf.x == 400 and gf.y == 0 and gf.w == 400 and gf.h == 300,
                "3x3 first press: cell 2 places top-middle (col1,row0) at once")
            ok(fake.liveHud() ~= nil, "the first press ARMS -- the mode stays open (not single-shot)")
            fake.pressHotkey("escape", {})
            ok(fake.liveHud() == nil, "escape exits the armed grid")

            -- W-6: a FULLSCREEN window. AX refuses a frame write to one, so placing
            -- was a silent no-op that still ARMED the mode -- the HUD then highlighted
            -- a cell the window had never gone to. placeSpan now takes it out of
            -- fullscreen and reports "not placed", which closes the mode; the next
            -- press arranges normally (window_modal's prologue does the same).
            do
                fake.focusedWindow = { x = 0, y = 0, w = 1200, h = 900,
                                       screenIndex = 1, fullscreen = true }
                local before = #fake.windowFrames
                fake.pressHotkey("9", HYP)
                fake.pressHotkey("2", {})
                ok(fake.fullscreenSets[#fake.fullscreenSets] == false,
                    "a grid press on a fullscreen window exits fullscreen (W-6)")
                ok(#fake.windowFrames == before,
                    "...places nothing while it is still fullscreen")
                ok(fake.liveHud() == nil,
                    "...and closes the mode rather than arming a cell it never used")
                fake.focusedWindow = { x = 0, y = 0, w = 100, h = 100, screenIndex = 1 }
            end

            -- 2x2: Hyper+4 -> first digit 3 lands bottom-left (cell 3 = row1,col0 -> 0,450,600x450).
            fake.pressHotkey("4", HYP)
            ok(fake.liveHud() ~= nil and fake.liveHud().title == "2×2 Grid",
                "Hyper+4 shows the 2x2 grid HUD")
            fake.pressHotkey("3", {})
            gf = fake.windowFrames[#fake.windowFrames]
            ok(gf.x == 0 and gf.y == 450 and gf.w == 600 and gf.h == 450,
                "2x2 first press: cell 3 places bottom-left (col0,row1)")
            fake.pressHotkey("escape", {})

            -- 6-cell grid, ORIENTED to the screen. Landscape (1200x900, w>h) -> 3x2:
            -- Hyper+6 shows a "3×2 Grid" HUD; cell 5 lands middle-bottom (400,450,400x450).
            fake.pressHotkey("6", HYP)
            ok(fake.liveHud() ~= nil and fake.liveHud().title == "3×2 Grid",
                "Hyper+6 on a landscape screen shows a 3×2 grid HUD")
            fake.pressHotkey("5", {})
            gf = fake.windowFrames[#fake.windowFrames]
            ok(gf.x == 400 and gf.y == 450 and gf.w == 400 and gf.h == 450,
                "6-grid cell 5 -> middle-bottom of a 3x2 (col1,row1)")
            fake.pressHotkey("escape", {})

            -- SAME action, PORTRAIT screen (900x1200, h>w) -> 2x3: the shape follows the
            -- aspect, not a fixed square. Cell 5 lands bottom-left (col0,row2 -> 0,800,450x400).
            fake.screenList = { { x = 0, y = 0, w = 900, h = 1200 } }
            fake.focusedWindow = { x = 0, y = 0, w = 100, h = 100, screenIndex = 1 }
            fake.pressHotkey("6", HYP)
            ok(fake.liveHud() ~= nil and fake.liveHud().title == "2×3 Grid",
                "Hyper+6 on a portrait screen shows a 2×3 grid HUD (oriented)")
            fake.pressHotkey("5", {})
            gf = fake.windowFrames[#fake.windowFrames]
            ok(gf.x == 0 and gf.y == 800 and gf.w == 450 and gf.h == 400,
                "6-grid cell 5 -> bottom-left of a 2x3 (col0,row2)")
            fake.pressHotkey("escape", {})
            fake.screenList = { { x = 0, y = 0, w = 1200, h = 900 } }   -- restore landscape for the rest
            fake.focusedWindow = { x = 0, y = 0, w = 100, h = 100, screenIndex = 1 }

            -- STICKY MODIFIER + SHADOW: the leader (Hyper) held THROUGH the cell digit
            -- still fires it -- the user need not release Caps between Hyper+4 and the
            -- number. ctx.modal binds each bare cell key ALSO under the entering trigger's
            -- mods (Hyper), and that sticky twin SHADOWS any standalone on the combo for
            -- the mode's life -- the exact "leaked to a global Hyper+1 (window_deck)" bug.
            -- A stand-in global Hyper+1 proves it: silent while the grid is live, fires
            -- again after exit. (Under place-and-extend the first sticky press ARMS.)
            local stickyGlobalFires = 0
            local stickyGlobal = fake.adapter.bindHotkey(HYP, "1", function() stickyGlobalFires = stickyGlobalFires + 1 end)
            fake.pressHotkey("4", HYP)
            ok(fake.liveHud() ~= nil, "re-enter 2x2 for the sticky-modifier check")
            fake.pressHotkey("1", HYP)   -- Hyper still held through the cell key
            gf = fake.windowFrames[#fake.windowFrames]
            ok(gf.x == 0 and gf.y == 0 and gf.w == 600 and gf.h == 450,
                "2x2 cell 1 fires (arms) with the leader (Hyper) held through the digit")
            ok(stickyGlobalFires == 0, "the standalone Hyper+1 is shadowed while the grid is live")
            ok(fake.liveHud() ~= nil, "the sticky first press ARMS -- the grid stays open")
            fake.pressHotkey("escape", {})
            ok(fake.liveHud() == nil, "escape exits the armed grid")
            fake.pressHotkey("1", HYP)
            ok(stickyGlobalFires == 1, "the shadowed Hyper+1 fires again once the grid exits")
            stickyGlobal.stop()

            -- esc cancels with no placement.
            local nBefore = #fake.windowFrames
            fake.pressHotkey("9", HYP)
            ok(fake.liveHud() ~= nil, "re-enter shows the HUD again")
            fake.pressHotkey("escape", {})
            ok(fake.liveHud() == nil and #fake.windowFrames == nBefore,
                "esc cancels the grid without placing")

            -- no focused window -> alert, never an empty grid.
            fake.focusedWindow = nil
            fake.pressHotkey("9", HYP)
            ok(fake.liveHud() == nil, "no focused window -> no grid shown")
            fake.focusedWindow = { x = 0, y = 0, w = 100, h = 100, screenIndex = 1 }
        end

        -- ===== T25e2: TWO-CORNER placement (place-and-extend, directional). First
        -- cell = top-left corner-A; a second cell DOWN-RIGHT of it fills the rectangle.
        do
            fake.screenList = { { x = 0, y = 0, w = 1200, h = 900 } }
            fake.focusedWindow = { x = 0, y = 0, w = 100, h = 100, screenIndex = 1 }
            local gf

            -- PLACE-AND-EXTEND: on the 3x2 (Hyper+6, cw=400 ch=450), press corner-A
            -- (cell 1 = top-left) then a down-right cell (5) -> the window fills the 2x2
            -- span = left 2/3, full height (0,0,800,900), and the mode commits.
            fake.pressHotkey("6", HYP)
            fake.pressHotkey("1", {})
            ok(fake.liveHud() ~= nil, "first corner arms; the mode stays open")
            gf = fake.windowFrames[#fake.windowFrames]
            ok(gf.x == 0 and gf.y == 0 and gf.w == 400 and gf.h == 450,
                "corner-A (cell 1) is placed as a single cell immediately")
            fake.pressHotkey("5", {})   -- down-right of 1 -> extend
            gf = fake.windowFrames[#fake.windowFrames]
            ok(gf.x == 0 and gf.y == 0 and gf.w == 800 and gf.h == 900,
                "extend 1->5 fills the 2x2 span (left 2/3, full height)")
            ok(fake.liveHud() == nil, "a valid extension commits and exits")

            -- DIRECTIONAL "no turn back": on a 3x3 (cw=400 ch=300), cell 3 (top-right)
            -- then cell 4 (middle-left) is NOT a valid down-right corner -> it RE-PICKS:
            -- cell 4 becomes a fresh single placement (0,300,400x300), never a 3->4 span.
            fake.pressHotkey("9", HYP)
            fake.pressHotkey("3", {})   -- arm corner-A = cell 3 (col2,row0)
            local armedHandles = registry.liveHandleCount()   -- baseline: modal + one idle timer
            local nBeforeRepick = #fake.windowFrames
            local logsBeforeRepick = #fake.logs
            fake.pressHotkey("4", {})   -- backward -> re-pick
            gf = fake.windowFrames[#fake.windowFrames]
            ok(gf.x == 0 and gf.y == 300 and gf.w == 400 and gf.h == 300,
                "backward press 3->4 re-picks cell 4 as a single placement")
            ok(fake.liveHud() ~= nil, "re-pick keeps the mode armed on the new corner")
            ok(#fake.windowFrames == nBeforeRepick + 1, "re-pick places one cell, not a span")
            -- re-pick must STOP the old idle timer before re-arming: the live scoped-handle
            -- count is unchanged (a leak would push it to baseline+1).
            ok(registry.liveHandleCount() == armedHandles,
                "re-pick stops the old idle timer before re-arming -- no leaked handle")
            local sawRepick = false
            for i = logsBeforeRepick + 1, #fake.logs do
                if fake.logs[i]:find("re%-pick") then sawRepick = true end
            end
            ok(sawRepick, "the re-pick is logged")
            -- the timer was re-armed on the NEW corner: firing it dismisses cleanly (proves
            -- it is the fresh timer, not a stale one left running on the old corner).
            fake.fireTimers("after", 2.5)
            ok(fake.liveHud() == nil, "the re-armed idle timer dismisses on the new corner")

            -- SAME-CELL commit: pressing corner-A again (B == A, trivially down-right)
            -- commits that single cell and exits -- a natural "done".
            fake.pressHotkey("9", HYP)
            fake.pressHotkey("5", {})   -- arm center (col1,row1 -> 400,300,400x300)
            ok(fake.liveHud() ~= nil, "single press arms")
            fake.pressHotkey("5", {})
            gf = fake.windowFrames[#fake.windowFrames]
            ok(gf.x == 400 and gf.y == 300 and gf.w == 400 and gf.h == 300,
                "same-cell 5->5 commits the single center cell")
            ok(fake.liveHud() == nil, "same-cell press commits and exits")

            -- SINGLE-CELL auto-dismiss: press one cell, then let the arm window (ARM_IDLE
            -- = 2.5s) lapse -> the single placement stands, no extra frame, mode dismisses.
            fake.pressHotkey("9", HYP)
            fake.pressHotkey("1", {})
            ok(fake.liveHud() ~= nil, "armed after the single press")
            local nBeforeTimeout = #fake.windowFrames
            local logsBeforeTimeout = #fake.logs
            fake.fireTimers("after", 2.5)
            ok(fake.liveHud() == nil, "the arm window lapsing dismisses the mode")
            ok(#fake.windowFrames == nBeforeTimeout, "timeout adds no frame (the cell was already placed)")
            local sawTimeout = false
            for i = logsBeforeTimeout + 1, #fake.logs do
                if fake.logs[i]:find("timeout%-dismiss") then sawTimeout = true end
            end
            ok(sawTimeout, "the timeout-dismiss is logged")

            -- HUD STATE TAGS: after the first press on a 3x3, corner-A is "corner", cells
            -- down-right are "valid", up/left are "dim", and the caption switches to the
            -- extend prompt -- proving the live updateHud seam end-to-end (modal -> hud).
            fake.pressHotkey("9", HYP)
            fake.pressHotkey("5", {})    -- corner-A = center (col1,row1)
            local hud = fake.liveHud()
            ok(hud ~= nil, "armed HUD is live")
            local stateAt, previewAt = {}, {}
            for _, c in ipairs(hud.spec.cells) do
                stateAt[c.col .. "," .. c.row] = c.state
                previewAt[c.col .. "," .. c.row] = c.preview
            end
            ok(stateAt["1,1"] == "corner", "corner-A cell is tagged 'corner'")
            ok(stateAt["2,2"] == "valid", "a down-right cell is tagged 'valid'")
            ok(stateAt["0,0"] == "dim", "an up-left cell is tagged 'dim'")
            ok(hud.spec.caption == "press a cell down-right to extend",
                "the caption switches to the extend prompt")
            -- each valid cell carries the window-size preview (fractions of the grid):
            -- corner-A = cell 5 (col1,row1), so 5->9 = the bottom-right 2/3 x 2/3 block.
            local p9 = previewAt["2,2"]
            ok(p9 ~= nil and math.abs(p9.x - 1 / 3) < 1e-9 and math.abs(p9.y - 1 / 3) < 1e-9
                and math.abs(p9.w - 2 / 3) < 1e-9 and math.abs(p9.h - 2 / 3) < 1e-9,
                "a valid cell carries the window-size preview (5->9 = bottom-right 2/3)")
            ok(previewAt["0,0"] == nil, "a dim cell carries no preview")
            fake.pressHotkey("escape", {})

            -- disabling mid-grid while ARMED (a live idle timer) tears the HUD + digit
            -- bindings + the afterSeconds timer down with no leak.
            fake.pressHotkey("9", HYP)
            fake.pressHotkey("5", {})   -- arm -> a live afterSeconds idle timer
            ok(fake.liveHud() ~= nil, "grid HUD is up (armed) before the disable")
            registry.setEnabled("window_grid", false)
            ok(fake.liveHud() == nil, "disable mid-grid drops the HUD")
            ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
                "clean after window_grid test (armed idle timer torn down)")
        end
    end,
}
