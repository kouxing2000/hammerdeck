-- test/cases/password_generator.lua -- password_generator (build a random password,
-- copy to clipboard, notify; avoid-ambiguous class stripping; length floor; empty
-- character-set guidance).
--
-- Migrated from run.lua T13c (RUN_LUA_SPLIT_SPEC Phase 2). Hermetic: registers its own
-- feature; freshWorld() + handle tripwire keep it isolated.

return {
    id = "password_generator",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        registry.register(require("features.password_generator"))
        fake.settings["hammerdeck.opt.password_generator.length"]         = 24
        fake.settings["hammerdeck.opt.password_generator.avoidAmbiguous"] = true
        registry.setEnabled("password_generator", true)

        local pwNotes = #fake.notifications
        fake.pasteboard = nil
        fake.pressHotkey("p")
        local pw = fake.pasteboard
        ok(type(pw) == "string" and #pw == 24, "password_generator copies a 24-char password")
        ok(#fake.notifications == pwNotes + 1, "password_generator notifies on copy")

        -- avoidAmbiguous strips 0 O 1 l I; all four enabled classes still appear
        ok(not pw:find("[0O1lI]"), "avoidAmbiguous strips ambiguous glyphs")
        ok(pw:find("%l") and pw:find("%u") and pw:find("%d") and pw:find("[^%w]"),
            "all four character classes appear in the password")

        -- consecutive generations differ (randomness sanity)
        fake.pressHotkey("p"); local pw2 = fake.pasteboard
        fake.pressHotkey("p"); local pw3 = fake.pasteboard
        ok(pw2 ~= pw3, "consecutive passwords differ")

        -- length floor: a length below the enabled-class count still fits one of each
        fake.settings["hammerdeck.opt.password_generator.length"] = 2   -- < 4 classes
        fake.pressHotkey("p")
        ok(#fake.pasteboard == 4, "length below the class count widens to one char per class")

        -- no character set enabled: clipboard untouched, a guidance notification fires
        fake.settings["hammerdeck.opt.password_generator.lowercase"] = false
        fake.settings["hammerdeck.opt.password_generator.uppercase"] = false
        fake.settings["hammerdeck.opt.password_generator.digits"]    = false
        fake.settings["hammerdeck.opt.password_generator.symbols"]   = false
        fake.pasteboard = "UNCHANGED"
        pwNotes = #fake.notifications
        fake.pressHotkey("p")
        ok(fake.pasteboard == "UNCHANGED", "no character set enabled: clipboard untouched")
        ok(#fake.notifications == pwNotes + 1, "no character set enabled: guidance notification")

        registry.setEnabled("password_generator", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after password_generator test")
    end,
}
