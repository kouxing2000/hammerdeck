-- test/cases/_integration/shortcut_advisories.lua -- triggers.advisories: the SOFT collision
-- warnings shown when a user binds a shortcut. It flags curated macOS factory defaults (present
-- even with an empty live read -- Spotlight on cmd+space, Finder search on cmd+alt+space),
-- common-app menu shadows (cmd+W = Close Window, case-insensitive on the key), and any
-- user-customized system shortcut read live from the OS -- while leaving free ergonomic combos,
-- the shipped command-palette default, and non-keyboard triggers advisory-free. A chord warns on
-- its prefix (a real global hotkey).
--
-- Migrated from run.lua T31's advisories sub-block (RUN_LUA_SPLIT_SPEC). Integration of a CORE
-- module (not a feature, no handles): the monolith leaned on `triggers` required back at T10;
-- the case sources it from the harness instead. It sets fake.systemHotkeys for the live-read
-- probe -- freshWorld() restores the pristine (empty) system-hotkey list for the next case.

return {
    id = "shortcut_advisories",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, triggers = t.ok, t.fake, t.triggers

        local function hasWarn(list, needle)
            for _, s in ipairs(list) do if s:find(needle, 1, true) then return true end end
            return false
        end

        -- curated macOS factory defaults (present even with an empty live read)
        fake.systemHotkeys = {}
        ok(hasWarn(triggers.advisories({ type = "hotkey", mods = { "cmd" }, key = "space" }), "Spotlight"),
            "cmd+space warns about Spotlight")
        ok(hasWarn(triggers.advisories({ type = "hotkey", mods = { "cmd", "alt" }, key = "space" }),
            "Finder search"), "cmd+alt+space warns about Finder search")
        -- the command palette's shipped default must be clean out of the box
        ok(#triggers.advisories({ type = "hotkey", mods = { "cmd", "shift" }, key = "space" }) == 0,
            "command palette default (shift+cmd+space) is conflict-free")
        -- common-app shadow (case-insensitive on the typed key)
        ok(hasWarn(triggers.advisories({ type = "hotkey", mods = { "cmd" }, key = "W" }), "Close Window"),
            "cmd+W warns it shadows Close Window")
        -- a free, ergonomic combo is clean
        ok(#triggers.advisories({ type = "hotkey", mods = { "ctrl", "alt", "cmd" }, key = "j" }) == 0,
            "ctrl+alt+cmd+j has no advisories")
        -- a chord prefix that collides still warns (the prefix is a real global hotkey)
        ok(hasWarn(triggers.advisories({ type = "chord", mods = { "cmd" }, key = "space", follows = { "b" } }),
            "Spotlight"), "a chord whose prefix is cmd+space warns about Spotlight")
        -- non-keyboard triggers never produce advisories
        ok(#triggers.advisories({ type = "schedule", everyMin = 5 }) == 0, "schedule trigger: no advisories")
        -- the live read is honored: a user-customized system shortcut is detected
        fake.systemHotkeys = { { mods = { "ctrl", "shift" }, key = "k", name = "My Custom Action" } }
        ok(hasWarn(triggers.advisories({ type = "hotkey", mods = { "ctrl", "shift" }, key = "k" }),
            "My Custom Action"), "live-read system shortcut is detected")
        fake.systemHotkeys = {}
    end,
}
