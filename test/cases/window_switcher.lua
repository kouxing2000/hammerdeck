-- test/cases/window_switcher.lua -- window_switcher (list windows, preselect the
-- previous, cycle on repeat, backward-wrap, rich subtext) AND its no-windows
-- onboarding (the Accessibility grant prompt vs a plain "No windows" message).
--
-- Migrated from run.lua T3 + T21 (RUN_LUA_SPLIT_SPEC Phase 2). Both were
-- window_switcher behavior that leaned on T1's all-manifests registration; the case
-- registers its own copy. The two blocks keep their own enable/disable cycles
-- verbatim (so the disable-frees-handles assertions survive); freshWorld() + the
-- handle tripwire keep the whole case isolated.

return {
    id = "window_switcher",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry
        registry.register(require("features.window_switcher"))

        -- happy path: open, list, preselect, cycle, pick.
        fake.windows = {
            { id = 11, title = "Current Window",  appName = "AppA", bundleID = "com.a" },
            { id = 22, title = "Previous Window", appName = "AppB", bundleID = "com.b" },
            { id = 33, title = "Older Window",    appName = "AppC", bundleID = "com.c" },
        }
        registry.setEnabled("window_switcher", true)
        fake.pressHotkey("tab")
        local ch = fake.visibleChooser()
        ok(ch ~= nil, "window_switcher opened a chooser")
        ok(#ch.choices == 3, "chooser lists all windows")
        ok(ch.selectedRow == 2, "chooser preselects the previous window")
        ok(ch.choices[1].image == "icon:com.a", "choices carry app icons")
        ok(ch.title == "Switch Window" and ch.titleSymbol == "macwindow.on.rectangle"
            and ch.titleBadge == "3 windows",
            "header carries title, glyph symbol, and live count badge")
        ch.userSelect(2)
        ok(fake.focused[#fake.focused] == 22, "selecting focuses the chosen window")

        -- repeat-invocation cycling, release modifier to pick
        fake.pressHotkey("tab")                        -- reopen (row 2)
        fake.pressHotkey("tab")                        -- cycle -> row 3
        ch = fake.visibleChooser()
        ok(ch.selectedRow == 3, "second invoke cycles the selection")
        fake.modifiers.alt = false
        fake.fireTimers("every", 0.1)                  -- modifier poll sees release
        ok(fake.focused[#fake.focused] == 33, "releasing the modifier picks the row")

        -- backward cycling (the donor's alt+`): wraps at the top
        fake.modifiers.alt = true
        fake.pressHotkey("tab")                        -- reopen (row 2)
        fake.pressHotkey("`")                          -- backward -> row 1
        ch = fake.visibleChooser()
        ok(ch.selectedRow == 1, "backward action cycles up")
        fake.pressHotkey("`")                          -- backward from 1 -> wrap to last
        ok(ch.selectedRow == 3, "backward wraps to the bottom")
        fake.modifiers.alt = false
        fake.fireTimers("every", 0.1)
        ok(fake.focused[#fake.focused] == 33, "release still picks after backward cycling")

        -- subtext = browser tab count and/or screen name (app name dropped -- the icon
        -- carries it); screen name only when the display is reported (native reports it
        -- only on multi-display), tab count only for browser windows (native reports it
        -- only for them). Either may be absent; both nil collapses the row to one line.
        fake.windows = {
            { id = 11, title = "W1", appName = "AppA", bundleID = "com.a", screenName = "Studio Display", tabCount = 12 },
            { id = 22, title = "W2", appName = "AppB", bundleID = "com.b", tabCount = 1 },
            { id = 33, title = "W3", appName = "AppC", bundleID = "com.c", screenName = "Studio Display" },
            { id = 44, title = "W4", appName = "AppD", bundleID = "com.d" },
        }
        fake.modifiers.alt = true
        fake.pressHotkey("tab")
        ch = fake.visibleChooser()
        ok(ch.choices[1].subText == "12 tabs · Studio Display",
            "tab count and screen name join in the subtext when both reported")
        ok(ch.choices[2].subText == "1 tab",
            "tab count alone is the subtext (singular pluralization), no screen name")
        ok(ch.choices[3].subText == "Studio Display",
            "screen name alone is the subtext when there is no tab count")
        ok(ch.choices[4].subText == nil,
            "no tab count and no screen name collapses the row to one line")
        ch.userSelect(1)
        fake.modifiers.alt = false

        registry.setEnabled("window_switcher", false)
        ok(registry.liveHandleCount() == 0, "window_switcher disable left no live handles")

        -- no-windows onboarding (was T21): untrusted fires the AX grant prompt +
        -- explains; trusted-but-empty says "No windows" plainly and does not re-prompt.
        registry.setEnabled("window_switcher", true)
        fake.windows = {}

        fake.axTrusted = false
        local alertsBefore, promptsBefore = #fake.alerts, fake.axPrompts
        fake.pressHotkey("tab")
        ok(fake.axPrompts == promptsBefore + 1, "untrusted empty list fires the AX prompt")
        ok(#fake.alerts == alertsBefore + 1 and fake.alerts[#fake.alerts]:match("Accessibility"),
            "the alert explains the Accessibility grant")
        ok(fake.visibleChooser() == nil, "no chooser opens without windows")

        -- trusted but genuinely no windows: plain message, no prompt
        fake.axTrusted = true
        fake.pressHotkey("tab")
        ok(fake.axPrompts == promptsBefore + 1, "trusted empty list does not re-prompt")
        ok(fake.alerts[#fake.alerts]:match("No windows"), "trusted empty list says so plainly")

        registry.setEnabled("window_switcher", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after AX onboarding test")
    end,
}
