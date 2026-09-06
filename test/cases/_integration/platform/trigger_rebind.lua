-- test/cases/_integration/platform/trigger_rebind.lua -- trigger rebind -- bind ANY action to ANY trigger (the core
-- promise). Codec round-trips for every spec shape, HH:MM parsing, validate +
-- modifier-name rejection, describe/glyph formatters, live rebind on a probe,
-- conflict refusal, the automatable policy (seam refuses an automated trigger
-- on a non-automatable action + ignores a stale stored one), clearTrigger,
-- and swapTriggers.
--
-- Migrated from run.lua T10 (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "trigger_rebind",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry, triggers = t.ok, t.fake, t.registry, t.triggers

        registry.loadCatalog({ "features.sleep_schedule", "features.break_reminder", "features.window_switcher" })

        -- codec round-trips for every spec shape
        local function roundtrip(spec) return triggers.decode(triggers.encode(spec)) end
        local hk = roundtrip({ type = "hotkey", mods = { "cmd", "alt" }, key = "j" })
        ok(hk.type == "hotkey" and hk.key == "j" and #hk.mods == 2, "hotkey codec round-trips")
        ok(triggers.encode({ type = "hotkey", mods = { "cmd", "alt" }, key = "j" })
            == triggers.encode({ type = "hotkey", mods = { "alt", "cmd" }, key = "j" }),
            "hotkey encoding is canonical (mod order does not matter)")
        ok(roundtrip({ type = "schedule", everyMin = 25 }).everyMin == 25, "schedule-every codec round-trips")
        ok(roundtrip({ type = "schedule", at = "00:30" }).at == "00:30", "schedule-at codec round-trips")
        ok(roundtrip({ type = "event", event = "wake" }).event == "wake", "event codec round-trips")
        ok(triggers.decode("garbage") == nil, "decode rejects a malformed string")
        ok(triggers.decode("event|bogus") == nil, "decode rejects an unknown event")

        -- shared HH:MM parse: valid times parse to numbers, out-of-range/malformed reject
        do
            local h, m = triggers.parseTimeOfDay("09:05")
            ok(h == 9 and m == 5, "parseTimeOfDay reads a valid HH:MM")
            local zh, zm = triggers.parseTimeOfDay("00:00")
            ok(zh == 0 and zm == 0, "parseTimeOfDay reads midnight (0 is a valid hour)")
            ok(triggers.parseTimeOfDay("29:99") == nil, "parseTimeOfDay rejects out-of-range 29:99")
            ok(triggers.parseTimeOfDay("8:5") == nil, "parseTimeOfDay rejects a 1-digit minute")
            ok(triggers.parseTimeOfDay("8") == nil, "parseTimeOfDay rejects a bare hour")
        end
        -- the gap the unified util closes: decode used to accept an out-of-range "at"
        ok(triggers.decode("schedule|at|29:99") == nil, "decode rejects an out-of-range schedule at")
        ok(triggers.decode("schedule|at|07:30").at == "07:30", "decode still accepts a valid schedule at")

        -- validate rejects malformed specs
        ok(not pcall(triggers.validate, { type = "hotkey" }), "validate rejects a hotkey with no key")
        ok(not pcall(triggers.validate, { type = "event", event = "nope" }), "validate rejects an unknown event")
        ok(not pcall(triggers.validate, { type = "schedule" }), "validate rejects a schedule with no when")
        ok(not pcall(triggers.validate, { type = "schedule", at = "29:99" }),
            "validate rejects a schedule with an out-of-range at")

        -- modifier NAMES are validated too (the Swift parsers used to drop an unknown
        -- name silently, binding a less-modified combo); long aliases stay accepted.
        ok(not pcall(triggers.validate, { type = "hotkey", mods = { "cmmd" }, key = "k" }),
            "validate rejects a hotkey with an unknown modifier")
        ok(not pcall(triggers.validate, { type = "chord", mods = { "hyper" }, key = "a", follows = { "b" } }),
            "validate rejects a chord with an unknown modifier")
        ok(pcall(triggers.validate, { type = "hotkey", mods = { "Command", "option" }, key = "k" }),
            "validate accepts long modifier aliases, case-insensitive")

        -- the fake adapter mirrors the seam's loud token rejection (KeyModifier.swift):
        -- a typo'd token errors in tests exactly like the real bridge would.
        ok(not pcall(fake.adapter.bindHotkey, { "cmmd" }, "k", function() end),
            "fake bind_hotkey rejects an unknown modifier")
        ok(not pcall(fake.adapter.keyStroke, { "comd" }, "v"), "fake key_stroke rejects an unknown modifier")
        ok(not pcall(fake.adapter.keyStroke, { true }, "v"), "fake key_stroke rejects a non-string modifier")
        ok(not pcall(fake.adapter.isModifierHeld, "atl"), "fake is_modifier_held rejects an unknown modifier")
        ok(not pcall(fake.adapter.setAppearance, "drak"), "fake set_appearance rejects an unknown mode")
        ok(pcall(fake.adapter.setAppearance, "toggle") and pcall(fake.adapter.setAppearance, nil),
            "fake set_appearance accepts toggle and nil (= toggle)")

        -- spec -> string formatters (the verbose describe + compact glyph forms)
        ok(triggers.describe(nil) == "no trigger", "describe: nil -> no trigger")
        ok(triggers.describe({ type = "hotkey", mods = { "cmd", "shift" }, key = "v" })
            == "hotkey: cmd+shift+v", "describe: hotkey")
        ok(triggers.describe({ type = "chord", mods = { "cmd" }, key = "a", follows = { "b", "c" } })
            == "chord: cmd+a then b c", "describe: chord")
        ok(triggers.describe({ type = "schedule", everyMin = 25 }) == "schedule: every 25 min", "describe: schedule-every")
        ok(triggers.describe({ type = "schedule", at = "00:30" }) == "schedule: daily at 00:30", "describe: schedule-at")
        ok(triggers.describe({ type = "event", event = "wake" }) == "event: wake", "describe: event")
        ok(triggers.glyph(nil) == nil, "glyph: nil -> nil")
        ok(triggers.glyph({ type = "hotkey", mods = { "cmd", "shift" }, key = "v" }) == "⇧⌘V", "glyph: hotkey canonical order + upcase")
        ok(triggers.glyph({ type = "hotkey", mods = { "control", "option" }, key = "left" }) == "⌃⌥←",
            "glyph: long-form mod aliases + named key")
        ok(triggers.glyph({ type = "chord", mods = { "cmd" }, key = "a", follows = { "b" } }) == "⌘A B", "glyph: chord (follow keys upcased)")
        ok(triggers.glyph({ type = "schedule", everyMin = 180 }) == "every 180m", "glyph: schedule-every")
        ok(triggers.glyph({ type = "event", event = "wake" }) == "on wake", "glyph: event")

        -- live rebind on a synthetic probe (counter action, no chooser state to manage)
        local fires = 0
        package.loaded["features._rebind_probe"] = {
            api = 1, id = "rebind_probe", name = "Rebind Probe",
            defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "p" },
            action = function() fires = fires + 1 end,
        }
        registry.load("features._rebind_probe")
        registry.setEnabled("rebind_probe", true)
        fake.pressHotkey("p")
        ok(fires == 1, "default trigger fires the action")
        ok(registry.setTrigger("rebind_probe", { type = "hotkey", mods = { "ctrl" }, key = "q" }) == true,
            "setTrigger rebinds successfully")
        fake.pressHotkey("p")
        ok(fires == 1, "the old hotkey no longer fires after rebind")
        fake.pressHotkey("q")
        ok(fires == 2, "the new hotkey fires the rebound action")
        ok(fake.settings["hammerdeck.trigger.rebind_probe.main"] == "hotkey|ctrl|q",
            "the override is persisted as an encoded string (per-action key)")

        -- conflict: a second enabled feature already owns ctrl+q
        local fires2 = 0
        package.loaded["features._rebind_other"] = {
            api = 1, id = "rebind_other", name = "Other Probe",
            defaultTrigger = { type = "hotkey", mods = { "alt" }, key = "z" },
            action = function() fires2 = fires2 + 1 end,
        }
        registry.load("features._rebind_other")
        registry.setEnabled("rebind_other", true)
        local okSet, reason = registry.setTrigger("rebind_other", { type = "hotkey", mods = { "ctrl" }, key = "q" })
        ok(okSet == false and reason ~= nil, "setTrigger refuses a hotkey already taken by an enabled feature")
        fake.pressHotkey("z")
        ok(fires2 == 1, "the rejected rebind left the original binding intact")

        -- a service has no rebindable trigger
        ok(not pcall(registry.setTrigger, "sleep_schedule", { type = "event", event = "wake" }),
            "setTrigger rejects always-on service features")

        -- describe exposes the editable trigger + override flag
        local probeDesc
        for _, d in ipairs(registry.describe()) do if d.id == "rebind_probe" then probeDesc = d end end
        ok(probeDesc.actions[1].trigger and probeDesc.actions[1].trigger.key == "q",
            "describe exposes the current trigger spec")
        ok(probeDesc.actions[1].triggerOverridden == true, "describe reports the override state")

        -- automatable policy: schedule/event are the automated trigger types ----------
        ok(triggers.isAutomated({ type = "schedule", everyMin = 5 }) == true, "schedule is automated")
        ok(triggers.isAutomated({ type = "event", event = "wake" }) == true, "event is automated")
        ok(triggers.isAutomated({ type = "hotkey", key = "p" }) == false, "hotkey is not automated")
        ok(triggers.isAutomated({ type = "chord", key = "a", follows = { "b" } }) == false, "chord is not automated")

        -- rebind_probe is the default (non-automatable): the seam refuses an automated
        -- trigger but still accepts a manual one, and describe reports the flag.
        ok(probeDesc.actions[1].automatable == false, "describe surfaces automatable=false by default")
        local okAuto, whyAuto = registry.setTrigger("rebind_probe", { type = "schedule", everyMin = 5 })
        ok(okAuto == false and whyAuto ~= nil, "seam refuses a schedule trigger on a non-automatable action")
        local okAuto2 = registry.setTrigger("rebind_probe", { type = "event", event = "wake" })
        ok(okAuto2 == false, "seam refuses an event trigger on a non-automatable action")

        -- an automatable action accepts an automated trigger
        local autoFires = 0
        package.loaded["features._auto_probe"] = {
            api = 1, id = "auto_probe", name = "Auto Probe",
            actions = { { id = "main", automatable = true, run = function() autoFires = autoFires + 1 end } },
        }
        registry.load("features._auto_probe")
        registry.setEnabled("auto_probe", true)
        ok(registry.setTrigger("auto_probe", { type = "schedule", everyMin = 15 }) == true,
            "seam accepts a schedule trigger on an automatable action")
        local autoDesc
        for _, d in ipairs(registry.describe()) do if d.id == "auto_probe" then autoDesc = d end end
        ok(autoDesc.actions[1].automatable == true, "describe surfaces automatable=true")
        registry.setEnabled("auto_probe", false)
        registry.unregister("auto_probe")

        -- bind-on-load enforcement: a STALE stored automated override on a
        -- non-automatable action (e.g. left behind after an author dropped automatable,
        -- or hand-edited) must be ignored on read, not bound. rebind_probe is the
        -- non-automatable hotkey probe; plant a schedule override directly in settings.
        fake.settings["hammerdeck.trigger.rebind_probe.main"] = "schedule|every|5"
        do
            local staleDesc
            for _, d in ipairs(registry.describe()) do if d.id == "rebind_probe" then staleDesc = d end end
            ok(staleDesc.actions[1].trigger.type == "hotkey",
                "a stale automated override on a non-automatable action is ignored (falls back to default)")
        end
        fake.settings["hammerdeck.trigger.rebind_probe.main"] = nil

        -- clearTrigger reverts to the manifest default
        registry.clearTrigger("rebind_probe")
        ok(fake.settings["hammerdeck.trigger.rebind_probe.main"] == nil
            and fake.settings["hammerdeck.trigger.rebind_probe"] == nil,
            "clearTrigger removes the override")
        fake.pressHotkey("p")
        ok(fires == 3, "clearTrigger restored the default trigger")
        fake.pressHotkey("q")
        ok(fires == 3, "the override key is no longer bound after clear")

        -- swapTriggers exchanges two actions' shortcuts (the Shortcut Map drag-to-swap).
        -- probe is ctrl+p, other is alt+z; after the swap they trade.
        local pf, of = fires, fires2
        ok(registry.swapTriggers("rebind_probe", "main", "rebind_other", "main") == true,
            "swapTriggers returns true")
        ok(fake.settings["hammerdeck.trigger.rebind_probe.main"] == "hotkey|alt|z",
            "probe took the other's hotkey (persisted)")
        ok(fake.settings["hammerdeck.trigger.rebind_other.main"] == "hotkey|ctrl|p",
            "other took the probe's hotkey (persisted)")
        fake.pressHotkey("z", { "alt" })
        ok(fires == pf + 1, "after swap, probe fires on alt+z (the other's old key)")
        fake.pressHotkey("p", { "ctrl" })
        ok(fires2 == of + 1, "after swap, other fires on ctrl+p (the probe's old key)")
        ok(fires == pf + 1, "probe no longer fires on ctrl+p")

        -- P-4: swapTriggers must honour the same automatable policy setTrigger
        -- enforces. "The combo SET is unchanged" is true, and says nothing about
        -- whether each spec is LEGAL on its new action: an automated spec landing
        -- on a context-dependent action is refused at LOAD, so that action falls
        -- back to its DEFAULT trigger -- the combo the other side has just taken.
        -- One press then fires both, and the schedule is gone.
        do
            package.loaded["features._swap_auto"] = {
                api = 1, id = "swap_auto", name = "Swap Auto",
                actions = { { id = "main", automatable = true,
                              defaultTrigger = { type = "schedule", everyMin = 30 },
                              run = function() end } },
            }
            registry.load("features._swap_auto")
            registry.setEnabled("swap_auto", true)

            local beforeProbe = fake.settings["hammerdeck.trigger.rebind_probe.main"]
            local beforeAuto  = fake.settings["hammerdeck.trigger.swap_auto.main"]
            local okSwap, whySwap =
                registry.swapTriggers("swap_auto", "main", "rebind_probe", "main")
            ok(okSwap == false and whySwap ~= nil,
                "swapTriggers refuses a schedule landing on a non-automatable action (P-4)")
            ok(fake.settings["hammerdeck.trigger.rebind_probe.main"] == beforeProbe
                and fake.settings["hammerdeck.trigger.swap_auto.main"] == beforeAuto,
                "...and writes NEITHER side -- a half-swap cannot be undone by swapping back")

            registry.setEnabled("swap_auto", false)
            registry.unregister("swap_auto")
            package.loaded["features._swap_auto"] = nil
        end

        registry.setEnabled("rebind_probe", false)
        registry.setEnabled("rebind_other", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after trigger-rebind tests")
    end,
}
