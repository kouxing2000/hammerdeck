-- test/cases/_integration/platform/window_mode_escapes.lua -- the three ways a
-- window move escaped the contracts window_ops exists to hold.
--
-- Each is a WIRING defect: every unit involved was correct on its own, and the
-- bug lived in how they were connected. So each assertion below drives the real
-- path a user takes, never the helper the fix touched -- a test that called
-- window_ops directly would pass for all three even with the wiring restored to
-- what it was.
--
--   1. A generated preset action moved a window without consulting the lease,
--      while the built-in snaps beside it all did. The per-file mover guard in
--      window_mode_lease.lua cannot see this: window_snap gates SOME of its
--      actions, so the file reads as compliant.
--   2. A reconfig that renumbered two occupied displays left one mode running
--      with no lease at all, permanently -- rekey is the only post-reconfig path
--      either mode has, and nothing re-claims afterwards. (A lease is identified
--      by token and carries its screen as a field, so this is now a per-lease
--      field assignment that cannot collide; the case is what keeps it that way.)
--   3. A mode's own restore was recorded as an undoable step, so Rewind fired
--      after the mode exited re-applied the ARRANGEMENT, with the originals the
--      mode had already discarded.

return {
    id = "window_mode_escapes",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry
        local HYP = { "cmd", "alt", "ctrl" }
        local window_ops = require("platform.window_ops")

        local SCREEN  = { x = 0, y = 0, w = 1600, h = 1000, name = "Main", index = 1 }
        local SCREEN2 = { x = 1600, y = 0, w = 1280, h = 800, name = "Side", index = 2 }

        local function realLayout()
            return {
                { id = 1, wid = 101, title = "Editor",  appName = "Code",   bundleID = "com.code", x = 300, y = 200, w = 900, h = 600 },
                { id = 2, wid = 102, title = "Browser", appName = "Safari", bundleID = "com.saf",  x = 100, y = 80,  w = 800, h = 700 },
                { id = 3, wid = 103, title = "Mail",    appName = "Mail",   bundleID = "com.mail", x = 700, y = 300, w = 700, h = 500 },
                { id = 4, wid = 104, title = "Notes",   appName = "Notes",  bundleID = "com.not",  x = 60,  y = 500, w = 500, h = 400 },
            }
        end
        local REAL = {}
        for _, w in ipairs(realLayout()) do
            REAL[w.id] = { x = w.x, y = w.y, w = w.w, h = w.h }
        end

        local function reset()
            fake.screenList = { SCREEN }
            fake.windows = realLayout()
            fake.focusedWindow = { x = 300, y = 200, w = 900, h = 600, screenIndex = 1 }
            fake.focusedWid = 101
            fake.windowFrameSets = {}
            fake.dialogs = {}
        end
        local function lastSetFor(id)
            for i = #fake.windowFrameSets, 1, -1 do
                if fake.windowFrameSets[i].id == id then return fake.windowFrameSets[i] end
            end
            return nil
        end
        local function at(f, want)
            return f and math.abs(f.x - want.x) < 1 and math.abs(f.y - want.y) < 1
                and math.abs(f.w - want.w) < 1 and math.abs(f.h - want.h) < 1
        end
        local function liveDialog()
            for _, d in ipairs(fake.dialogs) do if d.open then return d end end
            return nil
        end
        local function enterDeck()
            fake.pressHotkey("k", HYP)
            local dp = fake.openDisplayPicker()
            if dp then dp.userConfirm(dp.preselect) end
            local p = fake.openWindowPicker()
            if p then p.confirm(nil) end
            fake.fireTimers("after")
        end

        -- The preset BEFORE the register: dynamicActions is expanded at register
        -- time off the stored setting, so a later write produces no action at all.
        fake.settings["hammerdeck.opt.window_snap.presets"] =
            '[{"id":"p1","name":"Reading","x":0,"y":0,"w":0.375,"h":0.9}]'
        registry.register(require("features.window_deck"))
        registry.register(require("features.window_fan"))
        registry.register(require("features.window_snap"))
        registry.register(require("features.window_rewind"))

        -- ---------------------------------------------------------------------
        -- 1. A SAVED PLACEMENT IS AN ORDINARY WINDOW MOVE.
        -- ---------------------------------------------------------------------
        registry.setEnabled("window_deck", true)
        registry.setEnabled("window_snap", true)
        reset()

        enterDeck()
        ok(window_ops.modeHolder(1) ~= nil, "control: the deck holds its screen")
        fake.windowFrameSets = {}
        fake.dialogs = {}

        local ran = registry.runAction("window_snap", "preset_p1")
        ok(ran == true, "the generated preset action exists and ran")
        local d = liveDialog()
        ok(d ~= nil,
            "a saved placement fired over a live mode ASKS first, like every built-in snap")
        ok(#fake.windowFrameSets == 0,
            "...and moves nothing while the question is open")
        if d then d.choose(d.actions[2]) end            -- Cancel
        fake.fireTimers("after")
        ok(window_ops.modeHolder(1) ~= nil,
            "declining leaves the deck holding its screen")
        ok(#fake.windowFrameSets == 0, "declining moved no window")

        registry.setEnabled("window_snap", false)
        registry.setEnabled("window_deck", false)
        reset()

        -- ---------------------------------------------------------------------
        -- 2. A RECONFIG NEVER LEAVES A LIVE MODE UNLEASED.
        --
        -- Driven at the window_ops level deliberately: the defect is in the lease
        -- bookkeeping itself, and both modes reach it through the same two calls
        -- (claimMode at enter, rekey from screenChanged). Driving two full modes
        -- across a fake reconfig would exercise far more than the invariant and
        -- still assert exactly this.
        -- ---------------------------------------------------------------------
        do
            local evicted = { a = 0, b = 0 }
            local a = window_ops.claimMode(1, "window_deck", "Window Deck",
                function() evicted.a = evicted.a + 1 end)
            local b = window_ops.claimMode(2, "window_fan", "Window Fan",
                function() evicted.b = evicted.b + 1 end)
            ok(window_ops.modeHolder(1).id == "window_deck"
                and window_ops.modeHolder(2).id == "window_fan",
                "control: two modes, one per display")

            -- The displays trade indices. Each mode rekeys from its OWN
            -- screenChanged handler, so they arrive one at a time -- and the first
            -- to arrive is moving onto an index the second has not left yet.
            a.rekey(2)
            b.rekey(1)

            ok(#window_ops.heldScreens() == 2,
                "both modes still hold a lease after the renumbering (neither was abandoned)")
            ok(window_ops.modeHolder(2) and window_ops.modeHolder(2).id == "window_deck",
                "the deck's lease followed it to its new index")
            ok(window_ops.modeHolder(1) and window_ops.modeHolder(1).id == "window_fan",
                "the fan's lease followed it to its new index")
            ok(evicted.a == 0 and evicted.b == 0,
                "a renumbering evicts nobody -- both modes are still on a real display")

            -- And each handle still releases its OWN lease: one keyed to the
            -- index it was claimed at would now clear someone else's, or nothing.
            a.stop()
            ok(window_ops.modeHolder(2) == nil,
                "the moved lease is released by its own handle")
            ok(window_ops.modeHolder(1) ~= nil, "...and only its own")
            b.stop()
            ok(#window_ops.heldScreens() == 0, "both released")
        end

        -- ---------------------------------------------------------------------
        -- 3. A MODE'S RESTORE IS THE UNDO, NOT A NEW UNDOABLE STEP.
        -- ---------------------------------------------------------------------
        reset()
        registry.setEnabled("window_deck", true)
        registry.setEnabled("window_rewind", true)

        enterDeck()
        local gridded = {}
        for id = 1, 4 do gridded[id] = lastSetFor(id) end
        ok(gridded[1] ~= nil and not at(gridded[1], REAL[1]),
            "control: the deck actually moved the windows off their originals")

        -- Time passes while the deck is up -- the ordinary case, and the one that
        -- makes this reachable. window_history coalesces writes inside a 0.4s gap,
        -- so an enter and an exit in the same tick fold into ONE group whose
        -- before-frames are the originals, and undo behaves by accident. Only once
        -- the restore opens a group of its own does it capture the ARRANGEMENT as
        -- the frames to go back to.
        fake.clockOffset = fake.clockOffset + 2

        -- Leave the deck: every member goes back where the user had it.
        fake.windowFrameSets = {}
        -- Escape escalates: hero -> grid, then exit. Pressing it twice lands on
        -- the exit whichever state the entry picker left the deck in.
        fake.pressHotkey("escape", { "alt" })
        fake.fireTimers("after")
        fake.pressHotkey("escape", { "alt" })
        fake.fireTimers("after")
        for _, w in ipairs(fake.windows) do
            local set = lastSetFor(w.id)
            if set then w.x, w.y, w.w, w.h = set.x, set.y, set.w, set.h end
        end
        ok(at(lastSetFor(1), REAL[1]), "control: leaving the deck restored the originals")
        ok(window_ops.modeHolder(1) == nil, "control: and released the screen")

        -- Past the coalescing gap, so an undo now would open a NEW group rather
        -- than folding into the deck's own writes. This is the window in which the
        -- bug was reachable: inside the gap the restore merged with the arrangement
        -- and undo behaved.
        fake.clockOffset = fake.clockOffset + 2
        fake.windowFrameSets = {}
        fake.pressHotkey("z", HYP)
        local dz = liveDialog()
        if dz then dz.choose(dz.actions[1]) end
        fake.fireTimers("after")

        -- Nothing should have been re-applied: the restore left no undoable step
        -- behind it, so rewind has nothing from the deck to roll back.
        local reapplied = 0
        for id = 1, 4 do
            local s = lastSetFor(id)
            if s and gridded[id] and at(s, gridded[id]) then reapplied = reapplied + 1 end
        end
        ok(reapplied == 0,
            "rewind after leaving a mode NEVER re-applies the arrangement (re-applied: "
            .. reapplied .. " of 4)")
        for _, w in ipairs(fake.windows) do
            ok(at({ x = w.x, y = w.y, w = w.w, h = w.h }, REAL[w.id]) or lastSetFor(w.id) == nil,
                "window " .. w.id .. " is still at the user's own frame")
        end

        registry.setEnabled("window_rewind", false)
        registry.setEnabled("window_deck", false)

        -- ---------------------------------------------------------------------
        -- 3b. THE SAME BUG, VIA THE PATH THAT ACTUALLY REACHES IT.
        --
        -- Case 3 above enters and leaves a deck with no interaction in between,
        -- and that is the ONE shape where not-recording the restore is enough:
        -- the enter-group survives, its before-frames are the originals, and undo
        -- is a no-op. Every real session moves something while the mode is up --
        -- a retile, a reflow, a promotion, a Rearrange -- and history keeps only
        -- the MOST RECENT group, so that move replaces the enter-group with one
        -- whose before-frames are the mode's own arrangement.
        --
        -- Driven at the window_ops level: the defect is entirely in the history
        -- bookkeeping, and reproducing it through a real deck needs a specific
        -- in-deck interaction that would couple this case to the deck's UI.
        -- window_ops is the layer both modes share and the layer the fix is in.
        -- ---------------------------------------------------------------------
        do
            local W = window_ops
            W.setHistoryEnabled(true)                  -- what window_rewind does
            fake.windows = { { id = 1, wid = 101, title = "A", appName = "X",
                               bundleID = "com.x", x = 300, y = 200, w = 900, h = 600 } }
            local ORIG = { x = 300, y = 200, w = 900, h = 600 }
            local ARRANGED = { x = 0, y = 0, w = 800, h = 1000 }

            W.list(); W.setFrameFor(1, ARRANGED)       -- the mode arranges
            fake.clockOffset = fake.clockOffset + 2    -- past the coalescing gap
            W.list(); W.setFrameFor(1, { x = 100, y = 100, w = 700, h = 900 })
            ok(fake.windows[1].x == 100, "control: a move happened while the mode was up")

            fake.clockOffset = fake.clockOffset + 2
            W.setFrameFor(1, ORIG, true)               -- the mode restores
            W.forgetPendingLayout()                    -- ...and forgets its own layout
            ok(fake.windows[1].x == 300, "control: the restore put the window back")

            fake.clockOffset = fake.clockOffset + 2
            local moved = W.undoLast()
            ok(moved == 0,
                "after a mode restores, undo has nothing of the mode's left to apply (moved "
                .. moved .. ")")
            ok(fake.windows[1].x == 300 and fake.windows[1].w == 900,
                "the window is still at the user's own frame, not the mode's")
            W.setHistoryEnabled(false)
        end
    end,
}
