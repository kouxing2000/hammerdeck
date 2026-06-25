-- features/display_off
--
-- Turns the display off after a stretch of no input (ported from myHammerSpoon
-- modules/timers/idleDimmer.lua). Polls idle time; once past the threshold it
-- shows a one-time warning, then sleeps the display after a short lead time.
-- Any input wakes the display and re-arms the cycle. macOS still decides
-- whether to fully sleep based on active processes -- this only turns the
-- panel off.
--
-- (The donor was named "Dimmer" but it sleeps the display rather than dimming
-- brightness; the feature is named for what it does.)
--
-- SERVICE feature: the single poll timer goes through ctx, so disable tears it
-- down -- no stop() needed.

local POLL_INTERVAL = 5    -- seconds between idle checks
local WARN_SECONDS  = 10   -- warning lead time before the display sleeps

return {
    api         = 1,
    id          = "display_off",

    options = {
        { key = "idleThresholdMin", type = "int", default = 5,
          label = "Idle before display off (min)", min = 1, max = 60 },
    },

    -- Idle-triggered, not wall-clock: report as a condition (the Timeline lists
    -- it in the Events/conditions lane rather than on the 24h ruler).
    schedule = function(ctx)
        return {
            { label = "Turn off display", note = "after " .. ctx.opt("idleThresholdMin")
                .. "m idle", optionKey = "idleThresholdMin" },
        }
    end,

    start = function(ctx)
        local s = { warnedAt = nil, dimmed = false }

        local function check()
            local idle = ctx.idleSeconds()
            local threshold = ctx.opt("idleThresholdMin") * 60

            -- Active (or just woke): re-arm.
            if idle < threshold then
                s.warnedAt = nil
                s.dimmed = false
                return
            end

            -- First tick past the threshold: warn once.
            if not s.warnedAt then
                ctx.alert("No activity -- display turns off soon...")
                ctx.log("idle warning at " .. math.floor(idle) .. "s")
                s.warnedAt = ctx.now()
            end

            -- Lead time elapsed: sleep the display once.
            if not s.dimmed and (ctx.now() - s.warnedAt) >= WARN_SECONDS then
                ctx.displaySleep()
                ctx.log("display off at " .. math.floor(idle) .. "s idle")
                s.dimmed = true
            end
        end

        ctx.everySeconds(POLL_INTERVAL, check)
        ctx.log("started")
    end,
}
