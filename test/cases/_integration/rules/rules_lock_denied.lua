-- test/cases/_integration/rules/rules_lock_denied.lua -- SEC-2's DENIED path, at the wiring altitude the real
-- failure lives at. `adapter.lockScreen()` returns false when the Accessibility
-- grant is missing, and NOTHING was locked; every layer above it has to carry
-- that verdict, or the machine is left open while the log, the rules list and
-- the keeps-failing alert all say the screen was locked.
--
-- Three outcomes are asserted on the denied side, because each is a separate
-- caller that could drop the boolean: no lock reaches the seam, the effect
-- returns failure WITH a cause, and the rule row + daily log record FAILED
-- rather than `fired`. The granted control proves the same path still records
-- one lock and a success -- an always-failing path would satisfy the denied
-- assertions on its own.
--
-- This is the non-disruptive half of the SEC-2 gate (MANUAL_TEST_RUNBOOK.md):
-- the one thing left for a human is that a granted, packaged candidate reaches
-- the real login window. Nothing here may lock anything -- the fake adapter
-- counts the call.
--
-- Integration: platform subsystem. Hermetic -- freshWorld() runs registry.reset()
-- + rules.load({}) before the case, so the rules singleton starts empty.

return {
    id = "rules_lock_denied",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
        local rules   = require("platform.rules")
        local effects = require("platform.effects")

        local function row(rid)
            for _, r in ipairs(rules.describe()) do if r.id == rid then return r end end
        end
        -- Did any line logged since `from` contain `needle`? The log is the audit
        -- trail the release gate reads, so it is asserted as a real artifact.
        local function loggedSince(from, needle)
            for i = from + 1, #fake.logs do
                if fake.logs[i]:find(needle, 1, true) then return true end
            end
            return false
        end

        fake.settings["hammerdeck.rules"] = nil
        rules.load({})
        local _, rid = rules.add({ on = { type = "event", event = "wake" },
                                   effect = { kind = "lockScreen" } })
        rules.startAll()

        -- Granted control -------------------------------------------------------
        ok(fake.axTrusted == true, "control starts on a granted machine")
        local locks, marker = fake.actions.lock, #fake.logs
        fake.systemEvent("wake")
        ok(fake.actions.lock == locks + 1, "granted: the rule's effect locks exactly once")
        ok(row(rid).lastFiredOk == true, "granted: the rule row records a successful fire")
        ok(loggedSince(marker, "fired -> Lock the screen"),
            "granted: the log says the screen was locked")

        -- Denied ----------------------------------------------------------------
        fake.axTrusted = false
        locks, marker = fake.actions.lock, #fake.logs
        fake.systemEvent("wake")
        ok(fake.actions.lock == locks, "denied: no lock reached the seam -- nothing was locked")
        ok(row(rid).lastFiredOk == false, "denied: the rule row records FAILURE, not a fire")
        ok(not loggedSince(marker, "fired -> Lock the screen"),
            "denied: the log never claims the screen was locked")
        ok(loggedSince(marker, "effect FAILED"), "denied: the log records the failure")
        ok(loggedSince(marker, "grant Accessibility"),
            "denied: the failure names its cause, not a bare nil")

        -- The effect itself, dispatched directly: `false` plus a reason is the
        -- contract every caller above reads, including the keeps-failing alert.
        local fired, why = effects.dispatch({ kind = "lockScreen" })
        ok(fired == false, "denied: effects.dispatch reports the lock did not happen")
        ok(type(why) == "string" and why ~= "", "denied: the failure carries a cause")

        -- The Test button (`via = "test"`) is the path the manual runbook fires,
        -- so a denied grant must read as a failed test there too -- never a row
        -- that says Fired while the machine stayed open.
        marker = #fake.logs
        rules.fire(rid)
        local r = row(rid)
        ok(r.lastFiredTest == true and r.lastFiredOk == false,
            "denied: a Test fire is recorded as a failed test")
        ok(loggedSince(marker, "[test] effect FAILED"),
            "denied: the Test fire's log line says FAILED, not fired")

        -- Re-granting recovers: the wiring is gated on the live verdict, not on a
        -- state latched at bind time.
        fake.axTrusted = true
        locks = fake.actions.lock
        fake.systemEvent("wake")
        ok(fake.actions.lock == locks + 1 and row(rid).lastFiredOk == true,
            "the grant returning restores a working lock")

        -- cleanup
        rules.stopAll()
        rules.load({})
        fake.settings["hammerdeck.rules"] = nil
        ok(fake.liveHandles == 0, "no native handle leaked across the SEC-2 denied-path test")
    end,
}
