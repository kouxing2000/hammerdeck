-- features/usage_stats
--
-- Tracks computer usage to daily CSV files (ported from myHammerSpoon
-- modules/timers/usageTracker.lua + usageWidget.lua -- the widget renders
-- natively from snapshot() data; no HTML/webview):
--   <dataDir>/usage/YYYY-MM/YYYY-MM-DD.csv        sessions (wake,sleep,minutes)
--   <dataDir>/usage/YYYY-MM/YYYY-MM-DD-apps.csv   per-app focus time (seconds)
--
-- Sessions span unlock/wake -> lock/sleep. App focus time accrues to the
-- frontmost app, with idle time subtracted at each flush. The CSV keeps the
-- donor's `context` column (browser domain / editor project) but writes it
-- empty for now -- filling it needs the Accessibility window slice (#6) and a
-- curated browser-URL call; the format stays forward-compatible.
--
-- Deliberate departures from the donor: no git auto-commit of the data dir
-- (plain CSVs; commit yourself if you want history), and storage lives under
-- Application Support instead of ~/.hammerspoon/.usage.
--
-- SERVICE feature: all bindings go through ctx, so disable tears them down.
-- stop() records the open session so disable/quit doesn't lose the day.

local FLUSH_SECONDS       = 10 * 60   -- write app time to disk this often
local REFRESH_SECONDS     = 60        -- widget refresh cadence
local MIN_SESSION_SECONDS = 30        -- ignore rapid wake/sleep blips
local MIN_ENTRY_SECONDS   = 30        -- drop sub-30s apps from the CSV
local TOP_APPS            = 5         -- widget shows this many rows
local DAY_LABELS = { "S", "M", "T", "W", "T", "F", "S" }
local IGNORE_APPS = { loginwindow = true }

-- start() publishes its closures here so the manifest-level stop() can reach
-- them (same shared-upvalue pattern as count_down's cross-action state).
local shared = {}

local function start(ctx)
    local st = {
        wakeAt   = nil,   -- session start (nil = no open session)
        curApp   = nil,   -- frontmost app accruing time
        curSince = nil,   -- when it started accruing
        appTime  = {},    -- app name -> seconds today
        appDate  = nil,   -- the day appTime belongs to
        dayCache = {},    -- date -> total secs (past days never change)
        widget   = nil,   -- live desktop widget handle (when shown)
    }
    shared.st = st

    local function dateStr(t) return os.date("%Y-%m-%d", t) end
    local function monthDir(d) return ctx.dataDir() .. "/usage/" .. d:sub(1, 7) end
    local function appsPath(d) return monthDir(d) .. "/" .. d .. "-apps.csv" end
    local function sessionsPath(d) return monthDir(d) .. "/" .. d .. ".csv" end

    -- Move elapsed time onto the current app, minus the trailing idle stretch.
    local function flushCurrent()
        if not (st.curApp and st.curSince) then return end
        local now = ctx.now()
        local elapsed = now - st.curSince
        st.curSince = now
        if elapsed <= 0 then return end
        local idle = ctx.idleSeconds()
        if idle >= elapsed then return end        -- idle the whole interval
        st.appTime[st.curApp] = (st.appTime[st.curApp] or 0) + (elapsed - idle)
    end

    local function writeApps(d)
        if not next(st.appTime) then return end
        ctx.mkdir(monthDir(d))
        local rows = {}
        for app, secs in pairs(st.appTime) do rows[#rows + 1] = { app = app, secs = secs } end
        table.sort(rows, function(a, b) return a.secs > b.secs end)
        local out = { "app,context,seconds" }
        for _, r in ipairs(rows) do
            if r.secs >= MIN_ENTRY_SECONDS then
                out[#out + 1] = r.app .. ",," .. math.floor(r.secs)
            end
        end
        ctx.fileWrite(appsPath(d), table.concat(out, "\n") .. "\n")
    end

    -- At midnight, save the old day's pending time before resetting.
    local function rollover()
        local today = dateStr(ctx.now())
        if st.appDate and st.appDate ~= today then
            flushCurrent()
            writeApps(st.appDate)
            st.appTime = {}
        end
        st.appDate = today
    end

    -- Restore today's accumulated time after a restart / re-enable.
    local function loadFromDisk()
        local body = ctx.fileRead(appsPath(st.appDate))
        if not body then return end
        local first = true
        for line in body:gmatch("[^\n]+") do
            if first then
                first = false
            else
                local app, value = line:match("^(.-),.-,(%d+)$")
                if app and value then st.appTime[app] = tonumber(value) end
            end
        end
    end

    local function todayTotal()
        local t = 0
        for _, secs in pairs(st.appTime) do t = t + secs end
        return t
    end

    local function readDayTotal(d)
        if st.dayCache[d] then return st.dayCache[d] end
        local total = 0
        local body = ctx.fileRead(appsPath(d))
        if body then
            for line in body:gmatch("[^\n]+") do
                local v = line:match(",(%d+)$")
                if v then total = total + tonumber(v) end
            end
        end
        st.dayCache[d] = total
        return total
    end

    -- Today's stats as plain data: per-app rows (descending), 7-day series,
    -- and the average over past days that have data. The widget renders this.
    local function snapshot(topN)
        local now = ctx.now()
        local rows = {}
        for app, secs in pairs(st.appTime) do
            rows[#rows + 1] = { app = app, secs = math.floor(secs) }
        end
        table.sort(rows, function(a, b) return a.secs > b.secs end)
        while topN and #rows > topN do rows[#rows] = nil end

        local week, weekTotal, pastTotal, pastDays = {}, 0, 0, 0
        for i = 6, 0, -1 do
            local t = now - i * 86400
            local secs = (i == 0) and todayTotal() or readDayTotal(dateStr(t))
            weekTotal = weekTotal + secs
            if i > 0 and secs > 0 then
                pastDays = pastDays + 1
                pastTotal = pastTotal + secs
            end
            week[#week + 1] = {
                label = DAY_LABELS[tonumber(os.date("%w", t)) + 1],
                secs = math.floor(secs),
                today = (i == 0),
            }
        end
        local data = {
            total = math.floor(todayTotal()),
            updated = os.date("%H:%M", now),
            apps = rows, week = week, weekTotal = math.floor(weekTotal),
        }
        if pastDays > 0 then data.avg = math.floor(pastTotal / pastDays) end
        return data
    end
    shared.snapshot = snapshot

    local function flushAll()
        rollover()
        flushCurrent()
        writeApps(st.appDate)
    end
    shared.flushAll = flushAll

    -- Sync the desktop widget to the showWidget option (read live, so the
    -- Settings toggle takes effect within a refresh tick) and feed it data.
    local function refreshWidget()
        local want = ctx.opt("showWidget") == true
        if want and not st.widget then st.widget = ctx.usageWidget() end
        if not want then
            if st.widget then st.widget.stop(); st.widget = nil end
            return
        end
        rollover()
        flushCurrent()
        st.widget.setData(snapshot(TOP_APPS))
    end

    local function onWake()
        if st.wakeAt then return end
        local now = ctx.now()
        st.wakeAt = now
        st.curSince = now
        rollover()
        local app = ctx.frontmostApp()
        if app and not IGNORE_APPS[app] then st.curApp = app end
        ctx.log("wake at " .. os.date("%H:%M:%S", now))
    end

    local function recordSession()
        if not st.wakeAt then return end
        flushCurrent()
        st.curSince = nil               -- sleep must not accrue to the last app
        local now = ctx.now()
        local dur = now - st.wakeAt
        st.wakeAt = nil
        if dur < MIN_SESSION_SECONDS then
            ctx.log("skipping short session (" .. dur .. "s)")
            return
        end
        rollover()
        local d = st.appDate
        ctx.mkdir(monthDir(d))
        if not ctx.fileExists(sessionsPath(d)) then
            ctx.fileAppend(sessionsPath(d), "wake_time,sleep_time,duration_min")
        end
        ctx.fileAppend(sessionsPath(d),
            os.date("%H:%M:%S", now - dur) .. "," .. os.date("%H:%M:%S", now)
            .. "," .. math.floor(dur / 60 + 0.5))
        writeApps(d)
        ctx.log("session recorded (" .. math.floor(dur / 60 + 0.5) .. " min)")
    end
    shared.recordSession = recordSession

    -- Wire up.
    st.appDate = dateStr(ctx.now())
    loadFromDisk()
    onWake()
    ctx.onAppActivated(function(app)
        if not app or IGNORE_APPS[app] then return end
        rollover()
        flushCurrent()
        st.curApp = app
        st.curSince = ctx.now()
    end)
    ctx.onSystemEvent("wake", onWake)
    ctx.onSystemEvent("screenUnlock", onWake)
    ctx.onSystemEvent("sleep", recordSession)
    ctx.onSystemEvent("screenLock", recordSession)
    ctx.everySeconds(FLUSH_SECONDS, flushAll)
    ctx.everySeconds(REFRESH_SECONDS, refreshWidget)
    refreshWidget()
    ctx.log("started")
end

return {
    api         = 1,
    id          = "usage_stats",
    name        = "Usage Stats",
    description = "Tracks wake/sleep sessions and per-app focus time to daily "
        .. "CSV files (idle time excluded), with an optional desktop widget.",
    version     = "1.0.0",
    category    = "productivity",

    options = {
        { key = "showWidget", type = "bool", default = true,
          label = "Show desktop widget" },
    },

    start = start,

    stop = function(ctx)
        -- Record the open session, then flush regardless -- pending app time
        -- must hit disk even when no session is open (e.g. disabled while the
        -- screen is locked), or disabling loses the day's tail.
        if shared.recordSession then shared.recordSession() end
        if shared.flushAll then shared.flushAll() end
        shared.recordSession, shared.flushAll, shared.snapshot, shared.st =
            nil, nil, nil, nil
    end,
}
