-- test/cases/_integration/platform/window_mode_lease.lua -- ONE window mode per
-- screen, and what happens to the user's layout when a second one is triggered.
--
-- Window Deck and Window Fan each capture every member's CURRENT frame as the
-- frame to put back on exit. Run both at once and the second captures the FIRST
-- one's arrangement as the "original layout" -- so exiting deck-then-fan leaves
-- the user in the deck's grid with their real layout gone for good (undoLast is
-- single-step, not a snapshot). The lease in window_ops is what stops that, and
-- this case lives at the altitude of the DEFECT: it is about the WIRING between
-- two features, so a test inside either one's case file could pass while the
-- pair still destroyed the layout.
--
-- Covered here: the confirm dialog only appears for ANOTHER feature's mode; a
-- decline changes nothing; an accept restores the incumbent BEFORE the newcomer
-- looks at the screen (the settle); a one-shot mover is gated too; the lease is
-- released on every abandon path; every denial reaching the caller (a request
-- that resolves in silence leaves the deck's own `st.picking` latch set, which
-- reads as a shortcut that has stopped working); and the guard that stops the
-- next window-moving FEATURE being added without consulting any of it.

return {
    id = "window_mode_lease",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry
        local HYP = { "cmd", "alt", "ctrl" }
        local window_ops = require("platform.window_ops")

        local SCREEN  = { x = 0, y = 0, w = 1600, h = 1000, name = "Main", index = 1 }
        local SCREEN2 = { x = 1600, y = 0, w = 1280, h = 800, name = "Side", index = 2 }

        -- The user's REAL layout -- the one both modes must be able to give back.
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
        -- The live dialog, or nil. The lease is the only thing in this case that
        -- opens one, so "a dialog is open" reads as "arbitration happened".
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

        registry.register(require("features.window_deck"))
        registry.register(require("features.window_fan"))
        registry.register(require("features.window_snap"))
        registry.setEnabled("window_deck", true)
        registry.setEnabled("window_fan", true)
        registry.setEnabled("window_snap", true)

        -- ---------------------------------------------------------------------
        -- A lone mode never asks anyone anything.
        -- ---------------------------------------------------------------------
        reset()
        ok(window_ops.modeHolder(1) == nil, "no mode holds a screen at rest")
        enterDeck()
        ok(#fake.windowFrameSets == 4, "the deck tiled all four windows")
        ok(liveDialog() == nil, "entering the only mode shows no dialog")
        local h = window_ops.modeHolder(1)
        ok(h and h.id == "window_deck", "the live deck holds its screen")
        ok(window_ops.modeHolder(2) == nil, "and holds ONLY its screen (the lease is per-display)")

        -- ---------------------------------------------------------------------
        -- A second mode asks first -- and DECLINING changes nothing.
        -- ---------------------------------------------------------------------
        local gridded = {}
        for id = 1, 4 do gridded[id] = lastSetFor(id) end
        fake.windowFrameSets = {}
        fake.pressHotkey("f", HYP)                      -- Window Fan, over the live deck
        local d = liveDialog()
        ok(d ~= nil, "a second mode on a held screen asks the user first")
        ok(d and d.title and d.title:find("Window Deck"),
            "the dialog names the mode that is in the way")
        d.choose(d.actions[2])                          -- Cancel
        fake.fireTimers("after")
        ok(#fake.windowFrameSets == 0, "declining moves no window")
        local still = window_ops.modeHolder(1)
        ok(still and still.id == "window_deck", "declining leaves the deck holding the screen")

        -- ---------------------------------------------------------------------
        -- THE REGRESSION. Accepting must restore the deck's layout BEFORE the fan
        -- captures anything -- otherwise the fan records the GRID as the layout to
        -- put back, and the user's real one is unrecoverable.
        -- ---------------------------------------------------------------------
        fake.windowFrameSets = {}
        fake.pressHotkey("f", HYP)
        local d2 = liveDialog()
        ok(d2 ~= nil, "the dialog comes back on a second attempt")
        d2.choose(d2.actions[1])                        -- Quit Window Deck and continue
        -- The deck's restore is dispatched here; the fan has NOT run yet.
        ok(at(lastSetFor(1), REAL[1]), "accepting restores the deck's windows first")
        ok(window_ops.modeHolder(1) == nil or window_ops.modeHolder(1).id ~= "window_deck",
            "the deck no longer holds the screen")
        -- The fake's window rows follow the frames the restore just wrote, which is
        -- what the fan will list when the settle expires.
        for _, w in ipairs(fake.windows) do
            local set = lastSetFor(w.id)
            if set then w.x, w.y, w.w, w.h = set.x, set.y, set.w, set.h end
        end
        fake.fireTimers("after")                        -- settle expires -> the fan enters
        local holder = window_ops.modeHolder(1)
        ok(holder and holder.id == "window_fan", "after the settle the fan holds the screen")

        -- ...and leaving the fan puts the user back at their REAL layout, not the grid.
        fake.windowFrameSets = {}
        fake.pressHotkey("f", HYP)                      -- toggle the fan off
        fake.fireTimers("after")
        local restored, wrong = 0, 0
        for id = 1, 4 do
            local f = lastSetFor(id)
            if at(f, REAL[id]) then restored = restored + 1
            elseif f and gridded[id] and at(f, gridded[id]) then wrong = wrong + 1 end
        end
        ok(restored == 4, "leaving the fan restores the user's REAL layout, all four windows")
        ok(wrong == 0, "no window is left at a DECK grid slot (the poisoned-originals bug)")
        ok(window_ops.modeHolder(1) == nil, "leaving the last mode frees the screen")

        -- ---------------------------------------------------------------------
        -- A one-shot mover is gated too -- and declining leaves the mode intact.
        -- ---------------------------------------------------------------------
        reset()
        enterDeck()
        fake.windowFrameSets = {}
        fake.windowFrames = {}
        fake.pressHotkey("left", HYP)                   -- Window Snap: left half
        local ds = liveDialog()
        ok(ds ~= nil, "a one-shot mover on a held screen asks before moving a member")
        ds.choose(ds.actions[2])                        -- Cancel
        fake.fireTimers("after")
        ok(#fake.windowFrames == 0, "a declined snap moves nothing")
        local afterSnap = window_ops.modeHolder(1)
        ok(afterSnap and afterSnap.id == "window_deck", "and leaves the deck live")
        fake.pressHotkey("k", HYP)                      -- exit the deck
        fake.fireTimers("after")
        ok(window_ops.modeHolder(1) == nil, "the screen is free again")

        -- With no mode live, the same snap is silent and synchronous.
        reset()
        fake.windowFrames = {}
        fake.pressHotkey("left", HYP)
        ok(liveDialog() == nil, "with no mode live a snap shows no dialog")
        ok(#fake.windowFrames == 1, "and moves the window straight away")

        -- ---------------------------------------------------------------------
        -- An entry REFUSED after the grant must hand the screen back. A lease left
        -- behind here would make the next mode ask about one that never opened.
        -- ---------------------------------------------------------------------
        reset()
        enterDeck()                                     -- a real holder, so the grant is real
        fake.windows = {}                               -- ...but nothing left to fan
        fake.pressHotkey("f", HYP)
        local dr = liveDialog()
        ok(dr ~= nil, "the fan asks for the held screen")
        dr.choose(dr.actions[1])                        -- quit the deck and continue
        fake.fireTimers("after")                        -- settle -> the fan is granted, then refuses
        ok(window_ops.modeHolder(1) == nil,
            "a refused entry releases the screen it had been granted")
        ok(not window_ops.arbitrating(),
            "and the arbitration slot is free again after a refused entry")

        -- ---------------------------------------------------------------------
        -- A display reconfig renumbers screens; the lease follows its mode.
        -- ---------------------------------------------------------------------
        reset()
        enterDeck()
        ok(window_ops.modeHolder(1) ~= nil, "the deck holds index 1 before the reconfig")
        fake.screenList = { SCREEN2, { x = 0, y = 0, w = 1600, h = 1000, name = "Main", index = 2 } }
        fake.systemEvent("screenChanged")
        fake.fireTimers("after")
        local moved = window_ops.modeHolder(2)
        ok(moved and moved.id == "window_deck",
            "after a reconfig the lease follows the deck onto its new screen index")
        ok(window_ops.modeHolder(1) == nil, "and no longer guards the index it left")
        fake.pressHotkey("k", HYP)
        fake.fireTimers("after")

        -- ---------------------------------------------------------------------
        -- CANCELLING MUST NOT KILL THE HOTKEY. The deck latches st.picking before
        -- it asks, and its toggle refuses to re-enter while that is set -- so a
        -- request that resolves in SILENCE leaves the shortcut dead long after the
        -- other mode has gone. Every denial path has to reach the caller.
        -- ---------------------------------------------------------------------
        reset()
        fake.pressHotkey("f", HYP)                      -- the fan takes screen 1
        fake.fireTimers("after")
        ok(window_ops.modeHolder(1) ~= nil, "the fan holds the screen")
        fake.pressHotkey("k", HYP)                      -- deck asks...
        local dc = liveDialog()
        ok(dc ~= nil, "the deck asks for the fan's screen")
        dc.choose(dc.actions[2])                        -- ...and the user cancels
        fake.fireTimers("after")
        fake.pressHotkey("f", HYP)                      -- the fan leaves; screen is free
        fake.fireTimers("after")
        ok(window_ops.modeHolder(1) == nil, "the screen is free once the fan exits")
        fake.dialogs = {}
        fake.windowFrameSets = {}
        enterDeck()                                     -- the deck must still work
        ok(#fake.windowFrameSets == 4,
            "a cancelled request does not leave the deck's hotkey dead")
        fake.pressHotkey("k", HYP)
        fake.fireTimers("after")

        -- ---------------------------------------------------------------------
        -- THE ARBITRATION SLOT CANNOT OUTLIVE THE CTX THAT TOOK IT. A panel closed
        -- by scope teardown never invokes its callback, so the path that clears the
        -- slot never runs -- and a latched slot turns EVERY window mover in the
        -- catalog into a silent no-op for the rest of the session.
        -- ---------------------------------------------------------------------
        reset()
        enterDeck()
        fake.pressHotkey("f", HYP)                      -- the fan asks; dialog opens
        ok(liveDialog() ~= nil and window_ops.arbitrating(),
            "an open dialog holds the arbitration slot")
        registry.setEnabled("window_fan", false)        -- teardown closes it, no callback
        ok(not window_ops.arbitrating(),
            "disabling the asking feature releases the arbitration slot")
        registry.setEnabled("window_fan", true)
        fake.dialogs = {}
        fake.windowFrames = {}
        fake.pressHotkey("left", HYP)                   -- a mover still gets its dialog
        ok(liveDialog() ~= nil, "and the next request still arbitrates")
        liveDialog().choose(liveDialog().actions[2])
        fake.pressHotkey("k", HYP)                      -- exit the deck
        fake.fireTimers("after")

        -- ---------------------------------------------------------------------
        -- THE SETTLE GAP IS CLOSED. Between the eviction and the grant the slot is
        -- EMPTY, so a request that only checks for a holder reads "free" -- and a
        -- second MODE granted there would put two modes on one screen, which is
        -- the original defect reached through the fix.
        -- ---------------------------------------------------------------------
        reset()
        enterDeck()
        fake.pressHotkey("f", HYP)
        local dg = liveDialog()
        dg.choose(dg.actions[1])                        -- evicted; now inside the settle
        ok(window_ops.modeHolder(1) == nil and window_ops.arbitrating(),
            "inside the settle the slot is empty but arbitration is held")
        fake.dialogs = {}
        fake.windowFrames = {}
        fake.pressHotkey("left", HYP)                   -- a mover arrives mid-settle
        ok(#fake.windowFrames == 0,
            "a mover arriving inside the settle is dropped, not granted")
        ok(liveDialog() == nil, "and it does not stack a second dialog")
        fake.fireTimers("after")                        -- settle expires -> the fan lands
        ok(window_ops.modeHolder(1) ~= nil and window_ops.modeHolder(1).id == "window_fan",
            "the fan still gets the screen it was granted")
        fake.pressHotkey("f", HYP)
        fake.fireTimers("after")

        -- ---------------------------------------------------------------------
        -- ANY_SCREEN clears EVERY display. The actions that use it reach more than
        -- one, so evicting whichever holder a scan reached first would leave the
        -- guard not holding in exactly the multi-display case it exists for.
        -- ---------------------------------------------------------------------
        reset()
        fake.screenList = { SCREEN, SCREEN2 }
        enterDeck()                                     -- deck on screen 1
        do                                              -- fan on screen 2
            fake.focusedWindow = { x = 1700, y = 100, w = 600, h = 400, screenIndex = 2 }
            fake.focusedWid = 201
            fake.windows[#fake.windows + 1] =
                { id = 21, wid = 201, title = "Far", appName = "F", bundleID = "com.f",
                  x = 1700, y = 100, w = 600, h = 400 }
            fake.windows[#fake.windows + 1] =
                { id = 22, wid = 202, title = "Far2", appName = "G", bundleID = "com.g",
                  x = 1800, y = 300, w = 500, h = 300 }
            fake.pressHotkey("f", HYP)
            fake.fireTimers("after")
        end
        ok(window_ops.modeHolder(1) ~= nil and window_ops.modeHolder(2) ~= nil,
            "two modes coexist on two displays -- the whole point of a per-screen lease")
        ok(liveDialog() == nil, "and neither asked about the other")
        registry.register(require("features.window_rewind"))
        registry.setEnabled("window_rewind", true)
        fake.pressHotkey("z", HYP)                      -- undo: reaches any display
        local da = liveDialog()
        ok(da ~= nil, "a cross-display action asks before it runs")
        da.choose(da.actions[1])
        fake.fireTimers("after")
        ok(#window_ops.heldScreens() == 0,
            "accepting clears EVERY held display, not just the first one found")
        registry.setEnabled("window_rewind", false)

        -- ---------------------------------------------------------------------
        -- THE GUARD. The gate is per-action, so nothing structural stops the next
        -- window mover being added without one -- the same hole the leaf-guard and
        -- feature_requires mirrors exist to close. Every feature that writes a
        -- window frame must reach the lease, directly or through W.exclusiveScreen.
        -- ---------------------------------------------------------------------
        do
            local appdir = require("loader").appdir
            local fh = io.popen("ls -1 '" .. appdir .. "/features' 2>/dev/null")
            local ids = {}
            if fh then
                for line in fh:lines() do if line ~= "" then ids[#ids + 1] = line end end
                fh:close()
            end
            ok(#ids > 0, "mover guard: the feature scan is non-empty (no false green)")

            -- Moving the FOCUSED window or a listed one by id -- the two ways a
            -- feature can reposition anything.
            local MOVES = { "ctx%.window%.setFrame%s*%(", "ctx%.window%.setFrameFor%s*%(",
                            "ctx%.window%.undoLast%s*%(" }
            -- Consulting the lease. ONE spelling: the platform call itself, since
            -- a leaf-util wrapper around it would just be a second name to accept.
            local GATES = { "requestExclusive" }
            -- pointer_follows_window names setFrame only in its header prose: it is
            -- the POLICY behind that seam, not a caller of it. Verified by the scan
            -- below finding no code line, so it needs no exemption entry.
            -- The WHOLE lua/ folder per feature, not just init.lua -- the same
            -- enumeration feature_capabilities uses, and for the same reason: the
            -- loader resolves nested modules, window_deck already ships four
            -- sibling files, and a mover written into one of them would otherwise
            -- report zero offenders. A green that cannot see half its corpus is
            -- not a green.
            local offenders, scanned = {}, 0
            for _, id in ipairs(ids) do
                local moves, gated = false, false
                local fh2 = io.popen("find '" .. appdir .. "/features/" .. id
                    .. "/lua' -name '*.lua' 2>/dev/null")
                local paths = {}
                if fh2 then
                    for line in fh2:lines() do if line ~= "" then paths[#paths + 1] = line end end
                    fh2:close()
                end
                for _, path in ipairs(paths) do
                    local f = io.open(path, "r")
                    if f then
                        local src = f:read("a"); f:close()
                        scanned = scanned + 1
                        for line in src:gmatch("[^\n]+") do
                            local code = line:match("^%s*%-%-") and "" or line
                            for _, pat in ipairs(MOVES) do
                                if code:find(pat) then moves = true end
                            end
                            for _, pat in ipairs(GATES) do
                                if code:find(pat) then gated = true end
                            end
                        end
                    end
                end
                if moves and not gated then offenders[#offenders + 1] = id end
            end
            ok(scanned > #ids, "mover guard: the scan reaches sibling modules, not only init.lua")
            ok(#offenders == 0,
                "every window mover consults the exclusive-screen lease (unguarded: "
                .. (#offenders > 0 and table.concat(offenders, ", ") or "none") .. ")")
        end

        registry.setEnabled("window_snap", false)
        registry.setEnabled("window_fan", false)
        registry.setEnabled("window_deck", false)
        fake.fireTimers("after")
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
            "clean after the lease test (no leaked panel, border or observer)")
        ok(#window_ops.heldScreens() == 0,
            "and no screen is left leased by a disabled feature")
    end,
}
