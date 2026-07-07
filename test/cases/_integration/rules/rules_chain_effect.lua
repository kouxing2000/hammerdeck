-- test/cases/_integration/rules/rules_chain_effect.lua -- chain effect (M3) -- run several sub-effects IN ORDER; context-free iff every
-- step is; partial-success aggregation names the failed steps --------------------
--
-- Migrated from run.lua T40 (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration: platform subsystem, driven by throwaway features/effects. Hermetic --
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so the catalog
-- and the rules singleton both start empty.

return {
    id = "rules_chain_effect",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
        local effects = require("platform.effects")
        local rules   = require("platform.rules")

        fake.settings["hammerdeck.rules"] = nil
        rules.load({})

        -- validate: needs >= 1 step, each a valid effect, no nesting
        ok(pcall(effects.validate, { kind = "chain", effects = {} }) == false,
            "a chain needs at least one step")
        ok(pcall(effects.validate, { kind = "chain", effects = {
            { kind = "chain", effects = { { kind = "lockScreen" } } } } }) == false,
            "a chain step cannot itself be a chain (no nesting)")
        ok(pcall(effects.validate, { kind = "chain", effects = { { kind = "notify" } } }) == false,
            "a chain rejects an invalid step (notify needs a title)")
        ok(pcall(effects.validate, { kind = "chain", effects = {
            { kind = "notify", title = "hi" }, { kind = "runShortcut", name = "DND" } } }) == true,
            "a chain of valid steps validates")

        -- context policy: context-free iff EVERY step is
        ok(effects.requiresContext({ kind = "chain", effects = {
            { kind = "notify", title = "hi" }, { kind = "lockScreen" } } }) == false,
            "a chain of context-free steps is context-free")
        ok(effects.requiresContext({ kind = "chain", effects = {
            { kind = "notify", title = "hi" }, { kind = "command", feature = "ghost", action = "x" } } }) == true,
            "a chain with a context-requiring step requires context")

        -- describe lists the steps (the compact list-row / fire-log form)
        ok(effects.describe({ kind = "chain", effects = {
            { kind = "notify", title = "hi" }, { kind = "runShortcut", name = "DND" } } })
            == '2 steps: Notify "hi" -> Run Shortcut "DND"', "describe lists the chain steps")
        -- pronoun mode renders the chain as one flowing sentence (the read-back),
        -- lowercasing each step after the first and joining with ", then ".
        ok(effects.describe({ kind = "chain", effects = {
            { kind = "minimizeApp", app = effects.TRIGGER_APP }, { kind = "notify", title = "Done" } } },
            { pronoun = true })
            == 'Minimize it, then notify "Done"', "describe chain pronoun mode joins with 'then'")

        -- dispatch runs every step IN ORDER
        local nN, nS = #fake.notifications, #fake.shortcutsRun
        ok(effects.dispatch({ kind = "chain", effects = {
            { kind = "notify", title = "one" }, { kind = "runShortcut", name = "two" } } }) == true
            and #fake.notifications == nN + 1 and #fake.shortcutsRun == nS + 1,
            "a chain dispatches every step")

        -- partial: one step fails (layout with no present display) -> ran K/N note
        fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1 } }
        fake.windows = {}
        local okP, noteP = effects.dispatch({ kind = "chain", effects = {
            { kind = "notify", title = "ok" },
            { kind = "layout", placements = { { app = "X", screen = "Ghost", pos = "full" } } } } })
        ok(okP == true and type(noteP) == "string" and noteP:find("1/2", 1, true) ~= nil
            and noteP:find("step 2", 1, true) ~= nil,
            "a partial chain returns a note naming the failed step (ran 1/2)")

        -- every step fails -> (false, reason)
        local okF, reasonF = effects.dispatch({ kind = "chain", effects = {
            { kind = "layout", placements = { { app = "X", screen = "Ghost", pos = "full" } } } } })
        ok(okF == false and reasonF:find("every step failed", 1, true) ~= nil,
            "an all-failed chain reports failure")

        -- end-to-end: on wake -> notify + runShortcut (all context-free, so allowed)
        local nS3 = #fake.shortcutsRun
        ok(rules.add({ on = { type = "event", event = "wake" },
            effect = { kind = "chain", effects = {
                { kind = "notify", title = "morning" }, { kind = "runShortcut", name = "Coffee" } } } }) == true,
            "a chain rule on an automated trigger loads (all steps context-free)")
        fake.systemEvent("wake")
        ok(#fake.shortcutsRun == nS3 + 1, "on wake -> the chain runs its Shortcut step")

        -- context policy backstop: a chain with a context step is REFUSED on an automated trigger
        ok(select(1, rules.add({ on = { type = "event", event = "wake" },
            effect = { kind = "chain", effects = {
                { kind = "command", feature = "ghost", action = "x" } } } })) == false,
            "an automated trigger refuses a chain with a context-requiring step")

        -- the Do dropdown offers chain
        local seen = {}
        for _, e in ipairs(effects.catalog(true)) do seen[e.kind] = true end
        ok(seen.chain, "catalog offers the chain effect")

        rules.load({}); fake.settings["hammerdeck.rules"] = nil
        fake.windows = {}
        ok(fake.liveHandles == 0, "no native handle leaked across the chain tests")
    end,
}
