-- features/usage_stats
--
-- Tracks computer usage to daily CSV files (ported from the author's prior
-- Hammerspoon config -- the widget renders natively from snapshot() data; no
-- HTML/webview):
--   <dir>/YYYY-MM/YYYY-MM-DD.csv        sessions (wake,sleep,minutes)
--   <dir>/YYYY-MM/YYYY-MM-DD-apps.csv   per-app focus time (seconds)
--
-- <dir> is the `dir` option (default ~/.computer-usage): a user-owned,
-- app-name-neutral home, NOT under Application Support -- this is a personal
-- dataset you keep across renames and may git-commit, so it shouldn't be
-- namespaced under the app or buried in the Library. Resolved once at start();
-- changing it in Settings takes effect on the next enable/restart (existing
-- data is not auto-moved).
--
-- Sessions span unlock/wake -> lock/sleep. App focus time accrues to the
-- frontmost app, with idle time subtracted at each flush. The `context` column
-- records what the app was looking at: for code editors, the project name
-- parsed from the focused window title (always on -- low sensitivity, your own
-- repo names); for browsers, the active tab's DOMAIN ONLY (e.g. github.com, never
-- the full URL/path), each browser behind its OWN opt-in toggle (both OFF by
-- default -- browsing domains are sensitive). Chrome (`trackChromeSite`) excludes
-- incognito at the seam (browserActiveURL returns nil for a private window), so it
-- can promise "never incognito". Safari (`trackSafariSite`) CANNOT -- AppleScript
-- exposes no private-window flag -- so its toggle is separately RISK-FLAGGED:
-- enabling it may record Private Browsing domains. A 30s poll splits the accrual
-- when the context changes mid-app (tab switch, project switch).
--
-- Deliberate departures from the donor: no git auto-commit of the data dir
-- (plain CSVs; commit yourself if you want history), and the storage root is a
-- configurable, app-name-neutral folder (default ~/.computer-usage) instead of
-- the donor's hard-coded ~/.hammerspoon/.usage.
--
-- SERVICE feature: all bindings go through ctx, so disable tears them down.
-- stop() records the open session so disable/quit doesn't lose the day.

local FLUSH_SECONDS       = 10 * 60   -- write app time to disk this often
local REFRESH_SECONDS     = 60        -- widget refresh cadence
local CONTEXT_SECONDS     = 30        -- poll for tab/project switches (donor)
local MIN_SESSION_SECONDS = 30        -- ignore rapid wake/sleep blips
local MIN_ENTRY_SECONDS   = 30        -- drop sub-30s apps from the CSV
local TOP_APPS            = 5         -- widget shows this many rows
local TOP_CONTEXTS        = 3         -- context sub-rows per app (donor)
local IDLE_POLL_SKIP      = 5 * 60    -- skip context polling while idle
local IGNORE_APPS  = { loginwindow = true }
-- Browsers we can track sites for, each behind its OWN opt-in toggle. The split
-- exists because incognito-safety differs by browser: Chrome's window `mode`
-- marks incognito, so the seam returns nil for private windows -- Chrome tracking
-- can honestly promise "never incognito". Safari exposes NO private-window flag
-- via AppleScript (verified online: no scripting property; only a fragile,
-- locale-dependent Window-menu-scrape hack exists), so a Safari private window
-- CANNOT be excluded -- its toggle is therefore separate and RISK-FLAGGED:
-- enabling it MAY record Private Browsing domains. Both default off. (tab_switcher
-- still lists Safari tabs; this map governs only what usage_stats writes to disk.)
local BROWSER_OPT = {
    ["Google Chrome"] = "trackChromeSite",
    ["Safari"]        = "trackSafariSite",
}
local EDITOR_APPS  = { ["Code"] = true, ["Cursor"] = true }

local getDomain = require("platform.urls").getDomain
-- The on-disk CSV format (parse, dir resolution, path builders, aggregation) is
-- shared with the historical report reader (report.lua) so the two never drift.
local store = require("features.usage_stats.store")

