-- test/cases/_integration/platform/hot_reload.lua -- hot reload -- re-read the catalog from disk, keep enabled-state.
-- Uses the real on-disk MVP modules so the package.loaded invalidation +
-- re-require path runs for real; a re-required feature still works; a disabled
-- feature stays disabled; and a non-catalog feature (seeded here, since the
-- monolith leaned on a T9/T10 leftover) is dropped by reload.
--
-- Migrated from run.lua T11 (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "hot_reload",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        registry.loadCatalog({ "features.sleep_schedule", "features.break_reminder", "features.window_switcher" })
        -- Seed a window so the re-required window_switcher has a chooser to show
        -- (the monolith leaned on a window an earlier section left behind).
        fake.windows = { { id = 11, title = "W", appName = "AppA", bundleID = "com.a" } }
        -- A non-catalog feature (registered directly, not via loadCatalog) must be
        -- dropped by reload; the monolith leaned on a probe left behind by T9/T10,
        -- so seed our own to make the assertion meaningful in isolation.
        package.loaded["features._rebind_probe"] = {
            api = 1, id = "rebind_probe", name = "Rebind Probe",
            defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "p" },
            action = function() end,
        }
        registry.load("features._rebind_probe")

        do
        registry.setEnabled("window_switcher", true)
        ok(registry.liveHandleCount() >= 1, "an enabled feature has a live binding before reload")

        local summary = registry.reload()
        ok(summary.count == 3, "reload re-registered exactly the catalog features")
        ok(summary.failures == 0, "reload reported no load failures")
        ok(registry.isEnabled("window_switcher"), "enabled-state persisted across reload")
        ok(registry.liveHandleCount() >= 1, "reload re-bound the enabled feature")

        -- the freshly re-required feature actually works (closure state was rebuilt)
        fake.pressHotkey("tab")
        ok(fake.visibleChooser() ~= nil, "feature functions after a hot reload")
        fake.visibleChooser().userSelect(1)

        -- a feature left disabled is registered but not bound after reload
        local svcEnabled
        for _, d in ipairs(registry.describe()) do
            if d.id == "sleep_schedule" then svcEnabled = d.enabled end
        end
        ok(svcEnabled == false, "a disabled feature stays disabled after reload")

        -- the synthetic probes from T9/T10 (not in the catalog) are gone after reload
        local stillHasProbe = false
        for _, d in ipairs(registry.describe()) do
            if d.id == "rebind_probe" then stillHasProbe = true end
        end
        ok(not stillHasProbe, "non-catalog features are dropped by reload")

        registry.setEnabled("window_switcher", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after hot-reload test")

        end
    end,
}
