-- test/cases/_integration/rules/rules_state_signals.lua -- rules engine (M1) -- state-signal triggers, notify effect, mutation API --
-- The condition/state half of the framework: a rule fires on a STATE SIGNAL
-- crossing a value (frontmostApp becomes/leaves), the observable `notify` effect,
-- and the add/setEnabled/remove + describe surface the Settings Rules tab calls.
--
-- Migrated from run.lua T35 (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration: platform subsystem, driven by throwaway features/effects. Hermetic --
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so the catalog
-- and the rules singleton both start empty.

return {
    id = "rules_state_signals",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry
        local rules   = require("platform.rules")
        local effects = require("platform.effects")
        local json    = require("platform.json")

        -- (a) a `state` trigger fires on the enter transition, not on stay/leave
        fake.frontmost = "Finder"
        local nB = #fake.notifications
        ok(rules.load({
            { id = "safari-front",
              on = { type = "state", signal = "frontmostApp", becomes = "Safari" },
              effect = { kind = "notify", title = "HD", text = "Safari front" } },
        }) == 1, "state-trigger rule with a notify effect loads (notify is context-free)")
        rules.startAll()
        ok(rules.liveCount() == 1, "state rule bound")
        fake.activateApp("Mail")
        ok(#fake.notifications == nB, "switching to a non-target app does not fire")
        fake.activateApp("Safari")
        ok(#fake.notifications == nB + 1, "frontmost BECOMES Safari -> notify fires (enter)")
        fake.activateApp("Safari")
        ok(#fake.notifications == nB + 1, "re-activating Safari (no value change) does not re-fire")
        fake.activateApp("Notes")
        ok(#fake.notifications == nB + 1, "leaving Safari does not fire a 'becomes' rule")

        -- (b) a `leaves` trigger fires on the exit transition, not on enter
        rules.load({
            { id = "safari-leave",
              on = { type = "state", signal = "frontmostApp", leaves = "Safari" },
              effect = { kind = "notify", title = "HD", text = "left Safari" } },
        })
        rules.startAll()
        local nL = #fake.notifications
        fake.activateApp("Safari")
        ok(#fake.notifications == nL, "a 'leaves' rule does not fire on enter")
        fake.activateApp("Mail")
        ok(#fake.notifications == nL + 1, "frontmost LEAVES Safari -> notify fires (exit)")

        -- (c) context policy: a state trigger (automated) cannot run a non-automatable command
        package.loaded["features._m1_manual"] = {
            api = 1, id = "m1_manual", name = "M1 Manual",
            actions = { { id = "go", run = function() end } },
        }
        registry.load("features._m1_manual"); registry.setEnabled("m1_manual", true)
        ok(rules.load({
            { id = "bad", on = { type = "state", signal = "frontmostApp", becomes = "X" },
              effect = { kind = "command", feature = "m1_manual", action = "go" } },
        }) == 0, "state trigger on a non-automatable command is refused (context policy)")

        -- (d) an unknown signal is refused
        ok(rules.load({
            { id = "badsig", on = { type = "state", signal = "ghost", becomes = "X" },
              effect = { kind = "notify", title = "x" } },
        }) == 0, "a rule on an unknown signal is refused")

        -- (e) mutation API + persistence + describe (the UI surface)
        local ran = 0
        package.loaded["features._m1_auto"] = {
            api = 1, id = "m1_auto", name = "M1 Auto",
            actions = { { id = "go", automatable = true, run = function() ran = ran + 1 end } },
        }
        registry.load("features._m1_auto"); registry.setEnabled("m1_auto", true)
        fake.settings["hammerdeck.rules"] = nil
        rules.load({})
        local okAdd, rid = rules.add({ on = { type = "event", event = "wake" },
            effect = { kind = "command", feature = "m1_auto", action = "go" } })
        ok(okAdd and type(rid) == "string", "add() assigns an id and returns it")
        ok(rules.count() == 1 and rules.liveCount() == 1, "added rule is loaded + bound")
        ok(type(fake.settings["hammerdeck.rules"]) == "string", "add() persisted to hammerdeck.rules")
        local persisted = json.decode(fake.settings["hammerdeck.rules"])
        ok(type(persisted) == "table" and persisted[1].id == rid, "persisted JSON carries the rule")

        local d = rules.describe()
        ok(#d == 1 and d[1].id == rid and d[1].enabled == true
            and d[1].triggerDesc:find("wake") and d[1].effectDesc:find("Run M1 Auto"),
            "describe() yields {id, enabled, triggerDesc, effectDesc} for the UI")
        -- the command effect names the action by its friendly "Do"-dropdown label
        -- (the feature name for a sole action), not the raw "m1_auto.go" id.
        ok(effects.describe({ kind = "command", feature = "m1_auto", action = "go" }) == "Run M1 Auto",
            "describe command uses the friendly action label")
        -- fallback: an unloaded/parked feature's command shows the raw ids (no blank)
        ok(effects.describe({ kind = "command", feature = "ghost", action = "x" }) == "Run ghost.x",
            "describe command falls back to raw ids when the feature isn't loaded")
        -- fallback: a LOADED feature but an unknown action (a stale rule whose action
        -- was renamed/removed) -- resolveAction fails -> raw ids, not a blank
        ok(effects.describe({ kind = "command", feature = "m1_auto", action = "bogus" }) == "Run m1_auto.bogus",
            "describe command falls back to raw ids for an unknown action on a loaded feature")

        local logsBefore = #fake.logs
        fake.systemEvent("wake")
        ok(ran == 1, "the added rule fires")
        local sawFireLog = false
        for i = logsBefore + 1, #fake.logs do
            if fake.logs[i]:find("fired") then sawFireLog = true end
        end
        ok(sawFireLog, "a fired rule logs a diagnostic trace (so silent no-fires are debuggable)")
        ok(rules.setEnabled(rid, false) == true, "setEnabled(false) succeeds")
        ok(rules.count() == 1 and rules.liveCount() == 0, "a disabled rule stays loaded but unbound")
        fake.systemEvent("wake")
        ok(ran == 1, "a disabled rule does not fire")
        ok(rules.setEnabled(rid, true) == true, "setEnabled(true) re-binds")
        fake.systemEvent("wake")
        ok(ran == 2, "the re-enabled rule fires again")

        -- update in place: keep the id, change the effect (the UI "Save changes")
        ok(rules.update(rid, { on = { type = "event", event = "wake" },
            effect = { kind = "notify", title = "updated" } }) == true,
            "update() replaces a rule's spec in place")
        local du = rules.describe()
        ok(#du == 1 and du[1].id == rid and du[1].effectDesc:find("updated") ~= nil,
            "update kept the id and changed the effect")
        ok(du[1].on ~= nil and du[1].effect ~= nil,
            "describe() carries the raw on/effect spec (so the edit form can pre-fill)")
        -- the context policy is enforced on update too, not just add
        ok(rules.update(rid, { on = { type = "state", signal = "frontmostApp", becomes = "X" },
            effect = { kind = "command", feature = "m1_manual", action = "go" } }) == false,
            "update() refuses a context-violating change (policy enforced on edit)")

        -- (e2) advanced "Edit as JSON": specJSON exposes one rule's full stored spec,
        -- and updateJSON round-trips it -- including fields the guided form can't build
        -- (a placement's titlePattern). Bad input is refused with a reason, never thrown.
        local sj = rules.specJSON(rid)
        ok(type(sj) == "string" and json.decode(sj).id == rid,
            "specJSON returns the rule's full spec as JSON")
        ok(select(1, rules.specJSON("nope")) == nil, "specJSON(unknown id) returns nil + reason")
        ok(rules.updateJSON(rid, '{"on":{"type":"event","event":"sleep"},'
            .. '"effect":{"kind":"layout","placements":[{"app":"Safari",'
            .. '"titlePattern":"Docs","screen":"DELL","pos":"left"}]}}') == true,
            "updateJSON accepts a spec with a placement titlePattern (the advanced field)")
        ok(rules.describe()[1].effect.placements[1].titlePattern == "Docs",
            "the titlePattern survived the JSON round-trip into the stored spec")
        ok(select(1, rules.updateJSON(rid, "{not json")) == false,
            "updateJSON refuses malformed JSON with a reason (no crash)")
        ok(select(1, rules.updateJSON(rid, '{"on":{"type":"event","event":"wake"},'
            .. '"effect":{"kind":"layout","placements":[{"app":"Safari",'
            .. '"titlePattern":123,"screen":"DELL","pos":"left"}]}}')) == false,
            "updateJSON rejects a non-string titlePattern (validate guards the advanced path)")

        ok(rules.remove(rid) == true and rules.count() == 0, "remove() drops the rule")

        -- (f) formOptions feeds the Add form's dropdowns
        local fo = rules.formOptions()
        local sawFrontmost = false
        for _, s in ipairs(fo.signals) do if s == "frontmostApp" then sawFrontmost = true end end
        ok(type(fo.signals) == "table" and sawFrontmost, "formOptions lists the available signals")
        local sawNotify = false
        for _, e in ipairs(fo.effects) do if e.kind == "notify" then sawNotify = true end end
        ok(sawNotify, "formOptions offers the notify effect")

        -- (g) rule NAMES + the on-demand "Test" (rules.fire) ----------------------
        -- Wrapped in a nested do...end so its locals release before the block's tail
        -- (Lua caps a function at 200 locals; this big T35 block runs close).
        do
            rules.load({})
            local okN, nid = rules.add({ name = "Dock at desk",
                on = { type = "event", event = "wake" },
                effect = { kind = "notify", title = "HD", text = "docked" } })
            ok(okN, "add() accepts an optional rule name")
            ok(rules.describe()[1].name == "Dock at desk", "describe() surfaces the rule name")

            -- describe() also carries the plain-English sentence -- the same read-back the
            -- editor's Name placeholder shows, so an unnamed rule lists AS that sentence.
            local specs = rules.all()
            local d1 = rules.describe()[1]
            ok(#specs >= 1 and #d1.sentence > 0 and d1.sentence == rules.sentence(specs[1]),
                "describe() carries the read-back sentence (the list shows it for unnamed rules)")

            -- an UNNAMED rule reports name == "" -- the fallback the list row leans on
            -- (it shows the trigger text when the name is blank, never a nil/"rule2").
            local _, nid2 = rules.add({ on = { type = "event", event = "wake" },
                effect = { kind = "notify", title = "HD" } })
            local unnamed
            for _, r in ipairs(rules.describe()) do if r.id == nid2 then unnamed = r end end
            ok(unnamed ~= nil and unnamed.name == "", "an unnamed rule reports name == \"\" (list-row fallback)")
            rules.remove(nid2)

            -- fire() runs the effect ON DEMAND, bypassing the trigger (the Test button)
            local nF = #fake.notifications
            local fOk, fNote = rules.fire(nid)
            ok(fOk == true and #fake.notifications == nF + 1,
                "fire() runs the effect on demand -- no trigger needed")
            ok(fNote == nil or fNote == "", "a clean fire returns no partial-success note")

            -- a manual test tags the log [test] so it never reads like a real trigger fire
            local taggedTest = false
            for i = 1, #fake.logs do if fake.logs[i]:find("%[test%]") then taggedTest = true end end
            ok(taggedTest, "fire() tags its log trace as a manual [test]")

            -- fire() tests a DISABLED rule too (you verify the effect, not the binding)
            rules.setEnabled(nid, false)
            local nD = #fake.notifications
            ok(select(1, rules.fire(nid)) == true and #fake.notifications == nD + 1,
                "fire() tests a disabled rule (verify the effect before enabling it)")

            ok(select(1, rules.fire("nope")) == false, "fire(unknown id) returns false + reason")

            -- a non-string name is refused by validate (guards the JSON path too)
            ok(select(1, rules.add({ name = 123,
                on = { type = "event", event = "wake" },
                effect = { kind = "notify", title = "x" } })) == false,
                "add() rejects a non-string name")

            -- a state trigger with an empty/non-string value is refused -- it would
            -- otherwise bind happily and silently NEVER fire (sig.match never matches
            -- "" or a number against a string-valued signal). The form blocks an empty
            -- value, but the JSON authoring path needs this engine-side backstop.
            ok(select(1, rules.add({ on = { type = "state", signal = "frontmostApp", becomes = "" },
                effect = { kind = "notify", title = "x" } })) == false,
                "add() rejects a state trigger with an empty value (silent-dead-rule guard)")
            ok(select(1, rules.add({ on = { type = "state", signal = "frontmostApp", becomes = 5 },
                effect = { kind = "notify", title = "x" } })) == false,
                "add() rejects a non-string state trigger value")

            -- a daily-at schedule must be a REAL clock time: "29:79" matched the old
            -- HH:MM regex but could never fire correctly -- now range-checked.
            ok(select(1, rules.add({ on = { type = "schedule", at = "29:79" },
                effect = { kind = "notify", title = "x" } })) == false,
                "add() rejects an out-of-range daily-at time (29:79)")
            ok(rules.add({ on = { type = "schedule", at = "23:59" },
                effect = { kind = "notify", title = "x" } }) == true,
                "add() still accepts a valid edge time (23:59)")
        end

        -- cleanup
        rules.load({})
        fake.settings["hammerdeck.rules"] = nil
        registry.setEnabled("m1_manual", false); registry.unregister("m1_manual")
        registry.setEnabled("m1_auto", false); registry.unregister("m1_auto")
        ok(fake.liveHandles == 0, "no native handle leaked across the M1 rules tests")
    end,
}
