-- test/cases/_integration/rules/rules_sentence.lua -- rules.sentence -- the plain-language read-back shown live above the rule
-- form (the redesign's comprehension win: a rule reads as one English line, and a
-- from-trigger param reads as "it"). Pure formatting over signals.meta + describe.
--
-- Migrated from run.lua T40b (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration: platform subsystem, driven by throwaway features/effects. Hermetic --
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so the catalog
-- and the rules singleton both start empty.

return {
    id = "rules_sentence",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok = t.ok
        local effects = require("platform.effects")
        local rules   = require("platform.rules")

        -- ENTITY signal, leaves edge, app drawn from the trigger -> "it"
        ok(rules.sentence({
            on = { type = "state", signal = "frontmostApp", leaves = "Slack" },
            effect = { kind = "minimizeApp", app = effects.TRIGGER_APP } })
            == "When Slack loses focus, minimize it.",
            "sentence: app loses focus -> minimize it")
        -- ENTITY signal, becomes edge, display from the trigger
        ok(rules.sentence({
            on = { type = "state", signal = "displaysPresent", becomes = "DELL U2720Q" },
            effect = { kind = "solidWallpaper", color = "#FFFFFF", display = effects.TRIGGER_DISPLAY } })
            == "When DELL U2720Q connects, set wallpaper white on it.",
            "sentence: display connects -> wallpaper on it")
        -- PROPERTY signal (no `provides`) reads "the <name> <verb> <value>"
        ok(rules.sentence({
            on = { type = "state", signal = "powerSource", becomes = "battery" },
            effect = { kind = "solidWallpaper", color = "#000000", display = "all" } })
            == "When the power source becomes battery, set wallpaper black on all displays.",
            "sentence: property signal reads 'the X becomes Y'")
        -- PROPERTY signal, LEAVE edge -> "is no longer X" (a bare "leaves battery" is
        -- ungrammatical for a subject-less property; see signals.lua leaveVerb).
        ok(rules.sentence({
            on = { type = "state", signal = "powerSource", leaves = "battery" },
            effect = { kind = "lockScreen" } })
            == "When the power source is no longer battery, lock the screen.",
            "sentence: property leave edge reads 'is no longer'")
        -- a CHAIN effect reads as one flowing line ("..., then ..."), not "N steps: ..."
        ok(rules.sentence({
            on = { type = "state", signal = "frontmostApp", leaves = "Slack" },
            effect = { kind = "chain", effects = {
                { kind = "minimizeApp", app = effects.TRIGGER_APP }, { kind = "notify", title = "Done" } } } })
            == 'When Slack loses focus, minimize it, then notify "Done".',
            "sentence: a chain reads as one flowing line")
        -- event
        ok(rules.sentence({
            on = { type = "event", event = "wake" }, effect = { kind = "notify", title = "Hi" } })
            == 'When the Mac wakes, notify "Hi".', "sentence: event clause")
        -- schedule LEADS the line (no "When") -- both the daily-at and every-N forms
        ok(rules.sentence({
            on = { type = "schedule", at = "18:00" }, effect = { kind = "lockScreen" } })
            == "Every day at 18:00, lock the screen.", "sentence: schedule (at) leads the line")
        ok(rules.sentence({
            on = { type = "schedule", everyMin = 25 }, effect = { kind = "lockScreen" } })
            == "Every 25 minutes, lock the screen.", "sentence: schedule (everyMin) -- the %d branch")
        -- incomplete (no value) -> empty, so the host shows its placeholder
        ok(rules.sentence({
            on = { type = "state", signal = "frontmostApp" }, effect = { kind = "lockScreen" } }) == "",
            "sentence: a missing trigger value -> empty")
        -- the JSON wrapper the host calls
        ok(rules.sentenceJSON('{"on":{"type":"event","event":"sleep"},"effect":{"kind":"lockScreen"}}')
            == "When the Mac sleeps, lock the screen.", "sentenceJSON decodes + composes")
        ok(rules.sentenceJSON("not json") == "", "sentenceJSON: bad input -> empty")

        -- pronoun mode is OPT-IN: the default describe (list row / log) is unchanged.
        ok(effects.describe({ kind = "minimizeApp", app = effects.TRIGGER_APP }) == "Minimize the triggering app",
            "describe default keeps 'the triggering app'")
        ok(effects.describe({ kind = "minimizeApp", app = effects.TRIGGER_APP }, { pronoun = true }) == "Minimize it",
            "describe pronoun mode renders the from-trigger app as 'it'")
    end,
}
