-- test/cases/usage_stats_midnight.lua -- a session belongs to the day it STARTED.
--
-- Regression for the audit's N-3. recordSession() read its date from st.appDate
-- AFTER calling rollover(), so a session running 23:00 -> 01:00 was filed under
-- the WAKE-UP day: those minutes landed on a day the user had been asleep for,
-- and the day that actually earned them recorded no session at all. Both
-- activeMinutes and longestSessionMin were wrong, on two days at once, from one
-- misplaced line.
--
-- The existing usage_stats case locks and unlocks inside a single day, so the
-- attribution question never arises there. This case exists to cross midnight.
--
-- Note what is NOT asserted: the row's wake_time/sleep_time still read
-- "23:00:00,01:00:00", and that is correct -- the report's day track already
-- clamps a span whose end precedes its start (UsageReportView.swift:501-507).
-- The defect was never the times; it was which file they were written to.
local BASE = "/fake/data/usage"

---Pin the deterministic clock to a wall-clock instant.
---@param fake table
local function pinTo(fake, y, mo, d, h, mi)
    fake.clockOffset = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = 0 })
        - os.time()
end

---@param day string "YYYY-MM-DD"
local function sessionsPath(day) return BASE .. "/" .. day:sub(1, 7) .. "/" .. day .. ".csv" end

return {
    id = "usage_stats_midnight",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        registry.register(require("features.usage_stats"))
        fake.settings["hammerdeck.opt.usage_stats.dir"] = BASE
        fake.idle = 0
        fake.frontmost = "Code"

        -- Awake at 23:00 on the 29th ...
        pinTo(fake, 2026, 8, 29, 23, 0)
        registry.setEnabled("usage_stats", true)

        -- ... and locked at 01:00 on the 30th: one 120-minute night's work that
        -- happens to straddle the date line.
        pinTo(fake, 2026, 8, 30, 1, 0)
        fake.systemEvent("screenLock")

        local started = fake.files[sessionsPath("2026-08-29")]
        local ended   = fake.files[sessionsPath("2026-08-30")]
        ok(started ~= nil,
            "the session is filed under 2026-08-29, the day it started")
        ok(started and started:match("23:00:00,01:00:00,120") ~= nil,
            "with its real span and duration (got: " .. tostring(started and started:gsub("\n", " / ")) .. ")")
        ok(ended == nil,
            "and NOT under 2026-08-30, which the user slept through")

        registry.setEnabled("usage_stats", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after the midnight case")
    end,
}
