-- features/count_down
--
-- Visual countdown timer (ported from the CountDown spoon + the donor's
-- init.lua wiring): invoke, type the minutes, and a thin progress strip runs
-- along the bottom of the screen; a notification fires when time is up.
--
-- MULTI-ACTION feature (the first one): "start" prompts/cancels and "pause"
-- pause/resumes are sibling CHORDS under one prefix -- Hyper+C then C starts/
-- cancels, Hyper+C then P pauses/resumes -- exactly the contract's
-- any-trigger-any-action idea (each rebindable in Settings).
--
-- Donor deviation: invoking start while a countdown runs CANCELS it (alert),
-- instead of the spoon's finish-early-with-"time is up" notification -- saying
-- time is up when the user aborted was a lie.

---A minute count as a person would write it: "5", not "5.0"; "2.5" stays "2.5".
---@param m number
---@return string
local function showMinutes(m)
    if m % 1 == 0 then return string.format("%d", m) end
    return (string.format("%.2f", m):gsub("0+$", ""):gsub("%.$", ""))
end

return {
    api         = 1,
    id          = "count_down",

    options = {
        { key = "defaultMinutes", type = "int", default = 5,
          label = "Suggested minutes", min = 1, max = 480 },
    },

    actions = (function()
        -- Per-enable state shared across both actions (ctx.perEnable memoizes it
        -- on the ctx). Keeps `ctx` in the state -- the timer/bar callbacks call
        -- s.ctx.* long after the action returns.
        ---@param ctx Ctx
        local function ensure(ctx)
            return ctx.perEnable(function(ctx) return { ctx = ctx } end)
        end

        local function cancel(s)
            if s.timer then s.timer.stop(); s.timer = nil end
            if s.bar then s.bar.stop(); s.bar = nil end
            s.paused = false
            s.total, s.elapsed, s.minutes = nil, nil, nil
        end

        local function startTicking(s)
            s.timer = s.ctx.everySeconds(1, function()
                s.elapsed = s.elapsed + 1
                if s.elapsed >= s.total then
                    local minutes = s.minutes
                    local ctx = s.ctx
                    cancel(s)
                    -- %s, not %d: the prompt accepts "2.5" (a legitimate
                    -- 150-second timer), and Lua 5.4's %d RAISES on a
                    -- non-integer. i18n.safeFormat caught the raise and fell
                    -- back to the same English template, which failed the same
                    -- way -- so the notification read literally
                    -- "Time (%d min) is up!". Format the number here, where the
                    -- integer case can keep its clean "5" instead of "5.0".
                    ctx.notify(ctx.t("notify.up.title", "Time (%s min) is up!", showMinutes(minutes)),
                        ctx.t("notify.up.body", "Now is %s", os.date("%X", ctx.now())))
                else
                    s.bar.setProgress(s.elapsed / s.total)
                end
            end)
        end

        local function beginCountdown(s, minutes)
            s.minutes = minutes
            s.total = math.ceil(minutes * 60)
            s.elapsed = 0
            s.bar = s.ctx.progressBar()
            s.paused = false
            startTicking(s)
            s.ctx.log("countdown started for " .. minutes .. " min")
        end

        return {
            {
                id = "start", label = "Start / cancel countdown", icon = "play.fill",
                description = "Prompt for minutes and start the countdown, or "
                    .. "cancel the one already running.",
                defaultTrigger = { type = "chord", mods = { "cmd", "alt", "ctrl" }, key = "c", follows = { "c" } },
                mnemonic = "C for Countdown (Hyper+C, then C)",
                ---@param ctx Ctx
                run = function(ctx)
                    local s = ensure(ctx)
                    if s.timer or s.paused then
                        cancel(s)
                        ctx.alert(ctx.t("alert.cancelled", "Countdown cancelled"))
                        return
                    end
                    if s.prompt then return end   -- prompt already open
                    s.prompt = ctx.askText {
                        title = ctx.t("prompt.minutes.title", "Count down for how many minutes?"),
                        placeholder = ctx.t("prompt.minutes.ph", "minutes"),
                        default = tostring(ctx.opt("defaultMinutes")),
                        onSubmit = function(text)
                            s.prompt = nil
                            local minutes = tonumber(text)
                            if minutes and minutes > 0 then
                                beginCountdown(s, minutes)
                            elseif text and text ~= "" then
                                ctx.alert(ctx.t("alert.nan", "Not a number of minutes: %s", text))
                            end
                        end,
                    }
                end,
            },
            {
                id = "pause", label = "Pause / resume", icon = "playpause.fill",
                description = "Pause the running countdown, or resume it if it is "
                    .. "already paused.",
                defaultTrigger = { type = "chord", mods = { "cmd", "alt", "ctrl" }, key = "c", follows = { "p" } },
                mnemonic = "P for Pause (same Hyper+C prefix)",
                ---@param ctx Ctx
                run = function(ctx)
                    local s = ensure(ctx)
                    if s.timer then
                        s.timer.stop(); s.timer = nil
                        s.paused = true
                        ctx.log("countdown paused")
                    elseif s.paused then
                        s.paused = false
                        startTicking(s)
                        ctx.log("countdown resumed")
                    end
                end,
            },
        }
    end)(),
}
