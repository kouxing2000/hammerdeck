-- test/cases/_integration/platform/feature_quarantine.lua -- plugin quarantine -- one bad plugin must never take the platform
-- down. A missing module is recorded (not thrown), an invalid manifest fails
-- at register, a feature that throws inside start() (after creating a handle)
-- is torn down + recorded + described, and disabling clears the failure.
--
-- Migrated from run.lua T9 (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "feature_quarantine",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        -- (a) a missing module is recorded, not thrown
        do
        ok(registry.load("features._does_not_exist") == nil, "load returns nil for a missing module")
        ok(#registry.failures().load >= 1, "missing module recorded as a load failure")

        -- (b) an invalid manifest fails at register, still quarantined
        package.loaded["features._bad_manifest"] = { api = 1, id = "bad_manifest", name = "Bad" } -- no action/start
        ok(registry.load("features._bad_manifest") == nil, "load returns nil for an invalid manifest")

        -- (c) a feature that throws inside start(ctx) -- after creating a handle -- is
        --     quarantined: enable doesn't throw, the partial scope is torn down, and
        --     the failure is recorded + describable.
        package.loaded["features._bad_start"] = {
            api = 1, id = "bad_start", name = "Bad Start",
            start = function(ctx)
                ctx.everySeconds(5, function() end)   -- a handle BEFORE the throw
                error("boom in start")
            end,
        }
        ok(registry.load("features._bad_start") ~= nil, "valid manifest with a throwing start registers fine")
        ok(pcall(registry.setEnabled, "bad_start", true), "enabling a broken feature does not throw")
        ok(registry.failures().start["bad_start"] ~= nil, "start failure recorded")
        ok(registry.liveHandleCount() == 0, "broken start's partial handle was torn down")
        ok(fake.liveHandles == 0, "no native resource leaked by the broken start")

        local d = registry.describe()
        local badRow, sawLoadFail = nil, false
        for _, e in ipairs(d) do
            if e.id == "bad_start" then badRow = e end
            if e.category == "failed" then sawLoadFail = true end
        end
        ok(badRow ~= nil and badRow.failed == true, "describe marks the failed feature")
        ok(sawLoadFail, "describe surfaces load failures as inert rows")

        -- (d) disabling clears the recorded failure
        registry.setEnabled("bad_start", false)
        ok(registry.failures().start["bad_start"] == nil, "disable clears the start failure")

        end
    end,
}
