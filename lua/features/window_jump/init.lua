-- features/window_jump
--
-- Alt-Tab replacement: searchable window switcher ordered by focus recency
-- (ported from myHammerSpoon modules/window/windowsJumper.lua). Invoke once to
-- open; invoke again while open to cycle (alt+` cycles backward, donor
-- parity); release the cycle modifier to pick. Window rows carry the screen
-- name on multi-display setups.
--
-- Deliberately NOT ported from the donor: browser favicon composites and
-- URL-domain subtext -- tab-level switching is tabs_jumper's job now.

-- Closure state shared across invocations and BOTH actions; rebuilt when ctx
-- changes (a disable -> enable cycle invalidated the old handles).
local st = nil

-- Which modifier should release-to-pick watch? Derived from the firing
-- action's bound hotkey (no option to keep in sync with the trigger). nil
-- when the action has no hotkey (menubar fire) -- pick with Enter instead.
local MOD_PRIORITY = { "alt", "cmd", "ctrl", "shift" }
local function cycleModifier(ctx, actionId)
    local spec = ctx.actionTrigger(actionId)
    if not (spec and spec.type == "hotkey") then return nil end
    local has = {}
    for _, m in ipairs(spec.mods or {}) do has[m] = true end
    for _, m in ipairs(MOD_PRIORITY) do
        if has[m] then return m end
    end
    return nil
end

local function jump(ctx, actionId, backward)
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
        -- Repeat invocation while open: cycle selection (either direction).
        -- Wrap against the VISIBLE rows (a search query may have filtered
        -- the list): the chooser rejects an out-of-range row, which we
        -- detect to wrap around.
        local mod = cycleModifier(ctx, actionId)
        st.chooser.setPlaceholder(mod and ("Release " .. mod .. " to switch")
            or "Press Enter to switch")
        local row = st.chooser.getSelectedRow() + (backward and -1 or 1)
        st.chooser.setSelectedRow(row)
        if st.chooser.getSelectedRow() ~= row then
            st.chooser.setSelectedRow(backward and #st.lastChoices or 1)
        end

        -- Release-to-pick: poll the cycle modifier (when there is one).
        if mod and not st.altTimer then
            st.altTimer = ctx.everySeconds(0.1, function()
                if not ctx.isModifierHeld(mod) then
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
        st.lastChoices = choices
        st.chooser.setPlaceholder("Search windows")
        st.chooser.setChoices(choices)
        st.chooser.setQuery(nil)
        st.chooser.show()
        -- Row 1 is the currently-focused window; preselect the previous one.
        if #choices >= 2 then st.chooser.setSelectedRow(2) end
    end
end

return {
    api         = 1,
    id          = "window_jump",
    name        = "Window Jump",
    description = "Searchable Alt-Tab: switch windows across all apps, "
        .. "most recently used first.",
    version     = "1.2.0",
    category    = "productivity",

    options = {},

    actions = {
        -- id "main" keeps pre-multi-action stored trigger keys valid.
        { id = "main", label = "Jump to a window",
          defaultTrigger = { type = "hotkey", mods = { "alt" }, key = "tab" },
          run = function(ctx) jump(ctx, "main", false) end },
        { id = "open_backward", label = "Cycle backward",
          defaultTrigger = { type = "hotkey", mods = { "alt" }, key = "`" },
          run = function(ctx) jump(ctx, "open_backward", true) end },
    },
}
