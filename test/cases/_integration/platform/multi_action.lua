-- test/cases/_integration/platform/multi_action.lua -- multi-action features -- one plugin, several independently
-- rebindable shortcuts (+ an optional service). Both actions fire on their
-- own hotkeys, per-action rebind leaves siblings + the running service
-- untouched, siblings cannot collide, new-shape validation, per-action
-- describe state, and the legacy single-key stored override for sugar.
--
-- Migrated from run.lua T15 (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "multi_action",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, rejects, fake, registry = t.ok, t.rejects, t.fake, t.registry

        do
        local hits = { a = 0, b = 0 }
        local starts = 0
        package.loaded["features._multi"] = {
            api = 1, id = "multi", name = "Multi",
            start = function(ctx) starts = starts + 1 end,   -- service + actions combo
            actions = {
                { id = "alpha", label = "Alpha",
                  defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "1" },
                  run = function() hits.a = hits.a + 1 end },
                { id = "beta", label = "Beta",
                  defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "2" },
                  run = function() hits.b = hits.b + 1 end },
            },
        }
        registry.load("features._multi")
        registry.setEnabled("multi", true)
        ok(starts == 1, "service starts alongside its actions")
        fake.pressHotkey("1"); fake.pressHotkey("2")
        ok(hits.a == 1 and hits.b == 1, "both actions fire on their own hotkeys")

        -- per-action rebind: siblings and the running service are untouched
        ok(registry.setTrigger("multi", "beta", { type = "hotkey", mods = { "ctrl" }, key = "3" }) == true,
            "one action rebinds")
        ok(starts == 1, "rebinding one action does not restart the service")
        fake.pressHotkey("2")
        ok(hits.b == 1, "the rebound action's old key is dead")
        fake.pressHotkey("3"); fake.pressHotkey("1")
        ok(hits.b == 2 and hits.a == 2, "new key fires; the sibling action is unaffected")
        ok(fake.settings["hammerdeck.trigger.multi.beta"] == "hotkey|ctrl|3",
            "per-action override key persisted")

        -- sibling actions cannot collide on a hotkey
        local okSet2, why2 = registry.setTrigger("multi", "alpha", { type = "hotkey", mods = { "ctrl" }, key = "3" })
        ok(okSet2 == false and why2 ~= nil, "sibling actions cannot share a hotkey")

        -- new-shape manifest validation
        rejects({ api = 1, id = "x", name = "X", action = function() end,
                  actions = { { id = "a", run = function() end } } }, "action AND actions together")
        rejects({ api = 1, id = "x", name = "X",
                  actions = { { id = "a", run = function() end },
                              { id = "a", run = function() end } } }, "duplicate action ids")
        rejects({ api = 1, id = "x", name = "X", actions = { { id = "a" } } }, "action without run")

        -- describe carries per-action trigger state
        local multiDesc
        for _, d in ipairs(registry.describe()) do if d.id == "multi" then multiDesc = d end end
        ok(#multiDesc.actions == 2 and multiDesc.actions[2].id == "beta"
            and multiDesc.actions[2].trigger.key == "3"
            and multiDesc.actions[2].triggerOverridden == true,
            "describe exports per-action trigger state")
        ok(multiDesc.kind == "service" and multiDesc.triggerDesc == "2 actions",
            "a service + actions hybrid summarizes its ACTIONS in the list, not 'always-on service'")

        -- legacy stored key (pre-multi-action) is honored for single-action sugar
        package.loaded["features._legacy"] = {
            api = 1, id = "legacy", name = "Legacy",
            defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "8" },
            action = function() hits.a = hits.a + 100 end,
        }
        registry.load("features._legacy")
        fake.settings["hammerdeck.trigger.legacy"] = "hotkey|ctrl|9"   -- old-style override
        registry.setEnabled("legacy", true)
        fake.pressHotkey("9")
        ok(hits.a == 102, "legacy hammerdeck.trigger.<id> override is honored for sugar features")

        registry.setEnabled("multi", false)
        registry.setEnabled("legacy", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after multi-action tests")

        end
    end,
}
