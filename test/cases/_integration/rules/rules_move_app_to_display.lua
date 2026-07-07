-- test/cases/_integration/rules/rules_move_app_to_display.lua -- moveAppToDisplay effect -- relocate an app's window to another display
-- KEEPING its size (vs layout, which resizes). Reuses listWindows/screenFrames/
-- setWindowFrame; context-free; app/display may be from-trigger.
--
-- Migrated from run.lua T39b3 (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration: platform subsystem, driven by throwaway features/effects. Hermetic --
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so the catalog
-- and the rules singleton both start empty.

return {
    id = "rules_move_app_to_display",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
        local effects = require("platform.effects")

        fake.settings["hammerdeck.rules"] = nil
        fake.screenList = {
            { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1, builtin = true },
            { x = 1440, y = 0, w = 2560, h = 1440, name = "DELL U2720Q", index = 2 },
        }
        fake.windows = { { id = 7, appName = "Slack", x = 100, y = 120, w = 400, h = 300, title = "Slack" } }
        fake.windowFrameSets = {}

        ok(effects.requiresContext({ kind = "moveAppToDisplay", app = "Slack", display = "DELL U2720Q" }) == false,
            "moveAppToDisplay is context-free")
        ok(pcall(effects.validate, { kind = "moveAppToDisplay", app = "Slack" }) == false,
            "moveAppToDisplay requires a display")
        ok(pcall(effects.validate, { kind = "moveAppToDisplay", display = "DELL U2720Q" }) == false,
            "moveAppToDisplay requires an app")
        ok(pcall(effects.validate, { kind = "moveAppToDisplay", app = "Slack", display = "DELL U2720Q" }) == true,
            "moveAppToDisplay with app + display validates")

        -- dispatch keeps the SIZE (400x300) and preserves the within-screen offset:
        -- from Built-in (0,0) offset (100,120) -> DELL (1440,0) => (1540,120).
        ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Slack", display = "DELL U2720Q" }) == true,
            "moveAppToDisplay moves a matching window")
        local s = fake.windowFrameSets[#fake.windowFrameSets]
        ok(s and s.id == 7 and s.x == 1540 and s.y == 120 and s.w == 400 and s.h == 300,
            "moveAppToDisplay relocates to the display keeping the window's size + offset")

        -- a disconnected/typo'd display -> failure, no move
        fake.windowFrameSets = {}
        ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Slack", display = "Ghost" }) == false
            and #fake.windowFrameSets == 0, "moveAppToDisplay fails when the display isn't connected")

        -- no matching window -> failure
        ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Nope", display = "DELL U2720Q" }) == false,
            "moveAppToDisplay fails when no window matches the app")

        -- from-trigger: app + display resolve from context
        fake.windowFrameSets = {}
        effects.dispatch({ kind = "moveAppToDisplay", app = effects.TRIGGER_APP, display = effects.TRIGGER_DISPLAY },
            { app = "Slack", display = "DELL U2720Q" })
        ok(fake.windowFrameSets[#fake.windowFrameSets] and fake.windowFrameSets[#fake.windowFrameSets].x == 1540,
            "moveAppToDisplay resolves from-trigger app + display")

        ok(effects.describe({ kind = "moveAppToDisplay", app = "Slack", display = "DELL U2720Q" })
            == "Move Slack to DELL U2720Q", "describe labels moveAppToDisplay")

        -- restore the single-screen default so a later screen-reading test isn't
        -- polluted by this block's 2-screen config (matches the layout block's teardown)
        fake.windows = {}; fake.windowFrameSets = {}
        fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1, builtin = true } }
    end,
}
