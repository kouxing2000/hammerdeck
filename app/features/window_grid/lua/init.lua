-- features/window_grid
--
-- "Window Grid": place the focused window into a RECTANGLE of a grid by naming
-- its two corners. A hotkey deems the screen a grid and shows a numbered
-- cheat-sheet; press a cell and the window lands there immediately, then -- while
-- the mode stays briefly armed -- press a second cell DOWN-AND-RIGHT of the first
-- to grow the window to the rectangle those two corners bound. Hyper+9 -> 3x3
-- (cells 1-9), Hyper+6 -> a 6-cell grid oriented to the screen (3x2 wide / 2x3
-- tall), Hyper+4 -> 2x2. Cells number in READING ORDER, 1 = top-left,
-- left-to-right then top-to-bottom:
--
--     1 2 3            1 2
--     4 5 6    (3x3)   3 4   (2x2)
--     7 8 9
--
-- INTERACTION (place-and-extend, directional):
--   * The FIRST press places that single cell at once (no waiting) and arms it as
--     corner-A, the rectangle's TOP-LEFT. If no valid second press arrives within
--     ARM_IDLE, the single placement stands and the mode auto-dismisses.
--   * A SECOND press B extends only if B is down-and-right of A
--     (B.col >= A.col AND B.row >= A.row): the window fills the bounding box A->B
--     and the mode commits. Pressing A again (B == A) commits the single cell.
--   * A press that is NOT down-right of A ("turns back") is not a valid corner --
--     it RE-PICKS: that cell becomes a fresh corner-A (placed + re-armed). So on a
--     3x3, "3 then 4" re-picks cell 4, it never spans.
--   Examples (Hyper+6, 3x2):  2 then 3 -> top-right 2/3;  1 then 4 -> left 1/3
--   full height;  1 then 5 -> left 2/3 full height.
--
-- Rides the ported grid algorithm (platform.windows.gridCellToFrame), which
-- already takes a multi-cell SPAN, so a rectangle is pure cell math over
-- ctx.window.setFrame -- zero native surface beyond the focused-window frame and
-- the live HUD re-render (ctx.modal's updateHud) that highlights corner-A and
-- dims the now-invalid cells. Pairs with Window Snap (halves/thirds) and Window
-- Mode (fine nudge/resize).
--
-- Needs Accessibility (the focused-window frame surface).

local W = require("platform.windows")

local HYPER = { "cmd", "alt", "ctrl" }

-- How long (seconds) the mode stays armed after a placement, waiting for a second
-- corner. RESET on every placement keypress (arm / re-pick), so there is no rush --
-- generous enough to read the per-cell previews and decide. Escape exits instantly;
-- while armed only the 1..N digit keys are swallowed, everything else passes through.
local ARM_IDLE = 2.5

-- A 1-based cell number -> {x=col, y=row, w=1, h=1} on a `cols`-wide grid,
-- reading order (1 = top-left). Used both to place and to build the HUD.
---@param cols integer grid width (columns)
---@param num integer 1-based cell number, reading order
---@return {x:integer,y:integer,w:integer,h:integer} single cell in grid units
local function cellOf(cols, num)
    local idx = num - 1
    return { x = idx % cols, y = math.floor(idx / cols), w = 1, h = 1 }
end

-- The bounding SPAN of two cells, `a` (top-left) to `b` (bottom-right). Assumes
-- `b` is down-and-right of `a` (the directional invariant the caller enforces),
-- so w/h are always >= 1. b == a yields the single cell a.
---@param a {x:integer,y:integer} top-left cell (0-based col/row)
---@param b {x:integer,y:integer} bottom-right cell (down-right of a)
---@return {x:integer,y:integer,w:integer,h:integer} span in grid units
local function spanCell(a, b)
    return { x = a.x, y = a.y, w = b.x - a.x + 1, h = b.y - a.y + 1 }
end

-- Place the focused window into a grid-unit `cell` (a single cell or a span) of a
-- cols x rows grid, or alert via focusedOrAlert when there is no focused window /
-- Accessibility is missing. Returns true iff a window was actually placed.
--
-- A FULLSCREEN window is taken out of fullscreen and reported as not placed: AX
-- refuses a frame write to it, so placing would be a silent no-op that still
-- advanced the mode -- the HUD would highlight a cell the window never went to.
-- Exiting closes the mode (the caller stops on a false), and the next press
-- arranges normally, which is what window_modal's prologue does too.
---@param ctx table scoped feature ctx
---@param cols integer grid width
---@param rows integer grid height
---@param cell {x:integer,y:integer,w:integer,h:integer} cell/span in grid units
---@return boolean placed
---@param ctx Ctx
local function placeSpan(ctx, cols, rows, cell)
    local f = W.focusedOrAlert(ctx, "Window Grid")
    if not f then return false end
    if f.fullscreen then
        ctx.log("grid: focused window is fullscreen -- exiting fullscreen, not placed")
        ctx.window.setFullscreen(false)
        return false
    end
    ctx.window.setFrame(W.gridCellToFrame(f.screen, { w = cols, h = rows }, cell))
    return true
end

-- The numbered cheat-sheet for a cols x rows grid: each cell shows its number,
-- positioned where it lands the window. The HUD renderer sizes its board from
-- cols/rows, so a 2x2 reads as a 2x2 (not a corner of a 3x3). When `armA` is set
-- (the extend phase) each cell is tagged with a `state` the renderer styles:
-- "corner" = the picked top-left, "valid" = a legal second corner (down-right),
-- "dim" = an invalid ("turn back") cell. Each corner/valid cell ALSO carries a
-- `preview` = the window that pressing it would produce (corner-A -> this cell), as
-- fractions {x,y,w,h} of the whole grid; the renderer draws it as a mini-screen
-- thumbnail so the map reads "number -> the window size it makes". armA nil renders
-- exactly like the initial phase (no state/preview), so the entry HUD is unchanged.
---@param ctx table scoped feature ctx
---@param cols integer grid width
---@param rows integer grid height
---@param armA {x:integer,y:integer}|nil corner-A (top-left); nil = initial phase
---@return table hud spec for adapter.hud / WindowModeHUDPanel
---@param ctx Ctx
local function hudFor(ctx, cols, rows, armA)
    local cells = {}
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            local state, preview
            if armA then
                if c >= armA.x and r >= armA.y then      -- down-right of A -> a legal corner
                    state = (c == armA.x and r == armA.y) and "corner" or "valid"
                    preview = {
                        x = armA.x / cols, y = armA.y / rows,
                        w = (c - armA.x + 1) / cols, h = (r - armA.y + 1) / rows,
                    }
                else
                    state = "dim"                        -- up/left ("turn back") -> invalid
                end
            end
            cells[#cells + 1] = {
                col = c, row = r, keys = { tostring(r * cols + c + 1) },
                state = state, preview = preview,
            }
        end
    end
    return {
        title   = ctx.t("hud.title", "%1$d×%2$d Grid", cols, rows),
        cols    = cols,
        rows    = rows,
        cells   = cells,
        caption = armA
            and ctx.t("hud.captionExtend", "press a cell down-right to extend")
            or ctx.t("hud.caption", "press a number to place the window"),
        footer  = ctx.t("hud.footer", "esc  cancel"),
    }
end

-- One controller per enablement (ctx changes on re-enable). Tracks the live
-- placement modal, the armed corner-A, and the idle timer so a second entry
-- replaces the first instead of stacking.
---@param ctx Ctx
local function controllerFor(ctx)
    local st = { modal = nil, armA = nil, idleTimer = nil }

    -- The 1-based cell number of a 0-based cell (for logs/flash).
    local function numOf(cols, cell) return cell.y * cols + cell.x + 1 end

    -- Build + show the placement modal for a cols x rows grid. Assumes any prior
    -- modal is already stopped and a focused window was just confirmed (placeSpan
    -- re-checks per keypress). Shared by every entry so the oriented grid and the
    -- fixed squares render and behave identically -- only the dims differ.
    local function build(cols, rows)
        st.armA = nil
        ctx.log("grid enter", cols .. "x" .. rows)
        -- Set true by the commit/timeout branches (which log their own outcome) so
        -- onExit doesn't double-log; a bare Escape (or a re-entry that stops this
        -- modal) leaves it false, so onExit records the dismiss + any standing cell.
        local committed = false

        -- (Re)start the idle timer: on expiry the current single-cell placement
        -- (made at arm time) stands and the mode dismisses with a confirm flash.
        local function rearmTimer()
            if st.idleTimer then st.idleTimer.stop() end
            st.idleTimer = ctx.afterSeconds(ARM_IDLE, function()
                local a = st.armA
                ctx.log("grid timeout-dismiss cell", a and numOf(cols, a))
                committed = true
                if st.modal then st.modal.stop() end       -- onExit clears state
                if a then
                    ctx.confirmAction(
                        ctx.t("flash.placed", "Cell %1$d of %2$d", numOf(cols, a), cols * rows))
                end
            end)
        end

        -- Place the single cell `b`, arm it as corner-A, re-render the HUD to
        -- highlight it + dim the now-invalid cells, and reset the idle timer.
        local function armAt(b)
            if not placeSpan(ctx, cols, rows, b) then
                -- Nothing was placed: the window vanished mid-mode, or it was
                -- fullscreen and placeSpan has just taken it out. Either way there is
                -- no arrangement to arm, so close rather than highlight a cell the
                -- window never went to.
                if st.modal then st.modal.stop() end
                return
            end
            st.armA = b
            if st.modal then st.modal.updateHud(hudFor(ctx, cols, rows, b)) end
            rearmTimer()
        end

        local function onPress(num)
            local b = cellOf(cols, num)
            local a = st.armA
            if not a then                                  -- FIRST press: place + arm
                ctx.log("grid arm cell", num)
                armAt(b)
            elseif b.x >= a.x and b.y >= a.y then          -- VALID extension (B==A ok)
                if st.idleTimer then st.idleTimer.stop(); st.idleTimer = nil end
                local cell = spanCell(a, b)
                local placed = placeSpan(ctx, cols, rows, cell)
                if b.x == a.x and b.y == a.y then
                    ctx.log("grid commit-same cell", num)
                else
                    ctx.log("grid extend", numOf(cols, a), "->", num)
                end
                committed = true
                if st.modal then st.modal.stop() end       -- COMMIT + exit
                -- Confirm the RESULT after the banner dismisses: a real rectangle
                -- names its size, a 1x1 commit names the cell.
                if placed then
                    if cell.w > 1 or cell.h > 1 then
                        ctx.confirmAction(
                            ctx.t("flash.span", "%1$d×%2$d region", cell.w, cell.h))
                    else
                        ctx.confirmAction(
                            ctx.t("flash.placed", "Cell %1$d of %2$d", num, cols * rows))
                    end
                end
            else                                           -- INVALID: re-pick corner-A
                ctx.log("grid re-pick cell", num)
                armAt(b)
            end
        end

        local bindings = {}
        for num = 1, cols * rows do
            bindings[#bindings + 1] = { key = tostring(num), fn = function() onPress(num) end }
        end
        st.modal = ctx.modal({
            hud      = hudFor(ctx, cols, rows),
            bindings = bindings,
            -- A cell key can BE the entry key (Hyper+4 -> cell 4, Hyper+9 -> cell 9),
            -- so -- UNLIKE a toggle mode (Window Mode's Hyper+w exit) -- it must NOT
            -- be the sticky-twin exception. false = twin EVERY bare key, so the last
            -- cell lands (or arms) with the leader held. See ctx.modal / modal.lua.
            stickyExceptKey = false,
            onExit   = function()
                if st.idleTimer then st.idleTimer.stop() end
                if not committed then                       -- bare Escape / re-entry
                    ctx.log("grid dismiss cell", st.armA and numOf(cols, st.armA))
                end
                st.idleTimer, st.armA, st.modal = nil, nil, nil
            end,
        })
    end

    -- Fixed SQUARE grid (Hyper+4 -> 2x2, Hyper+9 -> 3x3): the entry key names both
    -- the cell count and the shape, so no aspect logic is needed.
    function st.enter(cols, rows)
        if st.modal then st.modal.stop() end               -- onExit nils st.modal
        if not W.focusedOrAlert(ctx, "Window Grid") then return end
        build(cols, rows)
    end

    -- N equal cells, shape ORIENTED to the focused window's screen (n=6 -> 3x2 on
    -- a landscape display, 2x3 on a portrait one). For non-square counts where no
    -- single square exists and the screen's aspect should decide the split.
    function st.enterOriented(n)
        if st.modal then st.modal.stop() end
        local f = W.focusedOrAlert(ctx, "Window Grid")
        if not f then return end
        local d = W.gridDimsForScreen(n, f.screen)
        build(d.w, d.h)
    end

    return st
end


-- A window MODE (Window Deck, Window Fan) holds each member's pre-mode frame so
-- it can put it back on exit; moving a member underneath it does not update that
-- record, so the mode's restore quietly stops being one. Every action here
-- therefore asks first when a mode owns the screen it is about to touch -- the
-- platform shows the dialog, tears that mode down and waits for its layout to
-- land before running us. No mode live (the normal case) = synchronous, no
-- dialog, so an auto-repeating arrow key costs nothing.
--
-- W.focusedScreen, not f.screen: a frame's `screen` is a bare {x,y,w,h} with no
-- index to key a lease by, and focusedScreen also falls back to the display under
-- the POINTER -- so focus on the desktop asks about the right screen instead of
-- resolving to nothing and running ungated over a mode's windows.
---@param ctx Ctx
---@param fn fun()
local function onFocusedScreen(ctx, fn)
    ctx.window.requestExclusive({ screen = W.focusedScreen(ctx) }, fn)
end

---@param ctx Ctx
local function with(ctx)
    return ctx.perEnable(controllerFor)
end

return {
    api     = 1,
    id      = "window_grid",

    actions = {
        { id = "grid_3x3", label = "3×3 grid placement", icon = "square.grid.3x3",
          description = "Deem the screen a 3×3 grid, then press a cell to place the "
              .. "focused window there -- or press a second cell down-right of it to "
              .. "fill that rectangle.",
          defaultTrigger = { type = "hotkey", mods = HYPER, key = "9" },
          mnemonic = "Hyper+9 — 9 cells = 3×3",
          ---@param ctx Ctx
          run = function(ctx) onFocusedScreen(ctx, function() with(ctx).enter(3, 3) end) end },
        { id = "grid_2x2", label = "2×2 grid placement", icon = "square.grid.2x2",
          description = "Deem the screen a 2×2 grid, then press a cell to place the "
              .. "focused window there -- or press a second cell down-right of it to "
              .. "fill that rectangle.",
          defaultTrigger = { type = "hotkey", mods = HYPER, key = "4" },
          mnemonic = "Hyper+4 — 4 cells = 2×2",
          ---@param ctx Ctx
          run = function(ctx) onFocusedScreen(ctx, function() with(ctx).enter(2, 2) end) end },

        -- A 6-cell grid, oriented to the screen (3×2 wide / 2×3 tall) -- the split
        -- that 2×2 and 3×3 can't express, and the one an ultrawide actually wants.
        -- Hyper+6 keeps the digit=cell-count mnemonic of Hyper+4 / Hyper+9.
        -- enterOriented reads the focused window's screen aspect to pick 3×2 vs 2×3.
        { id = "grid_6", label = "6-cell grid placement", icon = "square.grid.3x2",
          description = "Deem the screen a 6-cell grid -- 3×2 on a wide display, "
              .. "2×3 on a tall one -- then press a cell to place the focused window "
              .. "there, or a second cell down-right of it to fill that rectangle.",
          defaultTrigger = { type = "hotkey", mods = HYPER, key = "6" },
          mnemonic = "Hyper+6 — 6 cells = 3×2 (wide) or 2×3 (tall)",
          ---@param ctx Ctx
          run = function(ctx) onFocusedScreen(ctx, function() with(ctx).enterOriented(6) end) end },
    },
}
