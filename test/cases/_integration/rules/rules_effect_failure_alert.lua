-- test/cases/_integration/rules/rules_effect_failure_alert.lua -- a rule whose effect keeps FAILING raises ONE visible alert after 3
-- consecutive REAL fires (the directly-bound automated path already does this via
-- registry.FAIL_ALERT_AFTER; rules now mirror it, keyed per RULE). Manual "Test"
-- fires don't count toward the streak, and a success resets it -- so a scheduled
-- rule silently dying surfaces, without per-effect popup spam.
--
-- Migrated from run.lua T35a-P10 (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration: platform subsystem, driven by throwaway features/effects. Hermetic --
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so the catalog
-- and the rules singleton both start empty.

return {
    id = "rules_effect_failure_alert",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry
        local rules = require("platform.rules")

        -- An automatable action that throws on demand (toggle `boom` to make it succeed).
        local boom = true
        package.loaded["features._m1_fail"] = {
            api = 1, id = "m1_fail", name = "M1 Fail",
            actions = { { id = "boom", automatable = true,
                          run = function() if boom then error("kaboom") end end } },
        }
        registry.load("features._m1_fail"); registry.setEnabled("m1_fail", true)

        fake.frontmost = "Finder"
        ok(rules.load({
            { id = "flaky", name = "Flaky rule",
              on = { type = "state", signal = "frontmostApp", becomes = "Zoom" },
              effect = { kind = "command", feature = "m1_fail", action = "boom" } },
        }) == 1, "a rule on an automatable (but throwing) command loads")
        rules.startAll()
        ok(rules.liveCount() == 1, "failing-effect rule bound")

        -- Drive exactly one REAL fire (enter Zoom from elsewhere).
        local function enterZoom()
            fake.activateApp("Finder")   -- leave Zoom (a `becomes` rule does not fire on leave)
            fake.activateApp("Zoom")     -- enter -> one real fire
        end

        local aB = #fake.alerts
        enterZoom()
        ok(#fake.alerts == aB, "1st real failure: logged, no alert yet")
        enterZoom()
        ok(#fake.alerts == aB, "2nd real failure: still no alert")
        -- A manual Test fire fails too, but must NOT advance the streak.
        rules.fire("flaky")
        ok(#fake.alerts == aB, "a failing manual Test fire does not count toward the streak")
        enterZoom()
        ok(#fake.alerts == aB + 1, "3rd consecutive REAL failure raises exactly one alert")
        ok(fake.alerts[#fake.alerts]:find("Flaky rule", 1, true)
            and fake.alerts[#fake.alerts]:find("keeps failing", 1, true),
            "the alert names the rule and says it keeps failing")
        enterZoom()
        ok(#fake.alerts == aB + 1, "further failures stay quiet -- no popup spam")

        -- A SUCCESS clears the streak: it then takes 3 fresh failures to alert again.
        boom = false
        enterZoom()
        ok(#fake.alerts == aB + 1, "a successful fire raises no alert (and clears the streak)")
        boom = true
        enterZoom(); enterZoom()
        ok(#fake.alerts == aB + 1, "two failures after the reset: below threshold, still quiet")
        enterZoom()
        ok(#fake.alerts == aB + 2, "streak restarted post-success -> 3 more failures, one new alert")

        -- cleanup
        rules.load({})
        registry.setEnabled("m1_fail", false); registry.unregister("m1_fail")
        ok(fake.liveHandles == 0, "no native handle leaked across the P10 fail-alert test")
    end,
}
