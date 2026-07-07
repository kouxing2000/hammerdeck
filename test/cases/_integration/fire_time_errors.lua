-- test/cases/_integration/fire_time_errors.lua -- fire-time error containment: when a bound
-- action THROWS, the registry must contain it (never let one bad plugin crash the platform),
-- keep running it, stay quiet for the first couple of failures, then raise exactly ONE visible
-- alert on the third consecutive failure and never spam again. This is platform behavior, not a
-- feature -- it drives a throwaway `_boom` action whose only job is to error() every time.
--
-- Migrated from run.lua T30 (RUN_LUA_SPLIT_SPEC). Integration (no real feature under test):
-- it exercises the registry's fire path. Hermetic -- injects its own `features._boom` (cleared
-- by freshWorld's `^features%.` purge before the next case) and reads alert-count deltas, so it
-- is insensitive to any alerts an earlier case left behind.

return {
    id = "fire_time_errors",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        local boomCount = 0
        package.loaded["features._boom"] = {
            api = 1, id = "boom", name = "Boom Feature",
            defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "0" },
            action = function() boomCount = boomCount + 1; error("kaboom") end,
        }
        registry.load("features._boom")
        registry.setEnabled("boom", true)
        local alertsBoom = #fake.alerts
        fake.pressHotkey("0")   -- failure 1
        fake.pressHotkey("0")   -- failure 2
        ok(#fake.alerts == alertsBoom, "early failures stay quiet (logged only)")
        fake.pressHotkey("0")   -- failure 3 -> alert
        ok(#fake.alerts == alertsBoom + 1 and fake.alerts[#fake.alerts]:match("keeps failing"),
            "the third consecutive failure raises one visible alert")
        fake.pressHotkey("0")   -- failure 4 -> no more spam
        ok(#fake.alerts == alertsBoom + 1, "further failures do not spam additional alerts")
        ok(boomCount == 4, "a throwing action is contained, not silently swallowed (still ran each time)")
        registry.setEnabled("boom", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after error-surfacing test")
    end,
}
