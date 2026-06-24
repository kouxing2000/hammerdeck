-- features/usage_stats/report.lua
--
-- Host-callable historical reporter over the usage_stats CSV history. The
-- Homepage "Usage" tab calls range(fromISO, toISO) via lua.call and renders the
-- returned plain data with Apple Charts. Reads straight from disk through the
-- seam (adapter.fileRead), so it WORKS EVEN WHEN the usage_stats feature is
-- disabled -- the CSVs persist on disk and history outlives any single run.
--
-- This is a read-only REPORTER, not feature logic: it has no ctx, creates no
-- teardown-tracked handles, and is invoked by the host rather than a trigger.
-- It deliberately requires the seam directly (file IO + the stored `dir`
-- option) -- the one usage module that does, because it runs outside ctx.
-- All CSV-format knowledge (parse / paths / aggregation) stays in store.lua.

local adapter = require("platform.adapter")
local store   = require("features.usage_stats.store")

local M = {}

-- Storage root from the persisted `dir` option (same key the Settings UI and
-- ctx.opt write/read), so the report reads exactly where the tracker writes.
local function resolveBase()
    local dirOpt = adapter.getSetting("hammerdeck.opt.usage_stats.dir", "~/.computer-usage")
    return store.resolveDir(dirOpt, adapter.homeDir())
end

-- ISO yyyy-mm-dd -> epoch at local noon (noon avoids DST edges when stepping by
-- 86400s). Returns nil on a malformed date.
local function isoToTime(iso)
    local y, m, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return nil end
    return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
end

-- Iterate dates from..to inclusive, calling fn(dateStr, weekdayIndex1to7).
local function eachDay(fromISO, toISO, fn)
    local t, last = isoToTime(fromISO), isoToTime(toISO)
    if not (t and last) then return end
    while t <= last do
        fn(os.date("%Y-%m-%d", t), tonumber(os.date("%w", t)) + 1)
        t = t + 86400
    end
end

-- "HH:MM:SS" -> minutes since midnight (nil if unparseable).
local function hmsToMin(s)
    local h, m = s:match("^(%d+):(%d+)")
    if not h then return nil end
    return tonumber(h) * 60 + tonumber(m)
end

-- Aggregate the usage history over [fromISO, toISO] (inclusive) into a plain
-- table the host renders. Shapes (numbers cross the bridge as doubles):
--   total, activeDays, dayCount, dailyAvg, prevTotal, prevHasData
--   days     = { {date, label, secs, today}, ... }              -- per-day trend
--   apps     = { {app, secs, share, contexts={ {name,secs,share} }}, ... } (ranked, full)
--   sessions = { {date, wake, sleep, min, wakeMin, sleepMin}, ... } -- machine-active spans
--   busiestApp, busiestDay = {date, secs}
--   firstWakeMin, lastSleepMin, sessionCount, longestSessionMin, activeMinutes
function M.range(fromISO, toISO)
    local base = resolveBase()
    local read = adapter.fileRead
    local today = os.date("%Y-%m-%d")

    local acc, days = {}, {}
    local total, activeDays = 0, 0
    local busiestDay = nil

    local sessions = {}
    local firstWakeMin, lastSleepMin = nil, nil
    local sessCount, longestMin, activeMin = 0, 0, 0

    eachDay(fromISO, toISO, function(d, wday)
        local dayTotal = store.accumulateDay(read, base, d, acc)
        total = total + dayTotal
        if dayTotal > 0 then activeDays = activeDays + 1 end
        days[#days + 1] = {
            date  = d,
            label = store.DAY_LABELS[wday],
            secs  = math.floor(dayTotal),
            today = (d == today),
        }
        if dayTotal > 0 and (not busiestDay or dayTotal > busiestDay.secs) then
            busiestDay = { date = d, secs = math.floor(dayTotal) }
        end

        -- Sessions (machine-active wake->sleep spans) for the day.
        local body = read(store.sessionsPath(base, d))
        if body then
            local first = true
            for line in body:gmatch("[^\n]+") do
                if first then
                    first = false
                else
                    local wake, sleep, dur = line:match("^([^,]+),([^,]+),(%d+)")
                    if wake then
                        local wmin, smin, mn = hmsToMin(wake), hmsToMin(sleep), tonumber(dur)
                        sessions[#sessions + 1] = {
                            date = d, wake = wake, sleep = sleep, min = mn,
                            wakeMin = wmin, sleepMin = smin,
                        }
                        sessCount = sessCount + 1
                        activeMin = activeMin + mn
                        if mn > longestMin then longestMin = mn end
                        if wmin and (not firstWakeMin or wmin < firstWakeMin) then firstWakeMin = wmin end
                        if smin and (not lastSleepMin or smin > lastSleepMin) then lastSleepMin = smin end
                    end
                end
            end
        end
    end)

    -- Rank apps across the whole range (uncapped -- the report table wants the
    -- full list), then attach shares: each app vs the range total, each context
    -- vs its own app's time (so drill-in percentages read within the app).
    local apps = store.aggregate(acc, nil, nil)
    for _, a in ipairs(apps) do
        a.share = total > 0 and (a.secs / total) or 0
        for _, c in ipairs(a.contexts) do
            c.share = a.secs > 0 and (c.secs / a.secs) or 0
        end
    end

    -- Previous equal-length period (totals only) -> the vs-previous delta.
    local fromT, toT = isoToTime(fromISO), isoToTime(toISO)
    local prevTotal, prevHasData = 0, false
    if fromT and toT then
        local spanDays = math.floor((toT - fromT) / 86400 + 0.5) + 1
        for k = 1, spanDays do
            local dt = store.readDayTotal(read, base, os.date("%Y-%m-%d", fromT - k * 86400))
            prevTotal = prevTotal + dt
            if dt > 0 then prevHasData = true end
        end
    end

    return {
        from              = fromISO,
        to                = toISO,
        total             = math.floor(total),
        dayCount          = #days,
        activeDays        = activeDays,
        dailyAvg          = activeDays > 0 and math.floor(total / activeDays) or 0,
        prevTotal         = math.floor(prevTotal),
        prevHasData       = prevHasData,
        days              = days,
        apps              = apps,
        sessions          = sessions,
        busiestApp        = apps[1] and apps[1].app or nil,
        busiestDay        = busiestDay,
        firstWakeMin      = firstWakeMin,
        lastSleepMin      = lastSleepMin,
        sessionCount      = sessCount,
        longestSessionMin = longestMin,
        activeMinutes     = activeMin,
    }
end

return M
