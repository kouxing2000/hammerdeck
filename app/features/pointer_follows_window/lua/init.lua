-- features/pointer_follows_window
--
-- "Pointer Follows Moved Window": a global add-on for every window-movement
-- feature. When enabled, repositioning the focused window (window_snap to a
-- half/quarter, Window Mode nudge/throw, window_to_next_screen, ...) carries
-- the pointer along, preserving its RELATIVE position inside the window -- so
-- you never lose the cursor after a snap or a throw to another screen.
--
-- This feature has NO runtime of its own: its enabled-state is the toggle. The
-- actual follow happens at the single focused-window-move seam
-- (ctx.window.setFrame -> platform/window_ops.lua), which the registry wires to
-- read this feature's enabled-state (injected predicate, no magic key). One
-- toggle, every feature that moves the FOCUSED window benefits, no per-feature
-- code -- and any future focused-window mover inherits it automatically. (The
-- rules engine's by-id layout/move-to-display path is separate and intentionally
-- does NOT follow the pointer -- that would be wrong for a batch layout.)
--
-- Why "when WE move it" and not the old app-switch "mouse follows focus": every
-- move here is one Hammerdeck performed, so the destination is known exactly
-- and the follow is reliable -- unlike guessing on fuzzy app-focus changes.

return {
    api         = 1,
    id          = "pointer_follows_window",

    -- A pure toggle: enabling it flips the behavior at the window-move seam.
    -- No timers, watchers, or hotkeys -- start() is just a breadcrumb in the log.
    ---@param ctx Ctx
    start = function(ctx)
        ctx.log("active -- window moves will carry the pointer")
    end,
}
