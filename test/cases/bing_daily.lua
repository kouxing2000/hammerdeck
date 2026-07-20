-- test/cases/bing_daily.lua -- bing_daily: a service that fetches Bing's daily image, caches
-- it by id, sets it as wallpaper (applyTo all/primary), remembers the applied picture, and
-- exposes a rebindable "refresh" action (default 3h schedule trigger). Covers boot refresh,
-- cache re-apply on a display change (no network), no re-download of an unchanged picture,
-- rebinding refresh to a hotkey, and a failed request leaving state untouched.
--
-- Migrated from the bing half of run.lua T18 (RUN_LUA_SPLIT_SPEC Phase 2). The json-decoder
-- block that shared this section split out to test/cases/json_codec.lua. Hermetic: registers
-- its own feature and seeds its own HTTP responses; freshWorld() + handle tripwire isolate it.

return {
    id = "bing_daily",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        registry.register(require("features.bing_daily"))
        local bingApi = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1"

        -- Bing reports when the current picture expires: `enddate` (the day) plus
        -- `fullstartdate`'s HHMM (the daily flip moment). The feature splices the
        -- two into a UTC "YYYYMMDDHHMM" stamp and skips the request until then.
        -- Derived from the harness clock, NEVER hardcoded -- a literal date would
        -- turn this case into a time bomb that starts failing on that day.
        local function bodyFor(picId, atTime)
            return '{"images":[{"url":"/th?id=' .. picId .. '&rf=x.jpg&pid=hp"'
                .. ',"fullstartdate":"' .. os.date("!%Y%m%d%H%M", atTime)
                .. '","enddate":"' .. os.date("!%Y%m%d", atTime + 86400) .. '"}]}'
        end
        -- ...so the rollover lands exactly 24h out: tomorrow's date, this HHMM.
        local rolloverKey = "hammerdeck.state.bing_daily.picRollover"
        fake.httpResponses[bingApi] = {
            status = 200,
            body = bodyFor("OHR.TestPic_1920x1080.jpg", fake.now()),
        }
        registry.setEnabled("bing_daily", true)
        ok(fake.fireTimers("after", 5) == 1, "bing: boot refresh scheduled")
        ok(fake.httpRequests[#fake.httpRequests].headers["User-Agent"] ~= nil, "bing: sends a user agent")
        local dl = fake.downloads[#fake.downloads]
        ok(dl and dl.path == "/tmp/hammerdeck-fake-cache/OHR.TestPic_1920x1080.jpg",
            "bing: downloads the picture into the app cache by id")
        ok(fake.wallpapers[#fake.wallpapers] == dl.path, "bing: sets the wallpaper")
        ok(fake.wallpaperModes[#fake.wallpaperModes] == "all",
            "bing: applyTo defaults to all displays")
        ok(fake.settings["hammerdeck.state.bing_daily.lastPic"] == "OHR.TestPic_1920x1080.jpg",
            "bing: remembers the applied picture")
        do
            local bingRow
            for _, d in ipairs(registry.describe()) do if d.id == "bing_daily" then bingRow = d end end
            ok(bingRow and bingRow.actions[1].trigger and bingRow.actions[1].trigger.everyMin == 180,
                "bing: refresh action defaults to a 3h schedule trigger (visible + rebindable)")
        end

        -- a display change re-applies the CACHED wallpaper, no network round-trip
        local reqBefore = #fake.httpRequests
        local dlBefore = #fake.downloads
        fake.systemEvent("screenChanged")
        ok(fake.wallpapers[#fake.wallpapers] == dl.path
            and #fake.httpRequests == reqBefore and #fake.downloads == dlBefore,
            "bing: a screen change re-applies the cached wallpaper without hitting the network")

        ok(#fake.settings[rolloverKey] == 12,
            "bing: records the picture's rollover stamp from Bing's own dates")

        -- The 3h tick, while we still hold the day's picture: NO request at all.
        -- The picture changes once a day, so polling eight times is pure waste --
        -- the wallpaper is still re-asserted, just from cache.
        local dlCount, reqCount = #fake.downloads, #fake.httpRequests
        fake.fireTimers("every", 3 * 3600)
        ok(#fake.httpRequests == reqCount, "bing: holding the day's picture skips the Bing check")
        ok(#fake.downloads == dlCount, "bing: unchanged picture is not re-downloaded")
        ok(fake.wallpapers[#fake.wallpapers] == dl.path, "bing: skipped tick still re-applies the wallpaper")

        -- A re-apply that FAILS (cache file purged, no display matched) must not
        -- earn the skip -- it falls through and re-fetches, or the desktop sits
        -- stale until tomorrow on a wallpaper we never actually set.
        fake.wallpaperOk = false
        fake.fireTimers("every", 3 * 3600)
        ok(#fake.httpRequests == reqCount + 1, "bing: a failed re-apply re-fetches instead of skipping")
        fake.wallpaperOk = true

        -- Past the rollover: the picture is stale again, so the check resumes.
        fake.clockOffset = fake.clockOffset + 25 * 3600
        reqCount = #fake.httpRequests
        fake.fireTimers("every", 3 * 3600)
        ok(#fake.httpRequests == reqCount + 1, "bing: polls again once the picture has rolled over")

        -- A DOWNLOAD failure must leave the stamp describing the picture we still
        -- HOLD -- recording the new one before the file lands would pair yesterday's
        -- picture with tomorrow's stamp and skip every tick until a rollover we
        -- never reached (~24h of a stale desktop, self-inflicted).
        fake.httpResponses[bingApi].body = bodyFor("OHR.FailedPic_1920x1080.jpg", fake.now())
        fake.downloadOk = false
        fake.fireTimers("every", 3 * 3600)
        fake.downloadOk = true
        reqCount = #fake.httpRequests
        fake.fireTimers("every", 3 * 3600)
        ok(#fake.httpRequests == reqCount + 1, "bing: a failed download still retries on the next tick")
        ok(fake.settings["hammerdeck.state.bing_daily.lastPic"] == "OHR.FailedPic_1920x1080.jpg",
            "bing: the retry lands the picture that failed to download")

        -- Malformed dates from Bing must never ENTER state. The horizon check below
        -- is a backstop that also happens to reject garbage, but a stamp we cannot
        -- trust has no business being stored in the first place.
        fake.settings[rolloverKey] = nil
        fake.httpResponses[bingApi].body =
            '{"images":[{"url":"/th?id=OHR.Garbage_1920x1080.jpg&rf=x.jpg"'
            .. ',"fullstartdate":"xxxxxxxxabcd","enddate":"unknown!"}]}'
        fake.fireTimers("every", 3 * 3600)
        ok(fake.settings[rolloverKey] == "",
            "bing: malformed dates from Bing are never stored as a rollover stamp")

        -- A malformed stamp must never silence the feature: freshness is a STRING
        -- comparison, and any non-digit byte sorts above "9" -- so a 12-char piece
        -- of garbage would read as forever-in-the-future, permanently.
        fake.settings[rolloverKey] = "unknown!abcd"
        reqCount = #fake.httpRequests
        fake.fireTimers("every", 3 * 3600)
        ok(#fake.httpRequests == reqCount + 1, "bing: a garbage rollover stamp still polls")

        -- ...and neither may a well-formed but absurd one (Bing bug, clock moved
        -- backwards): the skip is capped at a believable horizon.
        fake.settings[rolloverKey] = os.date("!%Y%m%d%H%M", fake.now() + 400 * 24 * 3600)
        reqCount = #fake.httpRequests
        fake.fireTimers("every", 3 * 3600)
        ok(#fake.httpRequests == reqCount + 1, "bing: a far-future rollover stamp is not trusted")

        -- the refresh action carries a default schedule trigger; rebinding to a hotkey
        -- (this also drops the schedule timer, so subsequent refreshes fire on the key)
        ok(registry.setTrigger("bing_daily", "refresh",
            { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "w" }) == true,
            "bing: refresh action rebinds to a hotkey")
        fake.settings[rolloverKey] = nil   -- past the rollover: a new picture is due
        fake.httpResponses[bingApi].body =
            '{"images":[{"url":"/th?id=OHR.NewPic_1920x1080.jpg&rf=y.jpg"}]}'
        fake.settings["hammerdeck.opt.bing_daily.applyTo"] = "primary"
        fake.pressHotkey("w")
        ok(fake.downloads[#fake.downloads].path == "/tmp/hammerdeck-fake-cache/OHR.NewPic_1920x1080.jpg",
            "bing: manual refresh downloads the new picture")
        ok(fake.wallpaperModes[#fake.wallpaperModes] == "primary",
            "bing: applyTo='primary' threads through to setWallpaper")
        fake.settings["hammerdeck.opt.bing_daily.applyTo"] = nil

        -- a failed request leaves state untouched (refresh now fires on the hotkey)
        fake.httpResponses[bingApi] = { status = 500, body = nil }
        local wallCount = #fake.wallpapers
        fake.pressHotkey("w")
        ok(#fake.wallpapers == wallCount, "bing: failed request changes nothing")

        registry.setEnabled("bing_daily", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after bing_daily test")
    end,
}
