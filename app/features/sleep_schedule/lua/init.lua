-- features/sleep_schedule
--
-- Respectful quitting-time enforcement (ported from the author's prior
-- Hammerspoon config). Forces system sleep at a daily time with
-- graduated warnings:
--   Phase 1 (T-warn1): dismissable dialog with one-time snooze
--   Phase 2 (T-warn2): undismissable countdown banner
--   Phase 3 (T-0):     system sleep
-- One-time snooze is clamped to a hard cap. Weekend nights shift the whole
-- schedule later. Wake/unlock resets stale UI and recomputes fresh.
--
-- SERVICE feature: start(ctx) runs the state machine; all timers/watchers/UI
-- go through ctx, so disable tears everything down (no stop() needed).

local CHECK_INTERVAL = 10   -- seconds between schedule checks

local function timeToSecs(hhmm)
    local h, m = tostring(hhmm):match("^(%d+):(%d+)$")
    assert(h, "sleep_schedule: bad time string '" .. tostring(hhmm) .. "' (want HH:MM)")
    return (tonumber(h) * 3600 + tonumber(m) * 60) % 86400
end

local function formatTime(totalSecs)
    return string.format("%02d:%02d",
        math.floor(totalSecs / 3600) % 24, math.floor((totalSecs % 3600) / 60))
end

local function formatCountdown(secs)
    return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

-- A night SPANS midnight, so the weekday that decides the shift has to be the
-- night's own day rather than whatever the clock reads at this instant. Anchor
-- 12h back and every moment from noon today through 11:59 tomorrow names the
-- same night; the anchor only moves at noon, when no countdown is ever armed.
local NIGHT_ANCHOR_SECS = 12 * 3600

---Is the night that `t` falls within a Friday or Saturday night?
---@param t integer a time from ctx.now()
local function isWeekendNight(t)
    local wday = os.date("*t", t - NIGHT_ANCHOR_SECS).wday  -- 1=Sun .. 7=Sat
    return wday == 6 or wday == 7                           -- Friday or Saturday night
end

