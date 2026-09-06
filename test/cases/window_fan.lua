-- test/cases/window_fan.lua -- window_fan (Window Fan): a persistent window-
-- switcher MODE. Hyper+F gathers the focused screen's windows into the border-
-- anchored slab FAN, captures each original frame, and gives every window a
-- PERSISTENT colored border (the focused one bold). The borders STAY for the
-- mode's life: they re-anchor when a window moves (onFramesChanged) and re-style
-- when focus changes (onFocusChanged). The fan stays COMPLETE: a window that
-- opens (focus path) or is dragged in (poll path) is TAKEN into the fan, and a
-- closed / moved-out window is dropped and the survivors re-fan. Pressing again
-- (or the menubar toggle, or a disable) LEAVES the mode -- tearing down every
-- border + observer and restoring each window to its captured frame (matched by
-- stable wid across the id churn).
--
-- Covers the fannable predicate, the placement bijection, border PERSISTENCE
-- (no flash timer), frame tracking, focus highlight, AUTO-REFAN on both the
-- focus and poll paths, the leave/restore paths, restore across id churn, the
-- alerts, and leave-on-disable cleanliness.
--
-- The geometric handle-exclusivity invariant is in windows_geometry.lua.

return {
    id = "window_fan",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry, W = t.ok, t.fake, t.registry, t.W
        local HYP = { "cmd", "alt", "ctrl" }

        registry.register(require("features.window_fan"))
        registry.setEnabled("window_fan", true)   -- service: start builds the controller

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
        -- Identify a window's border by FRAME match: place() sets the window's frame
        -- AND its border overlay to the same slot, so the border at a window's frame
        -- is that window's. Robust to color REUSE across re-fans (color is no longer a
        -- stable per-window key -- a closed window's color is recycled to a newcomer).
        local function borderFor(wid)
            local w
            for _, ww in ipairs(fake.windows) do if ww.wid == wid then w = ww end end
            if not w then return nil end
            for _, o in ipairs(fake.liveOutlines()) do
                if o.frame and o.frame.x == w.x and o.frame.y == w.y
                   and o.frame.w == w.w and o.frame.h == w.h then return o end
            end
            return nil
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
            fake.pressHotkey("f", HYP)

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
        -- overlay the frontmost fanned window with a full-frame fill. A window
        -- that nothing ACTUALLY covers (the off-screen window is "in front" in
        -- z-order but doesn't overlap it) stays a full unfilled border.
        do
            table.insert(fake.windows, 1, { id = 900, wid = 999, title = "Other",
                appName = "Z", bundleID = "com.z", x = 1700, y = 100, w = 600, h = 400 })
            fake.focusedWid = 999          -- a window on screen 2, not in the fan
            fake.focusWindowChanged()
            local f101 = borderFor(101)    -- was frontmost on screen 1; nothing covers it
            ok(f101 ~= nil and f101.clipped == false and f101.filled == false,
                "off-screen focus leaves the uncovered fanned window a full UNFILLED border (no overlay)")
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

        -- ===== FOCUS RACE (mode still active from above): switching to a window
        -- RAISES it, but the CGWindow z-order read can LAG the raise -- listing the
        -- focused window BEHIND one it is actually above, which used to clip its
        -- (bold) border to a sliver. The focused window is hoisted to the front of
        -- the occlusion order, so it draws FULL regardless of read timing. Here we
        -- focus wid 104 WITHOUT reordering the list (the stale-read case).
        do
            fake.focusedWid = 104
            fake.focusWindowChanged()
            local f = borderFor(104)
            ok(f ~= nil and f.kind == "focus", "the switched-to window's border is bold")
            ok(f and f.clipped == false and f.filled == false,
                "the focused window draws a FULL border even when the z-order read lags the raise")
            -- restore the focus to the current front (103) so the next block is unchanged
            fake.focusedWid = 103
            fake.focusWindowChanged()
        end

        -- ===== AUTO-REFAN (focus path): a fanned window CLOSES and a NEW window
        -- OPENS on the screen (taking focus). The mode keeps every window grabbable,
        -- so the whole screen re-fans: the closed window's border is pruned, and the
        -- newcomer is TAKEN into the fan (bordered, moved onto a slab), never left
        -- floating unbordered.
        do
            ok(#fake.liveOutlines() == 5, "five borders before the dynamics")
            local SLOTS5 = W.fanSlots(SCREEN, 5, 40, 8)

            -- Notes (104) closes; a brand-new sized window (wid 999) opens on screen
            -- 1 at the front and takes focus.
            local kept = {}
            for _, w in ipairs(fake.windows) do
                if w.wid ~= 104 then kept[#kept + 1] = w end
            end
            table.insert(kept, 1, { id = 900, wid = 999, title = "New", appName = "X",
                bundleID = "com.x", x = 200, y = 150, w = 700, h = 500 })
            fake.windows = kept
            fake.focusedWid = 999
            local before = #fake.windowFrameSets
            fake.focusWindowChanged()

            ok(borderFor(104) == nil, "the closed window's border is pruned (no ghost)")
            ok(#fake.liveOutlines() == 5,
                "the newcomer replaced the closed window -- still five bordered windows")
            -- the whole screen re-fanned to the five slots (survivors re-placed,
            -- newcomer moved onto a slab).
            local placed = {}
            for i = before + 1, #fake.windowFrameSets do placed[#placed + 1] = fake.windowFrameSets[i] end
            ok(sortedKeys(placed) == sortedKeys(SLOTS5),
                "the screen re-fanned to five slots (newcomer taken in, survivors re-placed)")
            local n, onASlot = frameOf(900), false
            for _, s in ipairs(SLOTS5) do
                if n.x == s.x and n.y == s.y and n.w == s.w and n.h == s.h then onASlot = true end
            end
            ok(onASlot, "the newly-opened window sits on a fan slot (auto-taken into the fan)")
        end

        -- ===== LEAVE (toggle off): borders + observers torn down, windows restored.
        do
            fake.focusedWid = 101
            fake.pressHotkey("f", HYP)
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

        -- ===== RESTORE MATCHES ACROSS ID CHURN via the menubar toggle action
        -- (clicking "Fan windows" in the menubar while the mode is on exits it --
        -- the toggle IS the menubar click-to-quit; there is no separate action).
        do
            fake.windows = freshWindows()
            fake.pressHotkey("f", HYP)                       -- enter
            for _, w in ipairs(fake.windows) do w.id = w.id + 100 end   -- ids churn, wids stable
            registry.runAction("window_fan", "arrange")    -- the menubar click-to-quit
            local restoredOk = true
            for id, o in pairs(ORIG) do
                local w = frameOf(id + 100)
                if not (w and w.x == o.x and w.y == o.y) then restoredOk = false end
            end
            ok(restoredOk, "restore re-finds each window by stable wid, not id")
            ok(#fake.liveOutlines() == 0, "restore tore down the borders")
        end

        -- ===== AN APP THAT GOES QUIET UNDER AX IS NOT A CLOSED WINDOW.
        -- A window missing from a listing is ambiguous: closed, or its app just
        -- missed the AX messaging timeout. Reading the second as the first is
        -- DESTRUCTIVE -- it frees the captured original, and when the app answers
        -- again the window is re-captured from the SLAB it is sitting in, so leaving
        -- the mode "restores" it to the slab and the real geometry is lost for good.
        -- That shipped, and fired routinely (a 0.3s AX ceiling was dropping nine
        -- apps from every listing). ctx.window.droppedApps() is what disambiguates.
        do
            fake.windows = freshWindows()
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.pressHotkey("f", HYP)                 -- enter (5 windows)
            ok(#fake.liveOutlines() == 5, "entered with five windows")

            -- Safari (wid 102) is now sitting on a slab -- setFrameFor mutates the
            -- live rows, so this IS what a listing would report for it.
            local slab
            for _, w in ipairs(fake.windows) do
                if w.wid == 102 then slab = { x = w.x, y = w.y, w = w.w, h = w.h } end
            end
            ok(slab ~= nil and not (slab.x == ORIG[2].x and slab.y == ORIG[2].y),
                "Safari was moved onto a slab (its slab frame differs from its original)")

            -- Safari's app goes QUIET: its windows vanish from the listing, and the
            -- seam reports the app as dropped rather than the window as gone.
            local kept = {}
            for _, w in ipairs(fake.windows) do
                if w.wid ~= 102 then kept[#kept + 1] = w end
            end
            fake.windows = kept
            fake.droppedApps = { "com.saf" }
            fake.activateApp("Mail", "com.mail")       -- membership changed -> refan

            -- The survivors must NOT re-tile: 102's slot stays RESERVED, so the fan
            -- is still the five-slot geometry and nobody else budged.
            local stillOnFive = true
            for _, w in ipairs(fake.windows) do
                if w.wid ~= 108 and not w.minimized and not w.fullscreen then
                    local onSlot = false
                    for _, s in ipairs(SLOTS) do
                        if w.x == s.x and w.y == s.y and w.w == s.w and w.h == s.h then
                            onSlot = true
                        end
                    end
                    if not onSlot then stillOnFive = false end
                end
            end
            ok(stillOnFive,
                "an app going quiet reserves its slot -- the other windows do not re-tile")

            -- Safari answers again, reporting the SLAB frame it was left on. A
            -- re-capture here is exactly how the original used to be destroyed.
            table.insert(fake.windows, 2, { id = 2, wid = 102, title = "Browser",
                appName = "Safari", bundleID = "com.saf",
                x = slab.x, y = slab.y, w = slab.w, h = slab.h })
            fake.droppedApps = {}
            fake.activateApp("Safari", "com.saf")      -- reclaims the reserved slot

            fake.pressHotkey("f", HYP)                 -- leave -> restore
            local back = frameOf(2)
            ok(back and back.x == ORIG[2].x and back.y == ORIG[2].y
               and back.w == ORIG[2].w and back.h == ORIG[2].h,
                "a window whose app went quiet still restores to its TRUE original, not the slab")

            fake.droppedApps = {}
            fake.windows = freshWindows()
        end

        -- ===== A CAPTURED ORIGINAL IS NEVER DISCARDED WHILE THE MODE IS LIVE.
        -- droppedApps explains the AX case, but absence has causes it CANNOT
        -- classify -- above all a Space switch: CGWindowList is Space-scoped, so
        -- every window on another Space reads as absent while its app still answers
        -- fine. That lands in the "closed" branch, so freeing the original there
        -- would lose the real geometry by a different route than the AX one. The
        -- slot/colour are recycled (the fan re-tiles densely); the original is kept.
        do
            fake.windows = freshWindows()
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.pressHotkey("f", HYP)                 -- enter (5 windows)

            local slab
            for _, w in ipairs(fake.windows) do
                if w.wid == 103 then slab = { x = w.x, y = w.y, w = w.w, h = w.h } end
            end

            -- Mail (103) leaves for another Space: absent from the listing, and its
            -- app is NOT reported dropped (nothing timed out).
            local kept = {}
            for _, w in ipairs(fake.windows) do
                if w.wid ~= 103 then kept[#kept + 1] = w end
            end
            fake.windows = kept
            fake.droppedApps = {}
            fake.activateApp("Notes", "com.not")       -- membership changed -> refan

            -- It comes back on this Space, reporting the slab frame it was left on.
            table.insert(fake.windows, 3, { id = 3, wid = 103, title = "Mail",
                appName = "Mail", bundleID = "com.mail",
                x = slab.x, y = slab.y, w = slab.w, h = slab.h })
            fake.activateApp("Mail", "com.mail")
            fake.pressHotkey("f", HYP)                 -- leave -> restore

            local back = frameOf(3)
            ok(back and back.x == ORIG[3].x and back.y == ORIG[3].y
               and back.w == ORIG[3].w and back.h == ORIG[3].h,
                "a window absent for an unclassifiable reason (a Space switch) still restores to its TRUE original")

            fake.droppedApps = {}
            fake.windows = freshWindows()
        end

        -- ===== EDGE-THICKNESS OPTION is read LIVE: changing it re-sizes the fan.
        do
            fake.windows = freshWindows()
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.settings["hammerdeck.opt.window_fan.edge"] = 64   -- thicker edge than the default 40
            local before = #fake.windowFrameSets
            fake.pressHotkey("f", HYP)                               -- enter with edge=64
            local placed = {}
            for i = before + 1, #fake.windowFrameSets do placed[#placed + 1] = fake.windowFrameSets[i] end
            ok(sortedKeys(placed) == sortedKeys(W.fanSlots(SCREEN, 5, 64, 8)),
                "the Edge thickness option is read live (edge=64 slabs, not the default 40)")
            fake.pressHotkey("f", HYP)                               -- leave
            fake.settings["hammerdeck.opt.window_fan.edge"] = nil  -- reset for later blocks
        end

        -- ===== AUTO-REFAN (event path, no poll): a NEW app's window activates its
        -- app -- an instant membership trigger with no focus dependency. Add a sized
        -- window on the screen and fire onAppActivated; it must be taken in WITHOUT
        -- ticking the reconcile poll. Also proves activating an OFF-screen app (a
        -- plain app switch, no set change) does NOT re-fan.
        do
            fake.windows = freshWindows()
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.pressHotkey("f", HYP)                 -- enter (5 windows)
            ok(#fake.liveOutlines() == 5, "entered with five windows")

            -- a new app opens a window on screen 1 and its app activates (no focus
            -- pulse, no poll tick).
            table.insert(fake.windows, 1, { id = 10, wid = 110, title = "Fresh", appName = "X",
                bundleID = "com.x", x = 300, y = 300, w = 600, h = 450 })
            local before = #fake.windowFrameSets
            fake.activateApp("X", "com.x")             -- onAppActivated -> reconcile

            ok(#fake.liveOutlines() == 6, "the app-activation event took the new window into the fan")
            ok(before < #fake.windowFrameSets, "the event re-fanned the screen (no poll needed)")
            local SLOTS6 = W.fanSlots(SCREEN, 6, 40, 8)
            local n, onASlot = frameOf(10), false
            for _, s in ipairs(SLOTS6) do
                if n.x == s.x and n.y == s.y and n.w == s.w and n.h == s.h then onASlot = true end
            end
            ok(onASlot, "the new window sits on a six-window fan slot")

            -- switching to an app whose windows are NOT on this screen: no set change.
            local steady = #fake.windowFrameSets
            fake.activateApp("Other", "com.other")
            ok(#fake.windowFrameSets == steady, "activating an off-screen app does not re-fan (no set change)")
            fake.pressHotkey("f", HYP)                 -- leave
        end

        -- ===== CROSS-APP FOCUS FOLLOWS (regression): switching focus to ANOTHER
        -- app's window (SAME member set, so NOT a re-fan) reaches us ONLY as an
        -- app-activation -- the focused-window observer sees within-app switches
        -- only. The bold border + widget highlight must follow focus across apps.
        -- Before the fix, onAppActivated was membership-only, so the highlight stuck
        -- on the last window whenever focus crossed apps (the reported "our own app
        -- is special, focus not detected" bug).
        do
            fake.windows = freshWindows()
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.pressHotkey("f", HYP)                 -- enter (5 windows), focus on 101
            ok(borderFor(101) and borderFor(101).kind == "focus",
                "the initially-focused window (101, app 'Code') is bold")

            -- The user CLICKS Mail's window (wid 103, a DIFFERENT app): the OS raised
            -- it, so reorder row 1 = 103, point focus at it, and fire ONLY the
            -- app-activation (a cross-app switch fires no within-app focus pulse).
            local reordered, mail = {}, nil
            for _, w in ipairs(fake.windows) do
                if w.wid == 103 then mail = w else reordered[#reordered + 1] = w end
            end
            table.insert(reordered, 1, mail)
            fake.windows = reordered
            fake.focusedWid = 103
            local before = #fake.windowFrameSets
            fake.activateApp("Mail", "com.mail")       -- cross-app switch, SAME set

            ok(#fake.windowFrameSets == before, "no re-fan (the member set did not change)")
            ok(#fake.liveOutlines("focus") == 1, "still exactly one bold (focused) border")
            ok(borderFor(103) and borderFor(103).kind == "focus",
                "the cross-app focus moved the bold border to the newly-focused window")
            ok(borderFor(101) and borderFor(101).kind == "member",
                "the previously-focused window is no longer bold")
            local wdg = fake.liveFanWidget()
            local focusedTitle
            for _, r in ipairs(wdg.rows) do if r.focused then focusedTitle = r.title end end
            ok(focusedTitle == "Mail",
                "the widget highlight followed focus across apps (Mail, not the stale Editor)")
            fake.pressHotkey("f", HYP)                 -- leave
        end

        -- ===== UNRESOLVED FOCUS ON ACTIVATION (regression for the 0-clobber):
        -- activating a WINDOWLESS / menubar app resolves focusedWid to 0. syncFocus
        -- must NOT clear the highlight with that 0 -- there is no self-heal (the poll
        -- never re-reads focus, activation fires no focus pulse), so it keeps the last
        -- known focus, matching place()/refan()'s "0 = don't trust" rule. (A real
        -- non-member focus, wid ~= 0, still clears it -- covered by the block above.)
        do
            fake.windows = freshWindows()
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.pressHotkey("f", HYP)                 -- enter (5 windows), focus on 101
            ok(borderFor(101) and borderFor(101).kind == "focus",
                "the focused window (101) is bold before the windowless-app switch")

            -- a windowless app activates: focus is UNRESOLVED (wid 0), same window set.
            fake.focusedWid = 0
            local before = #fake.windowFrameSets
            fake.activateApp("Menubar", "com.menubar")

            ok(#fake.windowFrameSets == before, "no re-fan (the member set did not change)")
            ok(#fake.liveOutlines("focus") == 1 and borderFor(101) and borderFor(101).kind == "focus",
                "an unresolved (0) focus KEEPS the last highlight, it does not clear it")
            fake.pressHotkey("f", HYP)                 -- leave
        end

        -- ===== FOCUS SELF-HEAL (regression for the "focused window is tinted" bug):
        -- a cross-app click RAISES the clicked window (z-order shows it front), but
        -- the app-activation can fire BEFORE the new app's AX focused window resolves,
        -- so focusedWid races to 0. syncFocus keeps the STALE focus and refreshFromList
        -- HOISTS it over the real front -- so the window the user just focused is drawn
        -- as a clipped, TINTED member (not bold), exactly as reported. A short deferred
        -- re-read (fired here via the "after" timer once AX settles) must CONVERGE: the
        -- real front becomes bold + unfilled + unclipped, the stale one a plain member.
        do
            fake.windows = freshWindows()
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.pressHotkey("f", HYP)                 -- enter (5 windows), focus 101
            ok(borderFor(101) and borderFor(101).kind == "focus", "101 bold on enter")

            -- The user clicks Mail (103, another app): the OS raised it, so z-order
            -- row 1 = 103 -- but the new app's AX focus is not yet readable, so the
            -- activation resolves focusedWid to 0 (the race).
            local reordered, mail = {}, nil
            for _, w in ipairs(fake.windows) do
                if w.wid == 103 then mail = w else reordered[#reordered + 1] = w end
            end
            table.insert(reordered, 1, mail)
            fake.windows = reordered
            fake.focusedWid = 0                        -- unresolved at activation time
            fake.activateApp("Mail", "com.mail")       -- cross-app switch, SAME set

            -- Immediate pass: stale focus (101) is kept and hoisted over the real
            -- front (103), so 103 is drawn as a plain (non-bold) member -- the bug.
            ok(borderFor(103) and borderFor(103).kind == "member",
                "pre-heal: the real front is wrongly a plain member (stale focus hoisted over it)")

            -- AX settles: the deferred re-read now resolves focus to 103.
            fake.focusedWid = 103
            fake.fireTimers("after")                   -- the deferred focus re-read
            local m = borderFor(103)
            ok(m and m.kind == "focus" and m.filled == false and m.clipped == false,
                "the deferred re-read heals it: the real front is bold + unfilled (not tinted)")
            ok(borderFor(101) and borderFor(101).kind == "member",
                "the previously-focused window is no longer bold after the heal")
            fake.pressHotkey("f", HYP)                 -- leave
        end

        -- ===== AUTO-REFAN (loose poll backstop): a window DRAGGED in from another
        -- screen COMPLETES with no activation/focus pulse -- an AX window-move on an
        -- app we may not observe. The reconcile poll is the sole backstop for it. Add
        -- a sized window WITHOUT firing any event, tick the poll, and it is taken in.
        do
            fake.windows = freshWindows()
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.pressHotkey("f", HYP)                 -- enter (5 windows)
            ok(#fake.liveOutlines() == 5, "entered with five windows")

            -- a window finishes a drag onto screen 1 -- no focus and no app-activation.
            table.insert(fake.windows, { id = 9, wid = 109, title = "Dragged", appName = "D",
                bundleID = "com.d", x = 250, y = 250, w = 600, h = 450 })
            ok(#fake.liveOutlines() == 5, "before the poll tick the silent drag-in is not yet taken")
            local before = #fake.windowFrameSets
            fake.fireTimers("every", 2.0)              -- the loose reconcile poll

            ok(#fake.liveOutlines() == 6, "the poll took the dragged-in window into the fan")
            ok(before < #fake.windowFrameSets, "the poll re-fanned the screen")
            local SLOTS6 = W.fanSlots(SCREEN, 6, 40, 8)
            local d, onASlot = frameOf(9), false
            for _, s in ipairs(SLOTS6) do
                if d.x == s.x and d.y == s.y and d.w == s.w and d.h == s.h then onASlot = true end
            end
            ok(onASlot, "the dragged-in window sits on a six-window fan slot")

            -- a steady poll with no set change must NOT re-fan.
            local steady = #fake.windowFrameSets
            fake.fireTimers("every", 2.0)
            ok(#fake.windowFrameSets == steady, "a steady poll with no set change does not re-fan")
            fake.pressHotkey("f", HYP)                 -- leave
        end

        -- ===== MOVE OUT AND BACK: a window dragged to ANOTHER screen RESERVES its
        -- slot, color, and captured original -- moving it back reclaims the EXACT
        -- slab and color, and the OTHER windows never move. (Regression: the old code
        -- re-shuffled everyone via assignNearest and dealt the returning window a
        -- fresh monotonic color that eventually collided with a live one.)
        do
            fake.windows = freshWindows()
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.pressHotkey("f", HYP)                 -- enter (5 windows)

            local aSlot  = { frameOf(3).x, frameOf(3).y, frameOf(3).w, frameOf(3).h }  -- wid 103's slab
            local aColor = borderFor(103).color
            local others = { 1, 2, 4, 5 }             -- the four that must NOT move
            local otherSlabs = {}
            for _, id in ipairs(others) do
                local w = frameOf(id); otherSlabs[id] = { w.x, w.y, w.w, w.h }
            end

            -- drag window 103 to screen 2 (off SCREEN); it still EXISTS in the list.
            local a = frameOf(3); a.x, a.y = 1800, 120
            fake.fireTimers("every", 2.0)              -- poll -> reconcile -> reserve 103's slot

            ok(borderFor(103) == nil, "the moved-out window's border is dropped")
            ok(#fake.liveOutlines() == 4, "four borders remain (the fifth slot is reserved, a hole)")
            local undisturbed = true
            for _, id in ipairs(others) do
                local w, s = frameOf(id), otherSlabs[id]
                if not (w.x == s[1] and w.y == s[2] and w.w == s[3] and w.h == s[4]) then undisturbed = false end
            end
            ok(undisturbed, "the OTHER windows did not move when one left (slot reserved, no re-tile)")

            -- drag 103 back onto screen 1 -- to a DIFFERENT spot than its true
            -- original (700,300), so a bug that re-captured the original on return
            -- would restore to the wrong place and the final assertion would catch it.
            a.x, a.y = 500, 400
            fake.fireTimers("every", 2.0)              -- poll -> reconcile -> reclaim 103's slot

            ok(#fake.liveOutlines() == 5, "the returned window is taken back into the fan")
            local back = frameOf(3)
            ok(back.x == aSlot[1] and back.y == aSlot[2] and back.w == aSlot[3] and back.h == aSlot[4],
                "the returned window reclaims its EXACT original slab")
            ok(borderFor(103) and borderFor(103).color == aColor,
                "the returned window keeps its original border color (no conflict)")
            local stillOk = true
            for _, id in ipairs(others) do
                local w, s = frameOf(id), otherSlabs[id]
                if not (w.x == s[1] and w.y == s[2] and w.w == s[3] and w.h == s[4]) then stillOk = false end
            end
            ok(stillOk, "the OTHER windows STILL did not move when it returned")

            -- leaving restores 103 to its TRUE pre-stack original (reserved through the trip).
            fake.pressHotkey("f", HYP)
            ok(frameOf(3).x == ORIG[3].x and frameOf(3).y == ORIG[3].y,
                "leaving restores the round-tripped window to its true original position")
        end

        -- ===== FRACTIONAL SLOTS (regression for the %-format crash): a window
        -- count whose fan segments don't divide evenly gives non-integer slab
        -- dims. Entering must NOT throw, and the settle timer's realignment log
        -- must survive fractional slot values (both format sites fire here).
        do
            fake.windows = {}
            for i = 1, 9 do            -- 9 fannable -> T=3, segLen = 1504/3 = 501.33 (fractional)
                fake.windows[i] = { id = 300 + i, wid = 400 + i, title = "W" .. i,
                    appName = "App" .. i, bundleID = "com.w" .. i,
                    x = (i * 130) % 1300, y = (i * 90) % 700, w = 500, h = 400 }
            end
            fake.focusedWindow = { x = 0, y = 0, w = 500, h = 400, screenIndex = 1 }
            fake.focusedWid = 401
            fake.pressHotkey("f", HYP)                 -- enter log formats fractional margins
            ok(#fake.liveOutlines() == 9, "entered with 9 windows (fractional fan segments), no format crash")
            -- shift the ACTUAL frames off their slots so the settle callback logs a
            -- realignment -- its format runs on fractional slot dims.
            for _, w in ipairs(fake.windows) do w.x = w.x + 50 end
            fake.fireTimers("after")                   -- settle: realign log + re-clip, fractional-safe
            ok(#fake.liveOutlines() == 9, "the settle pass survives fractional slot dims (no format crash)")
            fake.pressHotkey("f", HYP)                 -- leave
        end

        -- ===== SWITCHER WIDGET: a draggable card listing the fan's windows -- a row
        -- per window (border color + the EDGE it exposes + title + icon), the focused
        -- one flagged. Clicking a row focuses that window; Exit leaves the mode; the
        -- rows track membership. Opt-out via the "widget" option.
        do
            fake.windows = freshWindows()
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.pressHotkey("f", HYP)                 -- enter (5 windows)

            local wdg = fake.liveFanWidget()
            ok(wdg ~= nil, "the switcher widget is shown on enter")
            ok(wdg and #wdg.rows == 5, "one widget row per window")
            local sides, shaped = { T = true, B = true, L = true, R = true }, true
            for _, r in ipairs(wdg.rows) do
                if not (r.color and sides[r.side] and r.title) then shaped = false end
            end
            ok(shaped, "each row carries a color, an exposed edge side (T/B/L/R), and a title")
            local focusedRows = 0
            for _, r in ipairs(wdg.rows) do if r.focused then focusedRows = focusedRows + 1 end end
            ok(focusedRows == 1, "exactly one row is flagged as the focused window")

            -- clicking the Mail row (wid 103 = id 3) focuses that window
            local mailIdx
            for i, r in ipairs(wdg.rows) do if r.title == "Mail" then mailIdx = i end end
            ok(mailIdx ~= nil, "the widget lists the Mail window by title")
            wdg.onSwitch(mailIdx)
            ok(fake.focused[#fake.focused] == 3, "clicking a row focuses THAT window (Mail = id 3)")
            ok(fake.raises[#fake.raises] == 3, "clicking a row also RAISES that window to front")

            -- a new window is taken in -> the widget grows to six rows
            table.insert(fake.windows, 1, { id = 10, wid = 110, title = "Fresh", appName = "X",
                bundleID = "com.x", x = 300, y = 300, w = 600, h = 450 })
            fake.activateApp("X", "com.x")             -- onAppActivated -> refan -> updateWidget
            ok(fake.liveFanWidget() and #fake.liveFanWidget().rows == 6,
                "the widget row list tracks membership (six rows after a window opens)")

            -- the widget's Exit button leaves the mode
            fake.liveFanWidget().onExit()
            ok(fake.liveFanWidget() == nil, "Exit tears down the widget")
            ok(#fake.liveOutlines() == 0, "Exit leaves the mode (borders gone)")
        end

        -- ===== WIDGET OPT-OUT: the "widget" option off suppresses the card, and the
        -- mode still works (borders, restore) without it.
        do
            fake.windows = freshWindows()
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.settings["hammerdeck.opt.window_fan.widget"] = false
            fake.pressHotkey("f", HYP)                 -- enter with the widget off
            ok(fake.liveFanWidget() == nil, "widget option off -> no widget shown")
            ok(#fake.liveOutlines() == 5, "the mode still fans the windows without the widget")
            fake.pressHotkey("f", HYP)                 -- leave
            fake.settings["hammerdeck.opt.window_fan.widget"] = nil
        end

        -- ===== SCREEN RECONFIG: a display RESIZE re-fans onto the new geometry and
        -- re-anchors the widget (the slots were sized to the old frame); the stacked
        -- display VANISHING leaves the mode WITHOUT restoring (the captured originals
        -- were on the gone display, so re-applying them would fling the windows off).
        do
            fake.windows = freshWindows()
            fake.screenList = { SCREEN, SCREEN2 }
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.pressHotkey("f", HYP)                 -- enter on SCREEN (1600x1000)
            ok(#fake.liveOutlines() == 5, "entered on the main screen")
            local wdx = fake.liveFanWidget().pos.x - SCREEN.x   -- widget offset from screen origin

            -- SCREEN both SHRINKS and MOVES (same name "Main"). The members are still in
            -- their OLD (larger) slabs, so their centres now fall OUTSIDE the new frame --
            -- a geometry re-classification would strand them. All five must re-fan onto it.
            -- The size is chosen to satisfy BOTH constraints at once, and it is load-
            -- bearing: capacity must still clear 5 (1060x400 fits 6) so the re-fan path
            -- actually runs, AND every member's slot centre must fall OUTSIDE the new
            -- frame (all 5 do) so the assertion below can still tell "re-fan the KNOWN
            -- members" from "re-derive membership by geometry". A gentler shrink leaves
            -- the centres inside and the block silently stops testing its own bug.
            local SMALL = { x = 100, y = 50, w = 1060, h = 400, name = "Main", index = 1 }
            fake.screenList = { SMALL, SCREEN2 }
            local before = #fake.windowFrameSets
            fake.systemEvent("screenChanged")
            ok(#fake.liveOutlines() == 5, "all five members re-fan onto the shrunk/moved screen (none stranded)")
            local placed = {}
            for i = before + 1, #fake.windowFrameSets do placed[#placed + 1] = fake.windowFrameSets[i] end
            ok(sortedKeys(placed) == sortedKeys(W.fanSlots(SMALL, 5, 40, 8)),
                "the fan re-placed onto the NEW (shrunk, moved) geometry")
            ok(fake.liveFanWidget() and fake.liveFanWidget().pos.x == SMALL.x + wdx,
                "the widget re-anchored to the new origin, offset preserved")

            -- The fanned display VANISHES -> leave without restore; windows stay put.
            local pre = { frameOf(1).x, frameOf(1).y }
            fake.screenList = { SCREEN2 }              -- "Main" is gone
            fake.systemEvent("screenChanged")
            ok(#fake.liveOutlines() == 0, "the vanished fanned display leaves the mode")
            ok(fake.liveFanWidget() == nil, "the widget is torn down when the screen vanishes")
            ok(frameOf(1).x == pre[1] and frameOf(1).y == pre[2],
                "windows are left in place, NOT restored to originals on the gone display")
            fake.screenList = { SCREEN, SCREEN2 }      -- reset for later blocks
        end

        -- ===== A SHRINK THAT OVERFLOWS CAPACITY LEAVES THE MODE (and restores).
        -- The capacity gate guards enter() and refan(), but a display RESIZE reaches
        -- place() by a third path -- and it is the one most likely to overflow, since
        -- nothing about it is under the user's control. Re-placing anyway would rebuild
        -- the buried-strip layout the gate exists to prevent. Restore IS wanted here:
        -- the display still exists (unlike the screen-GONE case), so the captured
        -- originals are still meaningful frames on it.
        do
            fake.windows = freshWindows()
            fake.screenList = { SCREEN, SCREEN2 }
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.pressHotkey("f", HYP)                 -- enter on SCREEN (fits 12)
            ok(#fake.liveOutlines() == 5, "entered with five windows")

            local TINY = { x = 0, y = 0, w = 800, h = 600, name = "Main", index = 1 }
            ok(W.fanCapacity(TINY, 40, 8) < 5,
                "the shrunk screen genuinely cannot hold the five members")
            local a = #fake.alerts
            fake.screenList = { TINY, SCREEN2 }
            fake.systemEvent("screenChanged")

            ok(#fake.liveOutlines() == 0, "an over-capacity shrink leaves the mode")
            ok(fake.liveFanWidget() == nil, "the widget is torn down with it")
            ok(#fake.alerts == a + 1, "and says why, rather than vanishing silently")
            local restoredOk = true
            for id, o in pairs(ORIG) do
                local w = frameOf(id)
                if w and not (w.x == o.x and w.y == o.y) then restoredOk = false end
            end
            ok(restoredOk, "every window is restored -- the display still exists")
            fake.screenList = { SCREEN, SCREEN2 }      -- reset for later blocks
        end

        -- ===== CAPACITY IS ABOUT THE FAN'S SIZE, NOT ITS MEMBER COUNT.
        -- place() lays the fan out at the HIGH-WATER slot index, so a slot reserved
        -- for a window that moved to another screen still consumes geometry. Gating
        -- on the number of visible members therefore lets a shrink through while the
        -- layout is far larger -- and the slabs fall below what any app accepts,
        -- which is the exact outcome the gate exists to prevent.
        do
            fake.windows = freshWindows()
            fake.screenList = { SCREEN, SCREEN2 }
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.pressHotkey("f", HYP)                 -- enter with 5 on SCREEN
            ok(#fake.liveOutlines() == 5, "entered with five members")

            -- Three members move to the OTHER screen: they keep their slots RESERVED,
            -- so the fan is still laid out at 5 while only 2 are visible.
            for _, w in ipairs(fake.windows) do
                if w.wid == 103 or w.wid == 104 or w.wid == 105 then
                    w.x, w.y = SCREEN2.x + 40, SCREEN2.y + 40
                end
            end
            fake.activateApp("Code", "com.code")
            ok(#fake.liveOutlines() == 2, "three members moved off; two remain bordered")

            -- A shrink whose capacity (4) is ABOVE the member count (2) but BELOW the
            -- fan's real size (5). Gating on members would sail straight through.
            local MID = { x = 0, y = 0, w = 800, h = 600, name = "Main", index = 1 }
            ok(W.fanCapacity(MID, 40, 8) == 4, "the shrunk screen fits 4 -- more than the 2 members")
            local a = #fake.alerts
            fake.screenList = { MID, SCREEN2 }
            fake.systemEvent("screenChanged")

            ok(#fake.liveOutlines() == 0,
                "a reserved-slot fan larger than capacity still leaves the mode")
            ok(#fake.alerts == a + 1, "and alerts, rather than silently laying out sub-minimum slabs")
            fake.screenList = { SCREEN, SCREEN2 }
            fake.windows = freshWindows()
        end

        -- ===== screenChanged HONOURS droppedApps, LIKE refan.
        -- A display reconfig is the likeliest moment for an app to miss the AX
        -- timeout, so the reconfig prune must make the same distinction refan makes:
        -- an app that went quiet keeps its slot AND its original; only a genuine
        -- close recycles the slot. Half-porting this left the reconfig path re-tiling
        -- on a blink and its retained-original fix untested.
        do
            fake.windows = freshWindows()
            fake.screenList = { SCREEN, SCREEN2 }
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.pressHotkey("f", HYP)
            ok(#fake.liveOutlines() == 5, "entered with five members")

            local slab
            for _, w in ipairs(fake.windows) do
                if w.wid == 102 then slab = { x = w.x, y = w.y, w = w.w, h = w.h } end
            end

            -- Safari goes quiet exactly as the display is reconfigured.
            local kept = {}
            for _, w in ipairs(fake.windows) do
                if w.wid ~= 102 then kept[#kept + 1] = w end
            end
            fake.windows = kept
            fake.droppedApps = { "com.saf" }
            local RESIZED = { x = 0, y = 0, w = 1500, h = 950, name = "Main", index = 1 }
            fake.screenList = { RESIZED, SCREEN2 }
            local before = #fake.windowFrameSets
            fake.systemEvent("screenChanged")
            ok(#fake.liveOutlines() == 4, "the quiet app's border is dropped")

            -- THE POINT: its slot stays RESERVED. That is only OBSERVABLE once someone
            -- competes for it -- freeing a slot does not shrink the fan unless it held
            -- the top index, so the survivors' geometry alone proves nothing. Open a
            -- new window while the app is still quiet: with the slot reserved the
            -- newcomer must take a SIXTH slot (fan of 6); if the quiet window's slot
            -- had been freed the newcomer would drop into its hole and the fan would
            -- stay at 5, re-tiling everyone when the quiet window came back.
            table.insert(fake.windows, { id = 60, wid = 601, title = "Newcomer",
                appName = "N", bundleID = "com.new", x = 300, y = 300, w = 600, h = 400 })
            before = #fake.windowFrameSets
            fake.activateApp("N", "com.new")
            local six = W.fanSlots(RESIZED, 6, 40, 8)
            local placed, allOnSix = {}, true
            for i = before + 1, #fake.windowFrameSets do placed[#placed + 1] = fake.windowFrameSets[i] end
            for _, f in ipairs(placed) do
                local hit = false
                for _, s in ipairs(six) do
                    if f.x == s.x and f.y == s.y and f.w == s.w and f.h == s.h then hit = true end
                end
                if not hit then allOnSix = false end
            end
            ok(#placed > 0 and allOnSix,
                "a quiet app's slot is RESERVED across a reconfig -- a newcomer extends the fan instead of stealing it")

            fake.droppedApps = {}
            fake.screenList = { SCREEN, SCREEN2 }
            fake.windows = freshWindows()
            registry.runAction("window_fan", "arrange")   -- leave, whatever state we are in
            if #fake.liveOutlines() > 0 then fake.pressHotkey("f", HYP) end
        end

        -- ===== ... AND A RECONFIG PRUNE NEVER DISCARDS THE CAPTURED ORIGINAL.
        -- Separate from the block above on purpose: that one drives the droppedApps
        -- branch, this one drives the OTHER branch -- a window absent for a reason the
        -- seam cannot classify (a Space move), where the slot is recycled but the
        -- original must survive. Testing only the first branch left this one unheld.
        do
            fake.windows = freshWindows()
            fake.screenList = { SCREEN, SCREEN2 }
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.pressHotkey("f", HYP)
            ok(#fake.liveOutlines() == 5, "entered with five members")

            local slab
            for _, w in ipairs(fake.windows) do
                if w.wid == 102 then slab = { x = w.x, y = w.y, w = w.w, h = w.h } end
            end

            -- Safari moves to another Space as the display is reconfigured: absent from
            -- the listing, but its app answers fine, so droppedApps stays EMPTY.
            local kept = {}
            for _, w in ipairs(fake.windows) do
                if w.wid ~= 102 then kept[#kept + 1] = w end
            end
            fake.windows = kept
            fake.droppedApps = {}
            local RESIZED = { x = 0, y = 0, w = 1500, h = 950, name = "Main", index = 1 }
            fake.screenList = { RESIZED, SCREEN2 }
            fake.systemEvent("screenChanged")

            -- It comes back reporting the SLAB it was left on -- re-capturing here is
            -- exactly how the real geometry used to be destroyed.
            table.insert(fake.windows, 2, { id = 2, wid = 102, title = "Browser",
                appName = "Safari", bundleID = "com.saf",
                x = slab.x, y = slab.y, w = slab.w, h = slab.h })
            fake.activateApp("Safari", "com.saf")
            fake.pressHotkey("f", HYP)                 -- leave -> restore

            local back = frameOf(2)
            ok(back and back.x == ORIG[2].x and back.y == ORIG[2].y
               and back.w == ORIG[2].w and back.h == ORIG[2].h,
                "a reconfig prune keeps the captured original -- restore is still the TRUE frame")
            fake.screenList = { SCREEN, SCREEN2 }
            fake.windows = freshWindows()
        end

        -- ===== A RECYCLED CGWindowID MUST NOT INHERIT A DEAD WINDOW'S ORIGINAL.
        -- Originals are retained for the whole mode session now (so an AX blind spot
        -- cannot destroy them), which means the retention window is minutes rather
        -- than sub-second -- long enough for macOS to recycle a closed window's id.
        -- Retention is therefore keyed to the owning app: a different owner is a
        -- different window, and its real frame must be captured fresh.
        do
            fake.windows = freshWindows()
            fake.screenList = { SCREEN, SCREEN2 }
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.pressHotkey("f", HYP)

            -- Notes (104) closes; a DIFFERENT app's new window reuses its wid.
            local kept = {}
            for _, w in ipairs(fake.windows) do
                if w.wid ~= 104 then kept[#kept + 1] = w end
            end
            local REUSED = { x = 222, y = 333, w = 640, h = 480 }
            table.insert(kept, { id = 44, wid = 104, title = "Recycled", appName = "Zed",
                bundleID = "com.zed", x = REUSED.x, y = REUSED.y, w = REUSED.w, h = REUSED.h })
            fake.windows = kept
            fake.activateApp("Zed", "com.zed")
            fake.pressHotkey("f", HYP)                 -- leave -> restore

            local r = frameOf(44)
            ok(r and r.x == REUSED.x and r.y == REUSED.y and r.w == REUSED.w and r.h == REUSED.h,
                "a wid-recycling window restores to ITS OWN frame, not the dead window's")
            fake.windows = freshWindows()
        end

        -- ===== ALERTS: nothing fannable, and nothing to restore.
        do
            fake.windows = {}
            fake.focusedWindow = nil
            fake.focusedWid = nil
            fake.mousePos = { x = 100, y = 100 }
            local a = #fake.alerts
            fake.pressHotkey("f", HYP)
            ok(#fake.alerts == a + 1, "no fannable windows -> alert, not active")
        end

        -- ===== CAPACITY GATE: the fan REFUSES rather than degrading.
        -- A window cannot shrink below its own minimum size, so past a certain N the
        -- slabs are a request every app rejects -- windows overshoot (measured
        -- median 3.8x) and bury their neighbours' strips, which voids the mode's one
        -- promise. Owner's call (2026-07-25): refuse, and say the real number.
        do
            local CAP = W.fanCapacity(SCREEN, 40, 8)
            ok(CAP > 0 and CAP < 20, "the test screen has a sane finite capacity (" .. CAP .. ")")

            -- Exactly at capacity: still fans.
            local wins = {}
            for i = 1, CAP do
                wins[i] = { id = 500 + i, wid = 5000 + i, title = "W" .. i, appName = "A" .. i,
                    bundleID = "com.cap" .. i, x = 100 + i, y = 100 + i, w = 600, h = 400 }
            end
            fake.windows = wins
            fake.focusedWindow = { x = 101, y = 101, w = 600, h = 400, screenIndex = 1 }
            fake.focusedWid = 5001
            fake.pressHotkey("f", HYP)
            ok(#fake.liveOutlines() == CAP, "exactly at capacity, the fan runs (" .. CAP .. " bordered)")
            fake.pressHotkey("f", HYP)                        -- leave

            -- One over: refused, with an alert, and nothing moved.
            wins[CAP + 1] = { id = 600, wid = 6000, title = "One too many", appName = "Z",
                bundleID = "com.cap.z", x = 120, y = 120, w = 600, h = 400 }
            fake.windows = wins
            local a, moved = #fake.alerts, #fake.windowFrameSets
            fake.pressHotkey("f", HYP)
            ok(#fake.alerts == a + 1, "one window over capacity -> an alert")
            ok(#fake.liveOutlines() == 0, "over capacity, the mode does NOT enter")
            ok(#fake.windowFrameSets == moved, "over capacity, not a single window is moved")
        end

        -- ===== THE CEILING ALSO APPLIES TO GROWTH. A screen reaches 30 windows by
        -- ACCUMULATING them, so every one of those opens arrives via refan, not
        -- enter() -- gating only entry would be theatre. A newcomer past capacity is
        -- left where it is. The subtle part is change detection: place() records the
        -- signature of what it PLACED, but the poll compares against the full
        -- fannable set, so a permanently-refused window would read as "set changed"
        -- on every single tick and re-fan forever.
        do
            local CAP = W.fanCapacity(SCREEN, 40, 8)
            local wins = {}
            for i = 1, CAP do
                wins[i] = { id = 700 + i, wid = 7000 + i, title = "G" .. i, appName = "B" .. i,
                    bundleID = "com.grow" .. i, x = 100 + i, y = 100 + i, w = 600, h = 400 }
            end
            fake.windows = wins
            fake.focusedWindow = { x = 101, y = 101, w = 600, h = 400, screenIndex = 1 }
            fake.focusedWid = 7001
            fake.pressHotkey("f", HYP)
            ok(#fake.liveOutlines() == CAP, "entered at capacity")

            -- A new window opens on the screen while the mode is live.
            table.insert(fake.windows, { id = 800, wid = 8000, title = "Latecomer", appName = "L",
                bundleID = "com.late", x = 300, y = 300, w = 600, h = 400 })
            fake.fireTimers("every", 2.0)
            ok(#fake.liveOutlines() == CAP,
                "a newcomer past capacity is NOT taken into the fan")
            local late = frameOf(800)
            ok(late.x == 300 and late.y == 300, "the refused newcomer is left exactly where it was")

            -- ... and the refusal must SETTLE. Two more quiet polls must not re-fan.
            local steady = #fake.windowFrameSets
            fake.fireTimers("every", 2.0)
            fake.fireTimers("every", 2.0)
            ok(#fake.windowFrameSets == steady,
                "a permanently-refused window does not re-trigger a refan on every poll")
            fake.pressHotkey("f", HYP)                        -- leave
        end

        -- ===== ONE ACTION, like Window Deck. The keyboard ring (next / prev /
        -- confirm) is GONE, not merely unbound: nothing to bind, to list in Settings,
        -- or to render as a menubar row.
        --
        -- NOTE ON WHAT IS *NOT* TESTED HERE, deliberately. Deleting the ring also
        -- retired st.cursor and collapsed selectedWid() to st.focusedWid at its three
        -- call sites -- and NO test can pin that rewiring, because it was a provable
        -- no-op: st.cursor had exactly one writer (st.step), so on every path that
        -- survives, selectedWid() already returned st.focusedWid. A test written for
        -- it would have been green before the change too, which is the definition of
        -- a test that proves nothing. The bold-border invariant it would have claimed
        -- to cover is already pinned, by blocks that DO discriminate: entry boldness
        -- at the top of this file, focus-follows-raise above, and the FOCUS RACE block
        -- (which bolds a window WITHOUT reordering, so a wiring to st.order[1] fails
        -- there). What IS new and worth a test is the declaration itself.
        do
            local fan
            for _, f in ipairs(registry.describe()) do
                if f.id == "window_fan" then fan = f end
            end
            ok(fan ~= nil and #fan.actions == 1 and fan.actions[1].id == "arrange",
                "window_fan declares exactly one action: the toggle")
            ok(fan.actions[1].defaultTrigger ~= nil,
                "and the toggle keeps its default Hyper+F")

            -- The palette therefore offers one row, labelled with the FEATURE name
            -- (the one-action fallback) rather than an action label.
            local rows = {}
            local view = require("platform.registry_view")
            for _, c in ipairs(view.commandList("some_other_feature")) do
                if c.featureId == "window_fan" then rows[#rows + 1] = c end
            end
            ok(#rows == 1 and rows[1].actionId == "arrange" and rows[1].label == "Window Fan",
                "the command palette carries one Window Fan row, named for the feature")
        end

        -- ===== LABEL MODE (`arrange` off): borders + list, nothing moved.
        -- The arrangement is the expensive half of this feature and the identification
        -- is the half that demonstrably works, so the arrangement is optional. With it
        -- off every constraint it imposes goes away: no window limit (nothing has to
        -- fit a slab), no minimum-size problem, no raise pass, and no restore.
        do
            fake.settings["hammerdeck.opt.window_fan.arrange"] = false
            fake.windows = freshWindows()
            fake.screenList = { SCREEN, SCREEN2 }
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            local movedBefore, raisedBefore = #fake.windowFrameSets, #fake.raises
            fake.pressHotkey("f", HYP)

            ok(#fake.liveOutlines() == 5, "label mode still borders every window")
            ok(#fake.windowFrameSets == movedBefore,
                "label mode moves NOTHING -- not a single setFrame")
            ok(#fake.raises == raisedBefore,
                "label mode runs no raise pass -- the user's own stacking is left alone")
            local placedOk = true
            for id, o in pairs(ORIG) do
                local w = frameOf(id)
                if w and not (w.x == o.x and w.y == o.y and w.w == o.w and w.h == o.h) then
                    placedOk = false
                end
            end
            ok(placedOk, "every window is still exactly where it was")

            -- Borders sit on the windows' REAL frames, and the widget's edge swatch is
            -- blanked (no edge is guaranteed exposed, so claiming one would be a lie).
            local b101 = borderFor(101)
            ok(b101 ~= nil and b101.frame.w == ORIG[1].w and b101.frame.h == ORIG[1].h,
                "a border spans the window's own frame, not a slab")
            local rows = fake.liveFanWidget().rows
            local sidesBlank = true
            for _, r in ipairs(rows) do if r.side ~= "" then sidesBlank = false end end
            ok(#rows == 5 and sidesBlank, "the widget lists all five with no edge glyph")

            -- LABEL MODE STILL TRACKS: a border must FOLLOW a window the user drags.
            -- That is the mode's headline claim, and the observer that delivers it
            -- (onFramesChanged) is ungated -- so drive the real event, not just the poll
            -- backstop. borderFor matches a border to a window BY FRAME, so finding one
            -- after the move is proof the border moved with it.
            local dragged = frameOf(3)
            -- The target must be BOTH genuinely different from this window's original
            -- frame (700,300 -- picking that made the "drag" a no-op and every
            -- assertion vacuous) AND centred well inside SCREEN: 700x500 at 400,450
            -- centres at 750,700, ~300pt clear of every edge. The earlier 1234,567 sat
            -- 16pt from the right edge, so nudging this window's width would push its
            -- centre off-screen, drop it from the labelled set, and make the "left
            -- where they put it" assertion pass because nothing COULD have moved it.
            dragged.x, dragged.y = 400, 450
            fake.fireFrameEvent({ bundleID = "com.mail", wid = 103,
                x = dragged.x, y = dragged.y, w = dragged.w, h = dragged.h })
            local movedBorder = borderFor(103)
            ok(movedBorder ~= nil,
                "a border FOLLOWS the window the user dragged (label mode tracks)")
            ok(movedBorder and movedBorder.frame.x == 400 and movedBorder.frame.y == 450,
                "and it sits on the window's new frame, not its old one")

            -- A window that JOINS mid-session is the case that really tests this: the
            -- newcomer path captures an original when arranging, so if label mode is
            -- not excluded there too, dragging a newly-opened window and leaving would
            -- snap it back to wherever it happened to open.
            table.insert(fake.windows, { id = 70, wid = 700, title = "Joined",
                appName = "J", bundleID = "com.join", x = 200, y = 200, w = 600, h = 400 })
            fake.activateApp("J", "com.join")          -- taken into the labelled set
            ok(#fake.liveOutlines() == 6, "a window opened during label mode is labelled too")
            local joined = frameOf(70)
            -- Drag it, but keep its CENTRE on the screen (600x400 at 888,500 centres
            -- at 1188,700 inside the 1600x1000 frame). Pushing the centre off would
            -- drop it from the labelled set altogether, and the assertion below would
            -- then pass because nothing could restore it -- not because nothing did.
            joined.x, joined.y = 888, 500
            fake.fireTimers("every", 2.0)

            fake.pressHotkey("f", HYP)                 -- leave
            ok(#fake.liveOutlines() == 0, "leaving label mode tears down the borders")
            local stillMoved = frameOf(3)
            ok(stillMoved.x == 400 and stillMoved.y == 450,
                "a window the USER moved during label mode is left where they put it")
            local stillJoined = frameOf(70)
            ok(stillJoined.x == 888 and stillJoined.y == 500,
                "a NEWCOMER the user moved is left alone too -- label mode captures nothing")

            fake.settings["hammerdeck.opt.window_fan.arrange"] = nil
            fake.windows = freshWindows()
        end

        -- ===== LABEL MODE HAS NO WINDOW LIMIT.
        -- The capacity gate exists only because slabs shrink below what apps accept.
        -- With nothing to fit, there is nothing to refuse -- which is the whole reason
        -- label mode is worth having on a screen that the fan declines.
        do
            fake.settings["hammerdeck.opt.window_fan.arrange"] = false
            local many = {}
            for i = 1, 20 do
                many[i] = { id = 900 + i, wid = 9000 + i, title = "W" .. i, appName = "A" .. i,
                    bundleID = "com.many" .. i, x = 100 + i, y = 100 + i, w = 700, h = 500 }
            end
            fake.windows = many
            fake.screenList = { SCREEN, SCREEN2 }
            fake.focusedWindow = { x = 101, y = 101, w = 700, h = 500, screenIndex = 1 }
            fake.focusedWid = 9001
            ok(W.fanCapacity(SCREEN, 40, 8) < 20,
                "20 windows is well past what the screen can FAN (" .. W.fanCapacity(SCREEN, 40, 8) .. ")")
            local a, moved = #fake.alerts, #fake.windowFrameSets
            fake.pressHotkey("f", HYP)

            ok(#fake.liveOutlines() == 20, "label mode labels all twenty -- no capacity refusal")
            ok(#fake.alerts == a, "and no alert: there is no limit to report")
            ok(#fake.windowFrameSets == moved, "still nothing moved")
            fake.pressHotkey("f", HYP)                 -- leave
            fake.settings["hammerdeck.opt.window_fan.arrange"] = nil
            fake.windows = freshWindows()
        end

        -- ===== W-3: A NEWCOMER THAT FILLS A FREED HOLE IS TAKEN IN, EVEN AT CAPACITY.
        -- The gate has to test the slot the newcomer would actually TAKE, not the
        -- fan's high-water index. lowestFreeIndex fills a hole left by a closed
        -- window, which does not grow the fan at all -- so a high-water gate refuses
        -- a window the geometry has room for, and it never stops: the high-water
        -- never falls, so once a fan touches capacity every later window is turned
        -- away for the rest of the mode, however many slots have since been freed.
        do
            -- A screen + edge whose capacity is small enough to REACH. Derived from
            -- the same call the feature makes, so the block tracks the algorithm
            -- rather than a magic number -- and asserted, since the whole scenario
            -- is "the fan is exactly full" and a capacity of 8 would never get there.
            local TIGHT = { x = 0, y = 0, w = 1100, h = 700, name = "Tight", index = 1 }
            fake.settings["hammerdeck.opt.window_fan.edge"] = 120
            local cap = W.fanCapacity(TIGHT, 120, 8)
            ok(cap == 4, "fixture: this screen + edge fans exactly 4 (" .. cap .. ")")

            fake.screenList = { TIGHT }
            fake.windows = {
                { id = 51, wid = 501, title = "One",   appName = "A", bundleID = "com.1", x = 10,  y = 10,  w = 300, h = 200 },
                { id = 52, wid = 502, title = "Two",   appName = "B", bundleID = "com.2", x = 20,  y = 20,  w = 300, h = 200 },
                { id = 53, wid = 503, title = "Three", appName = "C", bundleID = "com.3", x = 30,  y = 30,  w = 300, h = 200 },
                { id = 54, wid = 504, title = "Four",  appName = "D", bundleID = "com.4", x = 40,  y = 40,  w = 300, h = 200 },
            }
            fake.focusedWindow = { x = 10, y = 10, w = 300, h = 200, screenIndex = 1 }
            fake.focusedWid = 501
            registry.setEnabled("window_fan", true)
            fake.pressHotkey("f", HYP)
            ok(#fake.liveOutlines() == cap, "the fan enters exactly full (" .. cap .. " borders)")

            -- Window TWO closes -- freeing slot 2 while the high-water stays at 4 --
            -- and a newcomer opens. Closing the LAST-slotted window instead would
            -- drop the high-water too, and the old gate would have let it in: the
            -- hole has to be in the MIDDLE for this to test anything.
            fake.windows = {
                fake.windows[1], fake.windows[3], fake.windows[4],
                { id = 55, wid = 505, title = "Five", appName = "E", bundleID = "com.5",
                  x = 50, y = 50, w = 300, h = 200 },
            }
            fake.focusedWid = 505
            fake.focusWindowChanged()

            ok(borderFor(502) == nil, "the closed window's border is pruned")
            ok(borderFor(505) ~= nil,
                "the newcomer fills the freed slot rather than being refused at capacity (W-3)")
            ok(#fake.liveOutlines() == cap, "the fan is full again, not one short")

            fake.pressHotkey("f", HYP)                 -- leave
            registry.setEnabled("window_fan", false)
            fake.settings["hammerdeck.opt.window_fan.edge"] = nil
            fake.screenList = { SCREEN, SCREEN2 }
            fake.windows = freshWindows()
            registry.setEnabled("window_fan", true)
        end

        -- ===== LEAVE ON DISABLE: a live mode is torn down + restored on stop.
        do
            fake.windows = freshWindows()
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.pressHotkey("f", HYP)                        -- enter
            ok(#fake.liveOutlines() == 5 and frameOf(1).x ~= ORIG[1].x, "in the mode (bordered, moved)")
            registry.setEnabled("window_fan", false)        -- stop -> forceExit -> leave
            ok(#fake.liveOutlines() == 0, "disable tears down the borders")
            ok(frameOf(1).x == ORIG[1].x and frameOf(1).y == ORIG[1].y,
                "window 1 is back at its origin after the disable-restore")
        end

        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
            "clean after window_fan test (no leaked border or observer)")
    end,
}
