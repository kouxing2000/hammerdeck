-- test/cases/_integration/platform/ctx_uncovered_surface.lua -- the ctx methods
-- that `list_api` advertises to extension authors but no test had ever CALLED.
--
-- Why this case exists (audit 2026-09-02, finding F9). Coverage over the headless
-- suite found nine public ctx methods executed by nothing: dailyAt, httpRequest,
-- activateApp, lockScreen, startScreensaver, setAppearance, adjustVolume,
-- toggleMute and mediaKey. Every one of them is NAMED to an extension author by
-- the MCP `list_api` tool, so the first execution of each was an author's own
-- feature on their own machine -- the surface we document was the surface we did
-- not run. A typo in a ctx wrapper (wrong adapter name, dropped argument, missing
-- return) would have shipped silently; the gate is the seam-parity case, which
-- proves the names MATCH, not that the wrappers WORK.
--
-- Deliberately thin per method: one call, one observable effect through the fake.
-- This is a smoke net over the advertised surface, not a behavior spec -- the
-- features that use a method in anger own its semantics.
return {
    id = "ctx_uncovered_surface",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        -- One host feature, declaring the two tiers these methods sit behind
        -- (network for httpRequest, power for lockScreen/startScreensaver). The
        -- rest are ungated. Capturing ctx from inside the action is how a feature
        -- really receives it -- built by ctx.make, gate applied, scope tracked --
        -- so the wrappers under test are the ones a feature would call.
        local ctx
        registry.register({
            api = 1, id = "surface_probe", name = "Surface Probe",
            capabilities = { "network", "power" },
            action = function(c) ctx = c end,
        })
        registry.setEnabled("surface_probe", true)
        ok(registry.runAction("surface_probe", "main") == true, "probe captured a live ctx")
        ok(type(ctx) == "table", "ctx is the real scoped table")

        -- power -----------------------------------------------------------------
        local locks, savers = fake.actions.lock, fake.actions.screensaver
        ctx.lockScreen()
        ok(fake.actions.lock == locks + 1, "ctx.lockScreen reaches the seam")
        ctx.startScreensaver()
        ok(fake.actions.screensaver == savers + 1, "ctx.startScreensaver reaches the seam")

        -- appearance / audio ------------------------------------------------------
        ok(ctx.setAppearance("dark") == true, "ctx.setAppearance returns the seam's result")
        ok(fake.appearanceSet[#fake.appearanceSet] == "dark", "and passes the mode through")

        local before = fake.volume
        ok(ctx.adjustVolume(7) == before + 7, "ctx.adjustVolume returns the NEW level")
        ok(fake.volume == before + 7, "and moved the system volume by the delta")
        ok(ctx.adjustVolume(-7) == before, "a negative delta is a real argument, not an abs()")

        local muted = fake.muted
        ok(ctx.toggleMute() == (not muted), "ctx.toggleMute returns the new mute state")
        ok(fake.muted == (not muted), "and really flipped it")
        ctx.toggleMute()   -- leave the world as we found it

        ok(ctx.mediaKey("playpause") == true, "ctx.mediaKey accepts a known key")
        ok(fake.mediaKeys[#fake.mediaKeys] == "playpause", "and forwards the key name verbatim")

        -- apps --------------------------------------------------------------------
        fake.runningApps["Safari"] = true
        ok(ctx.activateApp("Safari") == true, "ctx.activateApp reports a running app activated")
        ok(fake.activatedApps[#fake.activatedApps] == "Safari", "and named the app it activated")
        ok(ctx.activateApp("Not Running") ~= true, "and does not claim success for a dead app")

        -- network: the general-purpose verb behind httpGet/httpPost ---------------
        -- The argument ORDER is the whole risk here (url, method, headers, body,
        -- cb) -- a wrapper that transposed method and headers would still "work"
        -- for every caller that only ever uses httpGet.
        fake.httpResponses["https://example.test/put"] = { status = 204, body = "" }
        local gotStatus
        ctx.httpRequest("https://example.test/put", "PUT",
            { ["X-Probe"] = "1" }, "payload", function(status) gotStatus = status end)
        local sent = fake.httpRequests[#fake.httpRequests]
        ok(sent.url == "https://example.test/put", "httpRequest sends the url")
        ok(sent.method == "PUT", "and the method, in its own slot")
        ok(sent.headers["X-Probe"] == "1", "and the headers, in theirs")
        ok(sent.body == "payload", "and the body")
        ok(gotStatus == 204, "and delivers the status to the callback")

        -- schedule: dailyAt is a TRACKED handle, so it must also die on disable ---
        local fired = 0
        ctx.dailyAt("07:30", function() fired = fired + 1 end)
        ok(fake.fireTimers("daily", "07:30") == 1, "ctx.dailyAt registered a daily timer")
        ok(fired == 1, "and its callback runs when the day reaches that time")

        registry.setEnabled("surface_probe", false)
        ok(fake.fireTimers("daily", "07:30") == 0,
            "disabling the feature stopped the dailyAt handle -- scope-tracked, like every one-shot")
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
            "clean after the uncovered-surface probe")
    end,
}