return {
    api         = 1,
    id          = "sleep_schedule",

    options = {
        { key = "sleepAt",         type = "time", default = "00:30", label = "Sleep at (HH:MM)" },
        { key = "warn1Min",        type = "int",  default = 10, label = "First warning (min before)", min = 2, max = 60 },
        { key = "warn2Min",        type = "int",  default = 5,  label = "Countdown overlay (min before)", min = 1, max = 30 },
        { key = "snoozeMin",       type = "int",  default = 15, label = "Snooze length (min)", min = 5, max = 60 },
        { key = "hardCapAt",       type = "time", default = "01:00", label = "Snooze hard cap (HH:MM)" },
        { key = "weekendShiftMin", type = "int",  default = 60, label = "Weekend shift (min)", min = 0, max = 180 },
    },

    -- Self-report the nightly schedule for the Automation Timeline. The two
    -- warning markers are DERIVED from sleepAt minus the warn offsets, so they
    -- are advisory (no optionKey -- edit the offset in Settings); the sleep and
    -- hard-cap markers map straight to their time options for inline editing.
    -- Weekday base times (the weekend shift is intentionally not folded in --
    -- the ruler is wall-clock and the shift only applies Fri/Sat nights).
    schedule = function(ctx)
        local sleepSecs = timeToSecs(ctx.opt("sleepAt"))
        local function before(min) return formatTime((sleepSecs - min * 60) % 86400) end
        return {
            { label = "First warning",     at = before(ctx.opt("warn1Min")) },
            { label = "Countdown overlay",  at = before(ctx.opt("warn2Min")) },
            { label = "Force system sleep", at = ctx.opt("sleepAt"),  optionKey = "sleepAt" },
            { label = "Snooze hard cap",    at = ctx.opt("hardCapAt"), optionKey = "hardCapAt" },
        }
    end,

    ---@param ctx Ctx
    start = function(ctx)
        -- Per-enablement state (fresh on every enable).
        local s = {
            warningShown = false,
            snoozed = false,
            effectiveSleepSecs = nil,   -- overridden when snoozed
            lastSecsLeft = nil,         -- detects day rollover
            banner = nil,
            warnDialog = nil,
        }

        -- Reading the weekday from the bare clock made the shift EVAPORATE at
        -- midnight: with the defaults (sleepAt 00:30, shift 60) Saturday 23:50
        -- promised sleep at 01:30, and at 00:10 the target silently became
        -- 00:30 -- the machine slept an hour before the dialog said it would,
        -- with unsaved work still open. The day-rollover guard cannot catch it
        -- either: it watches for a small backward step, and this is a 5400 ->
        -- 1800 jump. isWeekendNight now anchors to the night's own day.
        local function weekendShift()
            return isWeekendNight(ctx.now()) and ctx.opt("weekendShiftMin") * 60 or 0
        end

        local function baseSleepSecs()
            return (timeToSecs(ctx.opt("sleepAt")) + weekendShift()) % 86400
        end

        local function hardCapSecs()
            return (timeToSecs(ctx.opt("hardCapAt")) + weekendShift()) % 86400
        end

        local function effectiveSleepSecs()
            if s.snoozed and s.effectiveSleepSecs then return s.effectiveSleepSecs end
            return baseSleepSecs()
        end

        local function secondsUntilSleep()
            local now = os.date("*t", ctx.now())
            local diff = effectiveSleepSecs() - (now.hour * 3600 + now.min * 60 + now.sec)
            if diff < 0 then diff = diff + 86400 end
            return diff
        end

        local function dismissBanner()
            if s.banner then s.banner.stop(); s.banner = nil end
        end

        local function dismissWarnDialog()
            if s.warnDialog then s.warnDialog.stop(); s.warnDialog = nil end
        end

        local function resetState()
            s.warningShown = false
            s.snoozed = false
            s.effectiveSleepSecs = nil
            dismissBanner()
            dismissWarnDialog()
        end

        local function showCountdown(secsLeft)
            local text = ctx.t("banner.countdown", "System sleep in %s  --  Save your work!", formatCountdown(secsLeft))
            if s.banner then s.banner.setText(text) else s.banner = ctx.banner(text) end
        end

        -- Snooze target clamped to the hard cap. The cap is interpreted as the
        -- next occurrence AT/AFTER the base sleep time, so e.g. sleep 22:00
        -- with cap 01:00 wraps past midnight (instead of comparing raw
        -- seconds-of-day and "capping" three hours later).
        local function snoozeTargetSecs()
            local base = baseSleepSecs()
            local target = base + ctx.opt("snoozeMin") * 60
            local cap = hardCapSecs()
            if cap < base then cap = cap + 86400 end
            if target > cap then target = cap end
            return target % 86400
        end

        local function doSnooze()
            s.effectiveSleepSecs = snoozeTargetSecs()
            s.snoozed = true
            s.warningShown = false
            dismissBanner()
            ctx.log("snoozed, new sleep time " .. formatTime(s.effectiveSleepSecs))
        end

        local function showWarning(secsLeft)
            local infos = {
                ctx.t("info.sleepAt", "Sleep at %1$s (%2$d min left)", formatTime(effectiveSleepSecs()), math.floor(secsLeft / 60)),
            }
            if isWeekendNight(ctx.now()) then
                infos[#infos + 1] = ctx.t("info.weekendShift", "Weekend schedule (+%dmin)", ctx.opt("weekendShiftMin"))
            end

            -- The snooze row is conditional, so its INDEX moves; dispatch is on
            -- its stable id instead (CODE-12). This label is the strongest case
            -- for that rule in the catalog: it interpolates both the snooze
            -- minutes and a wall-clock time, so it is a different string on
            -- almost every call -- comparing the chosen text against a local
            -- worked only because the same call built both sides.
            local actions = { { id = "wrapUp",
                                label = ctx.t("action.wrapUp", "OK, I'll wrap up"),
                                icon = "symbol:checkmark.circle" } }
            if not s.snoozed then
                actions[#actions + 1] = {
                    id = "snooze",
                    label = ctx.t("action.snooze", "Snooze %1$d minutes (until %2$s)",
                        ctx.opt("snoozeMin"), formatTime(snoozeTargetSecs())),
                    icon = "symbol:zzz",
                }
            end

            dismissWarnDialog()
            s.warnDialog = ctx.askChoice {
                title = ctx.t("dialog.warnTitle", "Sleep schedule warning"),
                infos = infos,
                actions = actions,
                onChoose = function(choice)
                    s.warnDialog = nil
                    if choice == "snooze" then doSnooze() end
                end,
            }
        end

        local function check()
            local secsLeft = secondsUntilSleep()

            -- Day rollover: secsLeft jumped from nearly-zero to nearly-a-day.
            if s.lastSecsLeft and s.lastSecsLeft < 300 and secsLeft > 82800 then
                resetState()
                ctx.log("daily reset")
            end
            s.lastSecsLeft = secsLeft

            local w1 = ctx.opt("warn1Min") * 60
            -- The two warnings are range-checked independently, so warn2 > warn1
            -- is a legal setting -- and phase 1 needs `secsLeft <= w1 and
            -- secsLeft > w2`, which that inversion collapses to an empty window.
            -- The dismissable dialog then never opens and the one-time SNOOZE
            -- becomes unreachable, silently. Clamp rather than validate: the
            -- pair is edited one field at a time, so a transient inversion while
            -- the user is still typing must not break the schedule.
            local w2 = math.min(ctx.opt("warn2Min") * 60, w1 - 60)

            -- Phase 1: dismissable warning with snooze.
            if secsLeft <= w1 and secsLeft > w2 and not s.warningShown then
                ctx.log("pre-sleep warning (" .. math.floor(secsLeft / 60) .. " min left)")
                s.warningShown = true
                showWarning(secsLeft)
            end

            -- Phase 2: countdown banner.
            if secsLeft <= w2 and secsLeft > CHECK_INTERVAL then
                showCountdown(secsLeft)
            end

            -- Phase 3: sleep. (Re-fires on later ticks if the system refused
            -- to sleep -- intentional insistence.)
            if secsLeft <= CHECK_INTERVAL or secsLeft >= (86400 - CHECK_INTERVAL) then
                ctx.log("forcing system sleep now")
                resetState()
                ctx.systemSleep()
            end
        end

        ctx.everySeconds(CHECK_INTERVAL, check)

        -- The polling timer doesn't fire while asleep, and the day-rollover
        -- heuristic misses sleeps that begin mid-warning. Reset on wake/unlock
        -- so stale UI is cleared and check() recomputes fresh.
        local function onWake()
            resetState()
            s.lastSecsLeft = nil
            ctx.log("wake/unlock, state reset")
        end
        ctx.onSystemEvent("wake", onWake)
        ctx.onSystemEvent("screenUnlock", onWake)

        ctx.log("started (sleep at " .. formatTime(baseSleepSecs())
            .. (isWeekendNight(ctx.now()) and ", weekend shift" or "") .. ")")
    end,
}
