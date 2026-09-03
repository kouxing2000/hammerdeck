-- test/cases/sleep_schedule_weekend.lua -- the weekend shift must survive midnight.
--
-- Regression for the audit's N-1. The shift was resolved from the weekday of the
-- CURRENT instant, so it evaporated the moment the clock passed midnight and the
-- sleep target jumped backwards under a live countdown: on stock defaults
-- (sleepAt 00:30, weekendShiftMin 60) Saturday 23:50 promised 01:30 and then slept
-- the machine at 00:30 -- an hour early, with whatever was open still open.
--
-- The existing sleep_schedule case pins weekendShiftMin = 0, which is exactly why
-- this survived: with no shift there is nothing to evaporate. So this case holds
-- the non-zero setting, and it asserts the USER-VISIBLE outcome -- did the machine
-- get slept -- rather than any internal notion of "which night is it". A future
-- rewrite of how the night is resolved stays free as long as the answer holds.
local CHECK = 10   -- CHECK_INTERVAL: the poll period the feature ticks on

---Pin the deterministic clock to a wall-clock instant and return it.
---@param fake table
local function pinTo(fake, y, mo, d, h, mi, sec)
    local at = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = sec or 0 })
    fake.clockOffset = at - os.time()
    return at
end

return {
    id = "sleep_schedule_weekend",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        registry.register(require("features.sleep_schedule"))
        fake.settings["hammerdeck.opt.sleep_schedule.sleepAt"] = "00:30"
        fake.settings["hammerdeck.opt.sleep_schedule.weekendShiftMin"] = 60

        -- 2026-08-29 is a Saturday, 08-30 the Sunday it runs into.
        local sat = pinTo(fake, 2026, 8, 29, 23, 50)
        ok(os.date("*t", sat).wday == 7, "fixture really is a Saturday night")
        registry.setEnabled("sleep_schedule", true)
        fake.fireTimers("every", CHECK)
        ok(fake.actions.sleep == 0, "Saturday 23:50: far from the shifted target, nothing fires")

        -- Five seconds before the UNSHIFTED time, on the far side of midnight.
        -- This is the moment the bug fired: the target had silently moved back an
        -- hour, so the machine went to sleep here.
        pinTo(fake, 2026, 8, 30, 0, 29, 55)
        ok(os.date("*t", fake.now()).wday == 1, "and the clock really has crossed into Sunday")
        fake.fireTimers("every", CHECK)
        ok(fake.actions.sleep == 0,
            "00:30 on a weekend night must NOT sleep the machine -- the night's target is 01:30")

        -- Five seconds before the SHIFTED time: this is when it should happen.
        pinTo(fake, 2026, 8, 30, 1, 29, 55)
        fake.fireTimers("every", CHECK)
        ok(fake.actions.sleep >= 1, "01:30, the shifted target, does sleep the machine")

        -- The shift must not be STICKY either: Sunday evening starts a school
        -- night, so the unshifted 00:30 is correct there.
        registry.setEnabled("sleep_schedule", false)
        fake.actions.sleep = 0
        pinTo(fake, 2026, 8, 30, 23, 50)
        registry.setEnabled("sleep_schedule", true)
        fake.fireTimers("every", CHECK)
        ok(fake.actions.sleep == 0, "Sunday 23:50: not yet")
        pinTo(fake, 2026, 8, 31, 0, 29, 55)
        fake.fireTimers("every", CHECK)
        ok(fake.actions.sleep >= 1, "a school night sleeps at the unshifted 00:30")

        registry.setEnabled("sleep_schedule", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after the weekend case")
    end,
}
