-- features/display_off
--
-- Turns the display off after a stretch of no input (ported from the author's
-- prior Hammerspoon config). Polls idle time; once past the threshold it puts a
-- countdown banner on every screen, then sleeps the panel when the countdown
-- runs out. Any input clears the banner and re-arms the cycle. macOS still
-- decides whether to fully sleep based on active processes -- this only turns
-- the panel off.
--
-- TWO THINGS THIS GETS RIGHT that a naive idle timer does not, both learned from
-- the 2026-07-24 bug report ("turned off the monitor while I was watching a
-- video, with no notice at all"):
--
--   1. HID idle time cannot tell "away from the desk" from "watching a film" --
--      both look like nobody pressed a key. So idleness ALONE is never enough to
--      justify blanking the screen. Before acting we consult
--      ctx.displaySleepPrevented(), the macOS display-wake power assertion that
--      video players, video calls, screen sharing and presentation modes all
--      take, and that the OS's own idle-sleep obeys. While one is held we do
--      nothing. That is a system-level signal, not an app whitelist, so it covers
--      every such app for free -- including ones that don't exist yet.
--
--   2. A warning nobody sees is not a warning. The old code flashed a 2s toast on
--      whichever screen the CURSOR happened to be on, ten seconds before going
--      dark -- invisible if you were looking at a video on another display. The
--      warning is now a banner on EVERY screen that STAYS UP for the whole lead
--      time and counts down, so it cannot be missed and cannot be mistimed.
--
-- (The donor was named "Dimmer" but it sleeps the display rather than dimming
-- brightness; the feature is named for what it does.)
--
-- SERVICE feature: the poll timer and every banner go through ctx, so disable
-- tears them down -- no stop() needed.

local POLL_INTERVAL = 5    -- seconds between idle checks

return {
    api         = 1,
    id          = "display_off",

    options = {
        { key = "idleThresholdMin", type = "int", default = 5,
          label = "Idle before display off (min)", min = 1, max = 60 },
        -- The countdown is the user's only chance to intervene, so it is worth a
        -- knob: long enough to notice and react, short enough not to be a nag.
        { key = "warnSeconds", type = "int", default = 30,
          label = "Countdown warning before display off (sec)", min = 5, max = 120 },
    },

    -- Idle-triggered, not wall-clock: report as a condition (the Timeline lists
    -- it in the Events/conditions lane rather than on the 24h ruler).
    schedule = function(ctx)
        return {
            { label = "Turn off display", note = "after " .. ctx.opt("idleThresholdMin")
                .. "m idle", optionKey = "idleThresholdMin" },
        }
    end,

    ---@param ctx Ctx
    start = function(ctx)
        local s = { warnedAt = nil, dimmed = false, banners = nil, heldBy = nil }

        -- Drop the countdown banners (idempotent; safe when none are up).
        local function clearBanners()
            if not s.banners then return end
            for _, b in ipairs(s.banners) do b.stop() end
            s.banners = nil
        end

        -- Put the countdown on EVERY screen -- the panel is about to go dark
        -- everywhere, so a warning on one display is a warning half missed.
        local function showBanners(text)
            local frames = ctx.screen.frames()
            s.banners = {}
            if #frames == 0 then                        -- headless/no screens: one unpinned
                s.banners[1] = ctx.banner(text)
                return
            end
            for _, f in ipairs(frames) do
                s.banners[#s.banners + 1] = ctx.banner(text, f)
            end
        end

        local function setBannerText(text)
            for _, b in ipairs(s.banners or {}) do b.setText(text) end
        end

        local function countdownText(remaining)
            return ctx.t("banner.countdown",
                "No activity -- display turns off in %ds. Move the mouse to cancel.",
                remaining)
        end

        -- Back to square one: no warning showing, nothing dimmed.
        local function rearm()
            clearBanners()
            s.warnedAt = nil
            s.dimmed   = false
        end

        local function check()
            -- Something is deliberately holding the display awake (video, call,
            -- presentation, screen share). Idle time is meaningless here: the user
            -- IS present, just not typing. Stand down and re-arm.
            local heldBy = ctx.displaySleepPrevented()
            if heldBy then
                if s.heldBy ~= heldBy then              -- log the transition, not every poll
                    ctx.log("display held awake by " .. heldBy .. " -- standing down")
                    s.heldBy = heldBy
                end
                rearm()
                return
            end
            if s.heldBy then
                ctx.log("display no longer held awake (was " .. s.heldBy .. ")")
                s.heldBy = nil
            end

            local idle      = ctx.idleSeconds()
            local threshold = ctx.opt("idleThresholdMin") * 60

            -- Active (or just woke): re-arm.
            if idle < threshold then
                -- Only a countdown still RUNNING was cancelled. After the display
                -- actually slept, warnedAt is still set, and logging "cancelled"
                -- there would describe a countdown that had already completed --
                -- a lie in the one trace a live bug has to be diagnosed from.
                if s.warnedAt and not s.dimmed then
                    ctx.log("activity during countdown -- cancelled")
                end
                rearm()
                return
            end

            local warnSeconds = ctx.opt("warnSeconds")

            -- First tick past the threshold: start the countdown.
            if not s.warnedAt then
                s.warnedAt = ctx.now()
                showBanners(countdownText(warnSeconds))
                ctx.log("idle warning at " .. math.floor(idle) .. "s, "
                    .. warnSeconds .. "s countdown")
                return
            end

            local remaining = warnSeconds - (ctx.now() - s.warnedAt)
            if remaining > 0 then
                setBannerText(countdownText(math.ceil(remaining)))
                return
            end

            -- Countdown elapsed: sleep the display once.
            if not s.dimmed then
                clearBanners()
                ctx.displaySleep()
                ctx.log("display off at " .. math.floor(idle) .. "s idle")
                s.dimmed = true
            end
        end

        ctx.everySeconds(POLL_INTERVAL, check)
        -- An armed countdown measures against the WALL CLOCK, so a sleep/wake
        -- gap that straddles it leaves `remaining` hugely negative and the very
        -- first tick after waking blanks the screen the user just woke against
        -- a countdown that expired hours ago. sleep_schedule hooks the same two
        -- events for the same reason; nothing about a fresh wake should inherit
        -- the idle state that preceded it.
        local function onWake()
            if s.warnedAt or s.dimmed then ctx.log("wake -- dropping the armed countdown") end
            rearm()
        end
        ctx.onSystemEvent("wake", onWake)
        ctx.onSystemEvent("screenUnlock", onWake)
        ctx.log("started")
    end,
}
