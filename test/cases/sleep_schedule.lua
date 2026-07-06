-- test/cases/sleep_schedule.lua -- sleep_schedule: a service that walks graduated phases
-- toward a scheduled system sleep -- a warning dialog (snoozeable) at the lead window, a
-- live countdown banner nearer the time (dismissed + re-shown across wake/unlock), and the
-- actual sleep at T-0 -- then re-arms on a fresh enablement.
--
-- Migrated from run.lua T4 (RUN_LUA_SPLIT_SPEC Phase 2). Hermetic: registers its own
-- feature (the monolith leaned on T1's full-catalog registration) and drives its own
-- clock via minutesFromNow; freshWorld() before + handle tripwire after keep it isolated.

return {
    id = "sleep_schedule",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry, minutesFromNow = t.ok, t.fake, t.registry, t.minutesFromNow

        registry.register(require("features.sleep_schedule"))
        fake.settings["hammerdeck.opt.sleep_schedule.weekendShiftMin"] = 0
        fake.settings["hammerdeck.opt.sleep_schedule.hardCapAt"] = minutesFromNow(30)
        fake.settings["hammerdeck.opt.sleep_schedule.sleepAt"] = minutesFromNow(7)

        registry.setEnabled("sleep_schedule", true)
        ok(registry.liveHandleCount() == 3, "sleep_schedule: poll timer + 2 watchers live")

        fake.fireTimers("every", 10)
        local dlg = fake.openDialog()
        ok(dlg ~= nil, "phase 1: warning dialog at T-7min")
        ok(dlg.actions[2] and dlg.actions[2]:find("^Snooze") ~= nil, "warning offers snooze")

        dlg.choose(dlg.actions[2])                     -- snooze (+15min, cap now+30)
        fake.fireTimers("every", 10)
        ok(fake.openDialog() == nil, "after snooze: no immediate re-warning")
        ok(fake.liveBanner() == nil, "after snooze: no countdown banner")

        -- fresh enablement, inside the countdown window
        registry.setEnabled("sleep_schedule", false)
        fake.settings["hammerdeck.opt.sleep_schedule.sleepAt"] = minutesFromNow(4)
        registry.setEnabled("sleep_schedule", true)
        fake.fireTimers("every", 10)
        local banner = fake.liveBanner()
        ok(banner ~= nil, "phase 2: countdown banner at T-4min")
        ok(banner.text:find("System sleep in") ~= nil, "banner shows countdown text")

        fake.systemEvent("wake")                       -- wake resets stale UI
        ok(fake.liveBanner() == nil, "wake/unlock dismisses the banner")

        fake.fireTimers("every", 10)                   -- banner returns next poll
        ok(fake.liveBanner() ~= nil, "banner re-shown after reset while still in window")

        registry.setEnabled("sleep_schedule", false)
        -- Target an exact minute boundary, then place "now" 5s past it so the poll
        -- lands inside the T-0 window deterministically.
        local target = fake.now() + 60
        target = target - (target % 60)
        fake.settings["hammerdeck.opt.sleep_schedule.sleepAt"] = os.date("%H:%M", target)
        fake.clockOffset = fake.clockOffset + (target + 5 - fake.now())
        registry.setEnabled("sleep_schedule", true)
        fake.fireTimers("every", 10)
        ok(fake.actions.sleep == 1, "phase 3: system sleep fired at T-0")
        ok(fake.liveBanner() == nil, "phase 3 cleared the banner")

        registry.setEnabled("sleep_schedule", false)
        ok(registry.liveHandleCount() == 0, "sleep_schedule disable left no live handles")
    end,
}
