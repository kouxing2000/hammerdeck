-- test/cases/usage_stats.lua -- usage_stats: a background service that accrues per-app
-- focus time + machine sessions to daily CSVs, feeds a desktop widget, enriches rows with
-- browser-domain / editor-project context (each opt-in and per-browser), sweeps old months,
-- and survives disable/re-enable by reloading from disk. Plus its host-callable
-- report.range() reader, which rolls the CSVs up for the Homepage "Usage" tab and works
-- even while the feature is OFF (a "host reporter", per "The one inviolable rule").
--
-- Migrated from run.lua T20 (live service) + T32 (report.range) (RUN_LUA_SPLIT_SPEC
-- Phase 2). Hermetic: registers its own feature, pins its own storage dir + clock, and
-- seeds its own CSVs; freshWorld() before + handle tripwire after keep it isolated. The
-- two blocks are independent -- T20 pins dir=/fake/data/usage; report.range reads the
-- default ~/.computer-usage (/fake/home) -- so they share no fixtures.

return {
    id = "usage_stats",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        -- ===== live service (T20) =====
        registry.register(require("features.usage_stats"))

        -- Re-pin the clock to a fresh morning so this test owns its day arithmetic.
        local pin20 = os.date("*t") --[[@as osdateparam]]
        pin20.hour, pin20.min, pin20.sec = 9, 0, 0
        fake.clockOffset = os.time(pin20) - os.time()
        fake.idle = 0

        -- pin the storage folder to an absolute path (no ~ expansion) so the CSV
        -- paths below stay deterministic; the months live directly under it
        fake.settings["hammerdeck.opt.usage_stats.dir"] = "/fake/data/usage"
        local day20 = os.date("%Y-%m-%d", fake.now()) --[[@as string]]
        local appsCsv = "/fake/data/usage/" .. day20:sub(1, 7) .. "/" .. day20 .. "-apps.csv"
        local sessCsv = "/fake/data/usage/" .. day20:sub(1, 7) .. "/" .. day20 .. ".csv"

        fake.frontmost = "Code"
        registry.setEnabled("usage_stats", true)

        -- focus time accrues to the frontmost app; switching apps flushes
        fake.clockOffset = fake.clockOffset + 120
        fake.activateApp("Safari")
        fake.clockOffset = fake.clockOffset + 60
        fake.fireTimers("every", 600)   -- the 10-min flush writes the apps CSV
        local csv = fake.files[appsCsv]
        ok(csv ~= nil and csv:match("^app,context,seconds\n"), "apps CSV written with header")
        ok(csv:match("\nCode,,120\n") and csv:match("\nSafari,,60\n"),
            "both apps accrued their focus seconds (context column empty for now)")
        ok(csv:find("Code,,120") < csv:find("Safari,,60"), "rows sorted by time descending")

        -- a fully-idle interval is discarded; partial idle is subtracted
        fake.clockOffset = fake.clockOffset + 50
        fake.idle = 100                                    -- idle >= elapsed: discard
        fake.fireTimers("every", 600)
        ok(fake.files[appsCsv]:match("\nSafari,,60\n") ~= nil, "fully-idle interval added nothing")
        fake.idle = 10
        fake.clockOffset = fake.clockOffset + 40           -- 40s elapsed, 10s idle
        fake.fireTimers("every", 600)
        ok(fake.files[appsCsv]:match("\nSafari,,90\n") ~= nil, "partial idle subtracted (60+30)")
        fake.idle = 0

        -- locking records the session (wake -> lock, minutes rounded)
        fake.clockOffset = fake.clockOffset + 60
        fake.systemEvent("screenLock")
        local sess = fake.files[sessCsv]
        ok(sess ~= nil and sess:match("^wake_time,sleep_time,duration_min\n"),
            "session CSV written with header")
        ok(sess:match(",6\n") ~= nil, "session duration recorded (330s -> 6 min)")

        -- locked time accrues to nothing; unlock starts a new session
        fake.clockOffset = fake.clockOffset + 600
        fake.systemEvent("screenUnlock")
        fake.clockOffset = fake.clockOffset + 45
        fake.systemEvent("screenLock")
        local _, sessLines = fake.files[sessCsv]:gsub("\n", "")
        ok(sessLines == 3, "second session appended; locked time not counted")
        ok(fake.files[appsCsv]:match("\nSafari,,195\n") ~= nil,
            "post-unlock focus accrued to the frontmost app (90+60 at lock, +45)")

        -- sub-30s wake/lock blips are ignored
        fake.systemEvent("screenUnlock")
        fake.clockOffset = fake.clockOffset + 10
        fake.systemEvent("screenLock")
        local _, sessLines2 = fake.files[sessCsv]:gsub("\n", "")
        ok(sessLines2 == 3, "short session skipped")

        -- desktop widget: fed on each refresh tick; option toggle shows/hides live
        local widget = fake.liveUsageWidget()
        ok(widget ~= nil, "widget shown by default (showWidget=true)")
        fake.fireTimers("every", 60)   -- the refresh tick pushes data
        ok(widget.data ~= nil and widget.data.total == 325,
            "widget data total matches accrued time (120 + 195 + the 10s blip's focus)")
        ok(#widget.data.week == 7 and widget.data.week[7].today == true,
            "widget gets a 7-day series ending today")
        ok(widget.data.apps[1].app == "Safari" and widget.data.apps[1].secs == 205,
            "widget app rows sorted descending")
        fake.settings["hammerdeck.opt.usage_stats.showWidget"] = false
        fake.fireTimers("every", 60)
        ok(fake.liveUsageWidget() == nil, "widget hides when the option is switched off")
        fake.settings["hammerdeck.opt.usage_stats.showWidget"] = true
        fake.fireTimers("every", 60)
        ok(fake.liveUsageWidget() ~= nil, "widget re-shows when the option returns")

        -- the Settings store pings optionChanged on every write: the toggle applies
        -- INSTANTLY, no waiting for the 60s tick
        fake.settings["hammerdeck.opt.usage_stats.showWidget"] = false
        registry.optionChanged("usage_stats", "showWidget")
        ok(fake.liveUsageWidget() == nil, "onOptionChange hides the widget immediately")
        fake.settings["hammerdeck.opt.usage_stats.showWidget"] = true
        registry.optionChanged("usage_stats", "showWidget")
        ok(fake.liveUsageWidget() ~= nil, "and shows it back immediately")
        registry.optionChanged("usage_stats", "someOtherKey")      -- ignored key: no-op
        registry.optionChanged("no_such_feature", "defaultMinutes") -- absent feature: no-op
        ok(fake.liveUsageWidget() ~= nil, "unrelated keys and absent features no-op")
        fake.settings["hammerdeck.opt.usage_stats.showWidget"] = nil

        -- accumulated time survives a disable/re-enable (reloaded from the CSV)
        registry.setEnabled("usage_stats", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "usage_stats leaks nothing")
        fake.systemEvent("screenUnlock")   -- no live watchers: must be inert
        registry.setEnabled("usage_stats", true)
        fake.fireTimers("every", 600)
        ok(fake.files[appsCsv]:match("\nCode,,120\n") and fake.files[appsCsv]:match("\nSafari,,205\n"),
            "today's totals (incl. the blip's focus, flushed on disable) restored after re-enable")
        -- context enrichment: browser domain + editor project fill the CSV column.
        -- Chrome-site tracking is opt-in, so enable it for this slice (editor project
        -- context is always on and needs no opt-in).
        fake.settings["hammerdeck.opt.usage_stats.trackChromeSite"] = true
        fake.activeUrls["Google Chrome"] = "https://github.com/owner/repo"
        fake.activateApp("Google Chrome")              -- switch reads the context
        fake.clockOffset = fake.clockOffset + 90
        fake.activeUrls["Google Chrome"] = "https://news.site/page"
        fake.fireTimers("every", 30)                   -- tab switch: poll splits the slice
        fake.clockOffset = fake.clockOffset + 60
        fake.fireTimers("every", 600)                  -- flush + write
        local csvC = fake.files[appsCsv]
        ok(csvC:match("\nGoogle Chrome,github.com,90\n") ~= nil,
            "browser context = active tab's domain (pre-switch slice)")
        ok(csvC:match("\nGoogle Chrome,news.site,60\n") ~= nil,
            "the 30s context poll splits accrual on a tab change")

        fake.windowTitle = "main.swift — hammerdeck [SSH: devbox]"
        fake.activateApp("Code")
        fake.clockOffset = fake.clockOffset + 45
        fake.fireTimers("every", 600)
        ok(fake.files[appsCsv]:match("\nCode,hammerdeck,45\n") ~= nil,
            "editor context = project from the window title, suffix stripped")

        -- widget aggregates per app and carries the top context sub-rows
        fake.fireTimers("every", 60)
        local wd = fake.liveUsageWidget().data
        local chromeRow
        for _, r in ipairs(wd.apps) do if r.app == "Google Chrome" then chromeRow = r end end
        ok(chromeRow and chromeRow.secs == 150 and #chromeRow.contexts == 2
            and chromeRow.contexts[1].name == "github.com" and chromeRow.contexts[1].secs == 90,
            "widget aggregates contexts under the app, sorted by time")
        -- ===== THE BROWSER READ IS ASYNC: A STALE ANSWER MUST NOT WIN.
        -- Reading the active tab is an out-of-process subprocess call (it blocked the
        -- main thread for ~1s per call when it was synchronous). Async means two reads
        -- for the same app can be in flight, and if an OLDER answer lands last it
        -- would overwrite the newer domain -- after which the next flush banks real
        -- focus time under the wrong site in a daily CSV the user keeps. A generation
        -- counter drops any answer a later request has superseded.
        do
            fake.settings["hammerdeck.opt.usage_stats.trackChromeSite"] = true
            fake.activeUrls["Google Chrome"] = "https://first.example/page"
            fake.activateApp("Google Chrome")           -- resolves synchronously here
            -- Slices must clear MIN_ENTRY_SECONDS (30) or the CSV drops them, which
            -- would make these assertions pass for the wrong reason.
            fake.clockOffset = fake.clockOffset + 40

            -- Two reads in flight, each snapshotting a DIFFERENT domain at issue time.
            fake.deferAsync = true
            fake.activeUrls["Google Chrome"] = "https://second.example/page"
            fake.fireTimers("every", 30)               -- read A (older)
            fake.activeUrls["Google Chrome"] = "https://third.example/page"
            fake.fireTimers("every", 30)               -- read B (newer)
            ok(#fake.pendingAsync == 2, "two context reads are genuinely in flight")

            -- Deliver them OUT OF ORDER: newest first, then the stale one.
            local q = fake.pendingAsync
            fake.pendingAsync = { q[2], q[1] }
            fake.deliverAsync()
            fake.deferAsync = false
            fake.clockOffset = fake.clockOffset + 50
            fake.fireTimers("every", 600)              -- flush + write

            local csvS = fake.files[appsCsv]
            ok(csvS:match("\nGoogle Chrome,first%.example,4%d\n") ~= nil,
                "the pre-switch slice is banked under the domain that was current")
            ok(csvS:match("\nGoogle Chrome,third%.example,5%d\n") ~= nil,
                "the NEWEST read's domain wins and the following slice accrues to it")
            ok(csvS:match("\nGoogle Chrome,second%.example,") == nil,
                "a stale answer landing last is dropped, not written to the CSV")
            fake.settings["hammerdeck.opt.usage_stats.trackChromeSite"] = nil
        end

        -- ===== AN UNRESOLVED CONTEXT DEFERS, IT DOES NOT BANK A BLANK ONE.
        -- A browser activation starts its slice before the domain is known (subprocess
        -- round-trip). Banking time under "" while waiting would file a sliver under a
        -- context-less row on every single browser activation, and those accumulate
        -- into a bogus row over a day -- so flushCurrent defers while unresolved and
        -- the whole span lands under the real domain.
        do
            fake.settings["hammerdeck.opt.usage_stats.trackChromeSite"] = true
            fake.activeUrls["Google Chrome"] = "https://slow.example/page"
            fake.deferAsync = true
            fake.activateApp("Google Chrome")           -- context NOT resolved yet
            fake.clockOffset = fake.clockOffset + 40
            fake.fireTimers("every", 600)               -- a flush lands mid-resolve
            ok(fake.files[appsCsv]:match("\nGoogle Chrome,,%d") == nil,
                "a flush during the resolve window banks NOTHING under a blank context")

            fake.deliverAsync()                          -- domain arrives
            fake.deferAsync = false
            fake.clockOffset = fake.clockOffset + 20
            fake.fireTimers("every", 600)
            ok(fake.files[appsCsv]:match("\nGoogle Chrome,slow%.example,6%d\n") ~= nil,
                "the deferred span is attributed to the real domain once it resolves")
            fake.settings["hammerdeck.opt.usage_stats.trackChromeSite"] = nil
        end

        fake.settings["hammerdeck.opt.usage_stats.trackChromeSite"] = nil
        fake.windowTitle = nil

        -- the widget screen option recreates the panel on the chosen display instantly
        ok(fake.liveUsageWidget().screen == 1, "widget defaults to the primary screen")
        fake.settings["hammerdeck.opt.usage_stats.screen"] = "secondary"
        registry.optionChanged("usage_stats", "screen")
        ok(fake.liveUsageWidget().screen == 2, "screen option moves the widget immediately")
        fake.settings["hammerdeck.opt.usage_stats.screen"] = nil

        -- retention: month dirs older than keepMonths are swept (once per day)
        local oldMonth = os.date("%Y-%m", fake.now() - 100 * 86400)   -- >3 months back
        local oldFile = "/fake/data/usage/" .. oldMonth .. "/" .. oldMonth .. "-15-apps.csv"
        fake.files[oldFile] = "app,context,seconds\nOldApp,,999\n"
        fake.settings["hammerdeck.opt.usage_stats.keepMonths"] = 2
        fake.fireTimers("every", 600)   -- flush cadence runs the daily sweep
        ok(fake.files[oldFile] == nil, "retention sweep deletes months past the keep window")
        ok(fake.files[appsCsv] ~= nil, "the current month survives the sweep")
        fake.settings["hammerdeck.opt.usage_stats.keepMonths"] = nil

        -- CSV injection guard: an app name with a comma is quoted on write and parsed
        -- back on reload, instead of shifting the context/seconds columns
        fake.windowTitle = nil
        fake.activateApp("Excel, Inc.")
        fake.clockOffset = fake.clockOffset + 40
        fake.fireTimers("every", 600)
        ok(fake.files[appsCsv]:match('\n"Excel, Inc%.",,40\n') ~= nil,
            "an app name with a comma is CSV-quoted on write")
        registry.setEnabled("usage_stats", false)   -- stop() flushes the tail
        registry.setEnabled("usage_stats", true)     -- re-enable reloads from the CSV
        fake.fireTimers("every", 600)
        ok(fake.files[appsCsv]:match('\n"Excel, Inc%.",') ~= nil,
            "the quoted app round-trips through reload (parsed back, not column-shifted)")

        -- browser SITE (domain) tracking is OPT-IN and PER-BROWSER, verified on a FRESH
        -- day so these assertions own their CSV (a rollover clears the accumulated app
        -- time first). Chrome's incognito is excluded upstream in the Swift seam; the
        -- fake seam just returns the URL we set, so this covers the pieces that live in
        -- Lua: the per-browser consent gate and the domain-only reduction.
        do
            fake.clockOffset = fake.clockOffset + 86400          -- next day -> rollover resets appTime
            fake.idle = 0
            fake.windowTitle = nil
            local d2    = os.date("%Y-%m-%d", fake.now()) --[[@as string]]
            local apps2 = "/fake/data/usage/" .. d2:sub(1, 7) .. "/" .. d2 .. "-apps.csv"
            local csv2
            fake.activeUrls["Google Chrome"] = "https://github.com/acme/repo?token=secret"

            -- Chrome OFF by default: time accrues, but with an EMPTY context (no domain)
            fake.settings["hammerdeck.opt.usage_stats.trackChromeSite"] = nil
            fake.activateApp("Google Chrome")                    -- rolls to d2, opens the app
            fake.clockOffset = fake.clockOffset + 60
            fake.fireTimers("every", 600)
            csv2 = fake.files[apps2]
            ok(csv2 ~= nil and csv2:match("\nGoogle Chrome,,%d+\n") ~= nil,
                "Chrome site OFF by default: time keyed with an EMPTY context")
            ok(csv2:find("github") == nil, "no Chrome domain recorded without consent")

            -- opt in to Chrome: the domain (only) becomes the context on the next poll
            fake.settings["hammerdeck.opt.usage_stats.trackChromeSite"] = true
            fake.fireTimers("every", 30)
            fake.clockOffset = fake.clockOffset + 60
            fake.fireTimers("every", 600)
            csv2 = fake.files[apps2]
            ok(csv2:match("Google Chrome,github%.com,%d+") ~= nil,
                "after opt-in, Chrome time keys by DOMAIN (github.com)")
            ok(csv2:find("token=secret") == nil and csv2:find("/acme/repo") == nil,
                "only the domain is stored -- never the full URL/path")

            -- Safari has an INDEPENDENT gate: Chrome ON but trackSafariSite OFF must NOT
            -- record a Safari domain (proving the two toggles are not shared).
            fake.activeUrls["Safari"] = "https://duckduckgo.com/?q=x"
            fake.settings["hammerdeck.opt.usage_stats.trackSafariSite"] = nil
            fake.activateApp("Safari")
            fake.clockOffset = fake.clockOffset + 60
            fake.fireTimers("every", 600)
            csv2 = fake.files[apps2]
            ok(csv2:match("\nSafari,,%d+\n") ~= nil,
                "Safari OFF stays empty-context even while Chrome tracking is ON")
            ok(csv2:find("duckduckgo") == nil, "Safari domain not recorded under Chrome's toggle")

            -- opt in to Safari specifically -> its own domain is recorded (its own risk)
            fake.settings["hammerdeck.opt.usage_stats.trackSafariSite"] = true
            fake.fireTimers("every", 30)
            fake.clockOffset = fake.clockOffset + 60
            fake.fireTimers("every", 600)
            ok(fake.files[apps2]:match("Safari,duckduckgo%.com,%d+") ~= nil,
                "Safari ON: records its own domain via its independent toggle")

            fake.settings["hammerdeck.opt.usage_stats.trackChromeSite"] = nil
            fake.settings["hammerdeck.opt.usage_stats.trackSafariSite"] = nil
        end

        registry.setEnabled("usage_stats", false)
        fake.settings["hammerdeck.opt.usage_stats.dir"] = nil
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "usage_stats live service leaks nothing")

        -- ===== host reporter: report.range() (T32) =====
        -- The Homepage "Usage" tab calls features.usage_stats.report.range(from,to) via
        -- lua.call; it reads straight from disk (works even when the feature is off).
        -- Seed a few daily apps/sessions CSVs under the DEFAULT dir (~/.computer-usage,
        -- so /fake/home/.computer-usage) and assert the rolled-up shape.
        do
            local function approx(a, b) return math.abs(a - b) < 1e-6 end
            local U = "/fake/home/.computer-usage"
            -- range 2026-06-20 .. 22 (22 has no data -> inactive day)
            fake.files[U .. "/2026-06/2026-06-20-apps.csv"] =
                "app,context,seconds\nCode,projA,3600\nGoogle Chrome,github.com,1800\n"
            fake.files[U .. "/2026-06/2026-06-21-apps.csv"] =
                "app,context,seconds\nCode,projA,1200\nGoogle Chrome,news.example,600\nSlack,,300\n"
            fake.files[U .. "/2026-06/2026-06-20.csv"] =
                "wake_time,sleep_time,duration_min\n09:00:00,17:00:00,480\n"
            -- a day in the PRECEDING equal-length period (17..19) -> drives prevTotal
            fake.files[U .. "/2026-06/2026-06-19-apps.csv"] =
                "app,context,seconds\nCode,projA,1000\n"

            local report = require("features.usage_stats.report")
            local r = report.range("2026-06-20", "2026-06-22")

            ok(r.total == 7500, "report total sums all apps across the range")
            ok(r.activeDays == 2, "activeDays counts only days with recorded time")
            ok(r.dailyAvg == 3750, "dailyAvg = total / active days")
            ok(#r.days == 3 and r.days[3].date == "2026-06-22" and r.days[3].secs == 0,
                "days series has an entry per day, empty day = 0")

            ok(#r.apps == 3, "all apps ranked (uncapped)")
            ok(r.apps[1].app == "Code" and r.apps[1].secs == 4800, "apps ranked by total secs")
            ok(r.apps[2].app == "Google Chrome" and r.apps[2].secs == 2400, "second-ranked app")
            ok(r.apps[3].app == "Slack" and r.apps[3].secs == 300, "long-tail app kept")
            ok(approx(r.apps[1].share, 4800 / 7500), "app share = secs / range total")
            ok(r.busiestApp == "Code", "busiestApp is the top app")

            -- contexts merge across days and carry a within-app share
            ok(#r.apps[1].contexts == 1 and r.apps[1].contexts[1].name == "projA"
                and r.apps[1].contexts[1].secs == 4800, "context merged across days")
            ok(approx(r.apps[1].contexts[1].share, 1.0), "single-context app -> share 1.0")
            ok(#r.apps[2].contexts == 2, "two distinct browser domains kept as contexts")
            ok(r.apps[2].contexts[1].name == "github.com" and r.apps[2].contexts[1].secs == 1800,
                "top context first")
            ok(approx(r.apps[2].contexts[1].share, 1800 / 2400), "context share is within its app")

            -- sessions (machine-active spans)
            ok(#r.sessions == 1 and r.sessions[1].date == "2026-06-20", "session row read")
            ok(r.sessions[1].wakeMin == 540 and r.sessions[1].sleepMin == 1020,
                "session wake/sleep parsed to minutes-of-day")
            ok(r.firstWakeMin == 540 and r.lastSleepMin == 1020, "first wake / last sleep")
            ok(r.sessionCount == 1 and r.longestSessionMin == 480 and r.activeMinutes == 480,
                "session summary metrics")

            -- previous equal-length period (17..19): only 19 seeded
            ok(r.prevTotal == 1000 and r.prevHasData == true,
                "prevTotal sums the preceding equal-length period")

            -- empty range -> safe zeros, empty arrays (the report's empty state)
            local e = report.range("2025-01-01", "2025-01-03")
            ok(e.total == 0 and e.activeDays == 0 and #e.apps == 0 and e.busiestApp == nil,
                "empty history -> zeroed report, no apps")
        end
    end,
}
