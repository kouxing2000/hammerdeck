-- test/cases/_integration/platform/feature_autodiscovery.lua -- feature autodiscovery -- scan the features dir instead of a fixed
-- list. discover() returns one sorted+prefixed module per on-disk feature;
-- reload in discovery mode re-scans; a hot-plugged/removed folder appears/
-- disappears on the next reload.
--
-- Migrated from run.lua T14 (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "feature_autodiscovery",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        do
        fake.featureNames = { "window_switcher", "display_off", "plain_paste", "break_reminder", "sleep_schedule" }

        local discovered = registry.discover("ignored-by-fake")
        ok(#discovered == 5, "discover returns one module per feature on disk")
        ok(discovered[1] == "features.break_reminder", "discover sorts + prefixes module names")

        -- Switch to discovery mode and reload: it re-scans and ends with exactly the
        -- discovered set (this also drops the non-catalog test probes from T9/T10).
        registry.setFeatureDir("ignored-by-fake")
        local sum = registry.reload()
        ok(sum.count == 5 and sum.failures == 0, "reload in discovery mode loads the scanned features")

        -- Hot-plug: a name newly appearing in the scan shows up on the next reload;
        -- one that disappears is dropped.
        fake.featureNames = { "window_switcher" }
        local sum2 = registry.reload()
        ok(sum2.count == 1, "reload re-scans -- a removed feature folder is dropped")
        ok(registry.describe()[1].id == "window_switcher", "the surviving feature is the discovered one")

        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after autodiscovery test")

        end
    end,
}
