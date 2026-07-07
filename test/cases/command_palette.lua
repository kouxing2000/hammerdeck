-- test/cases/command_palette.lua -- command_palette: a fuzzy launcher (Hyper+Space) over
-- every enabled feature's actions. It reaches across features via the privileged
-- `capabilities = {"commands"}` grant (ctx.commands / ctx.runCommand, injected only for
-- holders -- least privilege), so it doubles as the coverage for that capability gate:
-- manifest.validate rejects an unknown capability, a plain feature never receives the
-- methods, and running a selected command defers to the next tick so the panel yields focus
-- first. Also covers the row shape (single- vs multi-action, source column, shortcut glyphs),
-- the showShortcuts option, frecency ordering, and the empty-catalog info row.
--
-- Migrated from run.lua T29 (RUN_LUA_SPLIT_SPEC Phase 2). Hermetic: registers command_palette
-- plus its own throwaway `features._cmd_*` fixtures (injected into package.loaded, which
-- freshWorld's `^features%.` purge clears before the next case). Sources manifest from the
-- harness for the capability-gate checks.

return {
    id = "command_palette",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry, manifest = t.ok, t.fake, t.registry, t.manifest

        registry.register(require("features.command_palette"))

        -- the capability gate is enforced at manifest validation
        ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
            capabilities = { "bogus" } }), "manifest rejects an unknown capability")
        ok(pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
            capabilities = { "commands" } }), "manifest accepts the known capability")

        -- per-action icon is optional metadata; when present it must be a string
        ok(pcall(manifest.validate, { api = 1, id = "x", name = "X",
            actions = { { id = "a", icon = "star.fill", run = function() end } } }),
            "manifest accepts a string per-action icon")
        ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X",
            actions = { { id = "a", icon = 42, run = function() end } } }),
            "manifest rejects a non-string per-action icon")

        -- two dummy features populate the palette: a single-action one and a
        -- multi-action one (one of whose actions is left unbound).
        local palHits = { a = 0, one = 0, two = 0 }
        package.loaded["features._cmd_a"] = {
            api = 1, id = "cmd_a", name = "Cmd A",
            defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "5" },
            action = function() palHits.a = palHits.a + 1 end,
        }
        package.loaded["features._cmd_b"] = {
            api = 1, id = "cmd_b", name = "Cmd B",
            icon = "b.circle",   -- feature-level glyph: inherited by every action...
            actions = {
                { id = "one", label = "Do one",
                  defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "7" },
                  run = function() palHits.one = palHits.one + 1 end },
                { id = "two", label = "Do two",   -- no trigger: dormant, manual-only
                  icon = "two.square",   -- ...unless the action overrides it
                  run = function() palHits.two = palHits.two + 1 end },
            },
        }
        package.loaded["features._cmd_off"] = {   -- registered but never enabled
            api = 1, id = "cmd_off", name = "Cmd Off",
            defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "8" },
            action = function() end,
        }
        registry.load("features._cmd_a")
        registry.load("features._cmd_b")
        registry.load("features._cmd_off")
        registry.setEnabled("cmd_a", true)
        registry.setEnabled("cmd_b", true)
        registry.setEnabled("command_palette", true)

        fake.pressHotkey("space", { "cmd", "alt", "ctrl" })
        local pch = fake.visibleChooser()
        ok(pch ~= nil, "palette opened a chooser")
        -- cmd_a (1) + cmd_b (2) = 3 rows; the palette excludes itself, disabled cmd_off excluded
        ok(#pch.choices == 3, "lists enabled features' actions; self + disabled excluded")
        local sub, sc, seen, img = {}, {}, {}, {}
        for _, c in ipairs(pch.choices) do
            sub[c.text] = c.subText; sc[c.text] = c.shortcut; seen[c.text] = true; img[c.text] = c.image
        end
        ok(seen["Cmd A"], "a single-action feature shows its name as the command")
        ok(seen["Do one"] and seen["Do two"], "a multi-action feature contributes one row per action")
        ok(sub["Cmd A"] == nil, "a single-action feature omits the redundant source column")
        ok(sc["Cmd A"] == "⌃5", "showShortcuts puts the compact trigger glyph in the shortcut column")
        ok(sub["Do one"] == "Cmd B" and sub["Do two"] == "Cmd B", "multi-action rows show their source feature")
        ok(sc["Do one"] == "⌃7", "a bound multi-action row shows its own shortcut")
        ok(sc["Do two"] == nil, "an unbound action has no shortcut")
        -- Icon resolution: every row carries a "symbol:" glyph token (never ragged);
        -- action icon overrides feature icon overrides a generic fallback.
        ok(img["Cmd A"] == "symbol:puzzlepiece.fill",
            "a feature with no icon falls back to the generic glyph (list never ragged)")
        ok(img["Do one"] == "symbol:b.circle",
            "an action with no icon of its own inherits the feature icon")
        ok(img["Do two"] == "symbol:two.square",
            "a per-action icon overrides the feature icon for that row")

        -- selecting a row runs that command -- on the next tick, after the panel yields
        local target
        for i, c in ipairs(pch.choices) do if c.text == "Do two" then target = i end end
        pch.userSelect(target)
        ok(palHits.two == 0, "selection is deferred until the panel yields focus")
        fake.fireTimers("after", 0)
        ok(palHits.two == 1, "the deferred command actually ran via ctx.runCommand")

        -- showShortcuts off -> bare feature name, no trigger suffix
        fake.settings["hammerdeck.opt.command_palette.showShortcuts"] = false
        fake.pressHotkey("space", { "cmd", "alt", "ctrl" })
        local pchNo = fake.visibleChooser()
        local subNo, scNo = {}, {}
        for _, c in ipairs(pchNo.choices) do subNo[c.text] = c.subText; scNo[c.text] = c.shortcut end
        ok(scNo["Cmd A"] == nil, "showShortcuts off drops the shortcut column")
        ok(subNo["Do one"] == "Cmd B", "source feature stays regardless of showShortcuts")
        ok(pchNo.choices[1].text == "Do two",
            "frecency: the previously-run command sorts to the top")
        pchNo.userSelect(0)   -- dismiss
        fake.settings["hammerdeck.opt.command_palette.showShortcuts"] = nil

        -- empty catalog: a single non-selectable info row instead of a blank panel
        registry.setEnabled("cmd_a", false)
        registry.setEnabled("cmd_b", false)
        fake.pressHotkey("space", { "cmd", "alt", "ctrl" })
        local pchEmpty = fake.visibleChooser()
        ok(pchEmpty ~= nil and #pchEmpty.choices == 1 and pchEmpty.choices[1].valid == false,
            "empty catalog shows a single info row")
        pchEmpty.userSelect(0)

        -- a plain feature does NOT receive the capability methods (least privilege)
        package.loaded["features._cmd_plain"] = {
            api = 1, id = "cmd_plain", name = "Cmd Plain",
            defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "9" },
            action = function(ctx)
                palHits.plainHasCommands = (ctx.commands ~= nil)
            end,
        }
        registry.load("features._cmd_plain")
        registry.setEnabled("cmd_plain", true)
        fake.pressHotkey("9", { "ctrl" })
        ok(palHits.plainHasCommands == false,
            "a feature without the capability never gets ctx.commands")

        registry.setEnabled("cmd_plain", false)
        registry.setEnabled("command_palette", false)
        registry.setEnabled("cmd_off", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after command_palette test")
    end,
}
