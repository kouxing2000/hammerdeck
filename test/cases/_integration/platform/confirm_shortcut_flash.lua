-- test/cases/_integration/platform/confirm_shortcut_flash.lua -- the confirm-shortcut flash -- a MANUAL trigger flashes which action
-- fired ONLY while confirm_shortcut is on; a selfEvident feature (opens its
-- own UI) suppresses the flash even with the preference on.
--
-- Migrated from run.lua T7d (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "confirm_shortcut_flash",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        do
            package.loaded["features._flash_probe"] = {
                api = 1, id = "flash_probe", name = "Flash Probe", icon = "bolt.fill",
                defaultTrigger = { type = "hotkey", mods = { "ctrl", "alt" }, key = "8" },
                action = function() end,
            }
            registry.load("features._flash_probe")
            registry.setEnabled("flash_probe", true)

            fake.settings["hammerdeck.enabled.confirm_shortcut"] = false
            local flashBefore = #fake.flashes
            fake.pressHotkey("8", { "ctrl", "alt" })
            ok(#fake.flashes == flashBefore,
                "manual hotkey with the confirm preference OFF shows no flash")

            fake.settings["hammerdeck.enabled.confirm_shortcut"] = true
            fake.pressHotkey("8", { "ctrl", "alt" })
            ok(#fake.flashes == flashBefore + 1
                and fake.flashes[#fake.flashes].text == "Flash Probe"
                and fake.flashes[#fake.flashes].symbol == "bolt.fill",
                "manual hotkey with the confirm preference ON flashes the feature name + glyph")

            -- A self-evident feature (opens its own UI) suppresses the flash even with the
            -- preference ON -- the chooser/window it fronts is its own confirmation.
            package.loaded["features._selfev_probe"] = {
                api = 1, id = "selfev_probe", name = "Self Evident Probe", selfEvident = true,
                defaultTrigger = { type = "hotkey", mods = { "ctrl", "alt" }, key = "7" },
                action = function() end,
            }
            registry.load("features._selfev_probe")
            registry.setEnabled("selfev_probe", true)
            local selfevBefore = #fake.flashes
            fake.pressHotkey("7", { "ctrl", "alt" })
            ok(#fake.flashes == selfevBefore,
                "a selfEvident feature does not flash even with confirm_shortcut on")
            registry.setEnabled("selfev_probe", false)
            registry.unregister("selfev_probe")

            registry.setEnabled("flash_probe", false)
            registry.unregister("flash_probe")
            fake.settings["hammerdeck.enabled.confirm_shortcut"] = nil
        end
    end,
}
