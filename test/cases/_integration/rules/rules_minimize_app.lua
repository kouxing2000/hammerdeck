-- test/cases/_integration/rules/rules_minimize_app.lua -- minimizeApp effect -- minimize a named app's window; context-free, and its
-- `app` may be drawn from the trigger ("the app from the trigger"). The SECOND
-- context-bound effect, and the first that binds on the `leaves` edge (an app
-- losing focus) -- proving from-trigger isn't display/becomes-only.
--
-- Migrated from run.lua T39c (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration: platform subsystem, driven by throwaway features/effects. Hermetic --
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so the catalog
-- and the rules singleton both start empty.

return {
    id = "rules_minimize_app",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
        local effects = require("platform.effects")
        local rules   = require("platform.rules")

        fake.settings["hammerdeck.rules"] = nil
        rules.load({})

        -- context-free + validated (needs a non-empty app)
        ok(effects.requiresContext({ kind = "minimizeApp", app = "Slack" }) == false,
            "minimizeApp is context-free")
        ok(pcall(effects.validate, { kind = "minimizeApp" }) == false,
            "minimizeApp requires an app")
        ok(pcall(effects.validate, { kind = "minimizeApp", app = "Slack" }) == true,
            "minimizeApp with an app validates")

        -- dispatch routes to the adapter with a LITERAL app name
        local nM = #fake.minimized
        effects.dispatch({ kind = "minimizeApp", app = "Slack" })
        ok(#fake.minimized == nM + 1 and fake.minimized[#fake.minimized] == "Slack",
            "minimizeApp dispatch minimizes the named app")

        -- from-trigger: the sentinel resolves to context.app
        effects.dispatch({ kind = "minimizeApp", app = effects.TRIGGER_APP }, { app = "Notes" })
        ok(fake.minimized[#fake.minimized] == "Notes",
            "minimizeApp resolves the from-trigger sentinel from the context")

        -- from-trigger with NO context app -> failure, nothing minimized
        local nM2 = #fake.minimized
        local okNo = effects.dispatch({ kind = "minimizeApp", app = effects.TRIGGER_APP })
        ok(okNo == false and #fake.minimized == nM2,
            "minimizeApp from-trigger with no app does nothing")

        -- describe
        ok(effects.describe({ kind = "minimizeApp", app = "Slack" }) == "Minimize Slack",
            "describe labels a literal-app minimizeApp")
        ok(effects.describe({ kind = "minimizeApp", app = effects.TRIGGER_APP }) == "Minimize the triggering app",
            "describe labels a from-trigger minimizeApp")

        -- end-to-end on the LEAVES edge: "frontmost app leaves Slack" -> minimize Slack.
        -- triggerContext yields {app = leaves}, proving from-trigger works on `leaves`,
        -- not just `becomes` (the generalization the focus-loss case forced).
        local _, mid = rules.add({
            on = { type = "state", signal = "frontmostApp", leaves = "Slack" },
            effect = { kind = "minimizeApp", app = effects.TRIGGER_APP } })
        local nM3 = #fake.minimized
        ok(rules.fire(mid) == true, "a minimizeApp rule fires (Test)")
        ok(#fake.minimized == nM3 + 1 and fake.minimized[#fake.minimized] == "Slack",
            "the app that lost focus flows from the rule's leaves condition into the effect")

        -- usesTriggerContext + describe.contextBound -- the host hides "Test" for a
        -- reactive (from-trigger) rule, since a manual fire has no live trigger context.
        ok(effects.usesTriggerContext({ kind = "minimizeApp", app = effects.TRIGGER_APP }) == true,
            "usesTriggerContext detects a from-trigger param")
        ok(effects.usesTriggerContext({ kind = "minimizeApp", app = "Slack" }) == false,
            "usesTriggerContext is false for a literal param")
        ok(effects.usesTriggerContext({ kind = "chain", effects = {
            { kind = "lockScreen" },
            { kind = "solidWallpaper", color = "#FFFFFF", display = effects.TRIGGER_DISPLAY } } }) == true,
            "usesTriggerContext recurses into chain steps")
        do
            local row
            for _, r in ipairs(rules.describe()) do if r.id == mid then row = r end end
            ok(row and row.contextBound == true, "describe flags a from-trigger rule as contextBound")
        end

        -- hideApp / quitApp: same {app} shape + context-binding, different verb.
        ok(pcall(effects.validate, { kind = "hideApp" }) == false, "hideApp requires an app")
        ok(pcall(effects.validate, { kind = "quitApp", app = "Mail" }) == true, "quitApp with an app validates")
        ok(effects.requiresContext({ kind = "hideApp", app = "Mail" }) == false, "hideApp is context-free")
        local nH = #fake.hidden
        effects.dispatch({ kind = "hideApp", app = "Mail" })
        ok(#fake.hidden == nH + 1 and fake.hidden[#fake.hidden] == "Mail", "hideApp dispatch hides the app")
        local nQ = #fake.quit
        effects.dispatch({ kind = "quitApp", app = effects.TRIGGER_APP }, { app = "Notes" })
        ok(#fake.quit == nQ + 1 and fake.quit[#fake.quit] == "Notes", "quitApp resolves @trigger:app from context")
        ok(effects.describe({ kind = "hideApp", app = "Mail" }) == "Hide Mail", "describe labels hideApp")
        ok(effects.describe({ kind = "quitApp", app = effects.TRIGGER_APP }) == "Quit the triggering app",
            "describe labels a from-trigger quitApp")

        -- the Do dropdown offers them on automated triggers
        local seen = {}
        for _, e in ipairs(effects.catalog(true)) do seen[e.kind] = true end
        ok(seen.minimizeApp and seen.hideApp and seen.quitApp,
            "catalog offers minimizeApp + hideApp + quitApp on automated triggers")

        rules.load({}); fake.settings["hammerdeck.rules"] = nil
        ok(fake.liveHandles == 0, "no native handle leaked across the app-target effect tests")
    end,
}
