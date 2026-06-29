-- features/window_grid
--
-- "Window Grid": drop the focused window into a cell of a SQUARE grid in two
-- keystrokes. A hotkey deems the screen an N x N grid and shows a numbered
-- cheat-sheet; the next number key lands the window in that cell, then the mode
-- exits. Hyper+9 -> 3x3 (cells 1-9), Hyper+4 -> 2x2 (cells 1-4). Cells number in
-- READING ORDER, 1 = top-left, left-to-right then top-to-bottom:
--
--     1 2 3            1 2
--     4 5 6    (3x3)   3 4   (2x2)
--     7 8 9
--
--   Hyper+9, 2   ->  top-middle of a 3x3 grid
--   Hyper+4, 3   ->  bottom-left of a 2x2 grid
--
-- This is the first consumer of the ported grid algorithm
-- (platform.windows.gridCellToFrame): pure cell placement (no move/resize
-- layer), riding ctx.window.setFrame, so it needs zero native surface beyond the
-- focused-window frame. Pairs with Window Snap (halves/thirds) and Window Mode
-- (fine nudge/resize). Two-keystroke flow built on a hotkey + a transient modal
-- (the digit is dynamic, so a fixed chord won't do).
--
-- Needs Accessibility (the focused-window frame surface).

local W = require("platform.windows")

local HYPER = { "cmd", "alt", "ctrl" }

-- A 1-based cell number -> {x=col, y=row, w=1, h=1} on a `cols`-wide grid,
-- reading order (1 = top-left). Used both to place and to build the HUD.
local function cellOf(cols, num)
    local idx = num - 1
    return { x = idx % cols, y = math.floor(idx / cols), w = 1, h = 1 }
end

-- Place the focused window in cell `num` of a cols x rows grid (or alert via
-- focusedOrAlert if there is no focused window / Accessibility is missing).
local function place(ctx, cols, rows, num)
    local f = W.focusedOrAlert(ctx, "Window Grid")
    if not f then return end
    ctx.window.setFrame(W.gridCellToFrame(f.screen, { w = cols, h = rows }, cellOf(cols, num)))
end

-- The numbered cheat-sheet for a cols x rows grid: each cell shows its number,
-- positioned where it lands the window. The HUD renderer sizes its board from
-- cols/rows, so a 2x2 reads as a 2x2 (not a corner of a 3x3).
local function hudFor(cols, rows)
    local cells = {}
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            cells[#cells + 1] = { col = c, row = r, keys = { tostring(r * cols + c + 1) } }
        end
    end
    return {
        title   = cols .. "×" .. rows .. " Grid",
        cols    = cols,
        rows    = rows,
        cells   = cells,
        caption = "press a number to place the window",
        footer  = "esc  cancel",
    }
end

-- One controller per enablement (ctx changes on re-enable). Tracks the live
-- placement modal so a second entry replaces the first instead of stacking.
local function controllerFor(ctx)
    local st = { modal = nil }

    function st.enter(cols, rows)
        if st.modal then st.modal.stop() end             -- onExit nils st.modal
        if not W.focusedOrAlert(ctx, "Window Grid") then return end
        local bindings = {}
        for num = 1, cols * rows do
            bindings[#bindings + 1] = { key = tostring(num), fn = function()
                place(ctx, cols, rows, num)
                if st.modal then st.modal.stop() end      -- single-shot: place, exit
            end }
        end
        st.modal = ctx.modal({
            hud      = hudFor(cols, rows),
            bindings = bindings,
            onExit   = function() st.modal = nil end,
        })
    end

    return st
end

local cached = nil
local function with(ctx)
    if not cached or cached.ctx ~= ctx then
        cached = { ctx = ctx, st = controllerFor(ctx) }
    end
    return cached.st
end

return {
    api     = 1,
    id      = "window_grid",

    actions = {
        { id = "grid_3x3", label = "3×3 grid placement",
          description = "Deem the screen a 3×3 grid, then press 1-9 to drop the "
              .. "focused window into that cell.",
          defaultTrigger = { type = "hotkey", mods = HYPER, key = "9" },
          mnemonic = "Hyper+9 — 9 cells = 3×3",
          run = function(ctx) with(ctx).enter(3, 3) end },
        { id = "grid_2x2", label = "2×2 grid placement",
          description = "Deem the screen a 2×2 grid, then press 1-4 to drop the "
              .. "focused window into that cell.",
          defaultTrigger = { type = "hotkey", mods = HYPER, key = "4" },
          mnemonic = "Hyper+4 — 4 cells = 2×2",
          run = function(ctx) with(ctx).enter(2, 2) end },
    },
}
