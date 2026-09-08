-- test/cases/display_off.lua -- display_off: a service that runs a visible countdown after
-- the idle threshold, sleeps the display when it expires, re-arms when the user returns --
-- and NEVER sleeps while something is holding the display awake (video, a call, a
-- presentation).
--
-- Migrated from run.lua T12 (RUN_LUA_SPLIT_SPEC Phase 2). Hermetic: registers its own
-- feature and drives its own idle/clock; freshWorld() before + handle tripwire after keep
-- it isolated.
--
-- The power-assertion block is the regression guard for the 2026-07-24 report ("turned the
-- monitor off while I was watching a video"): without the ctx.displaySleepPrevented() gate
-- in the feature, "held awake" below sleeps the display and the case goes red.

return {
    id = "display_off",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        -- Live countdown banners, i.e. the ones this feature currently has up.
        local function liveBanners()
            local n = 0
            for _, b in ipairs(fake.banners) do if not b.stopped then n = n + 1 end end
            return n
        end
        local function bannerText()
            for i = #fake.banners, 1, -1 do
                if not fake.banners[i].stopped then return fake.banners[i].text end
            end
        end

        registry.register(require("features.display_off"))
        fake.settings["hammerdeck.opt.display_off.idleThresholdMin"] = 5    -- 300s
        fake.settings["hammerdeck.opt.display_off.warnSeconds"]      = 30
        fake.screenList = {
            { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1, builtin = true },
            { x = 1440, y = 0, w = 1920, h = 1080, name = "External", index = 2 },
        }
        local dimsBefore = fake.actions.displaySleep
        registry.setEnabled("display_off", true)

        -- active: no countdown, no display sleep
        fake.idle = 10
        fake.fireTimers("every", 5)
        ok(liveBanners() == 0, "active: no countdown banner")
        ok(fake.actions.displaySleep == dimsBefore, "active: display not slept")

        -- idle past threshold: countdown starts, ONE banner per screen
        fake.idle = 6 * 60
        fake.fireTimers("every", 5)
        ok(liveBanners() == 2, "idle past threshold: a countdown banner on every screen")
        ok(bannerText() and bannerText():find("30"), "countdown opens at the full lead time")
        ok(fake.actions.displaySleep == dimsBefore, "no display sleep before the countdown ends")

        -- the countdown counts DOWN in place (no second set of banners)
        fake.clockOffset = fake.clockOffset + 10
        fake.fireTimers("every", 5)
        ok(liveBanners() == 2, "countdown updates in place, does not stack banners")
        ok(bannerText() and bannerText():find("20"), "countdown ticks down")

        -- countdown expires: display sleeps once, banners come down with it
        fake.clockOffset = fake.clockOffset + 20
        fake.fireTimers("every", 5)
        ok(fake.actions.displaySleep == dimsBefore + 1, "display slept after the countdown")
        ok(liveBanners() == 0, "banners cleared when the display sleeps")
        fake.fireTimers("every", 5)
        ok(fake.actions.displaySleep == dimsBefore + 1, "display sleep fired only once")

        -- returning to activity re-arms the cycle
        fake.idle = 0
        fake.fireTimers("every", 5)
        fake.idle = 6 * 60
        fake.fireTimers("every", 5)
        ok(liveBanners() == 2, "returning to activity re-arms the countdown")

        -- activity DURING the countdown cancels it without ever sleeping
        fake.idle = 0
        fake.fireTimers("every", 5)
        ok(liveBanners() == 0, "activity during the countdown clears the banners")
        ok(fake.actions.displaySleep == dimsBefore + 1, "cancelled countdown never slept the display")

        -- THE REGRESSION GUARD: watching a video. Idle time is way past the
        -- threshold (nobody is touching the keyboard), but an app holds the macOS
        -- display-wake assertion -- so nothing may happen, however long it runs.
        fake.idle = 6 * 60
        fake.displayHeldBy = "Google Chrome"
        for _ = 1, 12 do
            fake.clockOffset = fake.clockOffset + 5
            fake.fireTimers("every", 5)
        end
        ok(fake.actions.displaySleep == dimsBefore + 1,
            "display held awake: never slept despite being idle past the threshold")
        ok(liveBanners() == 0, "display held awake: no countdown banner shown at all")

        -- video ends: the normal cycle resumes from scratch
        fake.displayHeldBy = nil
        fake.fireTimers("every", 5)
        ok(liveBanners() == 2, "countdown resumes once nothing holds the display awake")
        fake.clockOffset = fake.clockOffset + 30
        fake.fireTimers("every", 5)
        ok(fake.actions.displaySleep == dimsBefore + 2, "display sleeps normally after the video ends")

        -- THE SECOND REGRESSION GUARD: back from a long absence. The idle counter
        -- keeps running through system sleep and the wake itself (lid, power button,
        -- Touch ID) is not an input event that resets it, so the first poll after
        -- waking reads the ENTIRE absence. Counting it opens a countdown in the face
        -- of a user who has just sat down. Without the wake clamp in the feature,
        -- "wake from a long absence: no countdown on the first poll" goes red.
        --
        -- The three assertions are one invariant in three parts, and NONE of them is
        -- redundant -- each kills a different wrong clamp that the others let pass:
        -- time-since-wake is a CEILING on idle, never a replacement for it (the
        -- active-user loop), and it holds for the whole absence, not just the first
        -- poll (the multi-poll window).
        fake.idle = 0
        fake.fireTimers("every", 5)                        -- back to armed and clean
        fake.clockOffset = fake.clockOffset + 3600
        fake.idle = 3600                                   -- what the counter reads across sleep
        fake.systemEvent("wake")
        fake.fireTimers("every", 5)
        ok(liveBanners() == 0, "wake from a long absence: no countdown on the first poll")
        ok(fake.actions.displaySleep == dimsBefore + 2, "wake from a long absence: display not slept")

        -- A clamp that fires ONCE and forgets reproduces the exact field symptom five
        -- seconds later, so drive the whole window the stale counter spans, not one tick.
        local sawBanner = false
        for _ = 1, 40 do                                   -- 200s, still short of the threshold
            fake.clockOffset = fake.clockOffset + 5
            fake.idle        = fake.idle + 5               -- nobody has touched anything yet
            fake.fireTimers("every", 5)
            if liveBanners() > 0 then sawBanner = true end
        end
        ok(not sawBanner, "wake from a long absence: no countdown for the whole stale window")

        -- ...and a clamp that REPLACES idle rather than capping it warns an active user
        -- at the threshold regardless of input. Work steadily for well past it.
        local dimsAtProbe = fake.actions.displaySleep
        for _ = 1, 80 do                                   -- 400s of clock, user active throughout
            fake.clockOffset = fake.clockOffset + 5
            fake.idle        = 0
            fake.fireTimers("every", 5)
            if liveBanners() > 0 then sawBanner = true end
        end
        ok(not sawBanner, "active user after waking: never sees a countdown")
        ok(fake.actions.displaySleep == dimsAtProbe, "active user after waking: display never slept")

        -- But a user who wakes the Mac and then walks away IS genuinely idle, and the
        -- post-wake cycle must complete -- countdown AND the sleep it exists to lead into.
        fake.idle = 0
        for _ = 1, 61 do                                   -- 305s of real, observed idleness
            fake.clockOffset = fake.clockOffset + 5
            fake.idle        = fake.idle + 5
            fake.fireTimers("every", 5)
        end
        ok(liveBanners() == 2, "idle for the full threshold AFTER waking: the countdown starts")
        fake.clockOffset = fake.clockOffset + 30
        fake.idle        = fake.idle + 30
        fake.fireTimers("every", 5)
        ok(fake.actions.displaySleep == dimsAtProbe + 1, "post-wake countdown expires into a display sleep")

        registry.setEnabled("display_off", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after display_off test")
    end,
}
