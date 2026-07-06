-- test/cases/windows_geometry.lua -- pure geometry unit tests for platform.windows: the
-- shared, side-effect-free core that window_snap / window_modal / window_grid all place
-- windows through. Covers moveToScreen (scale/fill-clamp/keepSize), adjacentScreen +
-- screenIndexAt (spatial L-to-R ordering, not array order; loud enum guard), gridCellToFrame
-- (cell placement, gutters, screen origin), and gridDimsForScreen (aspect-oriented split).
--
-- Migrated from run.lua T25c/T25c-2/T25d/T25d2 (RUN_LUA_SPLIT_SPEC Phase 2). These call
-- platform.windows directly with literal frames -- no feature, no adapter handles -- so
-- the case just sources W/frameEq/ok from the harness. freshWorld() before + the handle
-- tripwire after (trivially 0 here) keep it uniform with the feature cases.

return {
    id = "windows_geometry",
    ---@param t Harness
    run = function(t)
        local ok, frameEq, W = t.ok, t.frameEq, t.W

        -- T25c: windows.moveToScreen geometry (the pure shared core of both features)
        local s1 = { x = 0, y = 0, w = 1000, h = 800 }
        -- default (window_snap): same-size target, scale 1 -> position shifts, size kept.
        frameEq(W.moveToScreen({ x = 100, y = 100, w = 400, h = 300 }, s1, { x = 1000, y = 0, w = 1000, h = 800 }),
            1100, 100, 400, 300, "moveToScreen default: equal screens just translate")
        -- default: 2x larger target -> least-distortion scale 2 on both dims + position.
        frameEq(W.moveToScreen({ x = 100, y = 100, w = 400, h = 300 }, s1, { x = 0, y = 0, w = 2000, h = 1600 }),
            200, 200, 800, 600, "moveToScreen default: larger screen scales both dims")
        -- default fill-clamp: scaled window wider than target -> filled to the target edge.
        frameEq(W.moveToScreen({ x = 0, y = 0, w = 1000, h = 800 }, s1, { x = 1000, y = 0, w = 800, h = 800 }),
            1000, 0, 800, 800, "moveToScreen default: oversize result fills the target edge")
        -- keepSize (window_modal): size kept but shrunk to fit, clamped back inside.
        frameEq(W.moveToScreen({ x = 100, y = 100, w = 1500, h = 1000 }, s1, { x = 1000, y = 0, w = 800, h = 600 },
            { keepSize = true }),
            1000, 0, 800, 600, "moveToScreen keepSize: shrinks to fit and clamps inside")

        -- T25c-2: windows.adjacentScreen / screenIndexAt -- "next/prev screen" must
        -- follow the PHYSICAL arrangement (left-to-right), NOT adapter.screenFrames'
        -- array order (NSScreen.screens = primary first, then OS registration order).
        -- Three monitors registered OUT of spatial order proves it: array is A,C,B but
        -- physically A(left) B(middle) C(right). The old (i % n)+1 cycle would step
        -- A -> C (skipping the middle); the spatial helper steps A -> B -> C.
        do
            local scr = {
                { x = -1000, y = 0, w = 1000, h = 800, name = "A" },  -- index 1, leftmost
                { x = 1000,  y = 0, w = 1000, h = 800, name = "C" },  -- index 2, rightmost
                { x = 0,     y = 0, w = 1000, h = 800, name = "B" },  -- index 3, middle
            }
            local f, i = W.adjacentScreen(scr, 1, "next")
            ok(f.name == "B" and i == 3, "adjacentScreen next follows spatial L-to-R, not array order")
            f, i = W.adjacentScreen(scr, 1, "prev")
            ok(f.name == "C" and i == 2, "adjacentScreen prev from leftmost wraps to rightmost")
            ok(W.adjacentScreen(scr, 3, "next").name == "C", "adjacentScreen next from middle -> right")
            ok(W.adjacentScreen(scr, 2, "next").name == "A", "adjacentScreen next from rightmost wraps to leftmost")

            -- vertical stack: tie-break top-to-bottom by y (top-left origin, so y asc = top).
            local stack = {
                { x = 0, y = 800, w = 1000, h = 800, name = "bottom" },  -- index 1
                { x = 0, y = 0,   w = 1000, h = 800, name = "top" },     -- index 2
            }
            ok(W.adjacentScreen(stack, 2, "next").name == "bottom", "adjacentScreen tie-breaks top-to-bottom by y")

            -- degenerate arities: single screen re-centers on itself; none -> nil.
            local solo = W.adjacentScreen({ { x = 0, y = 0, w = 1, h = 1, name = "solo" } }, 1, "next")
            ok(solo and solo.name == "solo", "adjacentScreen on one screen re-centers on itself")
            ok(W.adjacentScreen({}, 1, "next") == nil, "adjacentScreen on no screens returns nil")

            -- a direction outside W.DIR errors loudly instead of silently stepping
            -- "next" (the '"previous"' bug class); a typo'd FIELD (W.DIR.PREVIOUS)
            -- is nil and takes the same loud path.
            ok(not pcall(W.adjacentScreen, scr, 1, "previous"), "adjacentScreen rejects a non-enum direction loudly")
            ok(not pcall(W.adjacentScreen, scr, 1, W.DIR.PREVIOUS), "a typo'd DIR field is nil and rejected loudly")

            -- screenIndexAt: the frame containing the point, defaulting to 1 off-screen.
            ok(W.screenIndexAt(scr, 500, 400) == 3, "screenIndexAt returns the frame under the point (middle)")
            ok(W.screenIndexAt(scr, -500, 400) == 1, "screenIndexAt returns the leftmost frame")
            ok(W.screenIndexAt(scr, 99999, 400) == 1, "screenIndexAt defaults to 1 when the point is off every screen")
        end

        -- T25d: windows.gridCellToFrame -- the ported grid cell-placement algorithm.
        -- A 3x1 grid on a 1200x900 screen -> 400-wide full-height columns.
        do
            local g3 = { w = 3, h = 1 }
            local gs = { x = 0, y = 0, w = 1200, h = 900 }
            frameEq(W.gridCellToFrame(gs, g3, { x = 0, y = 0, w = 1, h = 1 }),
                0, 0, 400, 900, "gridCellToFrame: left column of a 3x1 grid")
            frameEq(W.gridCellToFrame(gs, g3, { x = 1, y = 0, w = 2, h = 1 }),
                400, 0, 800, 900, "gridCellToFrame: a 2-column span from offset 1")
            -- A 2x2 grid with a 10pt gutter insets each placed cell on every side.
            frameEq(W.gridCellToFrame({ x = 0, y = 0, w = 1000, h = 800 }, { w = 2, h = 2 },
                { x = 0, y = 0, w = 1, h = 1 }, { x = 10, y = 10 }),
                10, 10, 480, 380, "gridCellToFrame: a margin insets each window by the gutter")
            -- The screen origin is honored (placed relative to a secondary screen's frame).
            frameEq(W.gridCellToFrame({ x = 1000, y = 0, w = 1200, h = 900 }, g3, { x = 2, y = 0, w = 1, h = 1 }),
                1800, 0, 400, 900, "gridCellToFrame: cell placed relative to the screen origin")
        end

        -- T25d2: windows.gridDimsForScreen -- orientation-aware split (Window Grid's 6)
        do
            local land = { w = 1600, h = 900 }   -- landscape: more columns
            local port = { w = 900,  h = 1600 }  -- portrait:  more rows
            local d
            d = W.gridDimsForScreen(6, land); ok(d.w == 3 and d.h == 2, "gridDimsForScreen(6, landscape) = 3x2")
            d = W.gridDimsForScreen(6, port); ok(d.w == 2 and d.h == 3, "gridDimsForScreen(6, portrait) = 2x3")
            -- Square counts are aspect-agnostic (same either way).
            d = W.gridDimsForScreen(4, land); ok(d.w == 2 and d.h == 2, "gridDimsForScreen(4) = 2x2 (square)")
            d = W.gridDimsForScreen(9, port); ok(d.w == 3 and d.h == 3, "gridDimsForScreen(9) = 3x3 (square)")
            -- A square screen (w == h) takes the landscape branch (>=): more columns.
            d = W.gridDimsForScreen(6, { w = 1000, h = 1000 }); ok(d.w == 3 and d.h == 2,
                "gridDimsForScreen(6, square screen) = 3x2 (w>=h -> wide)")
            -- Balanced-factor pick, not naive: 3 -> 3x1/1x3, prime 5 -> 5x1/1x5, 1 -> 1x1.
            d = W.gridDimsForScreen(3, land); ok(d.w == 3 and d.h == 1, "gridDimsForScreen(3, landscape) = 3x1")
            d = W.gridDimsForScreen(5, port); ok(d.w == 1 and d.h == 5, "gridDimsForScreen(5, portrait) = 1x5 (prime)")
            d = W.gridDimsForScreen(1, land); ok(d.w == 1 and d.h == 1, "gridDimsForScreen(1) = 1x1")
        end
    end,
}
