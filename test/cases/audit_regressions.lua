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
            ok(caps[1] and caps[1].pos.x >= 0 and caps[1].pos.x <= 1,
                "W-1b: the surviving placement's ratios are in range")
            -- focusedScreen keeps the aim default it documents: a pointer in the
            -- gap between displays still has to resolve to something.
            fake.windows = {}
            fake.mouse = { x = -5000, y = -5000 }
            local fs = W.focusedScreen({
                screen = { frames = function() return fake.screenList end },
                window = { frame = function() return nil end },
                mouse  = { position = function() return fake.mouse end },
            })
            ok(fs ~= nil and fs.name == "DELL",
                "W-1b: focusedScreen still falls back to the first screen (the aim default)")
            fake.screenList = nil
        end

        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
            "clean after the audit regression case")
    end,
}
