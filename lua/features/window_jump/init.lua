-- features/window_jump
--
-- Alt-Tab replacement: searchable window switcher ordered by focus recency
-- (ported from myHammerSpoon modules/window/windowsJumper.lua). Invoke once to
-- open; invoke again while open to cycle; release the cycle modifier to pick.
--
-- ACTION feature: the registry binds defaultTrigger -> action. The chooser is
-- kept across invocations (per enablement) for the cycling UX.
--
-- Deliberately NOT ported from the donor (deferred): browser favicon
-- composites and URL-domain subtext (modules/core/favicon.lua + osascript) --
-- app icons only for the MVP. Backward cycling needs a second trigger; the
-- single-trigger contract can't express it yet (see PLUGIN_SYSTEM.md).

return {
    api         = 1,
    id          = "window_jump",
    name        = "Window Jump",
    description = "Searchable Alt-Tab: switch windows across all apps, "
        .. "most recently used first.",
    version     = "1.0.0",
    category    = "productivity",

    options = {
        { key = "cycleModifier", type = "enum", default = "alt",
          values = { "alt", "cmd", "ctrl" },
          label = "Modifier to hold while cycling" },
    },

    defaultTrigger = { type = "hotkey", mods = { "alt" }, key = "tab" },

    action = (function()
        -- Closure state shared across invocations; rebuilt when ctx changes
        -- (i.e. after a disable -> enable cycle invalidated the old handles).
        local st = nil

        return function(ctx)
            if not st or st.ctx ~= ctx then
                st = { ctx = ctx, chooser = nil, altTimer = nil }
            end

            local function stopAltTimer()
                if st.altTimer then st.altTimer.stop(); st.altTimer = nil end
            end

            if not st.chooser then
                st.chooser = ctx.chooser {
                    searchSubText = true,
                    onHide = function() stopAltTimer() end,
                    onSelect = function(choice)
                        stopAltTimer()
                        if choice then ctx.focusWindow(choice.id) end
                    end,
                }
            end

            if st.chooser.isVisible() then
                -- Repeat invocation while open: cycle selection. Wrap against
                -- the VISIBLE rows (a search query may have filtered the
                -- list): the chooser rejects an out-of-range row, which we
                -- detect to wrap back to the top.
                st.chooser.setPlaceholder("Release " .. ctx.opt("cycleModifier") .. " to switch")
                local row = st.chooser.getSelectedRow() + 1
                st.chooser.setSelectedRow(row)
                if st.chooser.getSelectedRow() ~= row then
                    st.chooser.setSelectedRow(1)
                end

                -- Release-to-pick: poll the cycle modifier.
                if not st.altTimer then
                    st.altTimer = ctx.everySeconds(0.1, function()
                        if not ctx.isModifierHeld(ctx.opt("cycleModifier")) then
                            stopAltTimer()
                            st.chooser.select(st.chooser.getSelectedRow())
                        end
                    end)
                end
            else
                local windows = ctx.listWindows()
                if #windows == 0 then
                    if not ctx.axTrusted() then
                        -- Accessibility onboarding: fire the system prompt and
                        -- explain; the user re-triggers once granted.
                        ctx.axPrompt()
                        ctx.alert("Window Jump needs the Accessibility permission "
                            .. "-- enable Hammerdeck under System Settings > "
                            .. "Privacy & Security > Accessibility, then try again")
                    else
                        ctx.alert("No windows to switch between")
                    end
                    return
                end
                local choices = {}
                for _, w in ipairs(windows) do
                    local sub = w.appName
                    if w.screenName then sub = sub .. " (" .. w.screenName .. ")" end
                    choices[#choices + 1] = {
                        text = w.title,
                        subText = sub,
                        image = ctx.appIcon(w.bundleID),
                        id = w.id,
                    }
                end
                st.chooser.setPlaceholder("Search windows")
                st.chooser.setChoices(choices)
                st.chooser.setQuery(nil)
                st.chooser.show()
                -- Row 1 is the currently-focused window; preselect the previous one.
                if #choices >= 2 then st.chooser.setSelectedRow(2) end
            end
        end
    end)(),
}
