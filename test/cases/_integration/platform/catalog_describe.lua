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
        ok(jumpDesc.triggerDesc == "2 actions", "multi-action feature summarized in the list")
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
            "service features described as always-on")
        ok(#sleepDesc.options == 6, "sleep_schedule exports all 6 options")
        ok(sleepDesc.enabled == false, "describe reflects enabled state")
    end,
}
