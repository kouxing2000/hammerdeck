-- platform/windows -- pure window-geometry helpers shared by the window
-- features (window_snap, window_modal). Stateless leaf util: no require of its
-- own, every native call goes through the ctx passed in. Only the genuinely
-- identical code lives here; the divergent throw / fullscreen-guard math stays
-- in each feature.
--
-- Also the home for the ported Hammerspoon pure-Lua window algorithms (the
-- tiling/grid math -- just arithmetic over screen/window rects). They land here
-- because they are exactly this module's kind of code: pure rect math, zero
-- require, native only via a frame the caller already fetched. The strategy:
-- lift the MIT-licensed algorithms, keep the engine ours.

local M = {}

--- Direction tokens for `adjacentScreen`. A LuaLS value enum: annotated call
--- sites get editor/CI diagnostics for any string outside it, and a typo'd
--- FIELD (`W.DIR.PREVIOUS`) is nil, which the runtime assert rejects loudly.
--- Born of a real bug: a stringly-typed "previous" never matched "prev" and
--- silently fell through to "next", sending both bracket keys rightward.
---@enum ScreenDir
M.DIR = {
    NEXT = "next",
    PREV = "prev",
}

--- A screen-ratio rect: x/y offset and w/h size as fractions of the screen
--- visible frame (the donor's positionWindow).
---@param s {x:number,y:number,w:number,h:number} screen visible frame
---@param xR number x-offset ratio
---@param yR number y-offset ratio
---@param wR number width ratio
---@param hR number height ratio
---@return {x:number,y:number,w:number,h:number}
function M.rectFromRatios(s, xR, yR, wR, hR)
    return { x = s.x + s.w * xR, y = s.y + s.h * yR,
             w = s.w * wR, h = s.h * hR }
end

--- Rescale + reposition a frame from its source screen onto a target screen,
--- then clamp it inside the target. The shared geometry of "throw to another
--- screen" -- the two window features differ only in size policy (and the
--- divergent target-screen SELECTION, which stays in each caller):
---   * default (window_snap): least-distortion scale -- whichever axis ratio is
---     closer to 1 scales BOTH dims; a result wider/taller than the target is
---     filled to the target edge.
---   * keepSize (window_modal): size kept, only shrunk to fit; clamp just pulls
---     the frame back inside (no fill, since it already fits).
--- Position always scales per axis by the screen-size ratio, so a window keeps
--- its relative place on the new screen. Pure: no native calls.
---@param f {x:number,y:number,w:number,h:number} the window frame
---@param s {x:number,y:number,w:number,h:number} source screen visible frame
---@param t {x:number,y:number,w:number,h:number} target screen visible frame
---@param opts {keepSize:boolean}|nil
---@return {x:number,y:number,w:number,h:number}
function M.moveToScreen(f, s, t, opts)
    local keepSize = opts and opts.keepSize
    local sx, sy = t.w / s.w, t.h / s.h
    local nf = { x = t.x + (f.x - s.x) * sx, y = t.y + (f.y - s.y) * sy }
    if keepSize then
        nf.w, nf.h = math.min(f.w, t.w), math.min(f.h, t.h)
    else
        -- least distortion: the axis ratio nearer 1 drives both dimensions.
        local scale = math.abs(sy - 1) < math.abs(sx - 1) and sy or sx
        nf.w, nf.h = f.w * scale, f.h * scale
    end
    if nf.x + nf.w > t.x + t.w then
        nf.x = t.x + t.w - nf.w
        if not keepSize and nf.x < t.x then nf.x, nf.w = t.x, t.w end
    end
    if nf.y + nf.h > t.y + t.h then
        nf.y = t.y + t.h - nf.h
        if not keepSize and nf.y < t.y then nf.y, nf.h = t.y, t.h end
    end
    return nf
end

-- ---------------------------------------------------------------------------
-- Ported grid algorithm (Hammerspoon hs.grid, MIT). Pure rect arithmetic.
-- ---------------------------------------------------------------------------

