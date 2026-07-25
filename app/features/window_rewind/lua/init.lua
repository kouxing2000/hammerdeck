-- features/window_rewind
--
-- Global, single-step "undo" for window LAYOUT changes -- the rollback for the one
-- cleanly-reversible thing a Hammerdeck action does (window moves are exact
-- inverses; wallpaper / typed text / destructive ops are not). While enabled it
-- records the before-frame of every window a snap, screen-swap, grid, or deck move
-- repositions (through the window_ops funnel), and Hyper+Z restores the most
-- recent change -- windows AND the pointer -- to where they were.
--
-- SERVICE + one action: start(ctx) turns recording on (so its cost is paid only
-- while the feature is enabled); the "undo" action fires the restore. It never
-- touches native / the stateful platform modules -- it reaches the history engine
-- only through the curated ctx.window.enableHistory / ctx.window.undoLast helpers.

local HYPER = { "cmd", "alt", "ctrl" }

return {
    api     = 1,
    id      = "window_rewind",
    options = {},

    -- Recording lives in window_history (a CORE peer of window_ops); gate it on the
    -- feature's own enabled-state so a disabled feature adds no per-move overhead.
    ---@param ctx Ctx
    start = function(ctx)
        ctx.window.enableHistory(true)
        ctx.log("window_rewind: enabled -- recording window layout changes")
    end,
    ---@param ctx Ctx
    stop = function(ctx)
        ctx.window.enableHistory(false)
        ctx.log("window_rewind: disabled -- window history cleared")
    end,

    actions = {
        {
            id    = "undo",
            label = "Undo last window change",
            description = "Restore every window to where it was before the most recent "
                .. "snap, screen-swap, grid, or layout move -- and bring the pointer back too.",
            defaultTrigger = { type = "hotkey", mods = HYPER, key = "z" },
            mnemonic = "Hyper+Z -- Z is the universal undo key",
            -- Reads the live layout + history; firing it unattended (schedule/event)
            -- is meaningless, so it stays manual-only.
            automatable = false,
            ---@param ctx Ctx
            run = function(ctx)
                -- Undo needs Accessibility to list and move windows; without it there
                -- is nothing to restore, so onboard rather than report "nothing to undo".
                if not ctx.axTrusted() then
                    ctx.axPrompt()
                    ctx.alert(
                        ctx.t("window.axRequired",
                            "%1$s needs the Accessibility permission -- grant %2$s in System Settings, then try again", "Window Rewind", ctx.appName))
                    return
                end
                local n = ctx.window.undoLast()
                if n > 0 then
                    ctx.confirmAction(
                        ctx.plural("flash.restored", n,
                            { one = "Restored %d window", other = "Restored %d windows" }, n))
                    ctx.log("window_rewind: undo -- restored " .. n .. " window(s)")
                else
                    ctx.confirmAction(ctx.t("flash.nothing", "Nothing to undo"))
                    ctx.log("window_rewind: undo -- nothing to undo")
                end
            end,
        },
    },
}
