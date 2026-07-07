-- test/cases/_integration/rules/rules_fire_status.lua -- per-rule FIRE STATUS -- describe() reports when a rule last fired, whether
-- it was a Test, and whether the effect succeeded, so a silently-dead rule shows --
--
-- Migrated from run.lua T35f (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration: platform subsystem, driven by throwaway features/effects. Hermetic --
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so the catalog
-- and the rules singleton both start empty.

return {
    id = "rules_fire_status",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
        local rules = require("platform.rules")

        fake.settings["hammerdeck.rules"] = nil
        fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1 } }
        fake.windows = {}

        local function row(rid)
            for _, r in ipairs(rules.describe()) do if r.id == rid then return r end end
        end

        rules.load({})
        local _, nid = rules.add({ on = { type = "event", event = "wake" },
            effect = { kind = "notify", title = "hi" } })
        rules.startAll()
        ok(row(nid).lastFired == nil, "a fresh rule reports no last-fired time (not fired yet)")

        -- a REAL trigger fire stamps lastFired -- not a test, effect succeeded
        fake.systemEvent("wake")
        local r1 = row(nid)
        ok(type(r1.lastFired) == "number" and r1.lastFiredTest ~= true and r1.lastFiredOk == true,
            "a real trigger fire records lastFired (via trigger, ok)")

        -- a TEST fire is tagged so the UI can say 'tested' not 'fired'
        rules.fire(nid)
        ok(row(nid).lastFiredTest == true, "a Test fire is tagged lastFiredTest")

        -- editing a rule clears its fire history (the old fire no longer describes it)
        rules.update(nid, { on = { type = "event", event = "wake" },
            effect = { kind = "notify", title = "changed" } })
        ok(row(nid).lastFired == nil, "update() clears the fire history (behavior changed)")

        -- a FAILED effect (layout with no present display) records lastFiredOk = false
        local _, lid = rules.add({ on = { type = "event", event = "wake" },
            effect = { kind = "layout", placements = { { app = "X", screen = "Ghost", pos = "full" } } } })
        rules.startAll()
        fake.systemEvent("wake")
        ok(row(lid).lastFiredOk == false, "a failed effect records lastFiredOk = false")

        -- removing a rule drops its fire history; a fresh load clears it all
        rules.remove(nid)
        ok(row(nid) == nil, "a removed rule leaves no row")
        rules.load({ { id = nid, on = { type = "event", event = "wake" },
            effect = { kind = "notify", title = "hi" } } })
        ok(row(nid).lastFired == nil, "load() clears the fire history (a fresh session)")

        -- cleanup
        rules.stopAll()
        rules.load({})
        fake.settings["hammerdeck.rules"] = nil
        fake.windows = {}
        ok(fake.liveHandles == 0, "no native handle leaked across the fire-status tests")
    end,
}
