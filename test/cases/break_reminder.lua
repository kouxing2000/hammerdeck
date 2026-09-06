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
        local KEY = "hammerdeck.state.break_reminder.workSeconds"

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
        local dlgWrites = fake.settingWrites[KEY] or 0
        fake.fireTimers("after", 3)                    -- retry fires, user now pausable
        local dlg = fake.openDialog()
        ok(dlg ~= nil, "rest dialog shown after busy-retry")
        ok((fake.settingWrites[KEY] or 0) > dlgWrites,
           "N-14: opening the rest dialog checkpoints the counter it is about to display")

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

        -- The daily counter is checkpointed on BOUNDARIES, not on the 5s tick.
        -- Both halves are needed and neither implies the other: a value check
        -- alone passes for a per-tick write (the value it leaves is correct), and
        -- a write-count check alone passes for a feature that never persists at
        -- all. The lock below is the boundary; it is taken FIRST so the expected
        -- total is derived from a known-synced disk value rather than from where
        -- the sections above happened to leave the counter.
        fake.idle = 0
        fake.systemEvent("screenLock")             -- checkpoint: memory == disk
        local synced = tonumber(fake.settings[KEY] or 0)
        local writes = fake.settingWrites[KEY] or 0
        fake.systemEvent("screenUnlock")
        ok(fake.fireTimers("every", 5) == 1 and fake.fireTimers("every", 5) == 1
           and fake.fireTimers("every", 5) == 1, "three active ticks fired")
        ok((fake.settingWrites[KEY] or 0) == writes,
           "N-14: an active 5s tick accrues in memory and does NOT write")
        fake.systemEvent("screenLock")
        ok(tonumber(fake.settings[KEY] or 0) == synced + 15,
           "N-14: the lock boundary checkpoints the exact accrued total")
        fake.systemEvent("screenUnlock")

        -- The DAY ROLLOVER is a boundary too, and the only one where the value
        -- moves BACKWARDS: without a checkpoint there, a restart the next morning
        -- reads yesterday's total off disk and reports it as today's.
        fake.idle = 0
        fake.fireTimers("every", 5)                    -- accrue something to lose
        fake.clockOffset = fake.clockOffset + 24 * 3600
        local rollWrites = fake.settingWrites[KEY] or 0
        fake.fireTimers("every", 5)                    -- first tick of the new day
        ok((fake.settingWrites[KEY] or 0) > rollWrites,
           "N-14: crossing midnight writes")
        ok(tonumber(fake.settings[KEY] or 0) == 0,
           "N-14: ...and what it writes is the RESET, not yesterday's total")

        fake.idle = 6 * 60                             -- long idle pauses
        fake.fireTimers("every", 5)
        ok(fake.fireTimers("after") == 0, "long idle cancelled the rest timer")

        -- Going down is the LAST boundary: registry.stopAll runs on quit, and
        -- disable/reload take the same path, so an ordinary Quit must not drop the
        -- accrual since the last checkpoint out of "Worked today".
        fake.idle = 0
        fake.systemEvent("screenLock")                 -- checkpoint: memory == disk
        local atStop = tonumber(fake.settings[KEY] or 0)
        fake.systemEvent("screenUnlock")
        fake.fireTimers("every", 5)
        fake.fireTimers("every", 5)
        registry.setEnabled("break_reminder", false)
        ok(tonumber(fake.settings[KEY] or 0) == atStop + 10,
           "N-14: stop() checkpoints the accrual a quit would otherwise lose")
        ok(registry.liveHandleCount() == 0, "break_reminder disable left no live handles")
    end,
}
