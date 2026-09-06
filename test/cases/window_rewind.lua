-- test/cases/window_rewind.lua -- window_rewind: single-step undo of the last window
-- LAYOUT change, recorded at the window_ops funnel (the seam window_snap/deck move
-- through), so a snap, a whole-display swap, or a deck retile is undoable by one
-- global Hyper+Z. Covers: by-id batch (swap) undo + pointer restore, focused-move
-- undo, disable clears history, and an unrecordable move not clobbering the prior group.
--
-- Migrated from run.lua T24r (RUN_LUA_SPLIT_SPEC Phase 2). window_snap is the real
-- mover (window_rewind only records + restores), so the case registers BOTH (T24r
-- leaned on T24's window_snap registration). freshWorld() gives the clean input slate
-- T24r's fake.reset() used to; the handle tripwire keeps it isolated.

return {
    id = "window_rewind",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry, AC = t.ok, t.fake, t.registry, t.AC

        registry.register(require("features.window_snap"))
        registry.register(require("features.window_rewind"))
        registry.setEnabled("window_rewind", true)   -- start(ctx) turns recording on
        registry.setEnabled("window_snap", true)     -- a real mover to generate history

        -- (a) BY-ID batch: a two-display swap fires many setFrameFor in one synchronous
        -- loop -> ONE undo group. Undo restores every moved window to its pre-swap frame
        -- AND the pointer to where it was when the swap began. (Keys on the STABLE wid,
        -- re-resolved to a live id at undo time -- the ids-only-valid-until-next-list rule.)
        do
            fake.screenList = {
                { x = 0,    y = 0, w = 1000, h = 800 },      -- A
                { x = 1000, y = 0, w = 2000, h = 1200 },     -- B (bigger)
            }
            fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 } -- active = A
            fake.windows = {
                { id = 11, wid = 111, x = 100,  y = 100, w = 400, h = 300 },   -- on A -> moves to B
                { id = 12, wid = 222, x = 1200, y = 150, w = 600, h = 450 },   -- on B -> moves to A
            }
            fake.mousePos = { x = 150, y = 200 }         -- captured at group start
            local A = { x = 100,  y = 100, w = 400, h = 300 }
            local B = { x = 1200, y = 150, w = 600, h = 450 }

            assert(registry.runAction("window_snap", "swap_screens"))
            ok(fake.windows[1].x ~= A.x, "precondition: the swap actually moved the windows")

            fake.mousePos = { x = 999, y = 999 }         -- user drifts the pointer after the swap
            fake.windowFrameSets = {}
            assert(registry.runAction("window_rewind", "undo"))
            ok(#fake.windowFrameSets == 2, "undo moved back exactly the two swapped windows")
            ok(fake.windows[1].x == A.x and fake.windows[1].y == A.y
                and fake.windows[1].w == A.w and fake.windows[1].h == A.h,
                "window A restored to its pre-swap frame")
            ok(fake.windows[2].x == B.x and fake.windows[2].y == B.y
                and fake.windows[2].w == B.w and fake.windows[2].h == B.h,
                "window B restored to its pre-swap frame")
            ok(fake.mousePos.x == 150 and fake.mousePos.y == 200,
                "undo returns the pointer to the group-start position")

            fake.windowFrameSets = {}
            assert(registry.runAction("window_rewind", "undo"))
            ok(#fake.windowFrameSets == 0, "single-step: a second undo is a no-op (the group was consumed)")
        end

        -- (b) FOCUSED move: recorded via focusedWindowFrame()+focusedWindowWid() (no
        -- list() -- that path must never rebuild the AX cache mid-batch), restored by
        -- re-resolving the stored wid to a live id. The prior group was consumed by (a)'s
        -- undo, so this snap starts a fresh group.
        do
            fake.screenList = { { x = 0, y = 0, w = 1000, h = 800 } }
            fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
            fake.focusedWid = 111
            fake.windows = { { id = 11, wid = 111, x = 100, y = 100, w = 400, h = 300 } }
            fake.pressHotkey("left", AC)                  -- window_snap "left" -> focused {0,0,500,800}
            ok(fake.focusedWindow.x == 0 and fake.focusedWindow.w == 500,
                "precondition: the snap moved the focused window")
            -- The fake keeps the window LIST and the focused frame in separate stores;
            -- mirror what a real listWindows() would now report (the moved frame) so undo's
            -- re-list resolves wid 111 to id 11.
            fake.windows = { { id = 11, wid = 111, x = 0, y = 0, w = 500, h = 800 } }
            fake.windowFrameSets = {}
            assert(registry.runAction("window_rewind", "undo"))
            ok(#fake.windowFrameSets == 1
                and fake.windows[1].x == 100 and fake.windows[1].y == 100
                and fake.windows[1].w == 400 and fake.windows[1].h == 300,
                "undo restores a focused snap to its pre-snap frame")
        end

        -- disabling window_rewind clears any pending history (nothing to undo afterward)
        do
            fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
            fake.focusedWid = 111
            fake.windows = { { id = 11, wid = 111, x = 100, y = 100, w = 400, h = 300 } }
            fake.pressHotkey("left", AC)                  -- record a change...
            registry.setEnabled("window_rewind", false)   -- ...then disable: history is cleared
            registry.setEnabled("window_rewind", true)
            fake.windowFrameSets = {}
            assert(registry.runAction("window_rewind", "undo"))
            ok(#fake.windowFrameSets == 0, "disabling window_rewind clears pending history")
        end

        -- (d) a move we CAN'T record (unresolvable window id, a fresh action >1s later)
        -- must NOT clobber the still-valid prior undo group into an empty one -- the
        -- earlier change stays undoable. (Without the record-side guard, the id-less move
        -- would replace the pending group with an empty one and undo would restore
        -- nothing.)
        do
            fake.screenList = { { x = 0, y = 0, w = 1000, h = 800 } }
            fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
            fake.focusedWid = 111
            fake.windows = { { id = 11, wid = 111, x = 100, y = 100, w = 400, h = 300 } }
            fake.pressHotkey("left", AC)                  -- group A: before-frame {100,100,400,300}
            ok(fake.focusedWindow.x == 0 and fake.focusedWindow.w == 500,
                "precondition: the first snap moved and recorded the window")
            fake.clockOffset = fake.clockOffset + 2       -- a fresh action window (>GAP)
            fake.focusedWid = 0                            -- unresolvable id: this move can't be recorded
            fake.pressHotkey("right", AC)                 -- moves via AX, but records nothing
            fake.focusedWid = 111
            fake.windows = { { id = 11, wid = 111, x = 500, y = 0, w = 500, h = 800 } }  -- mirror the moved frame
            fake.windowFrameSets = {}
            assert(registry.runAction("window_rewind", "undo"))
            ok(#fake.windowFrameSets == 1
                and fake.windows[1].x == 100 and fake.windows[1].y == 100
                and fake.windows[1].w == 400 and fake.windows[1].h == 300,
                "an unrecordable move does not clobber the prior undo group (it still restores)")
        end

        -- (e) W-16: the skip gate is a MEMBERSHIP test, and it must answer the same
        -- way platform.windows does. A window parked over the Dock sits outside its
        -- screen row's VISIBLE rect but inside the FULL one -- it is plainly on that
        -- display, and listWindows labels it so. Read against the visible rect it
        -- resolved to "on no connected display", so undo silently dropped it: a
        -- smaller restored count and a window that never comes back.
        --
        -- The test drives undoLast, not the predicate: the defect was in which
        -- question the gate asked, so an assertion on W.onScreen alone would have
        -- passed against the pre-fix code (window_history had its own copy).
        do
            fake.clockOffset = fake.clockOffset + 2       -- a fresh group
            fake.screenList = {
                { x = 0, y = 37, w = 2560, h = 1318, index = 1,
                  full = { x = 0, y = 0, w = 2560, h = 1440 } },
            }
            -- Centre y = 1370: past the visible frame's 1355 bottom, inside the
            -- full frame's 1440. The Dock strip, in other words.
            local dockside = { x = 600, y = 1290, w = 420, h = 160 }
            fake.focusedWindow = { x = dockside.x, y = dockside.y, w = dockside.w,
                                   h = dockside.h, screenIndex = 1 }
            fake.focusedWid = 333
            fake.windows = { { id = 33, wid = 333, x = dockside.x, y = dockside.y,
                               w = dockside.w, h = dockside.h } }
            fake.pressHotkey("left", AC)                 -- snap it away from the Dock
            ok(fake.focusedWindow.x == 0 and fake.focusedWindow.y == 37,
                "precondition: the snap moved the dock-side window onto the visible frame")
            fake.windows = { { id = 33, wid = 333, x = 0, y = 37, w = 1280, h = 1318 } }
            fake.windowFrameSets = {}
            assert(registry.runAction("window_rewind", "undo"))
            ok(#fake.windowFrameSets == 1
                and fake.windows[1].x == dockside.x and fake.windows[1].y == dockside.y
                and fake.windows[1].w == dockside.w and fake.windows[1].h == dockside.h,
                "undo restores a window whose before-frame sat over the Dock (W-16)")
        end

        fake.focusedWid = nil
        registry.setEnabled("window_snap", false)
        registry.setEnabled("window_rewind", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after window_rewind test")
    end,
}
