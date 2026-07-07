-- test/cases/_integration/rules/rules_app_target_bundleid.lua -- app-target effects match by BUNDLE ID when the rule carries one (the
-- stable key, set when the user picks from the installed-apps list) -- falling back
-- to the display name for legacy rules + the from-trigger path. Proves (a) the
-- minimize/hide/quit trio pass the bundle id to the adapter, and (b) moveAppToDisplay
-- matches a window by bundleID even when its localized appName differs.
--
-- Migrated from run.lua T39b4 (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration: platform subsystem, driven by throwaway features/effects. Hermetic --
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so the catalog
-- and the rules singleton both start empty.

return {
    id = "rules_app_target_bundleid",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
        local effects = require("platform.effects")

        fake.settings["hammerdeck.rules"] = nil

        -- minimize: with appBundleId set, the adapter is called with the BUNDLE ID.
        local nM = #fake.minimized
        effects.dispatch({ kind = "minimizeApp", app = "Slack", appBundleId = "com.tinyspeck.slackmacgap" })
        ok(#fake.minimized == nM + 1 and fake.minimized[#fake.minimized] == "com.tinyspeck.slackmacgap",
            "minimizeApp prefers the bundle id when the rule has one")

        -- no appBundleId -> the display name (legacy / from-trigger fallback).
        effects.dispatch({ kind = "minimizeApp", app = "Slack" })
        ok(fake.minimized[#fake.minimized] == "Slack",
            "minimizeApp falls back to the name with no bundle id")

        -- an empty-string appBundleId is treated as absent (name fallback), not "".
        effects.dispatch({ kind = "quitApp", app = "Slack", appBundleId = "" })
        ok(fake.quit[#fake.quit] == "Slack", "an empty appBundleId falls back to the name")

        -- moveAppToDisplay: match by bundleID even when the window's appName differs from
        -- the rule's stored display name (locale/rename drift -- exactly what bundle-id
        -- identity fixes).
        fake.screenList = {
            { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1, builtin = true },
            { x = 1440, y = 0, w = 2560, h = 1440, name = "DELL U2720Q", index = 2 },
        }
        fake.windows = { { id = 9, appName = "Slack (renamed)", bundleID = "com.tinyspeck.slackmacgap",
                           x = 100, y = 120, w = 400, h = 300, title = "Slack" } }
        fake.windowFrameSets = {}
        ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Slack",
                appBundleId = "com.tinyspeck.slackmacgap", display = "DELL U2720Q" }) == true,
            "moveAppToDisplay matches a window by bundle id despite a different appName")
        local s = fake.windowFrameSets[#fake.windowFrameSets]
        ok(s and s.id == 9 and s.x == 1540, "the bundle-id-matched window is the one moved")

        -- neither name nor bundle id matches -> no move (bundleID isn't a wildcard).
        fake.windowFrameSets = {}
        ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Nope",
                appBundleId = "com.example.nope", display = "DELL U2720Q" }) == false
            and #fake.windowFrameSets == 0,
            "moveAppToDisplay does not move when neither name nor bundle id matches")

        -- strict: with a bundle id, a DIFFERENT app that merely shares the display name
        -- is NOT moved -- bundle id is authoritative, no name over-match.
        fake.windows = { { id = 5, appName = "Slack", bundleID = "com.other.slackclone",
                           x = 10, y = 10, w = 200, h = 200, title = "x" } }
        fake.windowFrameSets = {}
        ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Slack",
                appBundleId = "com.tinyspeck.slackmacgap", display = "DELL U2720Q" }) == false
            and #fake.windowFrameSets == 0,
            "moveAppToDisplay with a bundle id ignores a same-named app of a different bundle")

        fake.windows = {}; fake.windowFrameSets = {}
        fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1, builtin = true } }
    end,
}
