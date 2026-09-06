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
-- code -- and any future focused-window mover inherits it automatically.
--
-- What it does NOT cover, deliberately: everything that places windows BY ID
-- through ctx.window.setFrameFor -- Window Deck, Window Fan, and the rules
-- engine's layout / move-to-display effects. A batch layout must never yank the
-- cursor to chase one of its members, so window_ops.setFrameFor writes without
-- the follow (it says so itself). The feature description names the same three
-- movers this covers; keep the two in step if either changes.
--
-- Why "when WE move it" and not the old app-switch "mouse follows focus": every
-- move here is one Hammerdeck performed, so the destination is known exactly
-- and the follow is reliable -- unlike guessing on fuzzy app-focus changes.

return {
    api         = 1,
    id          = "pointer_follows_window",

    -- A pure toggle: enabling it flips the behavior at the window-move seam.
    -- No timers, watchers, or hotkeys -- start/stop are just breadcrumbs. Both,
    -- not just start: a lone "active" line makes the log read as though the
    -- follow is still on long after the user turned it off, which is the one
    -- question this feature's log exists to answer.
    ---@param ctx Ctx
    start = function(ctx)
        ctx.log("active -- focused-window moves will carry the pointer")
    end,

    ---@param ctx Ctx
    stop = function(ctx)
        ctx.log("off -- window moves no longer carry the pointer")
    end,
}
