-- test/cases/plain_paste.lua -- plain_paste (rewrite the clipboard as trimmed plain
-- text; newlines-to-commas mode; empty-clipboard alert; settle-timed cmd+v; type mode).
--
-- Migrated from run.lua T13 (RUN_LUA_SPLIT_SPEC Phase 2). Hermetic: registers its own
-- feature and drives its own clipboard/timer timeline; freshWorld() + handle tripwire
-- keep it isolated. (The describe-localization asserts that used to lean on this
-- section's registration now register their own copy -- see
-- test/cases/_integration/describe_localization.lua.)

return {
    id = "plain_paste",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        registry.register(require("features.plain_paste"))
        registry.setEnabled("plain_paste", true)

        -- plainText mode: trims (and the string round-trip strips formatting)
        fake.settings["hammerdeck.opt.plain_paste.mode"] = "plainText"
        fake.pasteboard = "   padded text\t "
        fake.pressHotkey("v")
        ok(fake.pasteboard == "padded text", "plainText mode trims the clipboard")

        -- newlinesToCommas mode
        fake.settings["hammerdeck.opt.plain_paste.mode"] = "newlinesToCommas"
        fake.pasteboard = "a\nb\r\nc"
        fake.pressHotkey("v")
        ok(fake.pasteboard == "a,b,c", "newlinesToCommas mode joins lines with commas")

        -- empty clipboard: alert, no write
        fake.pasteboard = ""
        local alertsBefore = #fake.alerts
        fake.pressHotkey("v")
        ok(#fake.alerts == alertsBefore + 1, "empty clipboard alerts")
        ok(fake.pasteboard == "", "empty clipboard left unchanged")

        -- one behavior: clean, then a synthesized cmd+v after the settle wait
        -- (immediate synthesis would merge with the still-held trigger modifiers)
        fake.settings["hammerdeck.opt.plain_paste.mode"] = "plainText"
        fake.pasteboard = "  pasted for you  "
        local keysBefore = #fake.keyEvents
        fake.pressHotkey("v")
        ok(fake.pasteboard == "pasted for you" and #fake.keyEvents == keysBefore,
            "cleans immediately; the paste waits for the settle timer")
        fake.fireTimers("after", 0.5)
        local pasteKey = fake.keyEvents[#fake.keyEvents]
        ok(pasteKey.key == "v" and pasteKey.mods[1] == "cmd", "then pastes (cmd+v)")

        -- the "type" action types the cleaned clipboard as keystrokes
        fake.pasteboard = "  secret token\n"
        fake.pressHotkey("y")
        ok(fake.typedTexts[#fake.typedTexts] == "secret token",
            "type action types the trimmed clipboard as keystrokes")

        registry.setEnabled("plain_paste", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after plain_paste test")
    end,
}
