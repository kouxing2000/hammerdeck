-- features/confirm_shortcut
--
-- "Confirm Shortcut Presses": a global preference. When enabled, firing a feature
-- with a MANUAL trigger (hotkey or chord) briefly flashes a quiet chip naming the
-- action that ran -- glyph + "Feature -- Action", top-center, single slot (a new
-- press replaces the last), fading on its own in ~1.4s. Two jobs: confirm the
-- press registered, and -- when you reach for a half-remembered shortcut -- show
-- WHICH action you actually triggered, so a wrong guess teaches instead of
-- silently doing the unexpected.
--
-- The quiet twin of notify_on_trigger: that one is for AUTOMATED runs you weren't
-- present for (a stacking top-right notification); this one is for runs you just
-- initiated (a single ephemeral flash). Independent toggles on purpose -- someone
-- learning the shortcuts may want this on and that off, or the reverse.
--
-- Like pointer_follows_window, this feature has NO runtime of its own: its
-- enabled-state IS the toggle, read at the single trigger-fire chokepoint
-- (registry bindAction -> flashManualFire), so one toggle covers every feature's
-- manual triggers with no per-feature code.

return {
    api   = 1,
    id    = "confirm_shortcut",

    -- A pure toggle: enabling it turns the flash on at the trigger-fire seam.
    -- No timers, watchers, or hotkeys -- start() is just a breadcrumb in the log.
    start = function(ctx)
        ctx.log("active -- manual shortcuts will flash what they fired")
    end,
}