-- start() publishes its closures here so the manifest-level stop() can reach
-- them (same shared-upvalue pattern as count_down's cross-action state).
local shared = {}

local function start(ctx)
    local st = {
        wakeAt   = nil,   -- session start (nil = no open session)
        curApp   = nil,   -- frontmost app accruing time
        curCtx   = "",    -- its current context (domain / project / "")
        curSince = nil,   -- when it started accruing
        appTime  = {},    -- "app\tcontext" -> seconds today (donor keying)
        appDate  = nil,   -- the day appTime belongs to
        dayCache = {},    -- date -> total secs (past days never change)
        widget   = nil,   -- live desktop widget handle (when shown)
    }
    shared.st = st

    -- What is the app looking at right now? Browsers: the active tab's
    -- domain. Editors: the project name from the window title (donor format
    -- "file — Project", with any " [SSH: ...]"-style suffix stripped).
    local function contextFor(app)
        local siteOpt = BROWSER_OPT[app]
        if siteOpt then
            -- Site (domain) tracking is OPT-IN per browser: off by default, so the
            -- user must agree before any domain is recorded. Read live each poll, so
            -- toggling applies on the next tick without a restart. For Chrome the
            -- seam excludes incognito (returns nil -> ""); for Safari it cannot,
            -- which is exactly why trackSafariSite is its own risk-flagged toggle.
            if ctx.opt(siteOpt) ~= true then return "" end
            return getDomain(ctx.browserActiveURL(app)) or ""
        elseif EDITOR_APPS[app] then
            local title = ctx.window.title() or ""
            local project = title:match(" — (.+)$")
            if project then
                project = project:match("^([^%[]+)") or project
                return project:match("^%s*(.-)%s*$")
            end
        end
        return ""
    end

    -- Storage root, resolved once via the shared resolver: the `dir` option with
    -- a leading ~ expanded via the seam (the feature never reads HOME itself),
    -- defaulted and anchored under home. Months live directly under here.
    local base = store.resolveDir(ctx.opt("dir"), ctx.homeDir())

    local function dateStr(t)     return store.dateStr(t) end
    local function monthDir(d)    return store.monthDir(base, d) end
    local function appsPath(d)    return store.appsPath(base, d) end
    local function sessionsPath(d) return store.sessionsPath(base, d) end

    -- Move elapsed time onto the current app+context, minus the trailing
    -- idle stretch.
    local function flushCurrent()
        if not (st.curApp and st.curSince) then return end
        local now = ctx.now()
        local elapsed = now - st.curSince
        st.curSince = now
        if elapsed <= 0 then return end
        local idle = ctx.idleSeconds()
        if idle >= elapsed then return end        -- idle the whole interval
        local key = st.curApp .. "\t" .. (st.curCtx or "")
        st.appTime[key] = (st.appTime[key] or 0) + (elapsed - idle)
    end

    local function writeApps(d)
        if not next(st.appTime) then return end
        ctx.mkdir(monthDir(d))
        local rows = {}
        for key, secs in pairs(st.appTime) do
            local app, context = key:match("^(.-)\t(.*)$")
            rows[#rows + 1] = { app = app or key, context = context or "", secs = secs }
        end
        table.sort(rows, function(a, b) return a.secs > b.secs end)
        local out = { "app,context,seconds" }
        for _, r in ipairs(rows) do
            if r.secs >= MIN_ENTRY_SECONDS then
                out[#out + 1] = store.csvField(r.app) .. "," .. store.csvField(r.context)
                    .. "," .. math.floor(r.secs)
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
                local app, context, value = store.parseAppsRow(line)
                if app then
                    st.appTime[app .. "\t" .. context] = value
                end
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
        local total = store.readDayTotal(ctx.fileRead, base, d)
        st.dayCache[d] = total
        return total
    end

    -- Today's stats as plain data: per-app rows (descending, aggregated
    -- across contexts, each carrying its top context sub-rows), the 7-day
    -- series, and the average over past days. The widget renders this.
    local function snapshot(topN)
        local now = ctx.now()
        local rows = store.aggregate(st.appTime, topN, TOP_CONTEXTS)

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
                label = store.DAY_LABELS[tonumber(os.date("%w", t)) + 1],
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

    -- Retention: delete month dirs older than keepMonths (0 = keep forever).
    -- Runs at most once per day, piggybacked on the flush cadence. Deletion
    -- goes through the CURATED removeSubdir (base must be under home).
    local function sweepRetention()
        local keep = ctx.opt("keepMonths")
        if not keep or keep <= 0 then return end
        if st.sweepDate == st.appDate then return end
        st.sweepDate = st.appDate
        local t = os.date("*t", ctx.now())
        for k = keep, keep + 23 do
            local m = { year = t.year, month = t.month - k, day = 1, hour = 12 }
            local ym = os.date("%Y-%m", os.time(m))
            ctx.removeSubdir(base, ym)
        end
    end

    local function flushAll()
        rollover()
        flushCurrent()
        writeApps(st.appDate)
        sweepRetention()
    end
    shared.flushAll = flushAll

    -- Sync the desktop widget to the showWidget option and feed it data.
    -- Runs on the 60s tick AND immediately when the option is edited
    -- (onOptionChange below), so the Settings toggle applies on the spot.
    local function refreshWidget()
        local want = ctx.opt("showWidget") == true
        if want and not st.widget then
            st.widget = ctx.usageWidget(ctx.opt("screen") == "secondary" and 2 or 1)
        end
        if not want then
            if st.widget then st.widget.stop(); st.widget = nil end
            return
        end
        rollover()
        flushCurrent()
        st.widget.setData(snapshot(TOP_APPS))
    end
    shared.refreshWidget = refreshWidget

    local function onWake()
        if st.wakeAt then return end
        local now = ctx.now()
        st.wakeAt = now
        st.curSince = now
        rollover()
        local app = ctx.frontmostApp()
        if app and not IGNORE_APPS[app] then
            st.curApp = app
            st.curCtx = contextFor(app)
        end
        ctx.log("wake at " .. os.date("%H:%M:%S", now))
    end

    -- Tab/project switches WITHIN an app don't fire an activation event; the
    -- donor polled for them. On change: flush the old slice, start the new.
    local function pollContext()
        if not st.curApp or ctx.idleSeconds() > IDLE_POLL_SKIP then return end
        rollover()
        local newCtx = contextFor(st.curApp)
        if newCtx ~= st.curCtx then
            flushCurrent()
            st.curCtx = newCtx
        end
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
        st.curCtx = contextFor(app)
        st.curSince = ctx.now()
    end)
    ctx.onSystemEvent("wake", onWake)
    ctx.onSystemEvent("screenUnlock", onWake)
    ctx.onSystemEvent("sleep", recordSession)
    ctx.onSystemEvent("screenLock", recordSession)
    ctx.everySeconds(FLUSH_SECONDS, flushAll)
    ctx.everySeconds(CONTEXT_SECONDS, pollContext)
    ctx.everySeconds(REFRESH_SECONDS, refreshWidget)
    refreshWidget()
    ctx.log("started")
end

return {
    api         = 1,
    id          = "usage_stats",
    -- Identity / presentation (name, version, description, category, context,
    -- page) lives in feature.json beside this lua/. `id` stays here as the
    -- structural anchor; api + behavior below.

    options = {
        { key = "dir", type = "string", default = "~/.computer-usage",
          collapsible = true,
          label = "Storage folder (~ allowed; restart to apply)" },
        { key = "trackChromeSite", type = "bool", default = false,
          label = "Record which website you're on in Chrome (domain only, e.g. github.com; off by default, incognito never recorded)" },
        { key = "trackSafariSite", type = "bool", default = false,
          label = "Also record Safari sites -- RISK: Safari can't hide Private Browsing, so private sites may be recorded (off by default)" },
        { key = "showWidget", type = "bool", default = true,
          label = "Show desktop widget" },
        { key = "screen", type = "enum", default = "primary",
          values = { "primary", "secondary" },
          labels = { "Main display", "Second display" },
          label = "Widget screen" },
        { key = "keepMonths", type = "int", default = 0, min = 0, max = 24,
          label = "Keep history (months, 0 = forever)" },
    },

    start = start,

    -- Widget option edits apply the moment they are made: the toggle
    -- shows/hides, the screen choice recreates the panel on the other display.
    onOptionChange = function(ctx, key)
        if not shared.refreshWidget then return end
        if key == "screen" and shared.st and shared.st.widget then
            shared.st.widget.stop()
            shared.st.widget = nil
        end
        if key == "showWidget" or key == "screen" then
            shared.refreshWidget()
        end
    end,

    stop = function(ctx)
        -- Record the open session, then flush regardless -- pending app time
        -- must hit disk even when no session is open (e.g. disabled while the
        -- screen is locked), or disabling loses the day's tail.
        if shared.recordSession then shared.recordSession() end
        if shared.flushAll then shared.flushAll() end
        shared.recordSession, shared.flushAll, shared.snapshot,
            shared.refreshWidget, shared.st = nil, nil, nil, nil, nil
    end,
}
