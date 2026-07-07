-- test/cases/_integration/rules/rules_atomic_effects.lua -- curated atomic effects (M3) -- runShortcut (the Shortcuts escape hatch),
-- openURL, lockScreen. All context-free, so they validate + fire on automated
-- triggers and the form's Do dropdown offers them.
--
-- Migrated from run.lua T39 (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration: platform subsystem, driven by throwaway features/effects. Hermetic --
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so the catalog
-- and the rules singleton both start empty.

return {
    id = "rules_atomic_effects",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
        local effects = require("platform.effects")
        local rules   = require("platform.rules")

        fake.settings["hammerdeck.rules"] = nil
        rules.load({})

        -- context-free + validated
        ok(effects.requiresContext({ kind = "runShortcut", name = "X" }) == false, "runShortcut is context-free")
        ok(effects.requiresContext({ kind = "openURL", url = "x" }) == false, "openURL is context-free")
        ok(effects.requiresContext({ kind = "lockScreen" }) == false, "lockScreen is context-free")
        ok(pcall(effects.validate, { kind = "runShortcut" }) == false, "runShortcut requires a name")
        ok(pcall(effects.validate, { kind = "openURL" }) == false, "openURL requires a url")
        ok(pcall(effects.validate, { kind = "lockScreen" }) == true, "lockScreen needs no params")

        -- dispatch routes to the adapter
        local nS = #fake.shortcutsRun
        effects.dispatch({ kind = "runShortcut", name = "Wind Down" })
        ok(#fake.shortcutsRun == nS + 1 and fake.shortcutsRun[#fake.shortcutsRun] == "Wind Down",
            "runShortcut dispatch runs the named Shortcut")
        local nU = #fake.openedUrls
        effects.dispatch({ kind = "openURL", url = "https://hammerdeck.app" })
        ok(#fake.openedUrls == nU + 1, "openURL dispatch opens the url")
        local nL = fake.actions.lock
        effects.dispatch({ kind = "lockScreen" })
        ok(fake.actions.lock == nL + 1, "lockScreen dispatch locks the screen")

        -- startScreensaver: a param-free context-free effect (sibling of lockScreen)
        ok(effects.requiresContext({ kind = "startScreensaver" }) == false, "startScreensaver is context-free")
        ok(pcall(effects.validate, { kind = "startScreensaver" }) == true, "startScreensaver needs no params")
        ok(effects.describe({ kind = "startScreensaver" }) == "Start the screensaver", "describe labels startScreensaver")
        local nSS = fake.actions.screensaver
        effects.dispatch({ kind = "startScreensaver" })
        ok(fake.actions.screensaver == nSS + 1, "startScreensaver dispatch starts the screensaver")

        -- speak: a context-free parameterized effect (a spoken sibling of notify)
        ok(effects.requiresContext({ kind = "speak", text = "hi" }) == false, "speak is context-free")
        ok(pcall(effects.validate, { kind = "speak", text = "hello" }) == true, "speak validates with text")
        ok(pcall(effects.validate, { kind = "speak" }) == false, "speak requires text")
        ok(pcall(effects.validate, { kind = "speak", text = "" }) == false, "speak rejects empty text")
        ok(effects.describe({ kind = "speak", text = "Standup" }) == 'Say "Standup"', "describe labels a speak effect")
        local nSp = #fake.spokenTexts
        effects.dispatch({ kind = "speak", text = "Battery low" })
        ok(#fake.spokenTexts == nSp + 1 and fake.spokenTexts[#fake.spokenTexts] == "Battery low",
            "speak dispatch says the text")

        -- emptyTrash / eject: param-free context-free system effects
        ok(effects.requiresContext({ kind = "emptyTrash" }) == false, "emptyTrash is context-free")
        ok(effects.requiresContext({ kind = "eject" }) == false, "eject is context-free")
        ok(pcall(effects.validate, { kind = "emptyTrash" }) == true, "emptyTrash needs no params")
        ok(pcall(effects.validate, { kind = "eject" }) == true, "eject needs no params")
        ok(effects.describe({ kind = "emptyTrash" }) == "Empty the Trash", "describe labels emptyTrash")
        ok(effects.describe({ kind = "eject" }) == "Eject external disks", "describe labels eject")
        local nT = fake.trashEmptied
        fake.trashReturn = 3
        local okT, noteT = effects.dispatch({ kind = "emptyTrash" })
        ok(fake.trashEmptied == nT + 1, "emptyTrash dispatch empties the trash")
        ok(okT == true and noteT == "emptied 3 items", "emptyTrash surfaces the count as a note")
        fake.trashReturn = 0   -- already empty: clean success, no note
        local okT0, noteT0 = effects.dispatch({ kind = "emptyTrash" })
        ok(okT0 == true and noteT0 == nil, "empty Trash is a clean success with no note")
        fake.trashReturn = -1  -- found items, removed none: a Full Disk Access denial
        local okTf, noteTf = effects.dispatch({ kind = "emptyTrash" })
        ok(okTf == false and noteTf:find("Full Disk Access"), "emptyTrash -1 surfaces a real failure")
        fake.trashReturn = 3   -- restore default
        local nEj = fake.ejected
        fake.ejectReturn = 1
        local okE, noteE = effects.dispatch({ kind = "eject" })
        ok(fake.ejected == nEj + 1, "eject dispatch ejects disks")
        ok(okE == true and noteE == "ejected 1 disk", "eject surfaces the count as a note")
        fake.ejectReturn = -1  -- disks present but all busy
        local okEf, noteEf = effects.dispatch({ kind = "eject" })
        ok(okEf == false and noteEf:find("busy"), "eject -1 surfaces a real failure")
        fake.ejectReturn = 1   -- restore default

        -- setAppearance / volume / mediaKey: the three system state-changers demoted
        -- from thin standalone features to grouped rules atoms. Each carries one enum
        -- param the guided form's sub-picker sets; all context-free.
        ok(effects.requiresContext({ kind = "setAppearance", mode = "dark" }) == false, "setAppearance is context-free")
        ok(pcall(effects.validate, { kind = "setAppearance", mode = "dark" }) == true, "setAppearance validates a mode")
        ok(pcall(effects.validate, { kind = "setAppearance" }) == false, "setAppearance requires a mode")
        ok(pcall(effects.validate, { kind = "setAppearance", mode = "sepia" }) == false, "setAppearance rejects a bad mode")
        ok(effects.describe({ kind = "setAppearance", mode = "dark" }) == "Switch to dark", "describe labels setAppearance dark")
        ok(effects.describe({ kind = "setAppearance", mode = "toggle" }) == "Toggle dark mode", "describe labels setAppearance toggle")
        local nA = #fake.appearanceSet
        effects.dispatch({ kind = "setAppearance", mode = "light" })
        ok(#fake.appearanceSet == nA + 1 and fake.appearanceSet[#fake.appearanceSet] == "light",
            "setAppearance dispatch sets the appearance")

        ok(effects.requiresContext({ kind = "volume", op = "up" }) == false, "volume is context-free")
        ok(pcall(effects.validate, { kind = "volume", op = "mute" }) == true, "volume validates an op")
        ok(pcall(effects.validate, { kind = "volume" }) == false, "volume requires an op")
        ok(pcall(effects.validate, { kind = "volume", op = "max" }) == false, "volume rejects a bad op")
        ok(effects.describe({ kind = "volume", op = "mute" }) == "Toggle mute", "describe labels volume mute")
        fake.volume = 50; fake.muted = false
        effects.dispatch({ kind = "volume", op = "up" })
        ok(fake.volume == 60, "volume up nudges +10")
        effects.dispatch({ kind = "volume", op = "down" })
        ok(fake.volume == 50, "volume down nudges -10")
        effects.dispatch({ kind = "volume", op = "mute" })
        ok(fake.muted == true, "volume mute toggles mute")
        fake.volumeReturn = -1   -- AppleScript error: adjustVolume returns -1
        local okVf, noteVf = effects.dispatch({ kind = "volume", op = "up" })
        ok(okVf == false and noteVf ~= nil, "volume -1 surfaces a real failure, not a lying green")
        fake.volumeReturn = nil   -- restore

        ok(effects.requiresContext({ kind = "mediaKey", key = "playpause" }) == false, "mediaKey is context-free")
        ok(pcall(effects.validate, { kind = "mediaKey", key = "next" }) == true, "mediaKey validates a key")
        ok(pcall(effects.validate, { kind = "mediaKey" }) == false, "mediaKey requires a key")
        ok(pcall(effects.validate, { kind = "mediaKey", key = "rewind" }) == false, "mediaKey rejects a bad key")
        ok(effects.describe({ kind = "mediaKey", key = "previous" }) == "Previous track", "describe labels mediaKey previous")
        fake.mediaKeys = {}
        effects.dispatch({ kind = "mediaKey", key = "playpause" })
        ok(#fake.mediaKeys == 1 and fake.mediaKeys[1] == "playpause", "mediaKey dispatch posts the transport key")

        -- end-to-end on an automated trigger: on wake -> run a Shortcut
        rules.add({ on = { type = "event", event = "wake" },
                    effect = { kind = "runShortcut", name = "Morning" } })
        ok(rules.describe()[1].effectDesc == 'Run Shortcut "Morning"', "describe labels a runShortcut effect")
        local nS2 = #fake.shortcutsRun
        fake.systemEvent("wake")
        ok(#fake.shortcutsRun == nS2 + 1, "on wake -> the Shortcut runs")

        -- the Do dropdown offers all three (context-free survive automatedOnly)
        local seen = {}
        for _, e in ipairs(effects.catalog(true)) do seen[e.kind] = true end
        ok(seen.runShortcut and seen.openURL and seen.lockScreen,
            "catalog offers runShortcut + openURL + lockScreen on automated triggers")
        ok(seen.setAppearance and seen.volume and seen.mediaKey,
            "catalog offers the appearance / volume / media atoms on automated triggers")

        rules.load({}); fake.settings["hammerdeck.rules"] = nil
        ok(fake.liveHandles == 0, "no native handle leaked across the effect tests")
    end,
}
