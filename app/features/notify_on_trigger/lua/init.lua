-- features/notify_on_trigger
--
-- "Notify on Automated Run": a global preference. When enabled, every time an
-- action fires from an AUTOMATED trigger -- a schedule or a system event, the
-- context-free triggers that fire with nobody at the keyboard -- the platform
-- shows a brief toast naming the feature, so an unattended run is VISIBLE
-- instead of silent. Manual triggers (hotkey / chord) and menubar / palette runs
-- never notify: you initiated those, so echoing them back would be pure noise.
--
-- Like pointer_follows_window, this feature has NO runtime of its own: its
-- enabled-state IS the toggle. The registry reads it at the single trigger-fire
-- chokepoint (bindAction -> notifyAutomatedFire), so one toggle covers every
-- feature's automated triggers with no per-feature code, and any feature that
-- later gains a schedule/event trigger is announced automatically.
--
-- Scope note: this rides the ACTION trigger path only. A SERVICE that runs its
-- own internal cadence (ctx.everySeconds / dailyAt -- e.g. sleep_schedule's
-- poll) is invisible to the trigger model, so it does not notify here; such a
-- feature announces its own moments via ctx.notify when it wants to.

return {
    api   = 1,
    id    = "notify_on_trigger",

    -- A pure toggle: enabling it flips notification on at the trigger-fire seam.
    -- No timers, watchers, or hotkeys -- start() is just a breadcrumb in the log.
    ---@param ctx Ctx
    start = function(ctx)
        ctx.log("active -- automated runs will show a notification")
    end,
}
