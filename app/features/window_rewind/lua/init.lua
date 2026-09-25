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

--- Restore the most recent layout change and report what happened.
---@param ctx Ctx
local function undo(ctx)
    local n, refused = ctx.window.undoLast()
    refused = refused or 0
    if n > 0 then
        ctx.confirmAction(
            ctx.plural("flash.restored", n,
                { one = "Restored %d window", other = "Restored %d windows" }, n))
    end
    if refused > 0 then
        -- An alert, not a confirmation: confirmAction is off unless the user opted
        -- into shortcut confirmations, and a window left stranded must be said
        -- whatever that preference is. The undo stays pending for these windows,
        -- so saying so is what makes the retry discoverable.
        ctx.alert(
            ctx.plural("alert.refused", refused,
                { one = "Couldn't move %d window back -- press again to retry",
                  other = "Couldn't move %d windows back -- press again to retry" }, refused))
    end
    if n > 0 or refused > 0 then
        ctx.log("window_rewind: undo -- restored " .. n .. " window(s)"
            .. (refused > 0 and (", " .. refused .. " refused and kept for a retry") or ""))
    else
        ctx.confirmAction(ctx.t("flash.nothing", "Nothing to undo"))
        ctx.log("window_rewind: undo -- nothing to undo")
    end
end

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
                -- A live window mode's own placements are in this same history (they
                -- ride ctx.window.setFrameFor), so an undo fired inside one rolls that
                -- mode's last beat back underneath it: the windows move, the mode's
                -- record of where they are does not. Whatever the last change touched
                -- may span displays, hence ANY_SCREEN.
                ctx.window.requestExclusive({ screen = ctx.window.ANY_SCREEN },
                    function() undo(ctx) end)
            end,
        },
    },
}
