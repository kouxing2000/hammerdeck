-- test/cases/_integration/rules/rules_frontmost_bundleid.lua -- frontmostApp matches by BUNDLE ID when the rule carries `on.bundleId` -- so a
-- rule keyed to an app fires regardless of the app's localized name (locale / rename),
-- and a DIFFERENT app that merely shares the display name does NOT. A rule with no
-- bundle id (free-typed) still matches by name. Exercises the real signal value
-- ({name, bundleId}) + rules.bindOne's bundle-id-first target + sig.match.
--
-- Migrated from run.lua T35b (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration: platform subsystem, driven by throwaway features/effects. Hermetic --
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so the catalog
-- and the rules singleton both start empty.

return {
    id = "rules_frontmost_bundleid",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
        local rules   = require("platform.rules")
        local effects = require("platform.effects")

        fake.settings["hammerdeck.rules"] = nil
        fake.frontmost = "Finder"; fake.frontmostId = "com.apple.finder"

        -- (a) bundle-id rule: becomes = display name, bundleId = the stable match key
        rules.load({
            { id = "slack-front",
              on = { type = "state", signal = "frontmostApp", becomes = "Slack",
                     bundleId = "com.tinyspeck.slackmacgap" },
              effect = { kind = "notify", title = "HD", text = "Slack front" } },
        })
        rules.startAll()
        local nB = #fake.notifications
        -- the app reports a DIFFERENT localized name but the matching bundle id -> fires
        fake.activateApp("Slack (Beta)", "com.tinyspeck.slackmacgap")
        ok(#fake.notifications == nB + 1,
            "frontmostApp matches by bundle id despite a different localized name")

        -- a same-NAME app of a DIFFERENT bundle does not fire (bundle id is authoritative)
        fake.activateApp("Finder", "com.apple.finder")   -- leave -> reset the edge
        local nB2 = #fake.notifications
        fake.activateApp("Slack", "com.other.slackclone")
        ok(#fake.notifications == nB2,
            "a same-named app of a different bundle does not fire a bundle-id rule")

        -- (b) a free-typed rule (no bundleId) still matches by name
        rules.load({
            { id = "notes-front",
              on = { type = "state", signal = "frontmostApp", becomes = "Notes" },
              effect = { kind = "notify", title = "HD", text = "Notes" } },
        })
        rules.startAll()
        local nN = #fake.notifications
        fake.activateApp("Notes", "com.apple.Notes")
        ok(#fake.notifications == nN + 1, "a rule with no bundle id matches by name (free-text)")

        -- (c) the engine IGNORES a stray on.bundleId on a signal that doesn't support it
        -- (sig.bundleIdMatch=false) -- so a hand-authored JSON rule (or a stale id left by
        -- switching signals in the form) on an enum/name/set signal still fires by its real
        -- value, instead of matching a bundle id it never satisfies (a silent dead rule).
        fake.appearance = "light"
        rules.load({
            { id = "appdark",
              on = { type = "state", signal = "appearance", becomes = "dark", bundleId = "com.stray.id" },
              effect = { kind = "notify", title = "Dark" } },
        })
        rules.startAll()
        local nD = #fake.notifications
        fake.appearance = "dark"; fake.systemEvent("appearanceChanged")
        ok(#fake.notifications == nD + 1,
            "a stray on.bundleId on a non-app signal is ignored -- the rule fires by its value, not dead")

        -- (d) from-trigger (@trigger:app) on a bundle-id rule resolves to the BUNDLE ID, so
        -- the effect finds the running app even when its localized name has drifted from the
        -- name the rule was authored with -- the case bundle-id matching exists for.
        rules.load({
            { id = "min-front",
              on = { type = "state", signal = "frontmostApp", becomes = "Slack",
                     bundleId = "com.tinyspeck.slackmacgap" },
              effect = { kind = "minimizeApp", app = effects.TRIGGER_APP } },
        })
        rules.startAll()
        local nMin = #fake.minimized
        fake.activateApp("Slack (Renamed)", "com.tinyspeck.slackmacgap")
        ok(#fake.minimized == nMin + 1 and fake.minimized[#fake.minimized] == "com.tinyspeck.slackmacgap",
            "from-trigger @trigger:app on a bundle-id rule passes the BUNDLE ID to the effect")

        rules.load({}); fake.frontmost = nil; fake.frontmostId = ""; fake.appearance = "light"
    end,
}
