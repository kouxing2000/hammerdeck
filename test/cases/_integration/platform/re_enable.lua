-- test/cases/_integration/platform/re_enable.lua -- re-enabling a feature works with a fresh ctx -- seeds its own window
-- (the split removed a hidden dependency on a fixture T3 left behind), fires
-- the chooser, then disables and asserts a clean handle count.
--
-- Migrated from run.lua T8 (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "re_enable",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        registry.loadCatalog({ "features.sleep_schedule", "features.break_reminder", "features.window_switcher" })

        -- seed our own window so the chooser has something to show -- this used to lean on
        -- the fixture T3 left behind (a hidden cross-section dependency the split removed).
        fake.windows = { { id = 11, title = "W", appName = "AppA", bundleID = "com.a" } }
        registry.setEnabled("window_switcher", true)
        fake.pressHotkey("tab")
        ok(fake.visibleChooser() ~= nil, "re-enabled feature works with a fresh ctx")
        registry.setEnabled("window_switcher", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after re-enable cycle")
    end,
}
