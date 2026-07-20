-- test/cases/_integration/platform/catalog_describe.lua -- registry.describe() -- the config-UI catalog view. Registers the
-- MVP catalog (loadCatalog, exactly as the real bootstrap), asserts the
-- sorted list + per-feature/per-action trigger descriptions, mnemonics,
-- icons, contexts, OS-precondition requires, and the typed option export
-- (incl. enum values/labels) the form generator consumes.
--
-- Migrated from run.lua T1/T6/T7 (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "catalog_describe",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        registry.loadCatalog({ "features.sleep_schedule", "features.break_reminder", "features.window_switcher" })
        ok(#registry.all() == 3, "3 features registered")
        ok(fake.liveHandles == 0, "fake adapter reports zero live native resources")

        local desc = registry.describe()
        ok(#desc == 3, "describe lists all 3 features")
        ok(desc[1].id == "break_reminder" and desc[1].kind == "service", "describe is sorted by id")
        local jumpDesc = desc[3]
        ok(jumpDesc.id == "window_switcher" and jumpDesc.kind == "action", "window_switcher is an action")
        -- (window_switcher is single-action since the backward action was
        -- dropped; the "N actions" multi-action summary stays covered by the
        -- hybrid_probe block below.)
        ok(jumpDesc.triggerDesc == "hotkey: alt+tab",
            "a single-action feature shows that action's trigger in the list")
        ok(jumpDesc.actions[1].triggerDesc == "hotkey: alt+tab", "per-action trigger described")
        ok(type(jumpDesc.actions[1].mnemonic) == "string" and jumpDesc.actions[1].mnemonic:find("⌥Tab"),
            "per-action mnemonic surfaced in describe()")
        ok(#jumpDesc.options == 0,
            "window_switcher exports no options (cycle modifier derives from the trigger)")
        ok(jumpDesc.context == "window", "describe() surfaces the feature context")
        ok(jumpDesc.requires[1] == "accessibility",
            "describe() surfaces OS preconditions (window features need Accessibility)")
        -- The per-feature SF Symbol overlaid from feature.json (META_FIELDS) flows all
        -- the way to describe(), so the menubar/Settings/Gallery can render it. nil when
        -- a feature declares none (host then falls back to the category glyph).
        ok(jumpDesc.icon == "macwindow.on.rectangle",
            "describe() surfaces the per-feature icon overlaid from feature.json")
        -- typed option export incl. enum values, on a synthetic probe
        package.loaded["features._enum_probe"] = {
            api = 1, id = "enum_probe", name = "Enum Probe",
            options = { { key = "mode", type = "enum", default = "a",
                          values = { "a", "b", "c" }, labels = { "Ay", "Bee", "Cee" },
                          label = "Mode" } },
            defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "9" },
            action = function() end,
        }
        registry.load("features._enum_probe")
        local probeDesc0 = nil
        for _, e in ipairs(registry.describe()) do
            if e.id == "enum_probe" then probeDesc0 = e end
        end
        ok(probeDesc0.options[1].key == "mode" and probeDesc0.options[1].type == "enum"
            and #probeDesc0.options[1].values == 3,
            "typed options (incl. enum values) exported for the form generator")
        ok(probeDesc0.options[1].labels and probeDesc0.options[1].labels[2] == "Bee",
            "enum display labels exported parallel to values")
        registry.unregister("enum_probe")
        local sleepDesc = desc[2]
        ok(sleepDesc.kind == "service" and sleepDesc.triggerDesc == "always-on service",
            "a PURE service (no actions) is described as always-on")
        ok(#sleepDesc.options == 6, "sleep_schedule exports all 6 options")
        ok(sleepDesc.enabled == false, "describe reflects enabled state")

        -- ===== SERVICE TRIGGER SUMMARIES (guard for the "always-on service"
        -- mislabel): a service that ALSO declares actions (the deck/fan class)
        -- is TRIGGERED from the user's side -- its start() is plumbing (an idle
        -- controller so disable can tear down / restore), so describe() must
        -- summarize its ACTIONS and never fall back to the always-on label.
        -- Only a PURE service (sleepDesc above) reads "always-on service".
        -- Guarded at the registry level, so the Settings header, the feature
        -- list, and the shortcut map all inherit the truth.
        do
            package.loaded["features._hybrid_probe"] = {
                api = 1, id = "hybrid_probe", name = "Hybrid Probe",
                start = function() end,
                actions = {
                    { id = "one", label = "One", run = function() end,
                      defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "1" } },
                    { id = "two", label = "Two", run = function() end },
                },
            }
            package.loaded["features._hybrid_single_probe"] = {
                api = 1, id = "hybrid_single_probe", name = "Hybrid Single Probe",
                start = function() end,
                actions = {
                    { id = "only", label = "Only", run = function() end,
                      defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "2" } },
                },
            }
            -- A hybrid whose single action ships DORMANT (no defaultTrigger --
            -- the "no uninvited hotkey grabs" shape): describing it by its
            -- (absent) trigger would read "no trigger" = "does nothing", though
            -- its start() runs the whole time. It falls back to always-on.
            package.loaded["features._hybrid_dormant_probe"] = {
                api = 1, id = "hybrid_dormant_probe", name = "Hybrid Dormant Probe",
                start = function() end,
                actions = { { id = "only", label = "Only", run = function() end } },
            }
            registry.load("features._hybrid_probe")
            registry.load("features._hybrid_single_probe")
            registry.load("features._hybrid_dormant_probe")
            local hybrid, single, dormant
            for _, e in ipairs(registry.describe()) do
                if e.id == "hybrid_probe" then hybrid = e end
                if e.id == "hybrid_single_probe" then single = e end
                if e.id == "hybrid_dormant_probe" then dormant = e end
            end
            ok(dormant and dormant.triggerDesc == "always-on service",
                "a hybrid with a DORMANT single action reads always-on, never 'no trigger'")
            ok(hybrid and hybrid.kind == "service" and hybrid.triggerDesc == "2 actions",
                "a service + actions hybrid summarizes its ACTIONS, never 'always-on service'")
            ok(single and single.triggerDesc ~= "always-on service"
                and single.triggerDesc:find("ctrl", 1, true) ~= nil,
                "a single-action hybrid shows that action's real trigger")
            registry.unregister("hybrid_probe")
            registry.unregister("hybrid_single_probe")
            registry.unregister("hybrid_dormant_probe")
        end
    end,
}
