-- test/cases/clipboard_history.lua -- clipboard history (poll, conceal, dedup, cap,
-- persist across disable/enable, pick-to-paste).
--
-- Migrated from run.lua T28 (RUN_LUA_SPLIT_SPEC Phase 2). Hermetic: registers its
-- own feature and drives its own copy/poll timeline; freshWorld() before + handle
-- tripwire after keep it isolated.

return {
    id = "clipboard_history",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        registry.register(require("features.clipboard_history"))
        registry.setEnabled("clipboard_history", true)
        local histPath = "/fake/data/clipboard_history/history.json"

        fake.copyText("alpha")
        fake.fireTimers("every", 0.8)
        ok(fake.files[histPath]:find("alpha", 1, true) ~= nil, "a copied entry is recorded + persisted")
        fake.copyText("beta")
        fake.fireTimers("every", 0.8)
        fake.copyText("the-password!", true)   -- concealed: password manager
        fake.fireTimers("every", 0.8)
        ok(fake.files[histPath]:find("the%-password") == nil,
            "concealed clips are NEVER recorded (checked before reading)")
        fake.copyText("alpha")                 -- re-copy: dedup moves to front
        fake.fireTimers("every", 0.8)

        fake.pressHotkey("h", { "cmd", "alt", "ctrl" })
        local hch = fake.visibleChooser()
        ok(hch ~= nil and #hch.choices == 2, "history chooser opens, deduped")
        ok(hch.choices[1].image == "symbol:doc.plaintext",
            "a text entry row carries the plain-text glyph")
        ok(hch.choices[1].text == "alpha" and hch.choices[2].text == "beta",
            "newest first, re-copy bumped alpha to the front")

        -- selecting writes the clipboard and pastes (paste_on_select donor default)
        fake.copyText("other")                 -- clipboard currently holds something else
        fake.fireTimers("every", 0.8)
        fake.pressHotkey("h", { "cmd", "alt", "ctrl" })
        fake.visibleChooser().userSelect(3)    -- pick "beta" (other, alpha, beta)
        ok(fake.pasteboard == "beta", "selection puts the entry on the clipboard")
        fake.fireTimers("after", 0.15)
        local pk = fake.keyEvents[#fake.keyEvents]
        ok(pk.key == "v" and pk.mods[1] == "cmd", "and pastes it (cmd+v)")

        -- pasteOnSelect off: clipboard only
        fake.settings["hammerdeck.opt.clipboard_history.pasteOnSelect"] = false
        local keysBefore28 = #fake.keyEvents
        fake.pressHotkey("h", { "cmd", "alt", "ctrl" })
        fake.visibleChooser().userSelect(2)
        fake.fireTimers("after", 0.15)
        ok(#fake.keyEvents == keysBefore28, "pasteOnSelect off -> no synthesized paste")
        fake.settings["hammerdeck.opt.clipboard_history.pasteOnSelect"] = nil

        -- the cap drops the oldest
        fake.settings["hammerdeck.opt.clipboard_history.historySize"] = nil
        fake.settings["hammerdeck.opt.clipboard_history.historySize"] = 2
        fake.copyText("gamma")
        fake.fireTimers("every", 0.8)
        fake.pressHotkey("h", { "cmd", "alt", "ctrl" })
        ok(#fake.visibleChooser().choices == 2, "historySize caps the list")
        fake.visibleChooser().userSelect(1)
        fake.fireTimers("after", 0.15)
        fake.settings["hammerdeck.opt.clipboard_history.historySize"] = nil

        -- history survives a disable/re-enable (restored from disk)
        registry.setEnabled("clipboard_history", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clipboard_history leaks nothing")
        registry.setEnabled("clipboard_history", true)
        fake.pressHotkey("h", { "cmd", "alt", "ctrl" })
        ok(#fake.visibleChooser().choices >= 1, "history restored from disk after re-enable")
        fake.visibleChooser().userSelect(1)
        fake.fireTimers("after", 0.15)
        registry.setEnabled("clipboard_history", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after clipboard_history test")
    end,
}
