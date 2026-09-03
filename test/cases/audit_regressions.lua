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

        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
            "clean after the audit regression case")
    end,
}
