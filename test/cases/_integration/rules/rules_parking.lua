-- test/cases/_integration/rules/rules_parking.lua -- PARKING -- a stored rule whose target is absent THIS boot (a renamed/gone
-- signal or feature) is PRESERVED + surfaced as "unavailable", never silently
-- deleted on the next mutation, and re-activates when its target returns ----------
--
-- Migrated from run.lua T35p (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration: platform subsystem, driven by throwaway features/effects. Hermetic --
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so the catalog
-- and the rules singleton both start empty.

return {
    id = "rules_parking",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
        local rules = require("platform.rules")

        fake.settings["hammerdeck.rules"] = nil

        -- reason attribution: a rule with a gone signal AND a command effect blames the
        -- SIGNAL (the verifiable cause), not the feature -- the parkReason ordering.
        rules.load({ { id = "both", on = { type = "state", signal = "ghostSignal", becomes = "X" },
            effect = { kind = "command", feature = "whatever", action = "go" } } })
        local both
        for _, r in ipairs(rules.describe()) do if r.id == "both" then both = r end end
        ok(both ~= nil and both.reason:find("ghostSignal", 1, true) ~= nil,
            "a gone-signal + command rule blames the signal, not the feature")

        -- one valid rule + one referencing a signal that no longer exists (same failure
        -- shape as a feature renamed/removed across an app update).
        local kept = rules.load({
            { id = "good",  on = { type = "event", event = "wake" },
              effect = { kind = "notify", title = "ok" } },
            { id = "ghost", on = { type = "state", signal = "ghostSignal", becomes = "X" },
              effect = { kind = "notify", title = "z" } },
        })
        ok(kept == 1, "load keeps the valid rule and PARKS the unavailable one (count excludes it)")
        rules.startAll()
        ok(rules.liveCount() == 1, "a parked rule is not bound")

        -- the parked rule is SURFACED (greyed/unavailable), not vanished
        local ghost
        for _, r in ipairs(rules.describe()) do if r.id == "ghost" then ghost = r end end
        ok(ghost ~= nil and ghost.unavailable == true, "describe() surfaces the parked rule as unavailable")
        ok(type(ghost.reason) == "string" and ghost.reason:find("ghostSignal", 1, true) ~= nil,
            "the unavailable reason names the missing target")

        -- THE BUG: a mutation must NOT erase the parked rule. setEnabled persists, then
        -- a fresh load from settings must still find BOTH.
        rules.setEnabled("good", false)
        rules.loadFromSettings()
        local stillGhost = false
        for _, r in ipairs(rules.describe()) do if r.id == "ghost" then stillGhost = true end end
        ok(stillGhost, "a mutation re-persists the parked rule -- it is NOT silently deleted")

        -- a parked rule is deletable
        ok(rules.remove("ghost") == true, "a parked rule can be removed")
        local gone = true
        for _, r in ipairs(rules.describe()) do if r.id == "ghost" then gone = false end end
        ok(gone, "removing a parked rule drops it from the list")

        -- editing a parked rule's JSON to a VALID spec un-parks it into the live set
        rules.load({
            { id = "fix", on = { type = "state", signal = "ghostSignal", becomes = "X" },
              effect = { kind = "notify", title = "z" } },
        })
        ok(rules.count() == 0 and select(1, rules.specJSON("fix")) ~= nil,
            "a parked rule is editable (specJSON returns it) though count excludes it")
        ok(rules.update("fix", { on = { type = "event", event = "wake" },
            effect = { kind = "notify", title = "z" } }) == true,
            "updating a parked rule to a valid spec succeeds (un-parks)")
        ok(rules.count() == 1, "the fixed rule un-parks into the live set")
        local fixed
        for _, r in ipairs(rules.describe()) do if r.id == "fix" then fixed = r end end
        ok(fixed ~= nil and fixed.unavailable ~= true, "the un-parked rule is now a normal live rule")

        -- cleanup
        rules.stopAll()
        rules.load({})
        fake.settings["hammerdeck.rules"] = nil
        ok(fake.liveHandles == 0, "no native handle leaked across the parking tests")
    end,
}
