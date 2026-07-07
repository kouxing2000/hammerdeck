-- test/cases/_integration/platform/default_enabled.lua -- defaultEnabled -- a feature with defaultEnabled=true ships enabled
-- when NO stored choice exists, an explicit user toggle always overrides,
-- and a plain feature still ships off (blank-slate).
--
-- Migrated from run.lua T7e (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "default_enabled",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        do
            package.loaded["features._defon_probe"] = {
                api = 1, id = "defon_probe", name = "Default On Probe",
                defaultEnabled = true, start = function() end,
            }
            registry.load("features._defon_probe")

            fake.settings["hammerdeck.enabled.defon_probe"] = nil
            ok(registry.isEnabled("defon_probe") == true,
                "defaultEnabled=true ships enabled when the user has never toggled it")
            fake.settings["hammerdeck.enabled.defon_probe"] = false
            ok(registry.isEnabled("defon_probe") == false,
                "an explicit user off overrides defaultEnabled=true")

            -- and a plain feature (no defaultEnabled) still ships OFF, as before.
            package.loaded["features._defoff_probe"] = {
                api = 1, id = "defoff_probe", name = "Default Off Probe", start = function() end,
            }
            registry.load("features._defoff_probe")
            fake.settings["hammerdeck.enabled.defoff_probe"] = nil
            ok(registry.isEnabled("defoff_probe") == false,
                "a feature without defaultEnabled stays off by default (blank-slate)")

            registry.unregister("defon_probe")
            registry.unregister("defoff_probe")
            fake.settings["hammerdeck.enabled.defon_probe"] = nil
        end
    end,
}
