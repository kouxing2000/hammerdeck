-- test/cases/break_reminder.lua -- break_reminder: a service that announces a work/rest
-- cycle, defers the rest dialog while the user is busy (idle-based retry), postpones on
-- request, pauses across lock and resumes fresh on unlock, accrues persisted work stats
-- on active ticks, and pauses on long idle.
--
-- Migrated from run.lua T5 (RUN_LUA_SPLIT_SPEC Phase 2). Hermetic: registers its own
-- feature (the monolith leaned on T1's full-catalog registration); freshWorld() before +
-- handle tripwire after keep it isolated. Renamed the timers-scan loop variable `t` to
-- `tm` so it no longer shadows the harness handle.

return {
    id = "break_reminder",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        local notificationsBefore = #fake.notifications
        registry.register(require("features.break_reminder"))
        registry.setEnabled("break_reminder", true)
        ok(#fake.notifications == notificationsBefore + 1, "break_reminder announces the cycle")
        ok(fake.fireTimers("every", 5) == 1, "idle-check timer is live")

        fake.clockOffset = fake.clockOffset + 25 * 60  -- the work interval passes
        fake.idle = 0
        fake.fireTimers("after", 25 * 60)              -- rest timer fires; user busy
        ok(fake.openDialog() == nil, "busy user: dialog deferred")
        fake.idle = 3
        fake.fireTimers("after", 3)                    -- retry fires, user now pausable
        local dlg = fake.openDialog()
        ok(dlg ~= nil, "rest dialog shown after busy-retry")

        dlg.choose("postpone 1 minute")
        local foundPostpone = false
        for _, tm in ipairs(fake.timers) do
            if not tm.stopped and tm.kind == "after" and tm.n == 60 then foundPostpone = true end
        end
        ok(foundPostpone, "postpone schedules a 60s timer")

        fake.systemEvent("screenLock")                 -- lock pauses the cycle
        ok(fake.fireTimers("after", 60) == 0, "lock cancelled the pending rest timer")

        fake.clockOffset = fake.clockOffset + 3
        local nBefore = #fake.notifications
        fake.systemEvent("screenUnlock")               -- unlock starts a fresh cycle
        ok(#fake.notifications == nBefore + 1, "unlock starts a fresh announced cycle")

        fake.idle = 0
        local stateBefore = tonumber(fake.settings["hammerdeck.state.break_reminder.workSeconds"] or 0)
        fake.fireTimers("every", 5)
        local stateAfter = tonumber(fake.settings["hammerdeck.state.break_reminder.workSeconds"] or 0)
        ok(stateAfter == stateBefore + 5, "active tick accrues persisted work stats")

        fake.idle = 6 * 60                             -- long idle pauses
        fake.fireTimers("every", 5)
        ok(fake.fireTimers("after") == 0, "long idle cancelled the rest timer")

        registry.setEnabled("break_reminder", false)
        ok(registry.liveHandleCount() == 0, "break_reminder disable left no live handles")
    end,
}
