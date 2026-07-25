-- features/break_reminder
--
-- Rest-eyes reminder with idle awareness (ported from the author's prior
-- Hammerspoon config). After a work interval, shows a rest dialog
-- (postpone / screensaver / lock / sleep). Going idle pauses the cycle; going
-- idle WHILE the dialog is open counts as the rest having been taken. Daily
-- work-time stats persist across restarts. Lock/sleep pauses; unlock/wake
-- restarts a fresh cycle.
--
-- SERVICE feature: all timers/watchers/dialogs go through ctx (scoped
-- teardown); stop() is not needed.

local MAX_SHOW_RETRIES = 10   -- delay the dialog while the user is mid-input

local function round(x) return math.floor(x + 0.5) end

local function durationInfo(secs)
    local h = math.floor(secs / 3600)
    local m = round((secs % 3600) / 60)
    if h > 0 then return h .. "h " .. m .. "m" end
    return m .. "m"
end

return {
    api         = 1,
    id          = "break_reminder",

    options = {
        { key = "workMin",             type = "int", default = 25, label = "Work interval (min)", min = 5, max = 90 },
        { key = "idleThresholdMin",    type = "int", default = 5,  label = "Idle pause threshold (min)", min = 1, max = 30 },
        { key = "dialogIdleDismissMin", type = "int", default = 2, label = "Idle during dialog counts as rest (min)", min = 1, max = 10 },
    },

    -- Self-report the recurring break for the Automation Timeline. The interval
    -- is the live `workMin` option, so editing it from the Timeline (optionKey)
    -- reschedules the real break.
    schedule = function(ctx)
        return {
            { label = "Take a break", everyMin = ctx.opt("workMin"), optionKey = "workMin" },
            { label = "Pauses after idle", note = "paused after "
                .. ctx.opt("idleThresholdMin") .. "m idle", optionKey = "idleThresholdMin" },
        }
    end,

    start = function(ctx)
        local persistedStamp = ctx.getState("lastStartWorkTimestamp")
        local s = {
            restTimer = nil,            -- one-shot to the next rest dialog
            retryTimer = nil,           -- "user is busy" delay loop
            dialog = nil,               -- the open rest dialog handle
            showingRestOption = false,  -- dialog open or retry loop running
            idleDismissed = false,      -- dialog auto-dismissed because user idle
            showRetryCount = 0,
            systemLocked = false,
            lastStartTime = 0,          -- last full-interval timer start
            startingTimer = false,      -- reentrancy guard
            lastTimerStartStamp = 0,    -- throttle guard
            workSeconds = tonumber(ctx.getState("workSeconds", 0)) or 0,
            lastStartWorkStamp = tonumber(persistedStamp) or ctx.now(),
        }
        -- First ever run: persist the stamp immediately. Without this, a
        -- restart reads "nil -> now" and the time-jump repair below clamps
        -- the whole day's persisted stats down to time-since-restart.
        if persistedStamp == nil then
            ctx.setState("lastStartWorkTimestamp", s.lastStartWorkStamp)
        end

        local function workSecondsTarget() return ctx.opt("workMin") * 60 end

        local startRestTimer        -- forward decls (mutually recursive)
        local showUserRestOption

        local function stopCycleTimers()
            if s.restTimer then s.restTimer.stop(); s.restTimer = nil end
            if s.retryTimer then s.retryTimer.stop(); s.retryTimer = nil end
            -- stop(), NOT dismiss(): dismiss fires onChoose(nil), which
            -- defaults to "postpone 1 minute" and would resurrect the cycle
            -- (e.g. popping the dialog under the lock screen). The only path
            -- that wants the callback is the idle-dismiss in checkIdle.
            if s.dialog then s.dialog.stop(); s.dialog = nil end
            s.showingRestOption = false
            s.idleDismissed = false
            s.showRetryCount = 0
        end

        -- announce: post the "rest eyes in N minutes" notification. Only
        -- session boundaries (enable, wake/unlock) announce -- repeating it
        -- on every mid-session cycle restart was noise.
        startRestTimer = function(seconds, isPostpone, announce)
            if s.systemLocked then
                ctx.log("startRestTimer: locked, skipping")
                return
            end
            seconds = seconds or workSecondsTarget()
            isPostpone = isPostpone or false
            local now = ctx.now()

            -- Reentrancy guard (dialog dismissal callbacks can re-enter here).
            if s.startingTimer then
                ctx.log("startRestTimer: skipping reentrant call")
                return
            end
            -- Throttle: block starts within 2s of the last one.
            if now - s.lastTimerStartStamp < 2 then
                ctx.log("startRestTimer: skipping too-soon call")
                return
            end
            -- Prevent overlapping full starts.
            if s.restTimer ~= nil and now - s.lastStartTime < 15 then
                ctx.log("startRestTimer: previous start too close, timer exists")
                return
            end

            s.startingTimer = true
            s.lastTimerStartStamp = now

            stopCycleTimers()

            if not isPostpone then
                if announce then
                    ctx.notify(
                        ctx.t("notify.rest.title", "Rest eyes in %d minutes", round(seconds / 60)),
                        ctx.t("notify.rest.body", "Rest at %s", os.date("%X", now + seconds)))
                end
                s.lastStartTime = now
            end

            s.restTimer = ctx.afterSeconds(seconds, showUserRestOption)
            ctx.log("rest timer started for " .. seconds .. "s")
            s.startingTimer = false
        end

        local function showRestDialog()
            local now = ctx.now()
            local workedMin = round((now - s.lastStartTime) / 60)
            local headline = ctx.t("alert.worked", "You have worked %d minutes!", workedMin)
            ctx.alert(headline)

            -- Repair stats after system-time jumps.
            if s.workSeconds > now - s.lastStartWorkStamp then
                s.workSeconds = now - s.lastStartWorkStamp
                ctx.setState("workSeconds", s.workSeconds)
            end

            -- Localized action labels, computed once -- DISPLAY only. Dispatch
            -- below is on each row's stable `id`, so the translated text and the
            -- branch that acts on it are fully decoupled (CODE-12): a retitled or
            -- newly-interpolated label can no longer silently stop matching.
            local L = {
                postpone1   = ctx.t("action.postpone1", "postpone 1 minute"),
                postpone5   = ctx.t("action.postpone5", "postpone 5 minutes"),
                screensaver = ctx.t("action.screensaver", "Start Screensaver"),
                lock        = ctx.t("action.lock", "Lock Screen"),
                sleep       = ctx.t("action.sleep", "System Sleep"),
            }

            s.dialog = ctx.askChoice {
                title = headline .. ctx.t("dialog.timeToRest", " Time to rest"),
                infos = {
                    ctx.t("info.workedToday", "Worked today: %s", durationInfo(s.workSeconds)),
                    ctx.t("info.elapsedToday", "Elapsed today: %s", durationInfo(now - s.lastStartWorkStamp)),
                },
                actions = {
                    { id = "postpone1",   label = L.postpone1,   icon = "symbol:clock" },
                    { id = "postpone5",   label = L.postpone5,   icon = "symbol:clock.arrow.circlepath" },
                    { id = "screensaver", label = L.screensaver, icon = "symbol:moon.stars" },
                    { id = "lock",        label = L.lock,        icon = "symbol:lock" },
                    { id = "sleep",       label = L.sleep,       icon = "symbol:powersleep" },
                },
                onChoose = function(choice)
                    s.dialog = nil
                    s.showingRestOption = false

                    -- Auto-dismissed because the user went idle with the dialog
                    -- open: the break was taken; start a fresh full cycle.
                    if s.idleDismissed then
                        s.idleDismissed = false
                        ctx.log("dialog auto-dismissed (user idle = resting); fresh timer")
                        startRestTimer()
                        return
                    end

                    -- Dismissed without choosing: treat as the gentlest option
                    -- and say so. (The alert shows the LABEL; the branch below
                    -- runs off the id.)
                    if choice == nil then
                        choice = "postpone1"
                        ctx.alert(L.postpone1)
                    end

                    ctx.log("rest dialog chose: " .. tostring(choice))
                    if choice == "lock" then
                        ctx.lockScreen()
                    elseif choice == "screensaver" then
                        ctx.startScreensaver()
                    elseif choice == "sleep" then
                        ctx.systemSleep()
                    elseif choice == "postpone1" then
                        startRestTimer(60, true)
                    elseif choice == "postpone5" then
                        startRestTimer(5 * 60, true)
                    end
                end,
            }
        end

        showUserRestOption = function()
            s.showingRestOption = true
            -- Don't interrupt active typing; retry shortly, bounded.
            if ctx.idleSeconds() > 2 or s.showRetryCount >= MAX_SHOW_RETRIES then
                if s.showRetryCount >= MAX_SHOW_RETRIES then
                    ctx.log("max retries reached, showing rest dialog anyway")
                end
                s.showRetryCount = 0
                showRestDialog()
            else
                s.showRetryCount = s.showRetryCount + 1
                ctx.log("user busy, delaying rest dialog (retry " .. s.showRetryCount .. ")")
                s.retryTimer = ctx.afterSeconds(3, showUserRestOption)
            end
        end

        local function checkIdle()
            if s.systemLocked then return end

            local idle = ctx.idleSeconds()

            -- Dialog open + user idle = the break is being taken.
            if s.dialog ~= nil and idle > ctx.opt("dialogIdleDismissMin") * 60 then
                ctx.log("idle with dialog open; dismissing as rest taken")
                s.idleDismissed = true
                s.dialog.dismiss()
                return
            end

            if idle > ctx.opt("idleThresholdMin") * 60 then
                if s.restTimer then
                    ctx.log("idle detected, pausing cycle")
                    stopCycleTimers()
                end
                return
            end

            -- Active: maintain daily stats.
            local now = ctx.now()
            local nowD, lastD = os.date("*t", now), os.date("*t", s.lastStartWorkStamp)
            if nowD.year ~= lastD.year or nowD.yday ~= lastD.yday then
                ctx.log("new day, resetting work stats")
                s.lastStartWorkStamp = now
                s.workSeconds = 0
                ctx.setState("lastStartWorkTimestamp", s.lastStartWorkStamp)
            end
            s.workSeconds = s.workSeconds + 5
            ctx.setState("workSeconds", s.workSeconds)

            if s.restTimer == nil and not s.showingRestOption then
                ctx.log("active with no timer, starting cycle")
                startRestTimer()
            end
        end

        local function onLocked()
            if s.systemLocked then return end
            ctx.log("lock/sleep, pausing")
            -- Set BEFORE stopping: dialog teardown must not restart the cycle.
            s.systemLocked = true
            stopCycleTimers()
        end
        local function onUnlocked()
            if not s.systemLocked then return end
            ctx.log("unlock/wake, fresh cycle")
            s.systemLocked = false
            startRestTimer(nil, false, true)
        end
        ctx.onSystemEvent("screenLock", onLocked)
        ctx.onSystemEvent("sleep", onLocked)
        ctx.onSystemEvent("screenUnlock", onUnlocked)
        ctx.onSystemEvent("wake", onUnlocked)

        startRestTimer(nil, false, true)
        ctx.everySeconds(5, checkIdle)
    end,
}