--- Convert a GRID CELL to a pixel frame (hs.grid's "place window in cell").
--- The screen's visible frame is divided into `dims.w` columns x `dims.h` rows
--- of equal cells; `cell` names a region of that grid in CELL UNITS -- {x,y} is
--- the 0-based top-left cell it starts at, {w,h} how many cells it spans. So on
--- a 3x1 grid, {x=0,w=1} is the left third and {x=1,w=2} the right two-thirds.
--- This generalizes rectFromRatios from continuous fractions to an integer grid:
--- the whole fraction-tiling family (halves, thirds, quarters, sixths) is one
--- call with the matching dims/cell, no per-ratio arithmetic at the call site.
---
--- Optional `margin` {x,y} is a GUTTER: each placed window is inset by that many
--- points on every side, so adjacent cells leave a visible gap (hs.grid's
--- margins). Default 0 = flush tiling, matching the rest of this module.
---
--- Pure: no native calls. The caller passes the screen frame it already has
--- (e.g. focusedOrAlert's `f.screen`) and hands the result to ctx.window.setFrame.
---@param s {x:number,y:number,w:number,h:number} screen visible frame
---@param dims {w:integer,h:integer} grid size: columns x rows
---@param cell {x:number,y:number,w:number,h:number} cell offset + span, in grid units
---@param margin {x:number,y:number}|nil per-window inset (gutter); default 0
---@return {x:number,y:number,w:number,h:number}
function M.gridCellToFrame(s, dims, cell, margin)
    assert(dims.w > 0 and dims.h > 0,
        "gridCellToFrame: grid dims must be positive (got " ..
        tostring(dims.w) .. "x" .. tostring(dims.h) .. ")")
    local mx = (margin and margin.x) or 0
    local my = (margin and margin.y) or 0
    local cw = s.w / dims.w
    local ch = s.h / dims.h
    return {
        x = s.x + cell.x * cw + mx,
        y = s.y + cell.y * ch + my,
        w = cell.w * cw - 2 * mx,
        h = cell.h * ch - 2 * my,
    }
end

--- Orientation-aware grid shape for placing ONE window among `n` equal cells:
--- the most balanced factor pair of `n`, with the LARGER factor on the screen's
--- LONGER axis. So n=6 -> 3x2 (three columns) on a landscape display, 2x3 on a
--- portrait one; n=4 -> 2x2 either way (square, so aspect is moot). Distinct from
--- `gridDims` below, which is the DECK's window-count tiling (always wide-biased);
--- this one FOLLOWS the screen the window lives on, for Window Grid's per-window
--- cell placement where a non-square cell count (6) should split by aspect.
--- Pure: only the screen's aspect (w vs h) is read; hand the result to
--- gridCellToFrame as its `dims`.
---@param n integer cell count (>= 1)
---@param screen {w:number,h:number} screen visible frame (aspect only)
---@return {w:integer,h:integer} columns x rows
function M.gridDimsForScreen(n, screen)
    assert(n and n >= 1, "gridDimsForScreen: n must be >= 1")
    local a = math.floor(math.sqrt(n))
    while a > 1 and n % a ~= 0 do a = a - 1 end   -- largest factor <= sqrt(n)
    local b = math.floor(n / a)                   -- b >= a, and a*b == n
    -- Wider than tall -> more columns (b) than rows; taller -> more rows.
    if screen.w >= screen.h then
        return { w = b, h = a }
    else
        return { w = a, h = b }
    end
end

-- ---------------------------------------------------------------------------
-- Deck tiling (Window Deck): a uniform grid over the whole screen + a
-- minimise-travel assignment of windows to cells. Pure rect math, same tier as
-- gridCellToFrame -- the "grid Phase 2" this module's header invites.
-- ---------------------------------------------------------------------------

-- Grid shape for `n` windows: {w=cols, h=rows}, wide-screen biased, minimising
-- empty cells. A 1..9 table (the deck caps at 9) with the aesthetic overrides
-- baked in (3 -> 3x1, 7/8 -> 4x2); n > 9 falls back to the ceil(sqrt) formula so
-- the function stays total. Every entry satisfies rows == ceil(n/cols), which is
-- what keeps `tileSlots`' partial-last-row math (lastCount >= 1) valid.
local GRID_DIMS = {
    [1] = { w = 1, h = 1 },
    [2] = { w = 2, h = 1 },
    [3] = { w = 3, h = 1 },
    [4] = { w = 2, h = 2 },
    [5] = { w = 3, h = 2 },
    [6] = { w = 3, h = 2 },
    [7] = { w = 4, h = 2 },
    [8] = { w = 4, h = 2 },
    [9] = { w = 3, h = 3 },
}

--- The grid dimensions for `n` windows.
---@param n integer window count (>= 1)
---@return {w:integer,h:integer} columns x rows
function M.gridDims(n)
    assert(n and n >= 1, "gridDims: n must be >= 1")
    local d = GRID_DIMS[n]
    if d then return { w = d.w, h = d.h } end
    local cols = math.ceil(math.sqrt(n))
    return { w = cols, h = math.ceil(n / cols) }
end

--- N uniform pixel slots tiling the screen in READING ORDER (1 = top-left,
--- left-to-right then top-to-bottom). Full rows carry `cols` cells; a partial
--- LAST row stretches its `k` windows to full width (no dead cells) by tiling
--- that row as a k-column grid. Each cell is inset by `gutter` on every side.
--- Reuses gridCellToFrame -- no new pixel math, just a per-row column count.
---@param screen {x:number,y:number,w:number,h:number} screen visible frame
---@param n integer window count (1..9)
---@param gutter number|nil per-window inset (px); default 0
---@return {x:number,y:number,w:number,h:number}[] slot frames, reading order
function M.tileSlots(screen, n, gutter)
    local dims = M.gridDims(n)
    local cols, rows = dims.w, dims.h
    local margin = { x = gutter or 0, y = gutter or 0 }
    local fullRows = rows - 1
    local lastCount = n - cols * fullRows   -- windows in the final row (1..cols)
    local slots = {}
    for row = 0, fullRows - 1 do
        for col = 0, cols - 1 do
            slots[#slots + 1] = M.gridCellToFrame(
                screen, { w = cols, h = rows },
                { x = col, y = row, w = 1, h = 1 }, margin)
        end
    end
    for col = 0, lastCount - 1 do
        slots[#slots + 1] = M.gridCellToFrame(
            screen, { w = lastCount, h = rows },
            { x = col, y = fullRows, w = 1, h = 1 }, margin)
    end
    return slots
end

--- The centre point of a rect.
---@param r {x:number,y:number,w:number,h:number}
---@return {x:number,y:number}
function M.center(r)
    return { x = r.x + r.w / 2, y = r.y + r.h / 2 }
end

local function sqdist(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return dx * dx + dy * dy
end

-- Exact minimum-total-travel bijection by pruned depth-first search over all
-- permutations. n <= 7 -> at most 5040 leaves, sub-millisecond, run once per
-- deck entry. The prune (abandon a branch once its partial cost meets the best
-- full cost) keeps the typical case far under the worst case.
local function bruteAssign(winCenters, slotCenters, n)
    local used, current = {}, {}
    -- perm = {} is a placeholder the first full leaf always replaces (n >= 1
    -- guarantees one); it keeps the return type non-nil for the checker.
    local best = { cost = math.huge, perm = {} }
    local function recurse(i, cost)
        if cost >= best.cost then return end
        if i > n then
            local p = {}
            for k = 1, n do p[k] = current[k] end
            best.cost, best.perm = cost, p
            return
        end
        for j = 1, n do
            if not used[j] then
                used[j] = true
                current[i] = j
                recurse(i + 1, cost + sqdist(winCenters[i], slotCenters[j]))
                used[j] = false
            end
        end
    end
    recurse(1, 0)
    return best.perm
end

-- Greedy near-optimal bijection for n = 8..9 (brute force's 40k+ leaves get
-- slow): take the globally shortest window->slot pair, commit it, repeat over
-- the remaining. O(n^2 log n). Hungarian is the exact upgrade if a pathological
-- layout ever surfaces.
local function greedyAssign(winCenters, slotCenters, n)
    local cand = {}
    for i = 1, n do
        for j = 1, n do
            cand[#cand + 1] = { i = i, j = j, d = sqdist(winCenters[i], slotCenters[j]) }
        end
    end
    table.sort(cand, function(a, b) return a.d < b.d end)
    local perm, usedWin, usedSlot, done = {}, {}, {}, 0
    for _, c in ipairs(cand) do
        if not usedWin[c.i] and not usedSlot[c.j] then
            perm[c.i] = c.j
            usedWin[c.i], usedSlot[c.j] = true, true
            done = done + 1
            if done == n then break end
        end
    end
    return perm
end

--- Assign each window to a distinct slot minimising total (squared) travel, so
--- a window keeps its spatial place instead of being flung across the screen.
--- Returns `perm` where `perm[i]` is the slot index window `i` takes. Exact for
--- n <= 7, greedy (near-optimal) for 8..9.
---@param winCenters {x:number,y:number}[] window centres, index-aligned to the caller's window list
---@param slotCenters {x:number,y:number}[] slot centres (from tileSlots via center)
---@return integer[] perm  window index -> slot index
function M.assignNearest(winCenters, slotCenters)
    assert(#winCenters == #slotCenters,
        "assignNearest: window/slot counts differ")
    local n = #winCenters
    if n == 0 then return {} end
    if n <= 7 then return bruteAssign(winCenters, slotCenters, n) end
    return greedyAssign(winCenters, slotCenters, n)
end

--- A centred rect covering `pct` (0..1) of the screen on each axis -- the deck's
--- hero frame.
---@param s {x:number,y:number,w:number,h:number} screen visible frame
---@param pct number fraction of the screen per axis (e.g. 0.78)
---@return {x:number,y:number,w:number,h:number}
function M.centeredRect(s, pct)
    local w, h = s.w * pct, s.h * pct
    return { x = s.x + (s.w - w) / 2, y = s.y + (s.h - h) / 2, w = w, h = h }
end

-- ---------------------------------------------------------------------------
-- Window-layout helpers (the rules engine's `layout` effect). All pure: given
-- a window list + screen list (from the adapter), decide what goes where.
-- ---------------------------------------------------------------------------

--- The named snap-grid positions a layout placement can target, each a
--- screen-ratio rect {xR,yR,wR,hR}. The Settings layout editor offers these by
--- key; `pos` may also be an explicit {x,y,w,h} ratio table (what "Capture
--- current layout" records -- exact, not snapped to the grid).
M.POSITIONS = {
    full        = { 0,   0,   1,   1   },
    left        = { 0,   0,   0.5, 1   },
    right       = { 0.5, 0,   0.5, 1   },
    top         = { 0,   0,   1,   0.5 },
    bottom      = { 0,   0.5, 1,   0.5 },
    topLeft     = { 0,   0,   0.5, 0.5 },
    topRight    = { 0.5, 0,   0.5, 0.5 },
    bottomLeft  = { 0,   0.5, 0.5, 0.5 },
    bottomRight = { 0.5, 0.5, 0.5, 0.5 },
}

-- Stable display order for the editor's position picker (POSITIONS is a map).
M.POSITION_ORDER = {
    "full", "left", "right", "top", "bottom",
    "topLeft", "topRight", "bottomLeft", "bottomRight",
}

-- Human labels for the position picker (single source for any UI surface).
M.POSITION_LABELS = {
    full        = "Full screen",
    left        = "Left half",       right       = "Right half",
    top         = "Top half",        bottom      = "Bottom half",
    topLeft     = "Top-left",        topRight    = "Top-right",
    bottomLeft  = "Bottom-left",     bottomRight = "Bottom-right",
}

--- Resolve a placement `pos` to a ratio rect {x,y,w,h} (fractions of a screen).
--- A string keys POSITIONS; a table is taken as explicit ratios (the capture
--- path). Returns nil for an unknown string -- the caller treats that as invalid.
---@param pos string|table
---@return {x:number,y:number,w:number,h:number}|nil
function M.ratiosFor(pos)
    if type(pos) == "table" then
        return { x = pos.x or 0, y = pos.y or 0, w = pos.w or 1, h = pos.h or 1 }
    end
    local g = M.POSITIONS[pos]
    if not g then return nil end
    return { x = g[1], y = g[2], w = g[3], h = g[4] }
end

--- Does a window row (from adapter.listWindows) match a placement's selector?
--- Matches by exact app name; an optional `titlePattern` is a plain (non-Lua-
--- pattern), CASE-INSENSITIVE substring of the title. A placement with neither
--- matches nothing.
---@param w table a window row { appName, title, ... }
---@param p table a placement { app, titlePattern? }
---@return boolean
function M.windowMatches(w, p)
    if type(p.app) ~= "string" or #p.app == 0 then return false end
    if w.appName ~= p.app then return false end
    if type(p.titlePattern) == "string" and #p.titlePattern > 0 then
        -- Case-insensitive: users type "docs", the title reads "Docs - report".
        -- NOTE: string.lower is ASCII-only, so non-ASCII titles (accented / CJK)
        -- aren't case-folded -- a best-effort disambiguator, not full Unicode.
        if type(w.title) ~= "string"
            or not w.title:lower():find(p.titlePattern:lower(), 1, true) then
            return false
        end
    end
    return true
end

--- Find the screen (from adapter.screenFrames) whose display name == `name`, or
--- nil if that display is not currently present -- which makes a layout
--- placement SELF-GATING: a "place on DELL U2720Q" entry is simply skipped when
--- that monitor is unplugged.
---@param screens table[] screen rows { x,y,w,h,name }
---@param name string
---@return table|nil
function M.resolveScreen(screens, name)
    for _, s in ipairs(screens or {}) do
        if (s.name or "") == name then return s end
    end
    return nil
end

--- The screen a frame sits on: the one whose visible frame contains the frame's
--- midpoint, else the first (used by "Capture current layout" to tag each window
--- with its display + ratios). Pure -- no reliance on listWindows' screenName.
---@param screens table[] screen rows { x,y,w,h,name }
---@param f table a frame { x,y,w,h }
---@return table|nil
function M.screenOfFrame(screens, f)
    local mx, my = f.x + f.w / 2, f.y + f.h / 2
    for _, s in ipairs(screens or {}) do
        if mx >= s.x and mx < s.x + s.w and my >= s.y and my < s.y + s.h then
            return s
        end
    end
    return screens and screens[1] or nil
end

--- 1-based index of the screen (in `frames`) whose visible frame contains the
--- point (x,y), else 1. The index space matches adapter.screenFrames /
--- f.screenIndex, so the result feeds straight into `adjacentScreen`.
---@param frames table[] screen rows { x,y,w,h }
---@param x number
---@param y number
---@return integer
function M.screenIndexAt(frames, x, y)
    for i, s in ipairs(frames or {}) do
        if x >= s.x and x < s.x + s.w and y >= s.y and y < s.y + s.h then
            return i
        end
    end
    return 1
end

--- The screen spatially adjacent to `frames[curIndex]` in direction `dir`,
--- cycling. Screens are ordered by their PHYSICAL arrangement -- left-to-right
--- by x, tie-broken top-to-bottom by y -- which each frame origin already
--- encodes (that IS what dragging the displays in System Settings > Displays
--- sets). "next" steps rightward/down, "prev" leftward/up. This is what a user
--- means by "next screen", unlike adapter.screenFrames' raw NSScreen.screens
--- order (primary first, then OS registration order -- non-spatial, which
--- surprises on 3+ monitors). `curIndex` is 1-based into `frames` (e.g.
--- f.screenIndex). Returns the target frame AND its 1-based index in `frames`
--- (the original index, NOT the spatial slot).
---@param frames table[] rows from adapter.screenFrames()
---@param curIndex integer
---@param dir ScreenDir
---@return table|nil frame, integer|nil index
function M.adjacentScreen(frames, curIndex, dir)
    -- Loud on a bad direction (see M.DIR): an unknown value silently stepping
    -- "next" once sent BOTH bracket keys rightward.
    assert(dir == M.DIR.NEXT or dir == M.DIR.PREV,
        "adjacentScreen: dir must be 'next' or 'prev' (windows.DIR), got " .. tostring(dir))
    local n = frames and #frames or 0
    if n == 0 then return nil, nil end
    if n == 1 then return frames[1], 1 end
    -- spatial order as a permutation of the original indices
    local order = {}
    for i = 1, n do order[i] = i end
    table.sort(order, function(a, b)
        local fa, fb = frames[a], frames[b]
        if fa.x ~= fb.x then return fa.x < fb.x end
        if fa.y ~= fb.y then return fa.y < fb.y end
        return a < b   -- deterministic for coincident origins (mirrored displays)
    end)
    local slot = 1
    for s = 1, n do if order[s] == curIndex then slot = s; break end end
    local step = (dir == "prev") and -1 or 1
    local ni = order[((slot - 1 + step) % n) + 1]
    return frames[ni], ni
end

--- The focused window's frame, or nil after alerting the user (the per-action
--- guard): if Accessibility is missing, prompt + onboard; otherwise alert that
--- nothing is focused.
---@param ctx table the curated feature ctx
---@param featureName string shown in the Accessibility onboarding message
---@return table|nil frame `{x,y,w,h,fullscreen,screenIndex,screen={x,y,w,h}}`
function M.focusedOrAlert(ctx, featureName)
    local f = ctx.window.frame()
    if f then return f end
    if not ctx.axTrusted() then
        ctx.axPrompt()
        -- ctx.t does the formatting (never a raw string.format over a translated template):
        -- the slots are numbered, so a locale may reorder them, and Lua's string.format
        -- would RAISE on "%1$s". This leaf reaches i18n only through the ctx handed to it.
        ctx.alert(ctx.t("window.axRequired",
            "%1$s needs the Accessibility permission -- grant %2$s in System Settings, then try again",
            featureName, ctx.appName))
    else
        ctx.alert(ctx.t("window.noFocused", "No focused window"))
    end
    return nil
end

return M
