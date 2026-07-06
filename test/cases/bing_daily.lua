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
        fake.httpResponses[bingApi] = {
            status = 200,
            body = '{"images":[{"url":"/th?id=OHR.TestPic_1920x1080.jpg&rf=x.jpg&pid=hp"}]}',
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

        -- same picture on the next poll: re-applied, NOT re-downloaded
        local dlCount = #fake.downloads
        fake.fireTimers("every", 3 * 3600)
        ok(#fake.downloads == dlCount, "bing: unchanged picture is not re-downloaded")
        ok(fake.wallpapers[#fake.wallpapers] == dl.path, "bing: unchanged picture is re-applied")

        -- the refresh action carries a default schedule trigger; rebinding to a hotkey
        -- (this also drops the schedule timer, so subsequent refreshes fire on the key)
        ok(registry.setTrigger("bing_daily", "refresh",
            { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "w" }) == true,
            "bing: refresh action rebinds to a hotkey")
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
