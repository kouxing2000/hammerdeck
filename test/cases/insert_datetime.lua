-- test/cases/insert_datetime.lua -- insert_datetime (type the formatted current
-- time; preset + custom strftime patterns; invalid-pattern guard; Preview button).
--
-- Migrated from run.lua T13d (RUN_LUA_SPLIT_SPEC Phase 2). Hermetic: registers its
-- own feature; the formatted time it types is driven by the fake clock (fake.now()),
-- pinned by freshWorld(). The handle tripwire after keeps it isolated.

return {
    id = "insert_datetime",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        registry.register(require("features.insert_datetime"))
        registry.setEnabled("insert_datetime", true)

        -- a preset format types os.date(fmt, ctx.now()) -- driven by the fake clock
        fake.settings["hammerdeck.opt.insert_datetime.format"] = "%Y-%m-%d %H:%M:%S"
        local idtTyped = #fake.typedTexts
        fake.pressHotkey("d")
        ok(#fake.typedTexts == idtTyped + 1
            and fake.typedTexts[#fake.typedTexts] == os.date("%Y-%m-%d %H:%M:%S", fake.now()),
            "insert_datetime types the preset-formatted current time")

        -- Custom format selected + a custom pattern set -> uses the custom pattern
        fake.settings["hammerdeck.opt.insert_datetime.format"]       = "custom"
        fake.settings["hammerdeck.opt.insert_datetime.customFormat"] = "%Y/%m/%d"
        fake.pressHotkey("d")
        ok(fake.typedTexts[#fake.typedTexts] == os.date("%Y/%m/%d", fake.now()),
            "insert_datetime honors a custom strftime pattern")

        -- Custom selected but the field is empty -> nothing typed, a guidance note fires
        fake.settings["hammerdeck.opt.insert_datetime.customFormat"] = ""
        idtTyped = #fake.typedTexts
        local idtNotes = #fake.notifications
        fake.pressHotkey("d")
        ok(#fake.typedTexts == idtTyped, "insert_datetime types nothing when custom format is empty")
        ok(#fake.notifications == idtNotes + 1, "insert_datetime notifies when custom format is empty")

        -- An INVALID strftime pattern RAISES in os.date -- the guard must catch it
        -- (notify), not crash the action.
        fake.settings["hammerdeck.opt.insert_datetime.customFormat"] = "%Q"
        idtTyped = #fake.typedTexts
        idtNotes = #fake.notifications
        fake.pressHotkey("d")
        ok(#fake.typedTexts == idtTyped, "insert_datetime types nothing on an invalid pattern")
        ok(#fake.notifications == idtNotes + 1, "insert_datetime notifies (not crashes) on an invalid pattern")

        -- The "Preview" validator button (optionAction) mirrors the action: it alerts
        -- the formatted result for a good pattern and the reason for a bad one.
        fake.settings["hammerdeck.opt.insert_datetime.customFormat"] = "%Y/%m/%d"
        local idtAlerts = #fake.alerts
        ok(registry.runOptionAction("insert_datetime", "customFormat") == true,
            "insert_datetime Preview button runs")
        ok(#fake.alerts == idtAlerts + 1
            and fake.alerts[#fake.alerts]:find(os.date("%Y/%m/%d", fake.now()), 1, true),
            "Preview alerts the formatted current time for a valid pattern")
        fake.settings["hammerdeck.opt.insert_datetime.customFormat"] = "%Q"
        registry.runOptionAction("insert_datetime", "customFormat")
        ok(fake.alerts[#fake.alerts]:find("Invalid", 1, true),
            "Preview alerts an Invalid-format message for a bad pattern")

        registry.setEnabled("insert_datetime", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after insert_datetime test")
    end,
}
