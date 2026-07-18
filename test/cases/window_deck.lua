-- test/cases/window_deck.lua -- window_deck: the focus-driven window manager. A toggle tiles
-- the active screen's windows into a grid (nearest-cell, not row-major), and focusing a member
-- promotes it to a centered ~78% "hero" over a scrim; swaps play as a sequenced beat (old hero
-- steps home, then the new one grows), a peek of a non-deck window stays on top without a
-- blink, and escalating Escape drops the hero then exits. Covers the v1.1 entry picker
-- (exclude/cancel/min-guard/recolor + Hero switch), the multi-monitor display map with its
-- "restore last deck" button, the draggable indicator widget (mini-map switch, ⌥number keys,
-- reorder, rearrange), retitle/wid identity (adoption + the wid ladder), the hide-until-stable
-- user-drag tracking with its own-move echo guard, and screen-reconfig re-anchor/exit.
--
-- Migrated from run.lua T25f (RUN_LUA_SPLIT_SPEC Phase 2). Hermetic: registers its own feature
-- and seeds its own fixtures (windows, screenList, mousePos). The section's leading
-- fake.resetOpts() and its trailing "restore the shared fake globals" block are both dropped --
-- freshWorld() gives each case a pristine world, and the handle tripwire after catches any leak.

return {
    id = "window_deck",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        local Wd = require("platform.windows")
        registry.register(require("features.window_deck"))
        fake.settings["hammerdeck.opt.window_deck.gutter"]        = 8
        fake.settings["hammerdeck.opt.window_deck.heroPercent"]   = 78
        fake.settings["hammerdeck.opt.window_deck.restoreOnExit"] = true
        local HYP = { "cmd", "alt", "ctrl" }

        local function near(a, b) return math.abs(a - b) < 0.5 end

        -- Four windows, one per quadrant of a 1440x900 screen, with the BOTTOM-RIGHT
        -- window listed FIRST -- so a naive row-major fill would mis-place it and the
        -- nearest-cell assignment is provable. Fresh copies each enter (placement
        -- mutates the rows).
        local function quadWindows()
            return {
                { id = 1, title = "BR", appName = "AppBR", bundleID = "com.br", x = 900,  y = 550, w = 300, h = 200 },
                { id = 2, title = "TL", appName = "AppTL", bundleID = "com.tl", x = 100,  y = 100, w = 300, h = 200 },
                { id = 3, title = "TR", appName = "AppTR", bundleID = "com.tr", x = 1000, y = 100, w = 300, h = 200 },
                { id = 4, title = "BL", appName = "AppBL", bundleID = "com.bl", x = 100,  y = 550, w = 300, h = 200 },
            }
        end
        -- The 2x2 slots (gutter 8) in reading order and the hero, from the same math
        -- the feature uses -- so the test tracks the algorithm, not a magic number.
        local SCREEN = { x = 0, y = 0, w = 1440, h = 900, name = "Main", index = 1, builtin = true }
        local slots  = Wd.tileSlots(SCREEN, 4, 8)          -- {TL, TR, BL, BR}
        local TLslot, TRslot, BLslot, BRslot = slots[1], slots[2], slots[3], slots[4]
        local HERO   = Wd.centeredRect(SCREEN, 0.78)

        -- simulate the user focusing the window with id `id`: set the AX focused-
        -- window identity the feature reads (frontmost app bundle id + focused title),
        -- then fire the matching watcher. `within` = a same-app switch (focus observer
        -- only, no app activation); otherwise a cross-app activation. NOTE: the feature
        -- keys off this identity, NOT list order -- the CG z-order lags the real event.
        local function focusWin(id, within, noFlush)
            local w
            for _, r in ipairs(fake.windows) do if r.id == id then w = r end end
            fake.windowTitle = w.title
            if within then
                fake.frontmost, fake.frontmostId = w.appName, w.bundleID
                fake.focusWindowChanged()
            else
                fake.activateApp(w.appName, w.bundleID)
            end
            -- `noFlush` leaves the beat mid-flight so the caller can assert the
            -- dispatch order (the window's move fires at flight START, under the
            -- ring); the caller flushes the timers itself.
            if noFlush then return end
            -- flush twice: the first fire lands the beat's ring flight (the FLIGHT
            -- timer) + any settle window; the landing may arm a NEW settle, which
            -- the second fire clears so the next focus event registers.
            fake.fireTimers("after")
            fake.fireTimers("after")
        end
        local function lastSetFor(id)                        -- most recent by-id move
            for i = #fake.windowFrameSets, 1, -1 do
                if fake.windowFrameSets[i].id == id then return fake.windowFrameSets[i] end
            end
            return nil
        end

        -- Enter the deck through the v1.1 pick flow (picker on every toggle): press
        -- the toggle, take the active screen if a multi-monitor screen chooser opens,
        -- then confirm the window multi-select with ALL rows checked -- the common
        -- "deck everything" path. (Sub-tests that exclude/cancel drive the picker by
        -- hand instead.) Exiting is a plain toggle press -- no picker on the way out.
        local function enterDeck()
            fake.pressHotkey("k", HYP)
            local dp = fake.openDisplayPicker()
            if dp then dp.userConfirm(dp.preselect) end   -- take the default (current) display
            local p = fake.openWindowPicker()
            if p then p.confirm(nil) end
            fake.fireTimers("after")   -- flush the deck's settle window (see beginSettle)
        end

        -- placement-math unit checks (pure) ---------------------------------------
        ok(Wd.gridDims(4).w == 2 and Wd.gridDims(4).h == 2, "gridDims(4) = 2x2")
        ok(Wd.gridDims(5).w == 3 and Wd.gridDims(5).h == 2, "gridDims(5) = 3x2 (partial last row)")
        ok(Wd.gridDims(7).w == 4 and Wd.gridDims(7).h == 2, "gridDims(7) = 4x2 override")
        ok(Wd.gridDims(9).w == 3 and Wd.gridDims(9).h == 3, "gridDims(9) = 3x3")
        do
            local s5 = Wd.tileSlots(SCREEN, 5, 8)
            ok(#s5 == 5, "tileSlots(5) yields 5 slots")
            ok(near(s5[1].w, 1440 / 3 - 16), "full-row cell is a third wide (minus gutters)")
            ok(near(s5[4].w, 1440 / 2 - 16) and near(s5[5].w, 1440 / 2 - 16),
                "partial last row of 2 stretches each to a half (no dead cells)")
        end

        -- T-WD1: enter -> flat GRID with nearest-cell assignment ------------------
        fake.focusedWindow = nil            -- pickScreen falls back to the cursor (screen 1)
        fake.mousePos = { x = 10, y = 10 }
        fake.screenList = { SCREEN }
        fake.windows = quadWindows()
        fake.windowFrameSets = {}
        registry.setEnabled("window_deck", true)
        ok(registry.liveHandleCount() == 1, "enabled service binds just the toggle hotkey")

        fake.raises = {}
        enterDeck()
        ok(#fake.windowFrameSets == 4, "entering the deck tiles all four windows")
        do
            local raised = fake.raisedSet()
            ok(raised[1] and raised[2] and raised[3] and raised[4],
                "entering raises every deck window above non-deck windows on the screen")
        end
        local brSet = lastSetFor(1)
        ok(brSet and near(brSet.x, BRslot.x) and near(brSet.y, BRslot.y)
            and near(brSet.w, BRslot.w) and near(brSet.h, BRslot.h),
            "the bottom-right window (listed first) lands in the bottom-right slot -- nearest-cell, not row-major")
        local tlSet = lastSetFor(2)
        ok(tlSet and near(tlSet.x, TLslot.x) and near(tlSet.y, TLslot.y),
            "the top-left window lands in the top-left slot")
        ok(fake.liveScrim() ~= nil, "the container scrim shows while the deck is active")
        do
            local sf = fake.liveScrim().screenFrame
            ok(sf and sf.x == SCREEN.x and sf.w == SCREEN.w,
                "the scrim is pinned to the DECK's screen, not the key window's screen")
            ok(#fake.liveScrim().holes == 4, "the scrim punches a hole for each deck window (GRID)")
        end
        ok(#fake.liveOutlines("member") == 4, "every deck member gets a subtle border (GRID)")
        do
            local seen, n = {}, 0
            for _, o in ipairs(fake.liveOutlines("member")) do
                if o.color ~= "" and not seen[o.color] then seen[o.color] = true; n = n + 1 end
            end
            ok(n == 4, "each deck member border has a distinct color")
        end
        ok(fake.liveOutline("hero") == nil and fake.liveOutline("ghost") == nil,
            "no hero/ghost border in the flat grid (no hero yet)")
        ok(fake.liveWidget() ~= nil, "the draggable indicator widget shows while the deck is active")
        ok(registry.liveHandleCount() == 16,
            "active deck = 7 base + frame watcher + 4 member borders + 4 ⌥number hotkeys")

        -- toggle off -> restore original frames, scrim gone
        local before = #fake.windowFrameSets
        fake.pressHotkey("k", HYP)
        ok(#fake.windowFrameSets == before + 4, "exiting restores every window")
        local brRestore = lastSetFor(1)
        ok(brRestore and brRestore.x == 900 and brRestore.y == 550
            and brRestore.w == 300 and brRestore.h == 200,
            "the bottom-right window is restored to its original frame")
        ok(fake.liveScrim() == nil, "the scrim is dismissed on exit")
        ok(registry.liveHandleCount() == 1, "exit drops the deck handles, keeps the toggle")

        -- disable WHILE decked -> stop(ctx) restores, then teardown leaves nothing
        fake.windows = quadWindows()
        fake.windowFrameSets = {}
        enterDeck()                                    -- re-enter
        ok(registry.liveHandleCount() == 16,
            "re-entered the deck (7 base + frame watcher + 4 member borders + 4 ⌥number hotkeys)")
        registry.setEnabled("window_deck", false)      -- disable mid-deck
        ok(lastSetFor(1) and lastSetFor(1).w == 300,
            "disabling mid-deck restores original frames via stop()")
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
            "clean after disable-while-decked")

        -- T-WD-pick: the entry picker (v1.1) -- exclude, cancel, min-guard --------
        registry.setEnabled("window_deck", true)
        -- exclude one: the picker lists all four pre-checked; drop the 4th (BL) row.
        -- The minimized and fullscreen rows appended below must NOT be offered at
        -- all -- AX lists them with their normal frames, but a deck slot for an
        -- invisible window is a ring around empty space.
        fake.windows = quadWindows()
        fake.windows[#fake.windows + 1] = { id = 66, title = "Hidden", appName = "AppMin",
            bundleID = "com.min", x = 150, y = 150, w = 300, h = 200, minimized = true }
        fake.windows[#fake.windows + 1] = { id = 67, title = "Full", appName = "AppFS",
            bundleID = "com.fs", x = 0, y = 0, w = 1440, h = 900, fullscreen = true }
        fake.windowFrameSets = {}
        fake.pressHotkey("k", HYP)
        do
            local p = fake.openWindowPicker()
            ok(p ~= nil and #p.items == 4,
                "the picker lists every deckable window -- minimized/fullscreen excluded")
            ok(p.min == 2, "the picker requires at least two to be kept")
            p.confirm({ 1, 2, 3 })                     -- keep BR, TL, TR; drop BL (id 4)
        end
        fake.fireTimers("after")   -- flush the deck's settle window (see beginSettle)
        ok(#fake.windowFrameSets == 3, "excluding a window decks only the kept three")
        ok(lastSetFor(4) == nil, "the excluded window is left untouched")
        ok(#fake.liveOutlines("member") == 3, "only the kept three windows get member borders")
        ok(fake.liveScrim() ~= nil and registry.liveHandleCount() == 14,
            "the deck is live after an exclude (7 base + frame watcher + 3 member borders + 3 ⌥number hotkeys)")
        fake.pressHotkey("k", HYP)                      -- exit
        ok(registry.liveHandleCount() == 1, "clean after the exclude test")

        -- cancel: dismissing the picker enters no deck and drops the picker handle
        fake.windows = quadWindows()
        fake.windowFrameSets = {}
        fake.pressHotkey("k", HYP)
        do
            local p = fake.openWindowPicker()
            ok(p ~= nil, "the picker opens on enter")
            p.cancel()
        end
        ok(#fake.windowFrameSets == 0, "cancelling the picker tiles nothing")
        ok(fake.liveScrim() == nil and registry.liveHandleCount() == 1,
            "cancelling leaves no deck and drops the picker handle")

        -- min-guard: confirming with fewer than two checked is refused (panel stays)
        fake.pressHotkey("k", HYP)
        do
            local p = fake.openWindowPicker()
            ok(p.confirm({ 1 }) == false, "confirming with one window is refused (needs >= 2)")
            ok(p.open, "the picker stays open after a refused confirm")
            p.cancel()
        end
        ok(registry.liveHandleCount() == 1, "clean after the min-guard test")

        -- recolor + persistence: pick a custom color in the picker -> the border uses
        -- it; re-open the picker later -> the same app is offered that color again
        fake.windows = quadWindows()
        fake.windowFrameSets = {}
        fake.pressHotkey("k", HYP)
        do
            local p = fake.openWindowPicker()
            ok(p.items[1].color ~= nil and p.items[1].color ~= "",
                "picker rows carry a border-color preview")
            ok(type(p.palette) == "table" and #p.palette > 0,
                "the picker gets the recolor palette (dot-click cycles it)")
            p.recolor(1, "#123456")                    -- recolor the BR window's app
            p.confirm(nil)
        end
        fake.fireTimers("after")
        do
            local found = false
            for _, o in ipairs(fake.liveOutlines("member")) do
                if o.color == "#123456" then found = true end
            end
            ok(found, "a recolored window's deck border uses the chosen color")
        end
        fake.pressHotkey("k", HYP)                      -- exit
        fake.windows = quadWindows()
        fake.pressHotkey("k", HYP)                      -- re-open the picker
        do
            local p = fake.openWindowPicker()
            ok(p.items[1].color == "#123456",
                "the chosen color persists for the app across decks")
            p.cancel()
        end

        -- T-WD-restore: the screen-selector "restore last deck" BUTTON (multi-monitor).
        -- A FRESH pick saves its membership as a template; a later trigger offers
        -- "Restore last deck" as the map's secondary action and rebuilds the SAME set
        -- with no window multi-select. Availability is smart: a closed member drops,
        -- the label reads "N of M", and the template is NOT eroded by a partial restore.
        do
            local S2 = { x = 1440, y = 0, w = 1440, h = 900, name = "Ext", index = 2 }
            fake.screenList = { SCREEN, S2 }              -- 2 screens -> the selector opens
            fake.focusedWindow = nil
            fake.mousePos = { x = 10, y = 10 }            -- active screen = 1 (SCREEN)
            fake.settings["hammerdeck.state.window_deck.lastDeck"] = nil   -- no template yet

            -- 1) fresh pick on screen 1, keep BR+TL+TR (drop BL) -> saves a 3-member template
            fake.windows = quadWindows()
            fake.windowFrameSets = {}
            fake.pressHotkey("k", HYP)
            do
                local dp = fake.openDisplayPicker()
                ok(dp and dp.title == "Deck which screen?", "multi-monitor opens the display map")
                ok(#dp.displays == 2 and dp.extraLabel == "",
                    "no last deck yet -> the map shows two displays and no restore button")
                dp.userConfirm({ 1 })                     -- deck the current display (screen 1)
            end
            do
                local p = fake.openWindowPicker()
                ok(p ~= nil, "choosing a screen opens the window multi-select")
                p.confirm({ 1, 2, 3 })                    -- keep BR, TL, TR; drop BL (id 4)
            end
            fake.fireTimers("after")
            ok(#fake.liveOutlines("member") == 3, "fresh pick decked the chosen three")
            fake.pressHotkey("k", HYP)                    -- exit

            -- 2) trigger again with everything open: the selector now leads with restore
            fake.windows = quadWindows()
            fake.windowFrameSets = {}
            fake.pressHotkey("k", HYP)
            do
                local dp = fake.openDisplayPicker()
                ok(dp and #dp.displays == 2, "the map shows the two displays")
                ok(dp.preselect[1] == 1 and dp.displays[1].name == "Main",
                    "the current display (screen 1) is the pre-selected default (Enter decks it)")
                ok(dp.extraLabel == "Restore last deck (3 windows)",
                    "a restorable last deck is offered as the secondary-action button (full count)")
                dp.userExtra()                            -- press Restore last deck
            end
            fake.fireTimers("after")
            ok(fake.openWindowPicker() == nil, "restore skips the window multi-select")
            ok(#fake.liveOutlines("member") == 3, "restore rebuilt the three-window deck")
            ok(lastSetFor(4) == nil, "the window dropped from the template (BL) is not restored")
            fake.pressHotkey("k", HYP)                    -- exit

            -- 3) smart availability: close a template member (TR, id 3). Restore is
            -- still offered around the gap and reads "2 of 3 available".
            local q = quadWindows()
            fake.windows = { q[1], q[2], q[4] }           -- BR, TL, BL  (TR closed)
            fake.windowFrameSets = {}
            fake.pressHotkey("k", HYP)
            do
                local dp = fake.openDisplayPicker()
                ok(dp.extraLabel == "Restore last deck (2 of 3 available)",
                    "a closed member drops from the count without blocking restore")
                dp.userExtra()                            -- restore around the missing one
            end
            fake.fireTimers("after")
            ok(#fake.liveOutlines("member") == 2, "a partial restore decks the survivors (2 of 3)")
            fake.pressHotkey("k", HYP)                    -- exit

            -- the template was NOT overwritten by the partial restore: with TR open
            -- again, restore offers the full three once more.
            fake.windows = quadWindows()
            fake.pressHotkey("k", HYP)
            do
                local dp = fake.openDisplayPicker()
                ok(dp.extraLabel == "Restore last deck (3 windows)",
                    "a partial restore did not erode the saved template")
                dp.cancel()                               -- cancel out
            end

            -- 4) beyond the 9-cap: with many windows open, template members sitting
            -- PAST the MRU top-9 must still be found -- restore matches an UNCAPPED
            -- list, else an open member would read as "missing" (regression guard).
            local q2 = quadWindows()
            local many = {}
            for i = 1, 9 do
                many[i] = { id = 100 + i, title = "Decoy" .. i, appName = "Decoy" .. i,
                    bundleID = "com.decoy" .. i, x = 50, y = 50, w = 200, h = 150 }
            end
            many[10], many[11], many[12] = q2[1], q2[2], q2[3]   -- BR, TL, TR after 9 decoys
            fake.windows = many
            fake.pressHotkey("k", HYP)
            do
                local dp = fake.openDisplayPicker()
                ok(dp.extraLabel == "Restore last deck (3 windows)",
                    "template members past the MRU top-9 are still found (uncapped restore match)")
                dp.cancel()                               -- cancel out
            end

            fake.screenList = { SCREEN }                  -- back to single-screen for later tests
            fake.windows = quadWindows()
        end

        registry.setEnabled("window_deck", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after the picker tests")

        -- T-WD-blink: apps that ACTIVATE on raise must not make the hero/peek fight --
        -- Regression for the focus-fight blink: raiseDeck's raises emit activation
        -- echoes; UNGUARDED, each echo re-enters reconcile and promotes -- forever
        -- (with raiseActivates on, an unguarded deck recurses until the Lua stack
        -- overflows). The settle guard keeps every raise pass bounded; a plain
        -- promote never raises, and a bare peek-return raises NOTHING either (the
        -- "return blink" fix) -- only enter and a post-peek beat landing raise.
        do
            fake.windows = quadWindows()
            fake.raiseActivates = true
            registry.setEnabled("window_deck", true)

            fake.raises = {}
            enterDeck()                    -- enter -> raiseDeck -> 4 activation echoes, all absorbed
            ok(#fake.raises == 4,
                "enter raises each deck window once even when raising activates the app (no loop)")

            fake.raises = {}
            focusWin(2)                    -- a plain promote does NOT raise -> no echoes, no fight
            ok(#fake.raises == 0, "a plain promote does not raise (no activation echoes to fight)")

            -- a peek then a bare return must raise NOTHING: any raise to an
            -- activating app fronts a member over the hero for a beat -- the
            -- "return blink". The user's own click already fronted the hero.
            table.insert(fake.windows, 1,
                { id = 77, title = "X", appName = "Other", bundleID = "com.x", x = 5, y = 5, w = 90, h = 90 })
            focusWin(77)                   -- peek a non-deck window (sets peeked)
            fake.raises, fake.focused = {}, {}
            focusWin(2)                    -- return to the hero: NO raises, NO focus
            ok(#fake.raises == 0 and #fake.focused == 0,
                "a peek-return raises and focuses NOTHING (the no-blink guarantee)")
            -- the deferred reclean lands on the NEXT beat (a swap), under motion
            -- cover: members re-raised, then the hero lifted LAST via a real FOCUS
            -- (beats an activating member). Ordering proof: under raiseActivates
            -- the LAST activation wins, so the hero's app ending frontmost shows
            -- the hero lift came after the member raises.
            fake.raises, fake.focused = {}, {}
            focusWin(3)                    -- swap -> beat -> landHero -> reclean
            ok(#fake.raises == 3 and #fake.focused == 1 and fake.focused[1] == 3,
                "the next beat recleans: 3 member raises + exactly one hero FOCUS "
                .. "(activation echoes never re-promote, no loop)")
            ok(fake.frontmostId == "com.tr",
                "the hero's own app is frontmost after the reclean (hero lift came last)")
            fake.fireTimers("after")       -- clear the reclean's settle window
            ok(registry.liveHandleCount() == 17,
                "no stray handle: 7 base + frame watcher + 4 member borders + 1 ghost + 4 ⌥number hotkeys (FOCUS)")

            fake.pressHotkey("k", HYP)     -- exit
            ok(registry.liveHandleCount() == 1, "clean after the blink regression")
            registry.setEnabled("window_deck", false)
            fake.raiseActivates = false
        end

        -- T-WD-peek-mid-flight: a peek during a promote flight keeps its focus ----
        -- landHero's reclean then runs while a NON-deck window holds focus. The
        -- hero's lift must fall back to the surgical raise: a real focus would
        -- yank focus off the peek, breaking "a peek stays on top while it holds
        -- focus". raiseDeck gates on focusedMember() captured BEFORE the raises.
        do
            fake.windows = quadWindows()
            registry.setEnabled("window_deck", true)
            enterDeck()
            focusWin(2)                    -- promote TL -> hero
            table.insert(fake.windows, 1,
                { id = 88, title = "P", appName = "Peek", bundleID = "com.peek", x = 5, y = 5, w = 90, h = 90 })
            focusWin(88)                   -- peek a non-deck window (sets peeked)
            focusWin(3, nil, true)         -- back to TR -> swap beat starts, mid-flight
            focusWin(88, nil, true)        -- user peeks AGAIN during the flight
            fake.raises, fake.focused = {}, {}
            fake.fireTimers("after")       -- step 1 lands -> step 2 launches
            fake.fireTimers("after")       -- step 2 lands -> landHero -> reclean
            ok(#fake.focused == 0,
                "reclean under a mid-flight peek never FOCUSES the hero (the peek keeps focus)")
            ok(#fake.raises == 4 and fake.raises[#fake.raises] == 3,
                "the hero is still lifted surgically, last, above the members")
            fake.pressHotkey("k", HYP)     -- exit
            registry.setEnabled("window_deck", false)
            ok(registry.liveHandleCount() == 0, "clean after the mid-flight peek regression")
        end

        -- T-WD-chrome-peek: the deck chrome (scrim + rings) is bound to the deck's
        -- FRONT context. It hides while a non-deck window is focused (a peek) so a
        -- ring never floats OVER that window and the scrim never dims it, then
        -- re-shows on return. Pure overlay ordering -- no window raise, no blink.
        do
            fake.windows = quadWindows()
            registry.setEnabled("window_deck", true)
            enterDeck()
            focusWin(2)                    -- promote a hero: chrome shown
            ok(fake.liveScrim() and not fake.liveScrim().hidden,
                "the scrim is visible while the deck holds focus")
            table.insert(fake.windows, 1,
                { id = 91, title = "N", appName = "NonDeck", bundleID = "com.n", x = 5, y = 5, w = 90, h = 90 })
            focusWin(91)                   -- peek a non-deck window
            ok(fake.liveScrim().hidden,
                "a peek hides the container scrim (no dim floats over the non-deck window)")
            ok(fake.liveWidget().hidden, "a peek hides the indicator widget too")
            do
                local anyShown = false
                for _, o in ipairs(fake.liveOutlines()) do
                    if not o.hidden then anyShown = true end
                end
                ok(not anyShown, "a peek hides every ring (none floats over the non-deck window)")
            end
            focusWin(2)                    -- return to the hero
            ok(not fake.liveScrim().hidden, "returning to the deck re-shows the scrim")
            ok(not fake.liveWidget().hidden, "returning to the deck re-shows the widget")
            do
                local anyHidden = false
                for _, o in ipairs(fake.liveOutlines()) do
                    if o.hidden then anyHidden = true end
                end
                ok(not anyHidden, "returning to the deck re-shows every ring")
            end
            fake.pressHotkey("k", HYP)     -- exit
            registry.setEnabled("window_deck", false)
            ok(registry.liveHandleCount() == 0, "clean after the chrome-peek test")
        end

        -- T-WD-occlusion: BORDER HONESTY. A peek then a bare return does NOT
        -- re-order windows (that is the "return blink" we refuse) -- so a member
        -- still sitting behind the ex-peek would, naively, get a ring drawn OVER
        -- that foreign window. renderBorders instead detects the occlusion from
        -- the CG z-order (list order) + geometry and draws no ring for it. Only
        -- the returned-to hero (on top via the user's click, per AX) keeps its
        -- ring; the beat that later re-raises the deck restores the rest.
        -- Helper: classify the live deck-member rings (skip the ghost/scrim).
        local function ringVisibility()
            local heroVisible, otherShown, otherHidden = false, 0, 0
            for _, o in ipairs(fake.liveOutlines()) do
                if o.kind == "hero" then
                    if not o.hidden then heroVisible = true end
                elseif o.kind == "member" or o.kind == "focus" then
                    if o.hidden then otherHidden = otherHidden + 1 else otherShown = otherShown + 1 end
                end
            end
            return heroVisible, otherShown, otherHidden
        end
        do
            fake.settings["hammerdeck.state.window_deck.heroMode"] = nil   -- explicit: Hero ON (default)
            fake.screenList = { SCREEN }   -- single-screen fast path (no display picker)
            fake.mousePos = { x = 10, y = 10 }
            fake.windows = quadWindows()
            registry.setEnabled("window_deck", true)
            enterDeck()
            focusWin(2)                    -- promote TL -> hero (on top)
            -- a full-screen foreign window now covers the whole deck, listed in
            -- FRONT (row 1 == frontmost). A real cmd-tab'd window, unlike the tiny
            -- placeholders elsewhere, actually covers the member slots.
            table.insert(fake.windows, 1,
                { id = 99, title = "Cover", appName = "Cover", bundleID = "com.cover",
                  x = 0, y = 0, w = 1440, h = 900 })
            focusWin(99)                   -- peek: chrome hidden
            focusWin(2)                    -- return to the hero (still row 3, behind the cover in CG)
            do
                local heroVisible, otherShown, otherHidden = ringVisibility()
                ok(heroVisible,
                    "peek-return: the hero keeps its ring (AX says it is frontmost, even as CG lags)")
                ok(otherHidden == 3 and otherShown == 0,
                    "peek-return: members still behind the ex-peek draw NO ring (border honesty, no re-order)")
            end
            -- the ex-peek slots get no scrim hole either -- dimmed, not revealed
            ok(#fake.liveScrim().holes == 1,
                "an occluded member punches no hole (the hero's is the only cutout)")
            -- a beat re-raises the deck -> peek cleared -> every ring/hole restored
            focusWin(3)                    -- swap -> beat -> landHero -> reclean
            do
                local _, otherShown, otherHidden = ringVisibility()
                ok(otherShown >= 1 and otherHidden == 0,
                    "the beat's reclean restores every hidden ring (deck back on top)")
            end
            fake.pressHotkey("k", HYP)     -- exit
            registry.setEnabled("window_deck", false)
            ok(registry.liveHandleCount() == 0, "clean after the occlusion test")
        end

        -- T-WD-occlusion-grid: Hero-OFF grid mode has NO beat to ever reclean, so
        -- a peeked window would bleed through the grid forever. Border honesty is
        -- the whole fix here: the focused tile keeps its (bold) ring; every other
        -- tile still behind the ex-peek draws none.
        do
            fake.settings["hammerdeck.state.window_deck.heroMode"] = "off"
            fake.screenList = { SCREEN }   -- single-screen fast path (no display picker)
            fake.mousePos = { x = 10, y = 10 }
            fake.windows = quadWindows()
            registry.setEnabled("window_deck", true)
            enterDeck()
            focusWin(2)                    -- grid focus: no hero, TL gets the bold ring
            table.insert(fake.windows, 1,
                { id = 98, title = "Cover", appName = "Cover", bundleID = "com.cov2",
                  x = 0, y = 0, w = 1440, h = 900 })
            focusWin(98)                   -- peek: chrome hidden
            focusWin(2)                    -- back to the grid tile (behind the cover in CG)
            do
                local shown, hidden = 0, 0
                for _, o in ipairs(fake.liveOutlines()) do
                    if o.kind == "member" or o.kind == "focus" then
                        if o.hidden then hidden = hidden + 1 else shown = shown + 1 end
                    end
                end
                ok(shown == 1 and hidden == 3,
                    "grid peek-return: only the focused tile keeps its ring; the occluded three draw none")
            end
            fake.pressHotkey("k", HYP)     -- exit
            registry.setEnabled("window_deck", false)
            fake.settings["hammerdeck.state.window_deck.heroMode"] = nil
            ok(registry.liveHandleCount() == 0, "clean after the grid-occlusion test")
        end

        -- T-WD-occlusion-reenter: the occlusion set must NOT leak across decks. The
        -- controller is memoized for the whole enablement (init.lua "one controller
        -- per enablement"), so a deck left with members occluded (grid mode, where
        -- st.peeked never clears) must reset st.occluded on exit -- else the NEXT
        -- deck's commit -> syncScrim reads the stale set and skips punching holes
        -- for live members (dimming them until the first focus event). This drives
        -- the real toggle-off/toggle-on path (one enablement), which every other
        -- case sidesteps by disabling the feature (which discards the controller).
        do
            fake.settings["hammerdeck.state.window_deck.heroMode"] = "off"   -- grid: peeked never self-clears
            fake.screenList = { SCREEN }
            fake.mousePos = { x = 10, y = 10 }
            fake.windows = quadWindows()
            registry.setEnabled("window_deck", true)
            enterDeck()
            focusWin(2)                    -- grid focus a tile
            table.insert(fake.windows, 1,
                { id = 97, title = "Cover", appName = "Cover", bundleID = "com.cov3",
                  x = 0, y = 0, w = 1440, h = 900 })
            focusWin(97)                   -- peek: chrome hidden
            focusWin(2)                    -- occlusion set: the three non-focused tiles
            fake.pressHotkey("k", HYP)     -- toggle OFF -> exitDeck (must clear st.occluded)
            table.remove(fake.windows, 1)  -- the peeked window is gone before the next deck
            enterDeck()                    -- toggle ON again -- SAME controller, fresh deck
            ok(#fake.liveScrim().holes == 4,
                "re-enter after an occluded exit punches a hole for EVERY member (no stale occlusion leak)")
            fake.pressHotkey("k", HYP)     -- exit
            registry.setEnabled("window_deck", false)
            fake.settings["hammerdeck.state.window_deck.heroMode"] = nil
            ok(registry.liveHandleCount() == 0, "clean after the occlusion-reenter test")
        end

        -- T-WD-widget-drag: dragging the indicator persists its position as an
        -- OFFSET from the deck screen, so it returns there on the next deck.
        do
            fake.windows = quadWindows()
            fake.screenList = { SCREEN }
            registry.setEnabled("window_deck", true)
            enterDeck()
            local w = fake.liveWidget()
            ok(w and w.pos.x == SCREEN.x + 20 and w.pos.y == SCREEN.y + 20,
                "the widget starts at the default top-left inset (20, 20)")
            w.onMove(SCREEN.x + 300, SCREEN.y + 140)   -- simulate a drag
            fake.pressHotkey("k", HYP)                  -- exit (feature stays enabled)
            enterDeck()                                 -- re-enter
            local w2 = fake.liveWidget()
            ok(w2 and w2.pos.x == SCREEN.x + 300 and w2.pos.y == SCREEN.y + 140,
                "the dragged position persists to the next deck (offset from the screen)")
            w2.onMove(SCREEN.x + 20, SCREEN.y + 20)     -- restore default for later tests
            fake.pressHotkey("k", HYP)
            registry.setEnabled("window_deck", false)
        end

        -- T-WD-widget-exit: the widget carries the deck screen's display name, and
        -- its Exit button exits the deck (full teardown, like a double ⌥Esc).
        do
            fake.windows = quadWindows()
            fake.screenList = { SCREEN }
            registry.setEnabled("window_deck", true)
            enterDeck()
            local w = fake.liveWidget()
            ok(w and w.name == SCREEN.name, "the widget shows the deck screen's display name")
            ok(w.screen and w.screen.w == SCREEN.w, "the widget gets the deck screen as its drag clamp")
            ok(fake.liveScrim() ~= nil and registry.liveHandleCount() == 16, "deck live before the Exit click")
            w.onExit()                                  -- click the Exit button
            ok(fake.liveScrim() == nil and registry.liveHandleCount() == 1,
                "the widget Exit button exits the deck (chrome gone, only the toggle left)")
            registry.setEnabled("window_deck", false)
        end

        -- T-WD-switcher: the widget's mini-map has a cell per window (row-major),
        -- lights the hero's cell, switches the hero on a cell click, and drops to
        -- the flat grid when you click the hero's own cell.
        do
            fake.windows = quadWindows()
            fake.screenList = { SCREEN }
            registry.setEnabled("window_deck", true)
            enterDeck()
            local w = fake.liveWidget()
            ok(w and w.cols == 2 and #w.colors == 4,
                "the mini-map has a cell per window at the grid's column count (2x2)")
            ok(w.hero == 0, "no cell is lit in the flat grid (no hero yet)")
            focusWin(2)                    -- promote the top-left window (id 2) -> cell 1
            ok(w.hero == 1, "promoting the top-left window lights mini-map cell 1")
            -- click a NON-hero cell -> focuses that window (drives the promote beat
            -- through the existing path; cell 4 = bottom-right = id 1)
            fake.focused = {}
            w.onSwitch(4)
            ok(fake.focused[#fake.focused] == 1,
                "clicking cell 4 focuses the bottom-right window (reuses the promote path)")
            -- click the HERO's own cell -> drop back to the flat grid
            focusWin(2)                    -- re-establish the TL hero at cell 1
            ok(w.hero == 1, "TL hero re-lit at cell 1")
            w.onSwitch(1)
            fake.fireTimers("after")       -- land the drop beat -> renderBorders -> setHero
            ok(w.hero == 0 and fake.liveOutline("hero") == nil,
                "clicking the hero's own cell drops back to the flat grid (no hero lit)")
            fake.pressHotkey("k", HYP)
            registry.setEnabled("window_deck", false)
        end

        -- T-WD-numkeys: ⌥1-9 switch the hero to that mini-map cell (shares
        -- switchToCell with the mini-map clicks).
        do
            fake.windows = quadWindows()
            fake.screenList = { SCREEN }
            registry.setEnabled("window_deck", true)
            enterDeck()
            local w = fake.liveWidget()
            fake.focused = {}
            fake.pressHotkey("4", { "alt" })   -- ⌥4 -> cell 4 = bottom-right = id 1
            ok(fake.focused[#fake.focused] == 1,
                "⌥4 focuses the bottom-right window (same as clicking mini-map cell 4)")
            focusWin(2)                        -- TL -> hero at cell 1
            ok(w.hero == 1, "TL promoted to hero (cell 1)")
            fake.pressHotkey("1", { "alt" })   -- ⌥1 on the hero's own cell
            fake.fireTimers("after")
            ok(w.hero == 0 and fake.liveOutline("hero") == nil,
                "⌥ on the hero's own cell drops back to the flat grid")
            fake.pressHotkey("k", HYP)
            registry.setEnabled("window_deck", false)
        end

        -- T-WD-hero-toggle: the widget's Hero switch gates promotion -- off = a pure
        -- grid tiler (focusing a window does not zoom it) -- and the choice persists.
        do
            fake.windows = quadWindows()
            fake.screenList = { SCREEN }
            registry.setEnabled("window_deck", true)
            enterDeck()
            local w = fake.liveWidget()
            ok(w.heroMode == true, "Hero starts ON by default")
            local hintOn = w.switchHint
            focusWin(2)
            ok(w.hero == 1 and fake.liveOutline("hero") ~= nil,
                "with Hero on, focusing a window zooms it into a hero")
            w.onToggleHero(false)          -- flip Hero OFF
            fake.fireTimers("after")       -- land the drop beat
            ok(w.hero == 0 and fake.liveOutline("hero") == nil,
                "flipping Hero off drops the current hero back to the grid")
            ok(w.switchHint ~= hintOn, "the mini-map hint rewords for grid-only mode when Hero is off")
            focusWin(3)                    -- focus another window
            ok(fake.liveOutline("hero") == nil,
                "with Hero off, focusing a window does not zoom it (pure grid tiler)")
            ok(#fake.liveOutlines("focus") == 1 and #fake.liveOutlines("member") == 3,
                "with Hero off, the focused window gets a bold FOCUS ring; the rest stay subtle members")
            w.onToggleHero(true)           -- flip Hero back ON (window 3 still focused)
            ok(w.switchHint == hintOn, "the hint reverts when Hero is toggled back on")
            -- Regression: toggling Hero ON must zoom whatever window is focused
            -- RIGHT NOW, without waiting for a fresh focus event. It used to only
            -- set the flag and sit flat until you re-focused something.
            fake.fireTimers("after")       -- land the promote beat the toggle kicked off
            fake.fireTimers("after")
            ok(fake.liveOutline("hero") ~= nil and w.hero ~= 0,
                "toggling Hero on immediately promotes the already-focused window")
            focusWin(2)                    -- and a fresh focus still promotes a different window
            ok(fake.liveOutline("hero") ~= nil and w.hero ~= 0,
                "flipping Hero on restores focus-to-hero")
            -- persistence: off -> exit -> re-enter starts off
            w.onToggleHero(false)
            fake.fireTimers("after")
            fake.pressHotkey("k", HYP)
            enterDeck()
            ok(fake.liveWidget().heroMode == false, "the Hero choice persists to the next deck")
            fake.liveWidget().onToggleHero(true)   -- restore default for later tests
            fake.pressHotkey("k", HYP)
            registry.setEnabled("window_deck", false)
        end

        -- T-WD-picker-hero: the picker's Hero switch sets (and persists) the deck's
        -- starting mode.
        do
            fake.windows = quadWindows()
            fake.screenList = { SCREEN }
            registry.setEnabled("window_deck", true)
            fake.pressHotkey("k", HYP)
            local dp = fake.openDisplayPicker()
            if dp then dp.userConfirm(dp.preselect) end
            local p = fake.openWindowPicker()
            ok(p ~= nil and p.hero == true,
                "the picker's Hero switch starts from the persisted value (on)")
            p.setHero(false)               -- flip the picker's Hero switch off
            p.confirm(nil)
            fake.fireTimers("after")
            ok(fake.liveWidget().heroMode == false,
                "confirming the picker with Hero off enters a grid-only deck")
            fake.pressHotkey("k", HYP)     -- exit
            enterDeck()                    -- default enter -> starts off (persisted)
            ok(fake.liveWidget().heroMode == false, "the picker's Hero choice persisted")
            fake.liveWidget().onToggleHero(true)   -- restore default for later tests
            fake.pressHotkey("k", HYP)
            registry.setEnabled("window_deck", false)
        end

        -- T-WD-rearrange: dragging a window off its slot enables the widget's
        -- Rearrange button; clicking it snaps every window home and clears the state.
        do
            fake.windows = quadWindows()
            fake.screenList = { SCREEN }
            registry.setEnabled("window_deck", true)
            enterDeck()
            local w = fake.liveWidget()
            ok(w.dirty == false, "Rearrange starts disabled -- the deck is freshly tiled")
            fake.fireFrameEvent{ bundleID = "com.tl", title = "TL", x = 500, y = 400, w = 300, h = 200 }
            fake.fireTimers("after")       -- settle -> renderBorders -> dirty recompute
            ok(w.dirty == true, "dragging a window off its slot enables Rearrange")
            fake.windowFrameSets = {}
            w.onRearrange()                -- click Rearrange
            local back = lastSetFor(2)     -- TL is window id 2
            ok(back and near(back.x, TLslot.x) and near(back.y, TLslot.y),
                "Rearrange snaps the dragged window back to its slot")
            ok(w.dirty == false, "Rearrange clears the dirty state (every window home)")
            fake.pressHotkey("k", HYP)
            registry.setEnabled("window_deck", false)
        end

        -- T-WD-reorder: dragging one mini-map CELL onto another (in the widget)
        -- swaps the two windows' slots and re-colors the mini-map to match.
        do
            fake.windows = quadWindows()
            fake.screenList = { SCREEN }
            registry.setEnabled("window_deck", true)
            enterDeck()
            local w = fake.liveWidget()
            local c1, c3 = w.colors[1], w.colors[3]   -- TL cell + BL cell colors
            fake.windowFrameSets = {}
            w.onReorder(1, 3)              -- drag mini-map cell 1 (TL) onto cell 3 (BL)
            local moved = lastSetFor(2)    -- TL window (id 2) -> BL slot
            ok(moved and near(moved.x, BLslot.x) and near(moved.y, BLslot.y),
                "reordering cell 1 onto cell 3 moves the TL window into the BL slot")
            ok(w.colors[1] == c3 and w.colors[3] == c1,
                "the mini-map cell colors swap to match the new arrangement")
            ok(w.dirty == false, "after a cell-swap every window sits on a slot (not dirty)")
            fake.pressHotkey("k", HYP)
            registry.setEnabled("window_deck", false)
        end

        -- T-WD-screenchange: the deck's screen is powered off / reconfigured. The
        -- old fixed-rect banner got orphaned onto a surviving display; the scrim's
        -- title rides a full-screen element the deck RE-ANCHORS -- or, if the deck's
        -- screen is GONE, the deck exits cleanly (its tiled world no longer exists)
        -- instead of stranding chrome on another screen.
        do
            -- (a) screen still present but moved/resized -> re-anchor, deck stays
            fake.screenList = { SCREEN }
            fake.windows = quadWindows()
            registry.setEnabled("window_deck", true)
            enterDeck()
            ok(fake.liveScrim() ~= nil, "deck live with a scrim before the reconfig")
            fake.screenList = { { x = 200, y = 0, w = 1600, h = 1000,
                                  name = "Main", index = 1, builtin = true } }
            fake.systemEvent("screenChanged")
            ok(fake.liveScrim() ~= nil,
                "a moved/resized deck screen keeps the deck (not orphaned, not exited)")
            ok(fake.liveScrim().screenFrame.w == 1600,
                "the scrim re-anchors to the deck screen's new frame")
            ok(fake.liveWidget() and fake.liveWidget().pos.x == 200 + 20,
                "the widget re-anchors onto the moved deck screen (offset preserved)")

            -- (b) deck screen GONE -> exit cleanly, no orphaned chrome
            fake.screenList = { { x = 0, y = 0, w = 1440, h = 900,
                                  name = "External", index = 1, builtin = false } }
            fake.systemEvent("screenChanged")
            ok(fake.liveScrim() == nil,
                "when the deck's screen disconnects the deck exits (no scrim orphaned elsewhere)")
            ok(registry.liveHandleCount() == 1, "the disconnect exit drops every deck handle but the toggle")

            registry.setEnabled("window_deck", false)
            fake.screenList = { SCREEN }
            ok(registry.liveHandleCount() == 0, "clean after the screen-change test")
        end

        -- T-WD2: focus-driven promotion + swap + escalating Escape ----------------
        fake.windows = quadWindows()
        registry.setEnabled("window_deck", true)
        enterDeck()                                    -- GRID
        fake.windowFrameSets = {}

        fake.raises = {}
        focusWin(2, nil, true)                        -- focus TL (cross-app), mid-flight
        do
            -- the polish: the real window's move is DISPATCHED at flight START (the
            -- ring covers the async AX apply), not when the ring lands -- the ring
            -- sat alone at the hero rect while the window popped in late otherwise
            local mid = lastSetFor(2)
            ok(mid and near(mid.w, HERO.w) and near(mid.h, HERO.h),
                "the promoted window's move is dispatched at flight start (under the ring)")
        end
        fake.fireTimers("after")
        fake.fireTimers("after")
        local heroSet = lastSetFor(2)
        ok(heroSet and near(heroSet.x, HERO.x) and near(heroSet.w, HERO.w)
            and near(heroSet.h, HERO.h),
            "focusing a group window promotes it to the centered hero (~78%)")
        do
            local hb = fake.liveOutline("hero")
            ok(hb and near(hb.frame.x, HERO.x) and near(hb.frame.w, HERO.w) and near(hb.frame.h, HERO.h),
                "a strong hero border marks the hero's bounds at the ~78% rect")
            local ghost = fake.liveOutline("ghost")
            ok(ghost and near(ghost.frame.x, TLslot.x) and near(ghost.frame.y, TLslot.y),
                "a ghost border marks the hero's home slot (where it drops back to)")
            ok(hb and ghost and hb.color ~= "" and hb.color == ghost.color,
                "the hero border and its ghost share the hero window's own color")
            ok(#fake.liveOutlines("member") == 3, "the other three members keep their subtle borders")
            local holed = 0
            for _, o in ipairs(fake.liveOutlines("member")) do
                if o.hole and near(o.hole.x, HERO.x) and near(o.hole.w, HERO.w) then holed = holed + 1 end
            end
            ok(holed == 3 and ghost.hole and near(ghost.hole.x, HERO.x),
                "member + ghost borders clip the hero rect out (no lines drawn across the hero)")
        end
        ok(#fake.raises == 0,
            "a plain promote does NOT re-raise the deck (already on top -- no needless blink)")

        fake.windowFrameSets = {}
        focusWin(3, nil, true)                        -- focus TR -> swap, step 1 mid-flight
        ok(lastSetFor(2) ~= nil and lastSetFor(3) == nil,
            "swap step 1: the old hero steps home first -- the incoming window has not moved yet")
        fake.fireTimers("after")                      -- step 1 lands -> step 2 launches
        ok(lastSetFor(3) ~= nil,
            "swap step 2: the incoming window's move dispatches as its ring lifts off")
        fake.fireTimers("after")                      -- step 2 lands
        local demoted = lastSetFor(2)
        ok(demoted and near(demoted.x, TLslot.x) and near(demoted.y, TLslot.y),
            "the outgoing hero drops back into its grid slot")
        local promoted = lastSetFor(3)
        ok(promoted and near(promoted.x, HERO.x) and near(promoted.w, HERO.w),
            "the newly-focused window becomes the hero")
        ok(fake.liveOutline("hero") ~= nil and #fake.liveOutlines("member") == 3,
            "after a swap: one hero border, three member borders (re-styled, not leaked)")
        do
            -- the sequenced beat: the outgoing hero's step-back is recorded BEFORE
            -- the incoming hero's grow (old back first, then the new steps out)
            local di, pi
            for i, s in ipairs(fake.windowFrameSets) do
                if s.id == 2 and not di then di = i end
                if s.id == 3 and not pi then pi = i end
            end
            ok(di and pi and di < pi,
                "the swap plays as a beat: the old hero steps back before the new one grows")
            local hb2 = fake.liveOutline("hero")
            ok(hb2 and (hb2.flights or 0) >= 1,
                "the incoming window's ring FLIES to the hero rect (the flight carries the eye)")
        end

        -- blur = stay: focusing a NON-group window changes nothing (it's a peek --
        -- left on top, deck NOT re-raised, so the peeked window stays visible)
        fake.windowFrameSets = {}
        fake.raises = {}
        table.insert(fake.windows, 1,
            { id = 99, title = "Inbox", appName = "Mail", bundleID = "com.mail", x = 200, y = 200, w = 300, h = 200 })
        focusWin(99)                                   -- focus a NON-group window
        ok(#fake.windowFrameSets == 0, "focus leaving the group is ignored -- no reshuffle")
        ok(#fake.raises == 0, "peeking a non-deck window does NOT raise the deck (peek stays on top)")

        -- returning to the hero after a peek moves no frames AND raises nothing --
        -- the user's own click already fronted the hero; raising here is what
        -- flashed members over the hero (the "return blink"). The reclean that
        -- sinks the ex-peek waits for the next beat's motion cover.
        fake.windowFrameSets = {}
        fake.raises, fake.focused = {}, {}
        focusWin(3)                                   -- return to the current hero after the peek
        ok(#fake.windowFrameSets == 0, "re-focusing the current hero moves no frames")
        ok(#fake.raises == 0 and #fake.focused == 0,
            "the bare return raises nothing (no-blink); the reclean is deferred to the next beat")

        -- escalating Escape: first drops the hero to GRID (banner stays), second exits.
        -- The drop is a reverse ring flight: the window's move home is dispatched at
        -- flight START (read before the flush proves it), the flush then lands the
        -- ring and re-renders the borders. The drop is also a beat: the reclean the
        -- peek above deferred lands HERE, under the drop's motion cover.
        fake.windowFrameSets = {}
        fake.raises, fake.focused = {}, {}
        fake.pressHotkey("escape", { "alt" })
        local dropped = lastSetFor(3)                  -- BEFORE the flight timer fires
        ok(dropped and near(dropped.x, TRslot.x) and near(dropped.y, TRslot.y),
            "first ⌥Esc dispatches the hero's move home at flight start (under the ring)")
        fake.fireTimers("after")
        fake.fireTimers("after")
        ok(fake.liveScrim() ~= nil, "first ⌥Esc keeps the deck active (scrim still up)")
        ok(#fake.raises == 4 and #fake.focused == 0,
            "the deferred reclean lands on the drop beat: all four members re-raised "
            .. "above the ex-peek (no hero left, so no focus lift)")
        ok(fake.liveOutline("hero") == nil and fake.liveOutline("ghost") == nil
            and #fake.liveOutlines("member") == 4,
            "dropping the hero to GRID: hero/ghost borders gone, all four back to member borders")
        do
            local anyHole = false
            for _, o in ipairs(fake.liveOutlines("member")) do
                if o.hole then anyHole = true end
            end
            ok(not anyHole, "back in GRID the borders clear their hero hole (full rings again)")
        end
        fake.pressHotkey("escape", { "alt" })
        ok(fake.liveScrim() == nil, "second ⌥Esc exits the deck")
        ok(registry.liveHandleCount() == 1, "exit left only the toggle bound")

        -- T-WD2b: a fast second switch mid-flight ---------------------------------
        -- The beat dispatches the promoted window toward the hero rect at flight
        -- START, so a beat cancelled mid-air (a newer promotion) must step that
        -- half-flown window back to its slot -- never strand it at centre.
        fake.windows = quadWindows()
        enterDeck()
        fake.windowFrameSets = {}
        focusWin(2, nil, true)                        -- TL's beat starts (mid-flight)
        focusWin(3, nil, true)                        -- TR takes over before the ring lands
        do
            local back = lastSetFor(2)
            ok(back and near(back.x, TLslot.x) and near(back.y, TLslot.y),
                "a beat cancelled mid-flight steps its half-flown window back to its slot")
        end
        fake.fireTimers("after")
        fake.fireTimers("after")
        do
            local hero2 = lastSetFor(3)
            ok(hero2 and near(hero2.w, HERO.w), "the newer focus wins the hero")
        end
        fake.pressHotkey("k", HYP)                     -- exit
        ok(registry.liveHandleCount() == 1, "clean after the mid-flight cancel test")

        -- T-WD3: within-app promotion via the focus observer (cmd+`) --------------
        -- Two windows of the SAME app: only the AXObserver path (onFocusChanged) can
        -- see this switch -- app activation never fires.
        fake.windows = {
            { id = 10, title = "Downloads", appName = "Finder", bundleID = "com.apple.finder", x = 100, y = 500, w = 400, h = 300 },
            { id = 11, title = "Documents", appName = "Finder", bundleID = "com.apple.finder", x = 100, y = 100, w = 400, h = 300 },
        }
        enterDeck()                                    -- GRID (2 Finder windows)
        fake.windowFrameSets = {}
        focusWin(11, true)                            -- focus the other Finder window (same app)
        local within = lastSetFor(11)
        ok(within and near(within.x, HERO.x) and near(within.w, HERO.w),
            "a within-app focus change (focus observer) promotes the newly-focused window")
        fake.pressHotkey("k", HYP)                     -- exit
        ok(registry.liveHandleCount() == 1, "clean after within-app test")

        -- T-WD4: edges -----------------------------------------------------------
        -- window closes mid-deck: the gone window is never rewritten, no crash
        fake.windows = quadWindows()
        enterDeck()
        focusWin(2)                                   -- TL is hero
        fake.windowFrameSets = {}
        do                                             -- BL (id=4) closes
            local kept = {}
            for _, w in ipairs(quadWindows()) do if w.id ~= 4 then kept[#kept + 1] = w end end
            fake.windows = kept
        end
        focusWin(3)                                   -- promote TR; BL is gone
        ok(lastSetFor(4) == nil, "a window that closed mid-deck is never rewritten")
        ok(lastSetFor(3) ~= nil, "the still-open windows keep working after one closes")
        fake.pressHotkey("k", HYP)                     -- exit

        -- hero closes -> deck falls back to GRID, so the next ⌥Esc EXITS (not drop)
        fake.windows = quadWindows()
        enterDeck()
        focusWin(2)                                   -- TL is hero
        do
            local kept = {}
            for _, w in ipairs(quadWindows()) do if w.id ~= 2 then kept[#kept + 1] = w end end
            table.insert(kept, 1,
                { id = 98, title = "Inbox", appName = "Mail", bundleID = "com.mail", x = 200, y = 200, w = 300, h = 200 })
            fake.windows = kept
        end
        focusWin(98)                                  -- hero gone; focus a non-group window
        fake.pressHotkey("escape", { "alt" })          -- mode is GRID now -> exits
        ok(fake.liveBanner() == nil,
            "when the hero window closes, the deck drops to GRID (one ⌥Esc then exits)")
        ok(registry.liveHandleCount() == 1, "clean after hero-closes test")

        -- >9 windows: the grid caps at 9
        do
            local many = {}
            for i = 1, 11 do
                many[i] = { id = 100 + i, title = "W" .. i, appName = "App" .. i,
                            bundleID = "com.w" .. i, x = (i % 4) * 200 + 20, y = math.floor(i / 4) * 200 + 20,
                            w = 150, h = 120 }
            end
            fake.windows = many
            fake.windowFrameSets = {}
            enterDeck()
            ok(#fake.windowFrameSets == 9, "the deck caps the grid at 9 windows")
            fake.pressHotkey("k", HYP)                  -- exit
        end

        -- colors: CHARACTERIZATION, not a regression test -- stored per-app
        -- colors load from state into the picker preview, and a full deck's
        -- colors stay distinct around them. (No 9-window input can force the
        -- dealer to duplicate -- cap == #PALETTE -- so distinctness here pins the
        -- property, it does not discriminate dealer implementations.)
        fake.settings["hammerdeck.state.window_deck.colors"] =
            '{"com.w2":"#30D158","com.w4":"#123456"}'   -- the LAST palette slot + a custom hex
        do
            local many = {}
            for i = 1, 9 do
                many[i] = { id = 300 + i, title = "C" .. i, appName = "App" .. i,
                            bundleID = "com.w" .. i, x = (i % 3) * 300 + 20,
                            y = (i % 3) * 200 + 20, w = 150, h = 120 }
            end
            fake.windows = many
            fake.pressHotkey("k", HYP)
            local p = fake.openWindowPicker()
            ok(p ~= nil and #p.items == 9 and p.items[2].color == "#30D158",
                "stored per-app colors load into the picker preview")
            local seen, dup = {}, false
            for _, it in ipairs(p.items) do
                if it.color and seen[it.color] then dup = true end
                seen[it.color] = true
            end
            ok(not dup, "a 9-window deck deals DISTINCT border colors even with stored colors in play")
            p.cancel()
        end
        fake.settings["hammerdeck.state.window_deck.colors"] = nil

        -- hero is set to the FULL ~78% and is NOT shrunk by an immediate read-back.
        -- (Regression: an earlier read-back-recenter ran ctx.window.frame() right
        -- after the async AX setFrame, saw the stale slot-sized frame, and re-centred
        -- the hero back down to a grid cell -- the ~25% hero bug. fake.focusedWindow is
        -- a deliberately tiny stale frame; the hero must still be full-size and no
        -- focused-window setFrame may fire.)
        fake.windows = quadWindows()
        enterDeck()
        fake.focusedWindow = { x = 0, y = 0, w = 200, h = 150, screenIndex = 1 }  -- stale/small read-back
        fake.windowFrameSets = {}
        local framesBefore = #fake.windowFrames
        focusWin(2)
        local promo = lastSetFor(2)
        ok(promo and near(promo.w, HERO.w) and near(promo.h, HERO.h),
            "the hero is set to the full ~78% size, not shrunk to its slot")
        ok(#fake.windowFrames == framesBefore,
            "no read-back re-center fires (it raced AX and shrank the hero to a grid cell)")
        fake.focusedWindow = nil
        fake.pressHotkey("k", HYP)                      -- exit

        -- T-WD5: the USER drags/resizes a member -> hide the ring until stable ----
        -- Live tracking would trail the drag (AX events throttle), so the deck
        -- hides the ring while frame events flow and re-shows it at the REAL frame
        -- once they go quiet. Our OWN AX moves echo the same events -- the echo
        -- guard must keep them from hiding rings mid-beat.
        fake.windows = quadWindows()
        enterDeck()
        do
            local function hiddenCount()   -- across ALL kinds (a hero ring can hide too)
                local n = 0
                for _, o in ipairs(fake.liveOutlines()) do
                    if o.hidden then n = n + 1 end
                end
                return n
            end
            -- a drag starts: first frame event hides TL's ring
            fake.fireFrameEvent{ bundleID = "com.tl", title = "TL", x = 400, y = 300, w = 300, h = 200 }
            ok(hiddenCount() == 1, "a user-dragged member hides its ring while in motion")
            -- more motion, then quiet: the stable timer re-shows at the REAL frame
            fake.fireFrameEvent{ bundleID = "com.tl", title = "TL", x = 500, y = 320, w = 300, h = 200 }
            fake.fireTimers("after")                    -- the stable timer fires
            local shown
            for _, o in ipairs(fake.liveOutlines("member")) do
                if o.frame and near(o.frame.x, 500) and near(o.frame.y, 320) then shown = o end
            end
            ok(shown ~= nil and not shown.hidden,
                "once stable, the ring re-shows at the window's REAL frame (not the stale slot)")
            -- our own beat moves must NOT hide rings: promote TL, then replay the
            -- move/resize echo the AX observer would deliver for our own setFrame
            focusWin(2, nil, true)                      -- beat dispatched, mid-flight
            fake.fireFrameEvent{ bundleID = "com.tl", title = "TL",
                                 x = HERO.x, y = HERO.y, w = HERO.w, h = HERO.h }
            ok(hiddenCount() == 0, "our own AX move's echo does not hide the ring (echo guard)")
            -- ...but a frame that DIVERGES from what we dispatched, even under an
            -- armed guard, is the user grabbing the window (promote-then-drag) --
            -- it must still be detected as motion
            fake.fireFrameEvent{ bundleID = "com.tl", title = "TL", x = 30, y = 700, w = 300, h = 200 }
            ok(hiddenCount() == 1,
                "a diverging frame under an armed echo guard is a USER drag -- ring hides")
            fake.fireTimers("after")
            fake.fireTimers("after")                    -- land the beat + settle the drag
            ok(hiddenCount() == 0, "all rings shown again after the beat and the drag settle")
            -- a render mid-drag must not un-hide a hidden ring: drag BL, then land
            -- a full swap beat with SELECTIVE flushes (flight timers only, 0.15s)
            -- while BL's stable timer (0.35s) is still pending -- the landing
            -- renderBorders must skip the dragged member
            fake.fireFrameEvent{ bundleID = "com.bl", title = "BL", x = 40, y = 40, w = 300, h = 200 }
            ok(hiddenCount() == 1, "BL's ring hides as its drag starts")
            focusWin(3, nil, true)                      -- swap toward TR, mid-drag
            fake.fireTimers("after", 0.15)              -- step 1 lands -> step 2 launches
            fake.fireTimers("after", 0.15)              -- step 2 lands -> renderBorders
            ok(hiddenCount() == 1,
                "a beat landing mid-drag does not re-show the dragged member's ring")
            fake.fireTimers("after")                    -- BL's stable timer fires
            ok(hiddenCount() == 0, "the dragged ring re-shows once its window settles")
        end
        fake.pressHotkey("k", HYP)                      -- exit
        ok(registry.liveHandleCount() == 1, "clean after the hide-until-stable test")

        -- T-WD6: retitling windows keep their deck identity (adoption) ------------
        -- Regression for the stranded-hero bug: members are keyed bundleID+title,
        -- so a retitle (browser tab switch, editor file switch -- sometimes caused
        -- by our own resize) used to break every later by-key lookup: the old hero
        -- could not be stepped home (it stayed at the hero rect UNDER the new
        -- hero) and exit could not restore the window. resolveIds adopts the
        -- renamed window (same app, unclaimed, at the member's last-known frame).
        fake.windows = quadWindows()
        enterDeck()
        focusWin(2)                                    -- TL is hero
        do
            for _, w in ipairs(fake.windows) do        -- the hero window RETITLES
                if w.id == 2 then w.title = "TL - now renamed" end
            end
            fake.windowFrameSets = {}
            focusWin(3)                                -- swap: the retitled old hero must step home
            local back = lastSetFor(2)
            ok(back and near(back.x, TLslot.x) and near(back.y, TLslot.y),
                "a RETITLED old hero is adopted and steps home -- never stranded under the new hero")
            local promoted = lastSetFor(3)
            ok(promoted and near(promoted.w, HERO.w),
                "the swap still promotes the newly-focused window after an adoption")
        end
        do                                             -- retitle a plain member, then exit
            for _, w in ipairs(fake.windows) do
                if w.id == 4 then w.title = "BL - renamed" end
            end
            fake.windowFrameSets = {}
            fake.pressHotkey("k", HYP)                 -- exit -> restore
            local restored = lastSetFor(4)
            ok(restored and restored.x == 100 and restored.y == 550,
                "a retitled member is adopted on exit and restored to its ORIGINAL frame")
        end
        ok(registry.liveHandleCount() == 1, "clean after the retitle-adoption test")

        -- T-WD7: wid-based identity (the hybrid) ----------------------------------
        -- Rows that carry the bridge-resolved CGWindowID are keyed by it, so a
        -- retitle never even needs the adoption fallback, and focus matching works
        -- through the wid ladder regardless of what the title says.
        fake.windows = quadWindows()
        for _, w in ipairs(fake.windows) do w.wid = 9000 + w.id end   -- stable OS ids
        enterDeck()
        fake.windowFrameSets = {}
        do
            -- promote via the focused WID while the reported title is nonsense --
            -- the ladder must match on wid, never looking at the title
            fake.windowTitle = "totally unrelated title"
            fake.frontmost, fake.frontmostId = "AppTL", "com.tl"
            fake.focusedWid = 9002
            fake.activateApp("AppTL", "com.tl")
            fake.fireTimers("after")
            fake.fireTimers("after")
            local promo = lastSetFor(2)
            ok(promo and near(promo.w, HERO.w),
                "promotion matches the focused window by its stable wid, not the title")
            -- the hero retitles: identity survives WITHOUT adoption (key = wid)
            for _, w in ipairs(fake.windows) do
                if w.id == 2 then w.title = "renamed again" end
            end
            fake.windowFrameSets = {}
            fake.focusedWid = 9003
            focusWin(3)                                -- swap (focusWin sets title too)
            local back = lastSetFor(2)
            ok(back and near(back.x, TLslot.x) and near(back.y, TLslot.y),
                "a retitled wid-keyed hero steps home -- identity held by the wid itself")
        end
        fake.pressHotkey("k", HYP)                      -- exit
        fake.focusedWid = nil
        ok(registry.liveHandleCount() == 1, "clean after the wid-identity test")

        -- multi-monitor: only the focused screen's windows are decked
        fake.screenList = {
            { x = 0,    y = 0, w = 1440, h = 900, name = "Left",  index = 1, builtin = true },
            { x = 1440, y = 0, w = 1440, h = 900, name = "Right", index = 2, builtin = false },
        }
        fake.windows = {
            { id = 201, title = "L1", appName = "AppL1", bundleID = "com.l1", x = 100,  y = 100, w = 300, h = 200 },
            { id = 202, title = "L2", appName = "AppL2", bundleID = "com.l2", x = 100,  y = 500, w = 300, h = 200 },
            { id = 203, title = "R1", appName = "AppR1", bundleID = "com.r1", x = 1600, y = 100, w = 300, h = 200 },
            { id = 204, title = "R2", appName = "AppR2", bundleID = "com.r2", x = 1600, y = 500, w = 300, h = 200 },
        }
        fake.focusedWindow = { x = 1600, y = 100, w = 300, h = 200, screenIndex = 2 }  -- focus on the right screen
        fake.windowFrameSets = {}
        fake.pressHotkey("k", HYP)
        -- multi-monitor: the display map opens with the ACTIVE screen pre-selected as
        -- the default, so a single Enter decks it.
        local dp = fake.openDisplayPicker()
        ok(dp and dp.title == "Deck which screen?"
            and #dp.displays == 2
            and dp.preselect[1] == 2
            and dp.displays[2].name == "Right",
            "multi-monitor opens the map with the CURRENT display (Right) pre-selected")
        ok(dp.displays[1].name == "Left",
            "the map lists displays in screen order (Left, Right)")
        dp.userConfirm(dp.preselect)   -- 'press Enter' on the pre-selected current display
        local wp = fake.openWindowPicker()
        ok(wp ~= nil and #wp.items == 2,
            "picking a screen leads to a window multi-select of only that screen's windows")
        ok(wp.screenFrame and wp.screenFrame.x == 1440,
            "the window picker opens centered on the PICKED display, not the key screen")
        wp.confirm(nil)
        ok(#fake.windowFrameSets == 2, "only the focused screen's two windows are decked")
        ok((lastSetFor(203) and lastSetFor(203).x >= 1440)
            and (lastSetFor(204) and lastSetFor(204).x >= 1440),
            "the decked windows are tiled onto the right screen")
        ok(lastSetFor(201) == nil and lastSetFor(202) == nil,
            "windows on the other screen are left untouched")
        fake.pressHotkey("k", HYP)                      -- exit

        registry.setEnabled("window_deck", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after window_deck test")
    end,
}
