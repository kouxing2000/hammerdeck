-- test/cases/_integration/rules/rules_displays_present.lua -- displaysPresent signal (M2) -- "monitor connected/disconnected" as a named
-- state trigger. The precise form of the coarse screenChanged event: a rule on
-- `displaysPresent becomes "DELL"` fires when THAT monitor connects (membership
-- enter), `leaves` when it disconnects -- so the seed "external monitor" case is
-- expressible by name, with a symmetric disconnect for free.
--
-- Migrated from run.lua T37 (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration: platform subsystem, driven by throwaway features/effects. Hermetic --
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so the catalog
-- and the rules singleton both start empty.

return {
    id = "rules_displays_present",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
        local rules   = require("platform.rules")
        local signals = require("platform.signals")

        -- docked to the laptop only
        fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1 } }
        fake.settings["hammerdeck.rules"] = nil
        rules.load({})

        -- (a) displaysPresent is a known signal; its value is the connected-display set
        ok(signals.exists("displaysPresent"), "displaysPresent is a registered signal")
        local sig = signals.get("displaysPresent")
        local cur = sig.read()
        ok(type(cur) == "table" and cur[1] == "Built-in", "displaysPresent reads the connected display set")
        ok(sig.match(cur, "Built-in") == true and sig.match(cur, "DELL") == false,
            "membership match: Built-in is present, DELL is not")

        -- (b) a 'becomes' rule fires when THAT monitor connects, not on unrelated changes
        local nB = #fake.notifications
        ok(rules.add({
            on = { type = "state", signal = "displaysPresent", becomes = "DELL" },
            effect = { kind = "notify", title = "Docked", text = "DELL connected" },
        }) == true, "a displaysPresent-becomes rule loads (automated trigger, context-free effect)")
        fake.systemEvent("screenChanged")   -- same set (e.g. a resolution tweak)
        ok(#fake.notifications == nB, "screenChanged with no new display does not fire the connect rule")
        fake.screenList = {
            { x = 0,    y = 0, w = 1440, h = 900,  name = "Built-in", index = 1 },
            { x = 1440, y = 0, w = 2560, h = 1440, name = "DELL",     index = 2 },
        }
        fake.systemEvent("screenChanged")
        ok(#fake.notifications == nB + 1, "DELL connects -> the rule fires (membership enter)")
        fake.systemEvent("screenChanged")
        ok(#fake.notifications == nB + 1, "a further screenChanged with DELL still present does not re-fire")

        -- (c) a 'leaves' rule fires on DISCONNECT; the 'becomes' rule does not
        rules.add({
            on = { type = "state", signal = "displaysPresent", leaves = "DELL" },
            effect = { kind = "notify", title = "Undocked", text = "DELL gone" },
        })
        local nL = #fake.notifications
        fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1 } }
        fake.systemEvent("screenChanged")
        ok(#fake.notifications == nL + 1, "DELL disconnects -> only the 'leaves' rule fires")

        -- (d) formOptions exposes displaysPresent + its candidate displays
        local fo = rules.formOptions()
        local sawDisplays = false
        for _, s in ipairs(fo.signals) do if s == "displaysPresent" then sawDisplays = true end end
        ok(sawDisplays, "formOptions lists displaysPresent as a signal")
        ok(type(fo.signalCandidates.displaysPresent) == "table"
            and fo.signalCandidates.displaysPresent[1] == "Built-in",
            "formOptions offers the connected displays as candidates")

        -- cleanup
        rules.load({})
        fake.settings["hammerdeck.rules"] = nil
        fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1 } }
        ok(fake.liveHandles == 0, "no native handle leaked across the displaysPresent tests")
    end,
}
