-- test/cases/_integration/rules/rules_engine_m0.lua -- rules engine (M0): the automation
-- framework spine. A rule binds ANY trigger to ANY effect across features; the M0
-- effect kind is `command` (run a feature action). Covers an event rule and a
-- manual-hotkey rule firing a target action, load() replacing the rule set, the
-- automatable context policy (an automated trigger on a non-automatable effect is
-- refused at load -- the same rule the registry enforces per action), malformed-rule
-- quarantine, a rule whose target feature is disabled firing as a logged no-op,
-- loadFromSettings decoding the `hammerdeck.rules` JSON key, and leak-free teardown.
-- Pure Lua over the fake adapter.
--
-- Migrated from run.lua T34 (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration (no shipped feature under test -- it drives throwaway `_rule_auto` /
-- `_rule_manual` actions, cleared by freshWorld's `^features%.` purge). Hermetic:
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so both the
-- catalog and the rules singleton start empty.

return {
    id = "rules_engine_m0",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry
        local rules = require("platform.rules")
        local json  = require("platform.json")

        -- An AUTOMATABLE target action (so event/schedule rules are allowed) with
        -- no defaultTrigger -- it exists only to be fired by rules.
        local ranAuto = 0
        package.loaded["features._rule_auto"] = {
            api = 1, id = "rule_auto", name = "Rule Auto",
            actions = { { id = "go", label = "Go", automatable = true,
                          run = function() ranAuto = ranAuto + 1 end } },
        }
        -- A NON-automatable target (context-dependent -- the default).
        package.loaded["features._rule_manual"] = {
            api = 1, id = "rule_manual", name = "Rule Manual",
            actions = { { id = "go", run = function() end } },
        }
        registry.load("features._rule_auto")
        registry.load("features._rule_manual")
        registry.setEnabled("rule_auto", true)
        registry.setEnabled("rule_manual", true)

        -- (a) an event rule fires the target action
        ok(rules.load({
            { id = "wake-go", on = { type = "event", event = "wake" },
              effect = { kind = "command", feature = "rule_auto", action = "go" } },
        }) == 1, "rules.load keeps a valid rule")
        rules.startAll()
        ok(rules.liveCount() == 1, "startAll bound the rule")
        fake.systemEvent("wake")
        ok(ranAuto == 1, "event rule fired the target feature's action")

        -- (b) a manual hotkey rule fires the same action
        ok(rules.load({
            { id = "hk-go", on = { type = "hotkey", mods = { "ctrl" }, key = "f13" },
              effect = { kind = "command", feature = "rule_auto", action = "go" } },
        }) == 1, "load replaces the rule set")
        rules.startAll()
        fake.systemEvent("wake")
        ok(ranAuto == 1, "the replaced (event) rule no longer fires after reload")
        fake.pressHotkey("f13", { "ctrl" })
        ok(ranAuto == 2, "hotkey rule fired the action")

        -- (c) CONTEXT POLICY: an automated trigger on a non-automatable effect is
        -- refused at load; a manual trigger on the same effect loads fine.
        local kept = rules.load({
            { id = "bad-auto", on = { type = "event", event = "wake" },
              effect = { kind = "command", feature = "rule_manual", action = "go" } },
            { id = "ok-manual", on = { type = "hotkey", mods = { "ctrl" }, key = "f14" },
              effect = { kind = "command", feature = "rule_manual", action = "go" } },
        })
        ok(kept == 1, "automated trigger on a non-automatable effect refused; manual kept")
        local ids = {}
        for _, r in ipairs(rules.all()) do ids[r.id] = true end
        ok(ids["ok-manual"] and not ids["bad-auto"],
            "the manual rule survived; the context-violating automated rule was dropped")

        -- (d) malformed rules are quarantined (no id, unknown effect kind), valid kept
        ok(rules.load({
            { id = "good", on = { type = "event", event = "wake" },
              effect = { kind = "command", feature = "rule_auto", action = "go" } },
            { on = { type = "event", event = "wake" },                       -- no id
              effect = { kind = "command", feature = "rule_auto", action = "go" } },
            { id = "badeffect", on = { type = "event", event = "wake" },
              effect = { kind = "teleport" } },                              -- unknown kind
        }) == 1, "malformed rules quarantined; the valid one is kept")

        -- (e) a rule whose target feature is DISABLED still loads, and firing it is a
        -- logged no-op (not a crash)
        registry.setEnabled("rule_auto", false)
        ok(rules.load({
            { id = "disabled-target", on = { type = "hotkey", mods = { "ctrl" }, key = "f15" },
              effect = { kind = "command", feature = "rule_auto", action = "go" } },
        }) == 1, "a rule targeting a disabled feature still loads (manual trigger)")
        rules.startAll()
        local before = ranAuto
        fake.pressHotkey("f15", { "ctrl" })
        ok(ranAuto == before, "firing a rule whose target is disabled is a no-op, not a crash")

        -- (f) loadFromSettings reads the JSON `hammerdeck.rules` key (the M4-UI source)
        registry.setEnabled("rule_auto", true)
        fake.settings["hammerdeck.rules"] = json.encode({
            { id = "from-settings", on = { type = "event", event = "wake" },
              effect = { kind = "command", feature = "rule_auto", action = "go" } },
        })
        ok(rules.loadFromSettings() == 1, "loadFromSettings decodes + loads the rules JSON setting")
        rules.startAll()
        before = ranAuto
        fake.systemEvent("wake")
        ok(ranAuto == before + 1, "a rule loaded from settings fires")
        fake.settings["hammerdeck.rules"] = nil

        -- (g) teardown leaks nothing
        rules.stopAll()
        ok(rules.liveCount() == 0, "stopAll unbound every rule")
        rules.load({})
        ok(rules.count() == 0, "rules.load({}) clears the set")

        registry.setEnabled("rule_auto", false)
        registry.setEnabled("rule_manual", false)
        registry.unregister("rule_auto")
        registry.unregister("rule_manual")
        ok(fake.liveHandles == 0, "no native handle leaked across the rules engine tests")
    end,
}
