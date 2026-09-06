-- test/cases/audit_regressions.lua -- one case per defect the 2026-09-02 audit's
-- second pass found and this branch fixed. Grouped rather than scattered because
-- each is a small, independent "this exact thing must not come back" assertion,
-- and a reader chasing one of them wants the finding id, the scenario and the
-- expectation in the same place.
--
-- Every block below was checked against the pre-fix code and fails there.

---The frame the press just recorded, or a hard failure naming the step. Also
---narrows away the optional `lastFrame()` returns, so frameEq keeps its type.
---@param t Harness
---@param what string
---@return {x:number,y:number,w:number,h:number}
local function recorded(t, what)
    local f = t.lastFrame()
    if not f then error("FAIL: " .. what .. " -- nothing recorded a frame", 2) end
    return f
end

return {
    id = "audit_regressions",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry, W = t.ok, t.fake, t.registry, t.W

        -- W-2 -----------------------------------------------------------------
        -- moveToScreen clamped only the FAR edges, so a window hanging off the
        -- left of its source screen mapped to a negative offset and landed back
        -- on the SOURCE display; one hanging above landed under the menu bar.
        do
            local src = { x = 0, y = 0, w = 1440, h = 900 }
            local dst = { x = 1440, y = 0, w = 1440, h = 900 }
            local off = W.moveToScreen({ x = -100, y = 100, w = 800, h = 600 }, src, dst,
                { keepSize = true })
            ok(off.x >= dst.x,
                "W-2: a window hanging off the left lands ON the target, not back on the source"
                .. " (x=" .. off.x .. ")")
            local high = W.moveToScreen({ x = 100, y = -80, w = 800, h = 600 }, src, dst,
                { keepSize = true })
            ok(high.y >= dst.y,
                "W-2: a window hanging above lands below the target's top edge (y=" .. high.y .. ")")
            -- and the ordinary case is untouched
            local plain = W.moveToScreen({ x = 100, y = 100, w = 400, h = 300 }, src, dst,
                { keepSize = true })
            t.frameEq(plain, 1540, 100, 400, 300, "W-2: an on-screen window still just translates")
        end

        -- N-2 -----------------------------------------------------------------
        -- warn1 and warn2 are range-checked independently, so warn2 > warn1 is a
        -- legal setting -- and it made phase 1's window empty, so the dismissable
        -- dialog never opened and the one-time snooze was unreachable.
        do
            registry.register(require("features.sleep_schedule"))
            fake.settings["hammerdeck.opt.sleep_schedule.weekendShiftMin"] = 0
            -- Sleep exactly warn1 away, so the tick lands INSIDE phase 1's
            -- window -- which the inverted pair had collapsed to nothing.
            fake.settings["hammerdeck.opt.sleep_schedule.sleepAt"] = t.minutesFromNow(10)
            fake.settings["hammerdeck.opt.sleep_schedule.warn1Min"] = 10
            fake.settings["hammerdeck.opt.sleep_schedule.warn2Min"] = 30   -- inverted!
            registry.setEnabled("sleep_schedule", true)
            fake.fireTimers("every", 10)
            local dlg = fake.openDialog()
            ok(dlg ~= nil,
                "N-2: an inverted warn1/warn2 pair still reaches the snooze dialog")
            if dlg then dlg.choose(dlg.actions[1]) end
            registry.setEnabled("sleep_schedule", false)
        end

        -- N-9 -----------------------------------------------------------------
        -- The history cap lived only in record(), so lowering historySize and
        -- restarting left every older entry visible, and on disk.
        do
            registry.register(require("features.clipboard_history"))
            local json = require("platform.json")
            local stored = {}
            for i = 1, 40 do stored[i] = "entry " .. i end
            -- The feature's own store path: dataDir()/<id>/history.json, written
            -- by an earlier run under whatever cap was set then.
            fake.files["/fake/data/clipboard_history/history.json"] = json.encode(stored)
            fake.settings["hammerdeck.opt.clipboard_history.historySize"] = 5
            registry.setEnabled("clipboard_history", true)
            fake.pressHotkey("h", { "cmd", "alt", "ctrl" })
            local ch = fake.visibleChooser()
            if ch then
                ok(#ch.choices <= 5,
                    "N-9: a stored history longer than the cap is trimmed on LOAD (got "
                    .. #ch.choices .. ")")
                ch.userSelect(1)   -- close it the way a person would
            else
                ok(false, "N-9: the clipboard chooser did not open")
            end
            registry.setEnabled("clipboard_history", false)
        end

        -- W-8 -----------------------------------------------------------------
        -- The undo stack carried no window identity, so snapping A, clicking B
        -- and pressing [ popped A's pre-snap frame and applied it to B.
        do
            registry.register(require("features.window_modal"))
            registry.setEnabled("window_modal", true)
            fake.screenList = { { x = 0, y = 0, w = 1000, h = 800 } }
            fake.focusedWid = 101
            fake.focusedWindow = { x = 200, y = 200, w = 400, h = 300, screenIndex = 1 }
            fake.pressHotkey("w", { "cmd", "alt", "ctrl" })   -- enter the mode
            fake.pressHotkey("h", {})                          -- snap A to the left half
            t.frameEq(recorded(t, "W-8 snap"), 0, 0, 500, 800, "W-8: window A snapped, so the stack holds A")

            -- The user clicks a DIFFERENT window and asks for undo.
            fake.focusedWid = 202
            fake.focusedWindow = { x = 600, y = 100, w = 300, h = 200, screenIndex = 1 }
            local framesBefore = #fake.windowFrames
            fake.pressHotkey("[", {})
            ok(#fake.windowFrames == framesBefore,
                "W-8: undo refuses to apply A's frame to B -- no window is moved")

            -- Back on A, undo still works: the guard must not break the feature.
            fake.focusedWid = 101
            fake.focusedWindow = { x = 0, y = 0, w = 500, h = 800, screenIndex = 1 }
            fake.pressHotkey("[", {})
            t.frameEq(recorded(t, "W-8 undo"), 200, 200, 400, 300, "W-8: undo on the RIGHT window still restores it")
            fake.pressHotkey("escape", {})
            registry.setEnabled("window_modal", false)
            fake.focusedWid = nil
        end

        -- N-5 -----------------------------------------------------------------
        -- The prompt accepts "2.5", but the completion title used %d, which Lua
        -- 5.4 RAISES on -- and the i18n fallback was the same failing template,
        -- so the notification read literally "Time (%d min) is up!".
        do
            registry.register(require("features.count_down"))
            registry.setEnabled("count_down", true)
            registry.runAction("count_down", "start")
            local prompt = fake.openTextPrompt()
            ok(prompt ~= nil, "N-5: the countdown prompt opened")
            if prompt then
                prompt.submit("2.5")
                -- The countdown counts TICKS, not wall clock: 2.5 min = 150.
                for _ = 1, 150 do fake.fireTimers("every", 1) end
                local note = fake.notifications[#fake.notifications]
                ok(note ~= nil and note.title:find("%%d") == nil,
                    "N-5: the title is not a raw format string (got: "
                    .. tostring(note and note.title) .. ")")
                ok(note ~= nil and note.title:find("2.5", 1, true) ~= nil,
                    "N-5: and it names the minutes the user actually typed")
            end
            registry.setEnabled("count_down", false)

            -- A value that rounds to a TRAILING DOT ("2.00" -> "2.") is the case
            -- my first fix got wrong and my first test missed, because 2.5 never
            -- reaches that branch. Drive the formatter through a real run.
            registry.setEnabled("count_down", true)
            registry.runAction("count_down", "start")
            local p2 = fake.openTextPrompt()
            if p2 then
                p2.submit("2.001")
                for _ = 1, 121 do fake.fireTimers("every", 1) end
                local note2 = fake.notifications[#fake.notifications]
                ok(note2 ~= nil and note2.title:find("%.%s*min") == nil
                       and note2.title:find("2%.[^0-9]") == nil,
                    "N-5: a near-integer minute count does not render a dangling dot (got: "
                    .. tostring(note2 and note2.title) .. ")")
            end
            registry.setEnabled("count_down", false)
        end

        -- N-8 -----------------------------------------------------------------
        -- Truncation was a BYTE operation on what the option calls "chars", so a
        -- long multibyte clip was cut mid-codepoint and the persisted JSON
        -- carried an invalid tail.
        do
            -- already registered by the N-9 block above; registering twice is a
            -- duplicate-id error by design
            fake.settings["hammerdeck.opt.clipboard_history.historySize"] = 10
            registry.setEnabled("clipboard_history", true)
            fake.copyText(string.rep("\228\184\173", 3000))   -- 3000x U+4E2D, 9000 bytes
            fake.fireTimers("every", 0.8)
            local stored = fake.files["/fake/data/clipboard_history/history.json"]
            ok(stored ~= nil and utf8.len(stored) ~= nil,
                "N-8: a truncated multibyte clip leaves the store valid UTF-8")
            registry.setEnabled("clipboard_history", false)
        end

        -- N-7 -----------------------------------------------------------------
        -- The countdown measures against the WALL CLOCK with no wake handler, so
        -- a sleep/wake gap straddling an armed countdown left `remaining` hugely
        -- negative and the first tick after waking blanked the screen the user
        -- had just woken -- against a countdown that expired hours earlier.
        do
            registry.register(require("features.display_off"))
            registry.setEnabled("display_off", true)
            fake.idle = 6 * 60                       -- past the 5-minute default
            fake.fireTimers("every", 5)              -- arms the 30s countdown
            ok(fake.liveBanner() ~= nil, "N-7: the idle countdown is armed")

            fake.clockOffset = fake.clockOffset + 4 * 3600   -- the machine slept
            fake.systemEvent("wake")
            local dimmedBefore = fake.actions.displaySleep
            fake.fireTimers("every", 5)
            ok(fake.actions.displaySleep == dimmedBefore,
                "N-7: the first tick after waking does NOT blank the screen")
            registry.setEnabled("display_off", false)
        end

        -- P-1 / P-11 ---------------------------------------------------------
        -- The rules-engine catalog fed i18n a nil default for `chain`, so the
        -- English build rendered the raw key "rules.effectKind.chain" in the
        -- Rules > Do dropdown -- and i18n_parity structurally cannot see it,
        -- because it checks translations against English sources and here the
        -- English source was the missing half. dispatch() separately indexed
        -- node.kind one line ABOVE its own nil guard, so a nil node threw
        -- against a contract that promises it never does.
        do
            local effects = require("platform.effects")
            for _, entry in ipairs(effects.catalog(true)) do
                ok(type(entry.label) == "string" and entry.label ~= ""
                       and not entry.label:match("^rules%%.effectKind%%."),
                    "P-1: catalog kind '" .. tostring(entry.kind)
                    .. "' has a real label, not its own i18n key (got: "
                    .. tostring(entry.label) .. ")")
            end
            local okDispatch, res = pcall(effects.dispatch, nil)
            ok(okDispatch and res == false,
                "P-11: dispatch(nil) returns a failure instead of throwing")
        end

        -- W-1 -----------------------------------------------------------------
        -- window_snap asked "which display is this window on?" with
        -- W.screenIndexAt, whose `or 1` fallback answers "display 1" for a point
        -- on NO display. So a window parked off every screen (a display was
        -- unplugged, or an app restored a stale frame) was treated as living on
        -- display 1: the swap dragged it there and counted it, and the picker
        -- inflated display 1's window count with it. Asserted through the
        -- feature, not through the helper -- the defect was in which question
        -- window_snap asked, and a test on screenIndexContaining alone would
        -- pass against the pre-fix code.
        do
            registry.register(require("features.window_snap"))
            registry.setEnabled("window_snap", true)

            -- Two displays: the swap runs immediately, no picker.
            fake.screenList = {
                { x = 0,    y = 0, w = 1000, h = 800 },
                { x = 1000, y = 0, w = 1000, h = 800 },
            }
            fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
            fake.windows = {
                { id = 71, x = 100, y = 100, w = 400, h = 300 },        -- on display 1
                { id = 72, x = -5000, y = -5000, w = 100, h = 100 },    -- centre on NO display
            }
            fake.windowFrameSets = {}
            assert(registry.runAction("window_snap", "swap_screens"))
            local byId = {}
            for _, s in ipairs(fake.windowFrameSets) do byId[s.id] = s end
            ok(byId[71], "W-1: a window really on display 1 still swaps")
            ok(not byId[72],
                "W-1: an off-screen window is NOT dragged onto display 1 by the swap")

            -- Three displays: the picker opens and carries per-display counts.
            fake.screenList = {
                { x = 0,    y = 0, w = 1000, h = 800, name = "Left"   },
                { x = 1000, y = 0, w = 1000, h = 800, name = "Middle" },
                { x = 2000, y = 0, w = 1000, h = 800, name = "Right"  },
            }
            fake.focusedWindow = { x = 100, y = 100, w = 200, h = 150, screenIndex = 1 }
            fake.windows = {
                { id = 73, x = 100, y = 100, w = 200, h = 150 },        -- Left
                { id = 74, x = -5000, y = -5000, w = 100, h = 100 },    -- nowhere
            }
            fake.windowFrameSets = {}
            assert(registry.runAction("window_snap", "swap_screens"))
            local dp = fake.displayPickers[#fake.displayPickers]
            ok(dp.displays[1].windows == 1,
                "W-1: the off-screen window is not counted on display 1 (got "
                .. tostring(dp.displays[1].windows) .. ")")
            dp.userConfirm({ 1, 3 })

            registry.setEnabled("window_snap", false)
            fake.windows = {}
        end

        -- N-13 / P-13 --------------------------------------------------------
        -- getDomain DELETED disallowed bytes instead of rejecting, so a port
        -- folded into the name. That string is not merely displayed: it is the
        -- `context` column of the user's daily usage CSV and a favicon cache
        -- filename, so a scrubbed host is persisted corruption. The localhost
        -- guard used find(), which rejected any host merely containing it.
        do
            local urls = require("platform.urls")
            local ported = urls.getDomain("https://host.com:8443/app")
            ok(ported == "host.com",
                "N-13: the port is dropped, not folded into the domain (got "
                .. tostring(ported) .. ")")
            ok(urls.getDomain("https://user:pw@sub.host.com/x") == "sub.host.com",
                "N-13: userinfo is dropped, not folded into the domain")
            ok(urls.getDomain("https://[::1]:8080/x") == nil,
                "N-13: an authority that is not host-shaped is rejected, not scrubbed")
            ok(urls.getDomain("https://notlocalhost.com/x") == "notlocalhost.com",
                "P-13: only localhost itself is rejected, not every host containing it")
            ok(urls.getDomain("http://localhost:3000/") == nil,
                "P-13: a real localhost dev URL is still rejected")
            ok(urls.getDomain("https://sub.host.tld/path?q=1") == "sub.host.tld",
                "N-13: an ordinary URL still yields its host")
        end

        -- N-4 -----------------------------------------------------------------
        -- The 7-day series stepped by a fixed 86400 from the CURRENT time of
        -- day. Anchored at noon instead, so a 23- or 25-hour DST day cannot
        -- make the step land back on the date it just left.
        do
            local store = require("features.usage_stats.store")
            local a = store.dayAnchors(os.time({ year = 2026, month = 3, day = 15, hour = 9 }), 7)
            ok(#a == 7, "N-4: dayAnchors returns one anchor per day (" .. #a .. ")")
            local seen, distinct = {}, 0
            for _, t in ipairs(a) do
                local d = os.date("%Y-%m-%d", t)
                if not seen[d] then seen[d] = true; distinct = distinct + 1 end
            end
            ok(distinct == 7, "N-4: the seven anchors are seven distinct dates (" .. distinct .. ")")
            ok(os.date("%Y-%m-%d", a[7]) == "2026-03-15",
                "N-4: the newest anchor is the day `now` falls in")
            ok(tonumber(os.date("%H", a[4])) == 12,
                "N-4: anchors sit at local noon, the far end from either DST boundary")
            -- The DST case itself needs a zone that HAS one, so it is asserted in
            -- Swift (testDailyWindowIsSevenDistinctDaysAcrossDST), which can force TZ.
        end

        -- P-10 -----------------------------------------------------------------
        -- The shared watcher fanned out with a bare loop. One throwing rule
        -- aborted the emit for every rule after it -- and since bindOne advances
        -- `matched` only after fire() returns, those rules then re-fired on every
        -- later emit instead of once per edge.
        do
            local signals = require("platform.signals")
            local sig = signals.get("frontmostApp")
            -- EVERY subscriber counts and THEN throws, so the assertion does not
            -- depend on pairs()' undefined order: a bare loop stops at whichever
            -- one it reaches first, and that is enough to fail this whatever the
            -- order turns out to be.
            local reached, handles = 0, {}
            local function thrower()
                reached = reached + 1
                error("P-10 probe")
            end
            for _ = 1, 2 do handles[#handles + 1] = sig.subscribe(thrower) end
            -- One LABELLED, the way rules.bindOne subscribes. The raised error
            -- carries only a rules.lua line shared by every rule on every
            -- signal, so without the label the log cannot answer the one
            -- question it is read to answer: which rule broke.
            handles[#handles + 1] = sig.subscribe(thrower, "rule:p10probe")
            local nLogs = #fake.logs
            -- pcall'd so an uncontained throw reports as the assertion below
            -- rather than a traceback out of the case.
            local emitOk = pcall(fake.activateApp, "P10Probe")
            ok(emitOk, "P-10: a throwing subscriber does not escape the emit")
            ok(reached == 3,
                "P-10: a throwing subscriber does not abort the fan-out (reached "
                .. reached .. "/3)")
            local errLines, named, labelled = 0, 0, 0
            for i = nLogs + 1, #fake.logs do
                local L = fake.logs[i]
                if L:find("subscriber") and L:find("error") then
                    errLines = errLines + 1
                    if L:find("frontmostApp", 1, true) then named = named + 1 end
                    if L:find("rule:p10probe", 1, true) then labelled = labelled + 1 end
                end
            end
            ok(errLines == 3,
                "P-10: every swallowed subscriber error is logged, not silent ("
                .. errLines .. "/3)")
            ok(named == 3,
                "P-10: each line names the SIGNAL (" .. named .. "/3)")
            ok(labelled == 1,
                "P-10: the labelled subscriber is named, so the log says WHICH rule broke ("
                .. labelled .. "/1)")
            for _, h in ipairs(handles) do h.stop() end

            -- ...and the WIRING: the label only helps if rules.bindOne actually
            -- passes one. Asserted by spying on subscribe rather than by making
            -- a real rule throw -- effects.dispatch is already pcall-contained,
            -- so a rule that fails through the supported path never reaches the
            -- line above.
            local rules = require("platform.rules")
            local realSubscribe, seenLabel = sig.subscribe, nil
            sig.subscribe = function(cb, label) seenLabel = label; return realSubscribe(cb, label) end
            local okSpy = pcall(function()
                rules.load({
                    { id = "p10-wiring",
                      on = { type = "state", signal = "frontmostApp", becomes = "Safari" },
                      effect = { kind = "notify", title = "HD" } },
                })
                rules.startAll()
            end)
            sig.subscribe = realSubscribe
            rules.load({})
            ok(okSpy and seenLabel == "rule:p10-wiring",
                "P-10: rules.bindOne subscribes under the rule's id (got "
                .. tostring(seenLabel) .. ")")
        end

        -- W-1b ----------------------------------------------------------------
        -- The frame-space twin of W-1, found reviewing that fix: screenOfFrame
        -- fell back to screens[1] for a midpoint on NO display, so "Capture
        -- current layout" tagged an off-screen window with display 1 and stored
        -- ratios far outside [0,1] -- which nothing downstream clamps. Its own
        -- doc already promised such a window was skipped; now it is.
        do
            local effects = require("platform.effects")
            -- Both screens EXTERNAL: an unscoped capture skips the built-in, so
            -- a built-in screens[1] would have hidden the defect behind the
            -- wrong guard.
            fake.screenList = {
                { x = 0, y = 0, w = 1440, h = 900, name = "DELL", index = 1 },
                { x = 1440, y = 0, w = 1440, h = 900, name = "LG", index = 2 },
            }
            fake.windows = {
                { id = 81, appName = "Notes", x = 100, y = 100, w = 400, h = 300 },
                { id = 82, appName = "Stale", x = -5000, y = -5000, w = 400, h = 300 },
            }
            local caps = effects.captureLayout()
            ok(#caps == 1,
                "W-1b: a window on no display is skipped, not captured against display 1 ("
                .. #caps .. " placements)")
            ok(caps[1] and caps[1].app == "Notes" and caps[1].screen == "DELL",
                "W-1b: the on-screen window is still captured, on its own display")
            -- focusedScreen keeps the aim default it documents: a pointer in the
            -- gap between displays still has to resolve to something.
            fake.windows = {}
            local gapPointer = { x = -5000, y = -5000 }
            local fs = W.focusedScreen({
                screen = { frames = function() return fake.screenList end },
                window = { frame = function() return nil end },
                mouse  = { position = function() return gapPointer end },
            })
            ok(fs ~= nil and fs.name == "DELL",
                "W-1b: focusedScreen still falls back to the first screen (the aim default)")
        end

        -- W-1c ------------------------------------------------------------------
        -- Found reviewing W-1b: membership was tested against the VISIBLE frame,
        -- but a screen row's visible frame excludes the menu-bar and Dock strips.
        -- A window parked over the Dock is plainly ON that display -- listWindows
        -- even labels it with that display's name, from the FULL frame -- yet
        -- screenOfFrame answered nil, so "Capture current layout" dropped it and
        -- moveAppToDisplay cornered it. Rows now carry `full`, and membership
        -- uses it.
        do
            local effects = require("platform.effects")
            fake.screenList = {
                -- 37pt menu bar at the top, ~85pt Dock at the bottom.
                { x = 0, y = 37, w = 2560, h = 1318, name = "DELL", index = 1,
                  full = { x = 0, y = 0, w = 2560, h = 1440 } },
                { x = 2560, y = 37, w = 1440, h = 863, name = "LG", index = 2,
                  full = { x = 2560, y = 0, w = 1440, h = 900 } },
            }
            -- midpoint (810, 1370): below the visible frame's 1355 bottom edge,
            -- inside the full frame's 1440.
            fake.windows = {
                { id = 91, appName = "Dockside", x = 600, y = 1290, w = 420, h = 160 },
            }
            local caps = effects.captureLayout()
            ok(#caps == 1 and caps[1].screen == "DELL",
                "W-1c: a window over the Dock is ON that display, not dropped ("
                .. #caps .. " placements)")

            -- ...and it still moves relative to its own screen, rather than being
            -- anchored at the destination's corner as an off-display window is.
            -- The menu-bar direction, which the Dock case above cannot reach: an
            -- origin ABOVE the visible frame's top makes (w.y - s.y) negative, so
            -- the stored ratio leaves [0,1] and `rectFromRatios` then SCALES that
            -- overhang onto whatever display the layout is restored on. Membership
            -- moved to the full frame; the ratio basis did not, so this window is
            -- newly capturable and newly out of range.
            fake.windows = {
                { id = 93, appName = "Palette", x = 100, y = 0, w = 300, h = 60 },
            }
            local top = effects.captureLayout()
            ok(#top == 1 and top[1].screen == "DELL",
                "W-1c: a window in the menu-bar strip is on that display too")
            ok(top[1] and top[1].pos.y >= 0 and top[1].pos.y <= 1
                and top[1].pos.x >= 0 and top[1].pos.x <= 1,
                "W-1c: its stored origin stays inside [0,1] (got "
                .. tostring(top[1] and top[1].pos.x) .. ","
                .. tostring(top[1] and top[1].pos.y) .. ")")

            fake.windows = {
                { id = 91, appName = "Dockside", x = 600, y = 1290, w = 420, h = 160 },
            }
            fake.windowFrameSets = {}
            ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Dockside",
                display = "LG" }) == true, "W-1c: the Dock-side window moves")
            -- x only: the window sits at the bottom of a 1440-tall screen moving
            -- onto a 900-tall one, so y is legitimately clamped by the
            -- keep-it-on-the-destination step and says nothing either way.
            -- x = dest.x + (600 - 0) = 3160, and the origin-anchor branch would
            -- give 2560 -- so this one number tells the two branches apart.
            local s = fake.windowFrameSets[#fake.windowFrameSets]
            ok(s and s.x == 3160,
                "W-1c: its offset within its own screen is preserved (got "
                .. tostring(s and s.x) .. ", expected 3160)")

            -- The genuinely off-display case: no offset exists, so it anchors at
            -- the destination origin -- a branch that was DEAD before W-1b made
            -- screenOfFrame nil-able, and is now live, so it needs saying out loud.
            fake.windows = {
                { id = 92, appName = "Nowhere", x = -9000, y = -9000, w = 300, h = 200 },
            }
            fake.windowFrameSets = {}
            local logsBefore = #fake.logs
            ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Nowhere",
                display = "LG" }) == true, "W-1c: an off-display window still moves")
            local s2 = fake.windowFrameSets[#fake.windowFrameSets]
            ok(s2 and s2.x == 2560 and s2.y == 37,
                "W-1c: with no current screen it anchors at the destination origin (got "
                .. tostring(s2 and s2.x) .. "," .. tostring(s2 and s2.y) .. ")")
            local sawAnchorLog = false
            for i = logsBefore + 1, #fake.logs do
                if fake.logs[i]:find("on no display", 1, true) then sawAnchorLog = true end
            end
            ok(sawAnchorLog,
                "W-1c: the anchor fallback logs, so a corner landing is not a mystery")

            fake.windows = {}
            fake.windowFrameSets = {}
            fake.screenList = {
                { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1,
                  builtin = true },
            }
        end

        -- P-3 ------------------------------------------------------------------
        -- A duplicate rule id parks the second copy (correctly -- a rule is never
        -- silently dropped), but the parked row kept the same `id`, so describe()
        -- handed SwiftUI two rows with one identity. Selecting the greyed
        -- duplicate and deleting it deleted the LIVE rule instead.
        do
            local rules = require("platform.rules")
            fake.settings["hammerdeck.rules"] = nil
            rules.load({
                { id = "dup", name = "first",
                  on = { type = "event", event = "wake" },
                  effect = { kind = "notify", title = "HD" } },
                { id = "dup", name = "second",
                  on = { type = "event", event = "sleep" },
                  effect = { kind = "notify", title = "HD2" } },
            })
            local rows = rules.describe()
            ok(#rows == 2, "P-3: both copies are listed, neither dropped (" .. #rows .. ")")
            ok(rows[1].id ~= rows[2].id,
                "P-3: the two rows carry DIFFERENT ids (" .. tostring(rows[1].id)
                .. " / " .. tostring(rows[2].id) .. ")")
            -- The collision is reported through `reason`, which RulesView already
            -- decodes (RuleInfo.unavailableReason) and renders as the row subtitle.
            -- A field of its own would have to be plumbed through Swift to say the
            -- same thing, and until it was, the row would say nothing at all.
            ok(rows[2].unavailable == true
                and type(rows[2].reason) == "string"
                and rows[2].reason:find("already uses the id", 1, true) ~= nil,
                "P-3: the parked row says WHY, through the field the UI already shows (got "
                .. tostring(rows[2].reason) .. ")")

            -- The row's own JSON, not the live rule's -- the editor loads this.
            local sj = rules.specJSON(rows[2].id)
            ok(sj and sj:find('"second"', 1, true) ~= nil,
                "P-3: specJSON on the parked row returns the PARKED spec")

            -- The assertion the defect fails: delete the greyed row, and the live
            -- rule that shares its id must survive.
            ok(rules.remove(rows[2].id) == true, "P-3: the parked duplicate can be deleted")
            local after = rules.describe()
            ok(#after == 1 and after[1].name == "first",
                "P-3: deleting the duplicate left the LIVE rule alone (kept "
                .. (after[1] and after[1].name or "nothing") .. ")")

            -- Editing the duplicate must CHANGE the id -- writing the address into
            -- the user's rule, or silently merging onto the live one, are both worse
            -- than refusing with the reason.
            rules.load({
                { id = "dup", name = "first",
                  on = { type = "event", event = "wake" },
                  effect = { kind = "notify", title = "HD" } },
                { id = "dup", name = "second",
                  on = { type = "event", event = "sleep" },
                  effect = { kind = "notify", title = "HD2" } },
            })
            local addr = rules.describe()[2].id
            ok(select(1, rules.update(addr, { id = "dup", name = "second",
                on = { type = "event", event = "sleep" },
                effect = { kind = "notify", title = "HD2" } })) == false,
                "P-3: re-saving the duplicate under the SAME id is refused, not merged")
            ok(rules.update(addr, { id = "dup2", name = "second",
                on = { type = "event", event = "sleep" },
                effect = { kind = "notify", title = "HD2" } }) == true,
                "P-3: giving the copy a fresh id un-parks it")
            local fixed = rules.describe()
            ok(#fixed == 2 and fixed[1].id == "dup" and fixed[2].id == "dup2",
                "P-3: both rules are now live under distinct ids")

            -- The address must name an ENTRY, not a slot. `remove`/`update` both
            -- table.remove(parked, ..), which renumbers everything after the hole,
            -- and RulesView.editing is a value snapshot that is never re-derived --
            -- so it hands back an address minted BEFORE the shift. Addressed by
            -- position, that resolves to a different parked rule and deletes a rule
            -- the user never touched: the very wrong-row defect P-3 is about.
            rules.load({
                { id = "dup", name = "first",
                  on = { type = "event", event = "wake" },
                  effect = { kind = "notify", title = "HD" } },
                { id = "dup", name = "A",
                  on = { type = "event", event = "sleep" },
                  effect = { kind = "notify", title = "HD" } },
                { id = "dup", name = "B",
                  on = { type = "event", event = "sleep" },
                  effect = { kind = "notify", title = "HD" } },
            })
            local before = rules.describe()
            ok(#before == 3, "P-3: three rows, one live and two parked (" .. #before .. ")")
            local addrA, addrB = before[2].id, before[3].id
            ok(rules.remove(addrA) == true, "P-3: the first parked copy is removed")
            -- addrB was minted before that removal; B is now at index 1 of `parked`.
            local sjB = rules.specJSON(addrB)
            ok(sjB and sjB:find('"B"', 1, true) ~= nil,
                "P-3: an address minted before a removal still names ITS OWN rule (got "
                .. tostring(sjB) .. ")")
            ok(rules.remove(addrB) == true and #rules.describe() == 1,
                "P-3: ...and removing it takes B, leaving only the live rule")

            rules.load({})
            fake.settings["hammerdeck.rules"] = nil
        end

        -- P-8 ------------------------------------------------------------------
        -- parkReason blamed the target feature for EVERY remaining park with a
        -- command effect, so a rule parked for an unrelated reason reported
        -- "feature 'X' isn't available" while X sat there loaded and enabled --
        -- sending the user to fix what was never broken, and leaving the real
        -- cause with no voice. Here the real cause is the CONTEXT POLICY: an
        -- automated trigger may not run a context-dependent action.
        do
            local rules = require("platform.rules")
            fake.settings["hammerdeck.rules"] = nil
            package.loaded["features._p8_probe"] = {
                api = 1, id = "p8_probe", name = "P8 Probe",
                actions = { { id = "main", run = function() end } },   -- NOT automatable
            }
            registry.load("features._p8_probe")
            registry.setEnabled("p8_probe", true)

            rules.load({
                { id = "p8", name = "auto-fires a context-dependent action",
                  on = { type = "schedule", everyMin = 5 },
                  effect = { kind = "command", feature = "p8_probe", action = "main" } },
            })
            local row = rules.describe()[1]
            ok(row and row.unavailable == true, "P-8: the rule parks (context policy)")
            ok(row.reason:find("isn't available", 1, true) == nil,
                "P-8: ...and does NOT blame a feature that is loaded and enabled (got "
                .. tostring(row.reason) .. ")")
            -- Not blaming the wrong thing is only half the row. Asserting the
            -- ABSENCE of the bad string passes against any generic filler, so the
            -- reason has to be held to naming the real cause -- and to arriving
            -- clean, without the `rules.lua:NNN:` prefix `error()` prepends or the
            -- rule id the row already displays beside it.
            ok(row.reason:find("automatable", 1, true) ~= nil,
                "P-8: ...and it NAMES the context policy that actually parked it (got "
                .. tostring(row.reason) .. ")")
            ok(row.reason:find("%.lua:%d+:") == nil and row.reason:find("^rule '") == nil,
                "P-8: ...with no file:line or rule-id prefix leaking through (got "
                .. tostring(row.reason) .. ")")

            -- The genuine case still reports the feature, or the fix would be a
            -- blanket silencing rather than an honest answer.
            rules.load({
                { id = "p8b", name = "targets a feature that is gone",
                  on = { type = "event", event = "wake" },
                  effect = { kind = "command", feature = "no_such_feature" } },
            })
            local gone = rules.describe()[1]
            ok(gone and gone.reason:find("no_such_feature", 1, true) ~= nil,
                "P-8: a target that really IS missing is still named (got "
                .. tostring(gone and gone.reason) .. ")")

            rules.load({})
            fake.settings["hammerdeck.rules"] = nil
            registry.setEnabled("p8_probe", false)
            registry.unregister("p8_probe")
            package.loaded["features._p8_probe"] = nil
        end

        -- P-9 ------------------------------------------------------------------
        -- `enter and on.becomes or on.leaves` collapses to `on.leaves` whenever
        -- `on.becomes` is boolean FALSE, so the read-back sentence describes the
        -- OPPOSITE edge -- with the opposite value. Unreachable through validate
        -- today (a state target must be a non-empty string), so the pure function
        -- is driven directly: it is the half of the invariant that talks to the
        -- user, and bindOne already spells its half out rather than rely on that.
        do
            local rules = require("platform.rules")
            local sent = rules.sentence({
                id = "p9",
                on = { type = "state", signal = "frontmostApp",
                       becomes = false, leaves = "Safari" },
                effect = { kind = "notify", title = "HD" },
            })
            ok(type(sent) == "string" and sent ~= "",
                "P-9: a boolean-false `becomes` still produces a sentence")
            ok(sent:find("Safari", 1, true) == nil,
                "P-9: ...and it does NOT fall through to the `leaves` value (got "
                .. sent .. ")")
        end

        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
            "clean after the audit regression case")
    end,
}
