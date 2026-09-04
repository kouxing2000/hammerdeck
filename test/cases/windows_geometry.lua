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

        -- onScreen: centre-in-rect membership -- the SANCTIONED "is this window on
        -- this screen" test. Never identity-compare ctx.screen.frames() rows: the
        -- real host builds fresh tables each call, so rawequal is silently
        -- always-false in production (it only "passes" against a fake that returns
        -- one stable table). A straddling window belongs to whichever screen holds
        -- its CENTRE, so the seam is decided crisply, never double-counted.
        do
            local s1 = { x = 0, y = 0, w = 1000, h = 800 }
            local s2 = { x = 1000, y = 0, w = 1000, h = 800 }
            ok(W.onScreen({ x = 100, y = 100, w = 400, h = 300 }, s1), "onScreen: window inside s1")
            ok(not W.onScreen({ x = 100, y = 100, w = 400, h = 300 }, s2), "onScreen: that window is not on s2")
            ok(W.onScreen({ x = 700, y = 100, w = 400, h = 300 }, s1),
                "onScreen: straddler with centre 900 -> s1")
            ok(not W.onScreen({ x = 900, y = 100, w = 400, h = 300 }, s1),
                "onScreen: straddler with centre 1100 -> not s1")
            ok(W.onScreen({ x = 900, y = 100, w = 400, h = 300 }, s2),
                "onScreen: ...and yes on s2 (crisp seam, no double-count)")

            -- W-1c: the sanctioned predicate must answer membership the SAME way
            -- screenOfFrame does. A row's own rect is the VISIBLE frame, which
            -- excludes the menu-bar and Dock strips -- and a window parked over
            -- the Dock is plainly on that display (listWindows labels it so, from
            -- the full frame). Two membership predicates that disagree put one
            -- window on a display and off it in the same breath.
            local rows = {
                { x = 0, y = 37, w = 2560, h = 1318, name = "DELL", index = 1,
                  full = { x = 0, y = 0, w = 2560, h = 1440 } },
            }
            local dockside = { x = 600, y = 1290, w = 420, h = 160 }  -- centre y 1370
            ok(W.onScreen(dockside, rows[1]),
                "onScreen: a window over the Dock is ON that display (full frame, not visible)")
            local via = W.screenOfFrame(rows, dockside)
            ok(via ~= nil and via.name == "DELL",
                "onScreen: ...and screenOfFrame agrees -- one question, one answer")
            -- A row with no `full` still falls back to its own rect, so every
            -- older caller and fixture keeps the behavior it was written against.
            ok(not W.onScreen(dockside, { x = 0, y = 37, w = 2560, h = 1318 }),
                "onScreen: a row without `full` falls back to the visible rect")
        end

        -- fanSlots (Window Fan's border-anchored slab fan). The CORE invariant is
        -- strip-exclusivity: each window's designated edge strip is disjoint from
        -- EVERY OTHER window's frame -- from which z-order-independence follows with
        -- no z-simulation (raising any window covers bodies, never a strip). Also:
        -- the strip spans exactly its frame's designated edge, same-side frames are
        -- pairwise disjoint, everything sits inside the screen, and strips are the
        -- full `s` thick.
        do
            local SCREEN = { x = 0, y = 0, w = 1600, h = 1000 }
            local S, GAP = 40, 8
            local function overlap(a, b)
                return a.x < b.x + b.w and b.x < a.x + a.w
                    and a.y < b.y + b.h and b.y < a.y + a.h
            end
            for n = 1, 14 do
                local slots = W.fanSlots(SCREEN, n, S, GAP)
                ok(#slots == n, "fanSlots(" .. n .. "): n slots")
                local exclusive, spans, thick, inside = true, true, true, true
                local sameSideDisjoint = true
                for i, si in ipairs(slots) do
                    -- strip disjoint from every OTHER frame (the z-independence core)
                    for j, sj in ipairs(slots) do
                        if i ~= j and overlap(si.strip, sj) then exclusive = false end
                    end
                    -- the strip is the full designated edge of its own frame
                    local st, f = si.strip, si
                    local onEdge =
                        (si.side == "T" and st.x == f.x and st.y == f.y and st.w == f.w and st.h == S) or
                        (si.side == "B" and st.x == f.x and st.y == f.y + f.h - S and st.w == f.w and st.h == S) or
                        (si.side == "L" and st.x == f.x and st.y == f.y and st.w == S and st.h == f.h) or
                        (si.side == "R" and st.x == f.x + f.w - S and st.y == f.y and st.w == S and st.h == f.h)
                    if not onEdge then spans = false end
                    if not (st.h == S or st.w == S) then thick = false end
                    if f.x < SCREEN.x or f.y < SCREEN.y
                        or f.x + f.w > SCREEN.x + SCREEN.w
                        or f.y + f.h > SCREEN.y + SCREEN.h then inside = false end
                    -- same-side frames pairwise disjoint
                    for j = i + 1, #slots do
                        if slots[j].side == si.side and overlap(si, slots[j]) then
                            sameSideDisjoint = false
                        end
                    end
                end
                ok(exclusive, "fanSlots(" .. n .. "): every strip is disjoint from every other frame (z-independent)")
                ok(spans, "fanSlots(" .. n .. "): each strip spans its full designated edge")
                ok(thick and inside, "fanSlots(" .. n .. "): strips are s-thick, all frames inside the screen")
                ok(sameSideDisjoint, "fanSlots(" .. n .. "): same-side frames are pairwise disjoint")
            end
            -- The N=6 split the oracle gave: T=2, B=2, L=1, R=1 (round-robin T,B,L,R).
            local six = W.fanSlots(SCREEN, 6, S, GAP)
            local perSide = { T = 0, B = 0, L = 0, R = 0 }
            for _, s in ipairs(six) do perSide[s.side] = perSide[s.side] + 1 end
            ok(perSide.T == 2 and perSide.B == 2 and perSide.L == 1 and perSide.R == 1,
                "fanSlots(6): sides split T=2 B=2 L=1 R=1")
            -- L/R slabs span nearly the whole width (a full edge that beats a corner).
            local wideOne = nil
            for _, s in ipairs(six) do if s.side == "L" then wideOne = s end end
            ok(wideOne.w == 1600 - S, "fanSlots(6): an L slab spans the screen minus one strip")
        end

        -- rectSubtract / rectMinus (Window Fan's occlusion): a window's border is
        -- clipped to its frame MINUS everything in front. Disjoint pieces, exact
        -- area accounting (integer inputs keep it exact), covering the corner cases.
        do
            local function area(rects)
                local a = 0
                for _, r in ipairs(rects) do a = a + r.w * r.h end
                return a
            end
            local function disjoint(rects)
                for i = 1, #rects do
                    for j = i + 1, #rects do
                        local a, b = rects[i], rects[j]
                        if a.x < b.x + b.w and b.x < a.x + a.w
                            and a.y < b.y + b.h and b.y < a.y + a.h then return false end
                    end
                end
                return true
            end
            local R = { x = 0, y = 0, w = 100, h = 100 }
            -- no overlap -> the whole rect back, untouched.
            local none = W.rectSubtract(R, { x = 200, y = 200, w = 50, h = 50 })
            ok(#none == 1 and area(none) == 10000, "rectSubtract: no overlap returns the whole rect")
            -- full cover -> nothing.
            ok(#W.rectSubtract(R, { x = -10, y = -10, w = 200, h = 200 }) == 0,
                "rectSubtract: full cover returns nothing")
            -- a bite out of one corner: remaining area = 100*100 - 40*40, disjoint.
            local corner = W.rectSubtract(R, { x = 60, y = 60, w = 80, h = 80 })   -- covers 60..100 sq
            ok(area(corner) == 10000 - 40 * 40 and disjoint(corner),
                "rectSubtract: a corner bite leaves the L-region (disjoint, exact area)")
            -- a middle vertical slice splits into left + right, disjoint.
            local slit = W.rectSubtract(R, { x = 40, y = -10, w = 20, h = 200 })
            ok(area(slit) == 10000 - 20 * 100 and disjoint(slit) and #slit == 2,
                "rectSubtract: a through-slice splits into two disjoint pieces")
            -- rectMinus over TWO overlapping fronts: the union is subtracted once
            -- (no double-count), result disjoint. Fronts overlap in [50,60]x[50,60].
            local vis = W.rectMinus(R, {
                { x = 50, y = 0, w = 60, h = 60 },    -- within R: x[50,100]xy[0,60]  = 50*60
                { x = 0, y = 50, w = 60, h = 60 },    -- within R: x[0,60]xy[50,100]  = 60*50
            })
            -- covered union = 3000 + 3000 - 100 (the 10x10 overlap counted once) = 5900.
            ok(area(vis) == 10000 - 5900 and disjoint(vis),
                "rectMinus: overlapping fronts subtract as a union (no double-count), disjoint")
        end
    end,
}
