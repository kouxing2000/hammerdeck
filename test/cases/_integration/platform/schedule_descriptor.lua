-- test/cases/_integration/platform/schedule_descriptor.lua -- the schedule() descriptor -> describe().schedule (the Automation
-- Timeline). A service's internal timers self-report; derived times track
-- live option values; editable rows carry the optionKey the Timeline writes
-- through; malformed entries are dropped and a throwing descriptor is
-- quarantined.
--
-- Migrated from run.lua T7b (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "schedule_descriptor",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry, manifest = t.ok, t.fake, t.registry, t.manifest

        registry.loadCatalog({ "features.sleep_schedule", "features.break_reminder", "features.window_switcher" })

        fake.settings["hammerdeck.opt.sleep_schedule.sleepAt"]   = "23:30"
        fake.settings["hammerdeck.opt.sleep_schedule.warn1Min"]  = 10
        fake.settings["hammerdeck.opt.sleep_schedule.warn2Min"]  = 5
        fake.settings["hammerdeck.opt.sleep_schedule.hardCapAt"] = "01:00"
        fake.settings["hammerdeck.opt.break_reminder.workMin"]   = 30
        local descS = registry.describe()
        local sched = {}
        for _, e in ipairs(descS) do sched[e.id] = e.schedule end
        ok(type(sched.sleep_schedule) == "table" and #sched.sleep_schedule == 4,
            "sleep_schedule reports 4 schedule entries")
        ok(sched.sleep_schedule[1].kind == "at" and sched.sleep_schedule[1].at == "23:20",
            "first warning derived as sleepAt - warn1Min (23:30 - 10m)")
        ok(sched.sleep_schedule[2].at == "23:25", "countdown overlay derived as sleepAt - warn2Min")
        ok(sched.sleep_schedule[3].at == "23:30" and sched.sleep_schedule[3].optionKey == "sleepAt",
            "force-sleep marker maps to the sleepAt option for inline edit")
        ok(sched.sleep_schedule[4].at == "01:00" and sched.sleep_schedule[4].optionKey == "hardCapAt",
            "hard-cap marker maps to the hardCapAt option")
        ok(sched.sleep_schedule[1].optionKey == nil, "derived warnings are advisory (no optionKey)")
        ok(sched.sleep_schedule[1].category == "health", "entries inherit the feature category")
        ok(type(sched.break_reminder) == "table" and sched.break_reminder[1].kind == "everyMin"
            and sched.break_reminder[1].everyMin == 30 and sched.break_reminder[1].optionKey == "workMin",
            "break_reminder reports its recurring break from the live workMin option")
        ok(sched.window_switcher == nil, "a feature with no schedule descriptor reports none")

        -- malformed entries are skipped, not fatal; a throwing descriptor is quarantined
        package.loaded["features._sched_probe"] = {
            api = 1, id = "sched_probe", name = "Sched Probe", category = "general",
            start = function() end,
            schedule = function()
                return {
                    { label = "good", everyMin = 15 },
                    { label = "bad-zero", everyMin = 0 },        -- skipped (non-positive)
                    { everyMin = 5 },                            -- skipped (no label)
                    { label = "bad-time", at = "9999" },         -- skipped (not HH:MM)
                    { label = "out-of-range", at = "25:99" },    -- skipped (shape ok, range bad)
                    { label = "note only", note = "after wake" },
                }
            end,
        }
        registry.load("features._sched_probe")
        package.loaded["features._sched_throw"] = {
            api = 1, id = "sched_throw", name = "Sched Throw",
            start = function() end,
            schedule = function() error("boom") end,
        }
        registry.load("features._sched_throw")
        local probeSched, throwRow
        for _, e in ipairs(registry.describe()) do
            if e.id == "sched_probe" then probeSched = e.schedule end
            if e.id == "sched_throw" then throwRow = e end
        end
        ok(type(probeSched) == "table" and #probeSched == 2,
            "malformed schedule entries are dropped, valid ones kept")
        ok(probeSched[2].kind == "note" and probeSched[2].note == "after wake",
            "a note entry routes to the conditions lane")
        ok(throwRow ~= nil and throwRow.schedule == nil,
            "a throwing schedule() is quarantined -- describe() still returns the row")
        registry.unregister("sched_probe")
        registry.unregister("sched_throw")
        -- the schedule field must be a function
        ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
            schedule = { { label = "nope" } } }),
            "schedule must be a function, not a table")
    end,
}
