-- features/window_switcher
--
-- Alt-Tab replacement: searchable window switcher ordered by focus recency
-- (ported from the author's prior Hammerspoon config). Invoke once to
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

-- 1-based index of the screen whose VISIBLE frame contains point (cx, cy), or
-- nil (a minimized / off-screen window can map to none). `screens` are
-- ctx.screen.frames() rows in index order, so the array position IS the index.
local function screenIndexAt(screens, cx, cy)
    for i, s in ipairs(screens) do
        if cx >= s.x and cx < s.x + s.w and cy >= s.y and cy < s.y + s.h then
            return i
        end
    end
    return nil
end

-- Cross-screen arrival cue: when the picked window lives on a DIFFERENT display
-- than the one that currently has focus, pulse an accent border (grown from an
-- inset -> the full screen) around the destination screen so the eye knows
-- where to look before the window fronts. Multi-display only. Reuses the
-- outline overlay -- the same primitive as Auto Stack's rings -- so it floats
-- above every app's windows and needs no z-reordering; afterSeconds tears it
-- down. The handles live on `st` so a rapid second pick replaces the prior
-- pulse instead of leaking a second overlay.
local function pulseScreen(ctx, st, frame)
    if st.screenGlow then st.screenGlow.stop() end
    if st.glowTimer then st.glowTimer.stop() end
    local o = ctx.outline("hero")          -- bold, system-accent border
    o.setFilled(true)                      -- + a soft tint that reads as a flash
    local inset = 48
    o.setFrame({ x = frame.x + inset, y = frame.y + inset,
                 w = frame.w - 2 * inset, h = frame.h - 2 * inset })
    o.animateFrame(frame, 0.16)            -- grow to the screen edge == a pulse
    st.screenGlow = o
    st.glowTimer = ctx.afterSeconds(0.5, function()
        if st.screenGlow then st.screenGlow.stop(); st.screenGlow = nil end
        st.glowTimer = nil
    end)
    ctx.log("cross-screen switch -- pulsed destination screen "
        .. tostring(frame.index) .. " (" .. tostring(frame.name) .. ")")
end

local function jump(ctx, actionId, backward)
    -- Per-enable state, memoized on the ctx (shared across both actions).
    local st = ctx.perEnable(function() return { chooser = nil, altTimer = nil } end)

    if not st.chooser then
        st.chooser = ctx.chooser {
            searchSubText = true,
            onHide = function() cyclingChooser.stop(st) end,
            onSelect = function(choice)
                cyclingChooser.stop(st)
                if not choice then return end
                -- Highlight the destination display first when it is NOT the one
                -- the focused window is already on (multi-display only).
                if st.screens and #st.screens > 1 and st.sourceScreen
                    and choice.screenIndex and choice.screenIndex ~= st.sourceScreen then
                    pulseScreen(ctx, st, st.screens[choice.screenIndex])
                end
                ctx.window.focus(choice.id)
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
            and ctx.t("chooser.release", "Release %s to switch", mod)
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
                ctx.alert(ctx.t("alert.axRequired",
                    "Window Jump needs the Accessibility permission -- enable %s under System Settings > Privacy & Security > Accessibility, then try again", ctx.appName))
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
        -- Screen geometry for the cross-screen arrival cue (multi-display only).
        -- Source = the screen the currently-focused window is on; windows[1] is
        -- the front (z-ordered) window, i.e. the one that has focus right now.
        local screens = ctx.screen.frames()
        st.screens = screens
        st.sourceScreen = (#screens > 1 and windows[1])
            and screenIndexAt(screens, windows[1].x + windows[1].w / 2,
                              windows[1].y + windows[1].h / 2)
            or nil

        local choices = {}
        for _, w in ipairs(windows) do
            local parts = {}
            -- `> 0` guards the seam: 0 is truthy in Lua, so a future native
            -- change that emitted 0 would otherwise render "0 tabs".
            if w.tabCount and w.tabCount > 0 then
                parts[#parts + 1] = ctx.plural("chooser.tabs", w.tabCount,
                    { one = "%d tab", other = "%d tabs" }, w.tabCount)
            end
            if w.screenName then parts[#parts + 1] = w.screenName end
            choices[#choices + 1] = {
                text = w.title,
                subText = parts[1] and table.concat(parts, " · ") or nil,
                image = w.icon or ctx.appIcon(w.bundleID),
                id = w.id,
                screenIndex = (#screens > 1)
                    and screenIndexAt(screens, w.x + w.w / 2, w.y + w.h / 2) or nil,
            }
        end
        st.lastChoices = choices
        local count = #choices
        st.chooser.setTitle(ctx.t("chooser.title", "Switch Window"), "macwindow.on.rectangle",
            ctx.plural("chooser.count", count,
                { one = "%d window", other = "%d windows" }, count))
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
        { id = "main", label = "Switch to a window", icon = "macwindow.on.rectangle",
          description = "Open the window switcher, or cycle forward through windows "
              .. "when it is already open.",
          defaultTrigger = { type = "hotkey", mods = { "alt" }, key = "tab" },
          mnemonic = "⌥Tab — mirrors ⌘Tab, but for windows",
          run = function(ctx) jump(ctx, "main", false) end },
        { id = "open_backward", label = "Cycle backward", icon = "arrow.uturn.backward",
          description = "Open the window switcher, or cycle backward through windows "
              .. "when it is already open.",
          defaultTrigger = { type = "hotkey", mods = { "alt" }, key = "`" },
          mnemonic = "⌥` steps backward (like ⌘`)",
          run = function(ctx) jump(ctx, "open_backward", true) end },
    },
}
