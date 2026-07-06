-- test/cases/window_modal.lua -- window_modal: a modal hotkey group (Hyper+W enters
-- "Window Mode": a HUD legend up, bare keys live until Escape/toggle) that step-moves,
-- half/quadrant-snaps, resizes, centers, expands, undo/redo, and throws the focused
-- window across screens over the frame surface. Covers enter/exit/toggle and that a
-- mid-mode disable tears everything down with no leak.
--
-- Migrated from run.lua T25 (RUN_LUA_SPLIT_SPEC Phase 2). Hermetic: registers its own
-- feature and seeds its own screens + focused window; freshWorld() before + handle
-- tripwire after keep it isolated. Dropped the monolith's vacuous `ok(... == nil or
-- true, "noop guard")` line (always truthy -- asserts nothing; the same dead-assertion
-- smell the reviewer flagged in tab_switcher).

return {
    id = "window_modal",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        registry.register(require("features.window_modal"))
        registry.setEnabled("window_modal", true)
        fake.settings["hammerdeck.opt.window_modal.stepParts"] = 10   -- step = 100 x 80

        fake.screenList = {
            { x = 0, y = 0, w = 1000, h = 800 },
            { x = 1000, y = 0, w = 2000, h = 1200 },
        }
        fake.focusedWindow = { x = 200, y = 200, w = 400, h = 300, screenIndex = 1 }

        -- enter the mode: HUD up, bare keys live
        fake.pressHotkey("w", { "cmd", "alt", "ctrl" })
        ok(fake.liveHud() ~= nil and fake.liveHud().title == "Window Mode",
            "entering the mode shows the HUD")
        fake.pressHotkey("a", {})
        ok(fake.focusedWindow.x == 100, "A step-moves left by screen/stepParts")
        fake.pressHotkey("s", {})
        ok(fake.focusedWindow.y == 280, "S step-moves down")
        fake.pressHotkey("h", {})
        ok(fake.focusedWindow.w == 500 and fake.focusedWindow.h == 800 and fake.focusedWindow.x == 0,
            "H snaps the left half")
        fake.pressHotkey("i", {})
        ok(fake.focusedWindow.x == 500 and fake.focusedWindow.y == 400
            and fake.focusedWindow.w == 500 and fake.focusedWindow.h == 400,
            "I snaps the SE corner quadrant")
        fake.pressHotkey("l", { "shift" })
        ok(fake.focusedWindow.w == 600, "shift+L widens by one step")
        fake.pressHotkey("c", {})
        ok(fake.focusedWindow.x == 200 and fake.focusedWindow.y == 200,
            "C centers keeping the size")
        fake.pressHotkey("=", {})
        ok(fake.focusedWindow.x == 100 and fake.focusedWindow.w == 800
            and fake.focusedWindow.y == 120 and fake.focusedWindow.h == 560,
            "= expands one step on every side, center fixed")

        -- undo unwinds, redo replays
        fake.pressHotkey("[", {})
        ok(fake.focusedWindow.x == 200 and fake.focusedWindow.w == 600, "[ undoes the expand")
        fake.pressHotkey("]", {})
        ok(fake.focusedWindow.x == 100 and fake.focusedWindow.w == 800, "] redoes it")

        -- throw to the screen on the right (size kept, position scaled, clamped)
        fake.pressHotkey("right", {})
        ok(fake.windowFrames[#fake.windowFrames].x == 1200
            and fake.windowFrames[#fake.windowFrames].w == 800,
            "right-arrow moves to the right screen, size kept")

        -- escape exits: banner gone, bare keys dead
        local xBefore = fake.focusedWindow.x
        fake.pressHotkey("escape", {})
        ok(fake.liveHud() == nil, "escape drops the HUD")
        fake.pressHotkey("a", {})
        ok(fake.focusedWindow.x == xBefore, "bare keys are dead after exit")

        -- the trigger toggles: enter, then the same hotkey exits
        fake.pressHotkey("w", { "cmd", "alt", "ctrl" })
        ok(fake.liveHud() ~= nil, "re-enter works")
        fake.pressHotkey("w", { "cmd", "alt", "ctrl" })
        ok(fake.liveHud() == nil, "the enter hotkey toggles the mode off")

        -- disabling mid-mode leaks nothing
        fake.pressHotkey("w", { "cmd", "alt", "ctrl" })
        ok(fake.liveHud() ~= nil, "mode active before disable")
        registry.setEnabled("window_modal", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
            "disable mid-mode tears everything down")
    end,
}
