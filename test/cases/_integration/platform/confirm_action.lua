-- test/cases/_integration/platform/confirm_action.lua -- ctx.confirmAction -- a modal feature suppresses the mode-entry flash
-- (selfEvident) and instead flashes when its real action lands, gated on the
-- same confirm_shortcut preference and carrying the feature icon.
--
-- Migrated from run.lua T7f (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "confirm_action",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        do
            package.loaded["features._confirm_probe"] = {
                api = 1, id = "confirm_probe", name = "Confirm Probe", icon = "star.fill",
                selfEvident = true,   -- entry hotkey must NOT auto-flash; only confirmAction does
                defaultTrigger = { type = "hotkey", mods = { "ctrl", "alt" }, key = "6" },
                action = function(ctx) ctx.confirmAction() end,
            }
            registry.load("features._confirm_probe")
            registry.setEnabled("confirm_probe", true)

            fake.settings["hammerdeck.enabled.confirm_shortcut"] = false
            local cBefore = #fake.flashes
            fake.pressHotkey("6", { "ctrl", "alt" })
            ok(#fake.flashes == cBefore,
                "ctx.confirmAction does not flash while confirm_shortcut is off")

            fake.settings["hammerdeck.enabled.confirm_shortcut"] = true
            fake.pressHotkey("6", { "ctrl", "alt" })
            ok(#fake.flashes == cBefore + 1
                and fake.flashes[#fake.flashes].text == "Confirm Probe"
                and fake.flashes[#fake.flashes].symbol == "star.fill",
                "ctx.confirmAction flashes the feature name + icon once confirm_shortcut is on")

            registry.setEnabled("confirm_probe", false)
            registry.unregister("confirm_probe")
            fake.settings["hammerdeck.enabled.confirm_shortcut"] = nil
        end
    end,
}
