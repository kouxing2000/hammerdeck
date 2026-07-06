-- test/cases/display_off.lua -- display_off: a service that warns once after the idle
-- threshold, sleeps the display once after a fixed lead time, and re-arms the whole cycle
-- when the user returns to activity.
--
-- Migrated from run.lua T12 (RUN_LUA_SPLIT_SPEC Phase 2). Hermetic: registers its own
-- feature and drives its own idle/clock; freshWorld() before + handle tripwire after keep
-- it isolated.

return {
    id = "display_off",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        registry.register(require("features.display_off"))
        fake.settings["hammerdeck.opt.display_off.idleThresholdMin"] = 5   -- 300s
        -- (the 10s warning lead time is a constant now, not an option)
        local dimsBefore   = fake.actions.displaySleep
        local alertsBefore = #fake.alerts
        registry.setEnabled("display_off", true)

        -- active: no warning, no display sleep
        fake.idle = 10
        fake.fireTimers("every", 5)
        ok(#fake.alerts == alertsBefore, "active: no idle warning")
        ok(fake.actions.displaySleep == dimsBefore, "active: display not slept")

        -- idle past threshold: warn exactly once
        fake.idle = 6 * 60
        fake.fireTimers("every", 5)
        ok(#fake.alerts == alertsBefore + 1, "idle past threshold: warning shown")
        fake.fireTimers("every", 5)
        ok(#fake.alerts == alertsBefore + 1, "warning shown only once")
        ok(fake.actions.displaySleep == dimsBefore, "no display sleep before the lead time")

        -- lead time elapses: display sleeps exactly once
        fake.clockOffset = fake.clockOffset + 10
        fake.fireTimers("every", 5)
        ok(fake.actions.displaySleep == dimsBefore + 1, "display slept after the lead time")
        fake.fireTimers("every", 5)
        ok(fake.actions.displaySleep == dimsBefore + 1, "display sleep fired only once")

        -- returning to activity re-arms the cycle
        fake.idle = 0
        fake.fireTimers("every", 5)
        fake.idle = 6 * 60
        fake.fireTimers("every", 5)
        ok(#fake.alerts == alertsBefore + 2, "returning to activity re-arms the warning")

        registry.setEnabled("display_off", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after display_off test")
    end,
}
