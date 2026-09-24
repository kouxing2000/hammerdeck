-- test/cases/_integration/rules/rules_breaker.lua -- the rules BREAKER: a RISKY rule
-- (lock, screensaver, empty Trash, run a command) whose trigger fires 5 times
-- within 2 minutes is switched off, and the 5th fire never runs its effect. Plus
-- the save-time refusal of the one self-looping combination (lock on unlock) and
-- safe mode.
--
-- Driven at the WIRING altitude, through real bound triggers (fake.systemEvent,
-- fake.activateApp) rather than rules.fire: the hazard is a rule turning itself
-- off from INSIDE its own trigger callback, and the signal path iterates every
-- subscriber while that happens -- so a second rule on the same signal is asserted
-- to keep firing across the trip.
--
-- Integration: platform subsystem. Hermetic -- freshWorld() runs registry.reset()
-- + rules.load({}) before the case.

return {
    id = "rules_breaker",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
        local rules = require("platform.rules")
        local json  = require("platform.json")

        local function row(rid)
            for _, r in ipairs(rules.describe()) do if r.id == rid then return r end end
        end
        local function stored(rid)
            local list = json.decode(fake.settings["hammerdeck.rules"] or "[]")
            if type(list) ~= "table" then return nil end
            for _, s in ipairs(list) do if s.id == rid then return s end end
        end
        local function loggedSince(from, needle)
            for i = from + 1, #fake.logs do
                if fake.logs[i]:find(needle, 1, true) then return true end
            end
            return false
        end
        local function reset()
            rules.stopAll(); rules.setPaused(false); rules.load({})
            fake.settings["hammerdeck.rules"] = nil
        end
        local clock0 = fake.clockOffset

        -- A lockout rule tripping on its 5th fire ---------------------------------
        reset()
        local _, rid = rules.add({ name = "Lock on wake",
                                   on = { type = "event", event = "wake" },
                                   effect = { kind = "lockScreen" } })
        rules.startAll()
        ok(row(rid).risk == "lockout", "a lock rule's row carries its risk")

        local locks, told0 = fake.actions.lock, #fake.systemNotifications
        for _ = 1, 4 do
            fake.systemEvent("wake")
            fake.clockOffset = fake.clockOffset + 20
        end
        ok(fake.actions.lock == locks + 4, "fires 1-4 inside the window all run")
        ok(row(rid).enabled == true and rules.liveCount() == 1, "4 fires: still on and bound")

        -- Test fires are the user acting, not a loop: they never count.
        for _ = 1, 6 do rules.fire(rid) end
        ok(row(rid).enabled == true, "Test fires never advance the breaker")
        locks = fake.actions.lock

        local marker = #fake.logs
        fake.systemEvent("wake")                      -- the 5th real fire, 80s after the 1st
        ok(fake.actions.lock == locks, "the 5th fire's effect is NOT run")
        ok(row(rid).enabled == false, "the 5th fire turns the rule off")
        ok(rules.liveCount() == 0, "its binding is stopped")
        ok(type(row(rid).autoDisabledReason) == "string"
            and row(rid).autoDisabledReason:find("5 times", 1, true),
            "the row says why it was turned off")
        local s = stored(rid)
        ok(s and s.enabled == false and type(s.autoDisabledAt) == "number",
            "the trip is persisted, so it survives a relaunch")
        local told = fake.systemNotifications[#fake.systemNotifications]
        ok(#fake.systemNotifications == told0 + 1 and told.title == '"Lock on wake" was turned off',
            "one Notification Center notice, naming the rule -- it shows on a locked screen")
        ok(loggedSince(marker, "TURNED OFF by the breaker"), "the log records the trip and why")

        fake.systemEvent("wake")
        ok(fake.actions.lock == locks and #fake.systemNotifications == told0 + 1,
            "after the trip the trigger does nothing and raises no second notice")

        -- A relaunch loads it off, reason intact.
        rules.stopAll(); rules.loadFromSettings(); rules.startAll()
        ok(row(rid).enabled == false and row(rid).autoDisabledReason ~= nil,
            "reloaded from settings: still off, still explained")
        ok(rules.liveCount() == 0, "reloaded: not bound")

        -- Editing it in the form (which sends no `enabled`) keeps it OFF, reason and
        -- all: only the toggle turns a tripped rule back on.
        ok(rules.update(rid, { name = "Lock on wake (fixed)",
                               on = { type = "event", event = "wake" },
                               effect = { kind = "lockScreen" } }) == true, "a form edit saves")
        ok(row(rid).enabled == false and row(rid).autoDisabledReason ~= nil
            and rules.liveCount() == 0, "a form edit does not switch a tripped rule back on")
        ok(stored(rid).enabled == false and type(stored(rid).autoDisabledAt) == "number",
            "...on disk either")

        -- Turning it back on is the user overruling the breaker: reason cleared, and
        -- the window starts empty rather than one fire short of tripping again.
        rules.setEnabled(rid, true)
        ok(row(rid).autoDisabledReason == nil and stored(rid).autoDisabledAt == nil,
            "re-enabling clears the reason, in memory and on disk")
        locks = fake.actions.lock
        for _ = 1, 4 do fake.systemEvent("wake") end
        ok(fake.actions.lock == locks + 4 and row(rid).enabled == true,
            "after re-enabling, 4 fires run and the rule stays on")

        -- The window slides: fires older than 2 minutes drop out.
        fake.clockOffset = fake.clockOffset + 121
        fake.systemEvent("wake")
        ok(row(rid).enabled == true, "a 5th fire more than 2 minutes after the others does not trip")

        -- An ordinary rule is never tripped, however often it fires -----------------
        reset()
        local _, nid = rules.add({ on = { type = "event", event = "wake" },
                                   effect = { kind = "notify", title = "Morning" } })
        rules.startAll()
        ok(row(nid).risk == nil, "a notify rule carries no risk")
        local n0 = #fake.notifications
        for _ = 1, 12 do fake.systemEvent("wake") end
        ok(#fake.notifications == n0 + 12 and row(nid).enabled == true,
            "a non-risky rule fires 12 times in a row and stays on")

        -- A hotkey rule is a person pressing a key -- the rate limiter, not a loop ---
        reset()
        local _, hid = rules.add({ on = { type = "hotkey", mods = { "ctrl" }, key = "f13" },
                                   effect = { kind = "runCommand", command = "echo key" } })
        rules.startAll()
        local hr0 = #fake.runs
        for _ = 1, 8 do fake.pressHotkey("f13", { "ctrl" }) end
        ok(#fake.runs == hr0 + 8 and row(hid).enabled == true,
            "a risky rule on a hotkey runs every press and is never tripped")

        -- The signal path: tripping inside the subscriber loop ----------------------
        -- Two rules on frontmostApp; the risky one trips mid-iteration, the ordinary
        -- one must keep receiving the signal.
        reset()
        fake.frontmost = "Finder"
        local _, cid = rules.add({ on = { type = "state", signal = "frontmostApp", becomes = "Zoom" },
                                   effect = { kind = "runCommand", command = "echo hi" } })
        local _, mid = rules.add({ on = { type = "state", signal = "frontmostApp", becomes = "Zoom" },
                                   effect = { kind = "notify", title = "Zoom" } })
        rules.startAll()
        ok(rules.liveCount() == 2, "two frontmostApp rules bound")
        local runs0, notes0 = #fake.runs, #fake.notifications
        for _ = 1, 5 do
            fake.activateApp("Finder"); fake.activateApp("Zoom")
        end
        ok(#fake.runs == runs0 + 4, "the command ran 4 times; the 5th was blocked")
        ok(row(cid).enabled == false and row(cid).risk == "exec", "the run-command rule tripped")
        ok(#fake.notifications == notes0 + 5, "the other rule on the same signal saw all 5")
        fake.activateApp("Finder"); fake.activateApp("Zoom")
        ok(#fake.runs == runs0 + 4 and #fake.notifications == notes0 + 6,
            "after the trip only the ordinary rule still fires")
        ok(row(mid).enabled == true and rules.liveCount() == 1, "the ordinary rule is untouched")

        -- Save-time refusal of the self-looping combination -------------------------
        reset()
        local okA, errA = rules.add({ on = { type = "event", event = "screenUnlock" },
                                      effect = { kind = "lockScreen" } })
        ok(okA == false and tostring(errA):find("lock you out", 1, true),
            "lock-on-unlock is refused, with the reason")
        ok(rules.add({ on = { type = "event", event = "screenUnlock" },
                       effect = { kind = "chain", effects = { { kind = "notify", title = "x" },
                                                              { kind = "startScreensaver" } } } }) == false,
            "a chain that ends in a lockout is refused on unlock too")
        ok(rules.add({ on = { type = "event", event = "screenUnlock" },
                       effect = { kind = "chain", effects = { { kind = "runCommand", command = "x" },
                                                              { kind = "lockScreen" } } } }) == false,
            "a lock later in a chain, behind another risky step, is refused on unlock too")
        ok(rules.add({ on = { type = "event", event = "screenUnlock" },
                       effect = { kind = "notify", title = "Welcome back" } }) == true,
            "an ordinary effect on unlock is fine")
        ok(rules.add({ on = { type = "event", event = "wake" },
                       effect = { kind = "lockScreen" } }) == true,
            "lock on wake is allowed -- locking does not sleep the system, so it cannot loop")

        -- Where Notification Center is unavailable (a dev run), the notice falls
        -- back to the toast rather than vanishing.
        reset()
        fake.systemNotifyDelivers = false
        local _, fid = rules.add({ name = "Screensaver on wake",
                                   on = { type = "event", event = "wake" },
                                   effect = { kind = "startScreensaver" } })
        rules.startAll()
        local alerts0 = #fake.alerts
        for _ = 1, 5 do fake.systemEvent("wake") end
        ok(row(fid).enabled == false and #fake.alerts == alerts0 + 1
            and fake.alerts[#fake.alerts]:find("Screensaver on wake", 1, true),
            "no Notification Center: the trip notice falls back to the toast")
        fake.systemNotifyDelivers = true

        -- Safe mode: loaded, listed, never bound -- not even by an edit's restart --
        reset()
        local _, pid = rules.add({ on = { type = "event", event = "wake" },
                                   effect = { kind = "lockScreen" } })
        local _, qid = rules.add({ on = { type = "event", event = "sleep" },
                                   effect = { kind = "notify", title = "Night" } })
        rules.startAll()
        told0 = #fake.systemNotifications
        rules.enterSafeMode()
        ok(rules.liveCount() == 0 and rules.isPaused(), "safe mode unbinds everything")
        ok(#fake.systemNotifications == told0 + 1, "safe mode says so")
        ok(row(pid) ~= nil and row(qid) ~= nil, "paused rules are still listed")
        rules.setEnabled(pid, false)                  -- the user switching off the bad one
        ok(rules.liveCount() == 0, "an edit while paused does not re-arm the others")
        locks = fake.actions.lock
        fake.systemEvent("wake")
        ok(fake.actions.lock == locks, "nothing fires while paused")
        rules.setPaused(false); rules.startAll()
        ok(rules.liveCount() == 1, "resuming binds the rules that are on")

        -- cleanup
        reset()
        fake.clockOffset = clock0
        ok(fake.liveHandles == 0, "no native handle leaked across the breaker test")
    end,
}
