-- test/cases/_integration/rules/rules_signals_m2.lua -- the new state signals (M2) -- appearance (scalar), runningApps (membership),
-- powerSource (scalar). Each re-reads on a coarse onSystemEvent and fires on the
-- becomes/leaves transition; formOptions carries each signal's UI metadata so the
-- Rules form needs no per-signal Swift code.
--
-- Migrated from run.lua T38 (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration: platform subsystem, driven by throwaway features/effects. Hermetic --
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so the catalog
-- and the rules singleton both start empty.

return {
    id = "rules_signals_m2",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
        local rules   = require("platform.rules")
        local signals = require("platform.signals")

        fake.settings["hammerdeck.rules"] = nil
        rules.load({})

        -- (a) appearance: a scalar "dark"/"light" signal, fires on the transition
        fake.appearance = "light"
        ok(signals.exists("appearance"), "appearance is a registered signal")
        ok(signals.get("appearance").read() == "light", "appearance reads the current mode")
        local nB = #fake.notifications
        rules.add({ on = { type = "state", signal = "appearance", becomes = "dark" },
                    effect = { kind = "notify", title = "Dark" } })
        fake.systemEvent("appearanceChanged")   -- still light
        ok(#fake.notifications == nB, "appearanceChanged with no real change does not fire")
        fake.appearance = "dark"
        fake.systemEvent("appearanceChanged")
        ok(#fake.notifications == nB + 1, "appearance becomes dark -> fires")

        -- (b) runningApps: a membership set signal, "launches"/"quits". Like frontmostApp
        -- it now matches by the stable BUNDLE ID (name as a fallback); the value is a list
        -- of { name, bundleId }.
        rules.load({})
        fake.runningAppInfoList = { { name = "Finder", bundleId = "com.apple.finder" } }
        ok(signals.get("runningApps").match(
            { { name = "Finder", bundleId = "com.apple.finder" },
              { name = "Safari", bundleId = "com.apple.Safari" } }, "com.apple.Safari") == true,
            "runningApps membership matches by bundle id")
        ok(signals.get("runningApps").match(
            { { name = "Finder", bundleId = "com.apple.finder" } }, "Finder") == true,
            "runningApps membership also matches by name (fallback)")
        local nL = #fake.notifications
        rules.add({ on = { type = "state", signal = "runningApps", becomes = "Slack",
                           bundleId = "com.tinyspeck.slackmacgap" },
                    effect = { kind = "notify", title = "Slack up" } })
        fake.runningAppInfoList = { { name = "Finder", bundleId = "com.apple.finder" },
                                   { name = "Slack",  bundleId = "com.tinyspeck.slackmacgap" } }
        fake.systemEvent("appsChanged")
        ok(#fake.notifications == nL + 1, "Slack launches (matched by bundle id) -> the runningApps rule fires")
        fake.runningAppInfoList = { { name = "Finder", bundleId = "com.apple.finder" } }
        fake.systemEvent("appsChanged")
        ok(#fake.notifications == nL + 1, "Slack quitting does not fire a 'launches' rule")

        -- (c) powerSource: scalar "ac"/"battery"
        rules.load({})
        fake.power = "ac"
        local nP = #fake.notifications
        rules.add({ on = { type = "state", signal = "powerSource", becomes = "battery" },
                    effect = { kind = "notify", title = "Unplugged" } })
        fake.power = "battery"
        fake.systemEvent("powerChanged")
        ok(#fake.notifications == nP + 1, "unplugging (powerSource becomes battery) -> fires")

        -- (d) formOptions carries signal metadata (label + transition verbs) for the form
        local fo = rules.formOptions()
        ok(type(fo.signalMeta) == "table", "formOptions includes signalMeta")
        ok(fo.signalMeta.appearance and fo.signalMeta.appearance.label == "Appearance",
            "signalMeta carries a label per signal")
        ok(fo.signalMeta.runningApps and fo.signalMeta.runningApps.enterVerb == "launches",
            "signalMeta carries the transition verbs (runningApps: launches/quits)")
        -- bundleIdMatch rides signalMeta so the host gates its installed-apps app picker on
        -- the signal's capability, not a hardcoded name: true for the app-identity signals,
        -- false (default) for an enum signal like appearance.
        ok(fo.signalMeta.frontmostApp and fo.signalMeta.frontmostApp.bundleIdMatch == true,
            "signalMeta marks frontmostApp as bundleIdMatch")
        ok(fo.signalMeta.runningApps and fo.signalMeta.runningApps.bundleIdMatch == true,
            "signalMeta marks runningApps as bundleIdMatch")
        ok(fo.signalMeta.appearance and fo.signalMeta.appearance.bundleIdMatch == false,
            "signalMeta marks an enum signal (appearance) as NOT bundleIdMatch")
        -- goneOnLeave rides signalMeta so the host can warn when a from-trigger effect
        -- binds on a leave edge whose entity is gone (runningApps quits, displaysPresent
        -- disconnects) -- but NOT frontmostApp, whose "loses focus" keeps the app alive.
        ok(fo.signalMeta.runningApps and fo.signalMeta.runningApps.goneOnLeave == true,
            "signalMeta marks runningApps goneOnLeave (a quit app is gone)")
        ok(fo.signalMeta.displaysPresent and fo.signalMeta.displaysPresent.goneOnLeave == true,
            "signalMeta marks displaysPresent goneOnLeave (a disconnected display is gone)")
        ok(fo.signalMeta.frontmostApp and not fo.signalMeta.frontmostApp.goneOnLeave,
            "signalMeta does NOT mark frontmostApp goneOnLeave (losing focus keeps it alive)")
        -- timing subtitle (the verb-popover footgun-killer) rides signalMeta too
        ok(fo.signalMeta.frontmostApp and fo.signalMeta.frontmostApp.leaveWhen == "the moment you click away",
            "signalMeta carries the per-edge timing copy (frontmostApp leaveWhen)")
        ok(type(fo.signalCandidates.powerSource) == "table"
            and fo.signalCandidates.powerSource[1] == "ac",
            "powerSource offers ac/battery as candidates")

        -- cleanup
        rules.load({})
        fake.settings["hammerdeck.rules"] = nil
        fake.appearance = "light"; fake.runningAppInfoList = {}; fake.power = "ac"
        ok(fake.liveHandles == 0, "no native handle leaked across the new-signal tests")
    end,
}
