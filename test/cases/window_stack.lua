-- test/cases/window_stack.lua -- window_stack (Auto Stack): a persistent window-
-- switcher MODE. Hyper+S gathers the focused screen's windows into the diamond-
-- ring stack, captures each original frame, and gives every window a PERSISTENT
-- colored border (the focused one bold). The borders STAY for the mode's life:
-- they re-anchor when a window moves (onFramesChanged) and re-style when focus
-- changes (onFocusChanged). Pressing again (or the "restore" action, or a
-- disable) LEAVES the mode -- tearing down every border + observer and restoring
-- each window to its captured frame (matched by stable wid across the id churn).
--
-- Covers the stackable predicate, the placement bijection, border PERSISTENCE
-- (no flash timer), frame tracking, focus highlight, the leave/restore paths,
-- restore across id churn, the alerts, and leave-on-disable cleanliness.
--
-- The geometric handle-exclusivity invariant is in windows_geometry.lua.

return {
    id = "window_stack",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry, W = t.ok, t.fake, t.registry, t.W
        local HYP = { "cmd", "alt", "ctrl" }

        registry.register(require("features.window_stack"))
        registry.setEnabled("window_stack", true)   -- service: start builds the controller

        local SCREEN  = { x = 0, y = 0, w = 1600, h = 1000, name = "Main", index = 1 }
        local SCREEN2 = { x = 1600, y = 0, w = 1280, h = 800, name = "Side", index = 2 }
        fake.screenList = { SCREEN, SCREEN2 }

        local ORIG = {
            [1] = { x = 300, y = 200, w = 900, h = 600 },
            [2] = { x = 100, y = 80,  w = 800, h = 700 },
            [3] = { x = 700, y = 300, w = 700, h = 500 },
            [4] = { x = 60,  y = 500, w = 500, h = 400 },
            [5] = { x = 800, y = 100, w = 600, h = 450 },
        }
        local function freshWindows()
            return {
                { id = 1, wid = 101, title = "Editor",  appName = "Code",   bundleID = "com.code", x = 300,  y = 200, w = 900,  h = 600 },
                { id = 2, wid = 102, title = "Browser", appName = "Safari", bundleID = "com.saf",  x = 100,  y = 80,  w = 800,  h = 700 },
                { id = 3, wid = 103, title = "Mail",    appName = "Mail",   bundleID = "com.mail", x = 700,  y = 300, w = 700,  h = 500 },
                { id = 4, wid = 104, title = "Notes",   appName = "Notes",  bundleID = "com.not",  x = 60,   y = 500, w = 500,  h = 400 },
                { id = 5, wid = 105, title = "Term",    appName = "Term",   bundleID = "com.term", x = 800,  y = 100, w = 600,  h = 450 },
                { id = 6, wid = 106, title = "Mini",    appName = "A",      bundleID = "com.a",    x = 200,  y = 200, w = 400,  h = 300, minimized = true },
                { id = 7, wid = 107, title = "Full",    appName = "B",      bundleID = "com.b",    x = 0,    y = 0,   w = 1600, h = 1000, fullscreen = true },
                { id = 8, wid = 108, title = "Other",   appName = "C",      bundleID = "com.c",    x = 1700, y = 100, w = 600,  h = 400 },
            }
        end
        fake.windows = freshWindows()
        fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
        fake.focusedWid = 101

        local function frameKey(f)
            return string.format("%.1f,%.1f,%.1f,%.1f", f.x, f.y, f.w, f.h)
        end
        local function sortedKeys(frames)
            local keys = {}
            for _, f in ipairs(frames) do keys[#keys + 1] = frameKey(f) end
            table.sort(keys)
            return table.concat(keys, "|")
        end
        local function frameOf(id)
            for _, w in ipairs(fake.windows) do if w.id == id then return w end end
        end
        local SLOTS = W.fanSlots(SCREEN, 5, 40, 8)   -- border-anchored slab fan (variable sizes)
        -- Border colors are dealt positionally at enter (wins order 101..105).
        local COLOR = { [101] = "#4C8DFF", [102] = "#34C759", [103] = "#FF9F0A",
                        [104] = "#AF52DE", [105] = "#FF375F" }
        local function borderFor(wid)
            for _, o in ipairs(fake.liveOutlines()) do
                if o.color == COLOR[wid] then return o end
            end
        end
        local function clipArea(o)                    -- total area of a border's clip rects
            local a = 0
            for _, r in ipairs(o.clip or {}) do a = a + r.w * r.h end
            return a
        end

        -- ===== ENTER the mode: placement, one raise pass, focus hand-back, and
        -- OCCLUSION-CORRECT borders -- each window's FULL frame, clipped to the
        -- part nothing in front covers. The frontmost (focused) window is a full,
        -- unclipped border; the ones behind are clipped to their visible region.
        do
            fake.pressHotkey("s", HYP)

            ok(#fake.windowFrameSets == 5, "five windows placed (excluded ones skipped)")
            ok(sortedKeys(fake.windowFrameSets) == sortedKeys(SLOTS), "placed frames == the fanSlots set")
            ok(#fake.raises == 5 and fake.raises[1] == 5 and fake.raises[5] == 1,
                "raise pass runs back-to-front (reversed MRU)")
            ok(fake.focused[#fake.focused] == 1, "focused window lifted last with a real focus")

            ok(#fake.liveOutlines() == 5, "five persistent borders, one per window")
            fake.fireTimers("after")          -- the 0.3s settle timer re-reads frames + re-clips
            ok(#fake.liveOutlines() == 5, "borders PERSIST across the settle pass (nothing clears them)")

            -- Each border spans its FULL slab frame -- the CLIP, not a shrunken
            -- frame, does the occlusion. (Sizes vary now: the fan is not uniform.)
            local sizes, spanOk = {}, true
            for _, s in ipairs(SLOTS) do sizes[s.w .. "x" .. s.h] = true end
            for _, o in ipairs(fake.liveOutlines()) do
                if not (o.frame and sizes[o.frame.w .. "x" .. o.frame.h]) then spanOk = false end
            end
            ok(spanOk, "every border spans a whole slab frame (occlusion is by clip)")

            -- The focused window (wid 101) is frontmost -> full unclipped border, bold, unfilled.
            local front = borderFor(101)
            ok(front ~= nil and front.kind == "focus", "the focused window's border is bold")
            ok(front.clipped == false and front.filled == false,
                "the frontmost (focused) border is full + unclipped + unfilled")

            -- Every window behind is clipped + filled, and REAL occlusion happens:
            -- the huge overlapping slots mean a behind-window's visible area is a
            -- fraction of its frame (proves the clip actually subtracts the front).
            local clippedCount, filledCount, trulyOccluded = 0, 0, 0
            for _, o in ipairs(fake.liveOutlines("member")) do
                if o.clipped then clippedCount = clippedCount + 1 end
                if o.filled then filledCount = filledCount + 1 end
                if o.clip and clipArea(o) < o.frame.w * o.frame.h - 1 then
                    trulyOccluded = trulyOccluded + 1
                end
            end
            ok(clippedCount == 4 and filledCount == 4,
                "the four windows behind are clipped to their visible region and filled")
            ok(trulyOccluded >= 1,
                "occlusion is real -- a behind-window's clip is smaller than its frame")
        end

        -- ===== FOCUS OFF-SCREEN: focusing a window on ANOTHER screen must NOT
        -- overlay the frontmost stacked window with a full-frame fill. A window
        -- that nothing ACTUALLY covers (the off-screen window is "in front" in
        -- z-order but doesn't overlap it) stays a full unfilled border.
        do
            table.insert(fake.windows, 1, { id = 900, wid = 999, title = "Other",
                appName = "Z", bundleID = "com.z", x = 1700, y = 100, w = 600, h = 400 })
            fake.focusedWid = 999          -- a window on screen 2, not in the stack
            fake.focusWindowChanged()
            local f101 = borderFor(101)    -- was frontmost on screen 1; nothing covers it
            ok(f101 ~= nil and f101.clipped == false and f101.filled == false,
                "off-screen focus leaves the uncovered stacked window a full UNFILLED border (no overlay)")
            -- restore state for the next block
            table.remove(fake.windows, 1)
            fake.focusedWid = 101
            fake.focusWindowChanged()
        end

        -- ===== FOCUS MOVES: clicking another window raises it to front; its border
        -- becomes the full unclipped one, the old front gets clipped behind it.
        do
            -- The OS raised Mail (103) to front: reorder the list so row 1 = 103.
            local reordered, mail = {}, nil
            for _, w in ipairs(fake.windows) do
                if w.wid == 103 then mail = w else reordered[#reordered + 1] = w end
            end
            table.insert(reordered, 1, mail)
            fake.windows = reordered
            fake.focusedWid = 103
            fake.focusWindowChanged()

            ok(#fake.liveOutlines("focus") == 1, "still exactly one bold (focused) border")
            local nf = borderFor(103)
            ok(nf ~= nil and nf.kind == "focus" and nf.clipped == false and nf.filled == false,
                "the newly-focused (now front) window has the full unclipped border")
            local of = borderFor(101)
            ok(of ~= nil and of.kind == "member" and of.clipped == true,
                "the previously-front window (101) is now a clipped member behind the new front")
        end

        -- ===== DYNAMICS: a stacked window CLOSES -> its border is pruned on the
        -- next focus refresh (no ghost border), and a NEW window that appears in
        -- FRONT clips the borders behind it (occlusion considers non-stacked
        -- windows too), while itself staying unbordered.
        do
            ok(#fake.liveOutlines() == 5, "five borders before the dynamics")
            -- Notes (104) closes: drop it from the list, and a brand-new window
            -- (wid 999, not in the stack) opens at the FRONT overlapping the pile.
            local kept = {}
            for _, w in ipairs(fake.windows) do
                if w.wid ~= 104 then kept[#kept + 1] = w end
            end
            table.insert(kept, 1, { id = 900, wid = 999, title = "New", appName = "X",
                bundleID = "com.x", x = 0, y = 0, w = 1600, h = 1000 })
            fake.windows = kept
            fake.focusedWid = 999
            fake.focusWindowChanged()

            ok(borderFor(104) == nil and #fake.liveOutlines() == 4,
                "the closed window's border is pruned (no ghost)")
            ok(#fake.liveOutlines() == 4, "the new front window is NOT auto-bordered")
            -- every remaining stacked window sits behind the full-screen newcomer,
            -- so all are clipped (nothing is the unclipped frontmost anymore).
            local anyUnclipped = false
            for _, o in ipairs(fake.liveOutlines()) do
                if o.clipped == false then anyUnclipped = true end
            end
            ok(not anyUnclipped,
                "the new window in front clips every stacked border (non-stacked occluder honored)")
        end

        -- ===== LEAVE (toggle off): borders + observers torn down, windows restored.
        do
            fake.focusedWid = 101
            fake.pressHotkey("s", HYP)
            ok(#fake.liveOutlines() == 0, "leaving tears down every border")
            local restoredOk = true
            for id, o in pairs(ORIG) do
                local w = frameOf(id)                     -- id 4 (104) was closed above -> skip
                if w and not (w.x == o.x and w.y == o.y and w.w == o.w and w.h == o.h) then
                    restoredOk = false
                end
            end
            ok(restoredOk, "every still-open window is back at its captured original frame")
            -- observers gone: a stray frame event now touches nothing (no crash, no border).
            fake.fireFrameEvent({ bundleID = "com.saf", wid = 102, x = 1, y = 1, w = 9, h = 9 })
            ok(#fake.liveOutlines() == 0, "the frame observer was stopped on leave")
        end

        -- ===== RESTORE MATCHES ACROSS ID CHURN via the menubar "restore" action.
        do
            fake.windows = freshWindows()
            fake.pressHotkey("s", HYP)                       -- enter
            for _, w in ipairs(fake.windows) do w.id = w.id + 100 end   -- ids churn, wids stable
            registry.runAction("window_stack", "restore")    -- the menubar click-to-quit
            local restoredOk = true
            for id, o in pairs(ORIG) do
                local w = frameOf(id + 100)
                if not (w and w.x == o.x and w.y == o.y) then restoredOk = false end
            end
            ok(restoredOk, "restore re-finds each window by stable wid, not id")
            ok(#fake.liveOutlines() == 0, "restore tore down the borders")
        end

        -- ===== EDGE-THICKNESS OPTION is read LIVE: changing it re-sizes the fan.
        do
            fake.windows = freshWindows()
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.settings["hammerdeck.opt.window_stack.edge"] = 64   -- thicker edge than the default 40
            local before = #fake.windowFrameSets
            fake.pressHotkey("s", HYP)                               -- enter with edge=64
            local placed = {}
            for i = before + 1, #fake.windowFrameSets do placed[#placed + 1] = fake.windowFrameSets[i] end
            ok(sortedKeys(placed) == sortedKeys(W.fanSlots(SCREEN, 5, 64, 8)),
                "the Edge thickness option is read live (edge=64 slabs, not the default 40)")
            fake.pressHotkey("s", HYP)                               -- leave
            fake.settings["hammerdeck.opt.window_stack.edge"] = nil  -- reset for later blocks
        end

        -- ===== FRACTIONAL SLOTS (regression for the %-format crash): a window
        -- count whose fan segments don't divide evenly gives non-integer slab
        -- dims. Entering must NOT throw, and the settle timer's realignment log
        -- must survive fractional slot values (both format sites fire here).
        do
            fake.windows = {}
            for i = 1, 9 do            -- 9 stackable -> T=3, segLen = 1504/3 = 501.33 (fractional)
                fake.windows[i] = { id = 300 + i, wid = 400 + i, title = "W" .. i,
                    appName = "App" .. i, bundleID = "com.w" .. i,
                    x = (i * 130) % 1300, y = (i * 90) % 700, w = 500, h = 400 }
            end
            fake.focusedWindow = { x = 0, y = 0, w = 500, h = 400, screenIndex = 1 }
            fake.focusedWid = 401
            fake.pressHotkey("s", HYP)                 -- enter log formats fractional margins
            ok(#fake.liveOutlines() == 9, "entered with 9 windows (fractional fan segments), no format crash")
            -- shift the ACTUAL frames off their slots so the settle callback logs a
            -- realignment -- its format runs on fractional slot dims.
            for _, w in ipairs(fake.windows) do w.x = w.x + 50 end
            fake.fireTimers("after")                   -- settle: realign log + re-clip, fractional-safe
            ok(#fake.liveOutlines() == 9, "the settle pass survives fractional slot dims (no format crash)")
            fake.pressHotkey("s", HYP)                 -- leave
        end

        -- ===== ALERTS: nothing stackable, and nothing to restore.
        do
            fake.windows = {}
            fake.focusedWindow = nil
            fake.focusedWid = nil
            fake.mousePos = { x = 100, y = 100 }
            local a = #fake.alerts
            fake.pressHotkey("s", HYP)
            ok(#fake.alerts == a + 1, "no stackable windows -> alert, not active")
            registry.runAction("window_stack", "restore")
            ok(#fake.alerts == a + 2, "restore with no live mode -> 'nothing' alert")
        end

        -- ===== LEAVE ON DISABLE: a live mode is torn down + restored on stop.
        do
            fake.windows = freshWindows()
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.pressHotkey("s", HYP)                        -- enter
            ok(#fake.liveOutlines() == 5 and frameOf(1).x ~= ORIG[1].x, "in the mode (bordered, moved)")
            registry.setEnabled("window_stack", false)        -- stop -> forceExit -> leave
            ok(#fake.liveOutlines() == 0, "disable tears down the borders")
            ok(frameOf(1).x == ORIG[1].x and frameOf(1).y == ORIG[1].y,
                "window 1 is back at its origin after the disable-restore")
        end

        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
            "clean after window_stack test (no leaked border or observer)")
    end,
}
