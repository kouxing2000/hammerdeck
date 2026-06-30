-- features/window_switcher
--
-- Alt-Tab replacement: searchable window switcher ordered by focus recency
-- (ported from myHammerSpoon modules/window/windowsJumper.lua). Invoke once to
-- open; invoke again while open to cycle (alt+` cycles backward, donor
-- parity); release the cycle modifier to pick. Window rows carry the screen
-- name on multi-display setups.
--
-- Deliberately NOT ported from the donor: browser favicon composites and
-- URL-domain subtext -- tab-level switching is tab_switcher's job now.

-- Release-to-pick watches the modifier of the hotkey that fired this action
-- (shared with tab_switcher; nil when fired without a hotkey -> pick on Enter).
local cycleModifier = require("platform.hotkeys").cycleModifier
-- Shared cycle-with-wrap + release-to-pick mechanics (also drives tab_switcher).
local cyclingChooser = require("platform.cyclingChooser")

local function jump(ctx, actionId, backward)
    -- Per-enable state, memoized on the ctx (shared across both actions).
    local st = ctx.perEnable(function() return { chooser = nil, altTimer = nil } end)

    if not st.chooser then
        st.chooser = ctx.chooser {
            searchSubText = true,
            onHide = function() cyclingChooser.stop(st) end,
            onSelect = function(choice)
                cyclingChooser.stop(st)
                if choice then ctx.window.focus(choice.id) end
            end,
        }
    end

    if st.chooser.isVisible() then
        -- Repeat invocation while open: cycle selection (either direction).
        -- Wrap against the VISIBLE rows (a search query may have filtered the
        -- list). Release-to-pick arms ONLY while cycling here (the switcher has
        -- no preview-on-open step); armRelease self-gates on the modifier.
        local mod = cycleModifier(ctx.actionTrigger(actionId))
        st.chooser.setPlaceholder(mod
            and string.format(ctx.t("chooser.release", "Release %s to switch"), mod)
            or ctx.t("chooser.pressEnter", "Press Enter to switch"))
        cyclingChooser.cycle(st.chooser, backward, #st.lastChoices)
        cyclingChooser.armRelease(ctx, st.chooser, st, mod)
    else
        local windows = ctx.window.list()
        if #windows == 0 then
            if not ctx.axTrusted() then
                -- Accessibility onboarding: fire the system prompt and
                -- explain; the user re-triggers once granted.
                ctx.axPrompt()
                ctx.alert(string.format(ctx.t("alert.axRequired",
                    "Window Jump needs the Accessibility permission -- enable %s under System Settings > Privacy & Security > Accessibility, then try again"),
                    ctx.appName))
            else
                ctx.alert(ctx.t("alert.noWindows", "No windows to switch between"))
            end
            return
        end
        -- Second line = tab count (browser windows only -- native reports
        -- w.tabCount just for them) and/or the display the window is on (ONLY on
        -- multi-display setups: native reports w.screenName only then). Either
        -- may be absent; when both are nil the subText collapses the row back to
        -- one line. The app name is dropped on purpose -- the leading icon
        -- already identifies the app.
        local choices = {}
        for _, w in ipairs(windows) do
            local parts = {}
            -- `> 0` guards the seam: 0 is truthy in Lua, so a future native
            -- change that emitted 0 would otherwise render "0 tabs".
            if w.tabCount and w.tabCount > 0 then
                parts[#parts + 1] = string.format(ctx.plural("chooser.tabs", w.tabCount,
                    { one = "%d tab", other = "%d tabs" }), w.tabCount)
            end
            if w.screenName then parts[#parts + 1] = w.screenName end
            choices[#choices + 1] = {
                text = w.title,
                subText = parts[1] and table.concat(parts, " · ") or nil,
                image = w.icon or ctx.appIcon(w.bundleID),
                id = w.id,
            }
        end
        st.lastChoices = choices
        local count = #choices
        st.chooser.setTitle(ctx.t("chooser.title", "Switch Window"), "macwindow.on.rectangle",
            string.format(ctx.plural("chooser.count", count,
                { one = "%d window", other = "%d windows" }), count))
        st.chooser.setPlaceholder(ctx.t("chooser.search", "Search windows"))
        st.chooser.setChoices(choices)
        st.chooser.setQuery(nil)
        st.chooser.show()
        -- Row 1 is the currently-focused window; preselect the previous one.
        if #choices >= 2 then st.chooser.setSelectedRow(2) end
    end
end

return {
    api         = 1,
    id          = "window_switcher",

    options = {},

    actions = {
        -- id "main" keeps pre-multi-action stored trigger keys valid.
        { id = "main", label = "Switch to a window",
          description = "Open the window switcher, or cycle forward through windows "
              .. "when it is already open.",
          defaultTrigger = { type = "hotkey", mods = { "alt" }, key = "tab" },
          mnemonic = "⌥Tab — mirrors ⌘Tab, but for windows",
          run = function(ctx) jump(ctx, "main", false) end },
        { id = "open_backward", label = "Cycle backward",
          description = "Open the window switcher, or cycle backward through windows "
              .. "when it is already open.",
          defaultTrigger = { type = "hotkey", mods = { "alt" }, key = "`" },
          mnemonic = "⌥` steps backward (like ⌘`)",
          run = function(ctx) jump(ctx, "open_backward", true) end },
    },
}
