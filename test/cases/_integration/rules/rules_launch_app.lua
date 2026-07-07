-- test/cases/_integration/rules/rules_launch_app.lua -- launchApp effect (Open an app) -- the positive counterpart to quit. Unlike
-- minimize/hide/quit (which act on a RUNNING app by name or id), launch needs the
-- BUNDLE ID (the only launchable identifier), so validate requires appBundleId; `app`
-- is just the readable name for the sentence/log. Context-free, so it can fire on an
-- automated trigger ("open Slack at 9am").
--
-- Migrated from run.lua T39b5 (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration: platform subsystem, driven by throwaway features/effects. Hermetic --
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so the catalog
-- and the rules singleton both start empty.

return {
    id = "rules_launch_app",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
        local effects = require("platform.effects")

        fake.settings["hammerdeck.rules"] = nil

        ok(effects.requiresContext({ kind = "launchApp", app = "Slack", appBundleId = "com.tinyspeck.slackmacgap" }) == false,
            "launchApp is context-free (fires on an automated trigger)")
        -- validate needs BOTH the bundle id (launch key) and a name (for the sentence).
        ok(pcall(effects.validate, { kind = "launchApp", app = "Slack" }) == false,
            "launchApp requires a bundle id, not just a name")
        ok(pcall(effects.validate, { kind = "launchApp", appBundleId = "com.tinyspeck.slackmacgap" }) == false,
            "launchApp requires an app name for the sentence")
        ok(pcall(effects.validate, { kind = "launchApp", app = "Slack", appBundleId = "com.tinyspeck.slackmacgap" }) == true,
            "launchApp with a name + bundle id validates")
        -- no @trigger:app form (launch targets a specific installed app) -- a hand-authored
        -- one is rejected, not silently launched while the sentence reads the raw sentinel.
        ok(pcall(effects.validate, { kind = "launchApp", app = effects.TRIGGER_APP, appBundleId = "x" }) == false,
            "launchApp rejects the @trigger:app sentinel")

        -- dispatch launches by the BUNDLE ID (not the name).
        local nL = #fake.launchedApps
        ok(effects.dispatch({ kind = "launchApp", app = "Slack", appBundleId = "com.tinyspeck.slackmacgap" }) == true,
            "launchApp dispatch launches the app")
        ok(#fake.launchedApps == nL + 1 and fake.launchedApps[#fake.launchedApps] == "com.tinyspeck.slackmacgap",
            "launchApp passes the bundle id to launchOrFocusApp")

        -- a bundle id no installed app carries -> a real failure (not a lying green fire).
        fake.uninstalledApps = { ["com.example.ghost"] = true }
        ok(effects.dispatch({ kind = "launchApp", app = "Ghost", appBundleId = "com.example.ghost" }) == false,
            "launchApp fails when no installed app carries the bundle id")
        fake.uninstalledApps = nil

        -- describe reads "Open <app>" (the readable name, never the raw bundle id).
        ok(effects.describe({ kind = "launchApp", app = "Slack", appBundleId = "com.tinyspeck.slackmacgap" })
            == "Open Slack", "describe labels launchApp by name")

        -- it appears in the Do dropdown catalog (context-free -> survives automatedOnly).
        local found = false
        for _, e in ipairs(effects.catalog(true)) do if e.kind == "launchApp" then found = true end end
        ok(found, "launchApp is offered in the effects catalog for automated triggers")
    end,
}
