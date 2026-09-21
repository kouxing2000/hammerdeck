-- test/cases/_integration/platform/extensions.lua -- user extensions: features
-- loaded from a USER folder (the hammerdeck.extensionsDir setting) instead of
-- the built-in catalog. The on-disk fixture lives at
-- test/fixtures/extensions/ext_probe/ (lua/init.lua + feature.json + i18n/),
-- exercised through the REAL loader (extensions.* namespace) -- only discovery
-- goes through the fake (fake.featuresByDir). Covers: load via the setting,
-- the feature.json overlay from the extension root, the describe() extension
-- flag, firing an action, per-extension i18n catalogs, the id==folder guard,
-- duplicate-id quarantine (failure record must NOT reuse the colliding id),
-- dot-in-folder-name refusal, and reload dropping extensions when the setting
-- is cleared.
--
-- Integration (platform core). Hermetic: freshWorld() precedes the case and
-- registry.reset() detaches the loader's extensions root, so nothing leaks.

local EXT_DIR = "test/fixtures/extensions"

return {
    id = "extensions",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry
        local i18n = require("platform.i18n")

        -- ---------------------------------------------------------------
        -- Load from the setting: fixture discovered, overlaid, described.
        -- ---------------------------------------------------------------
        do
        fake.settings["hammerdeck.extensionsDir"] = EXT_DIR
        fake.featuresByDir[EXT_DIR] = { "ext_probe" }

        local n = registry.loadExtensions()
        ok(n == 1, "loadExtensions loads the fixture extension")

        local row
        for _, r in ipairs(registry.describe()) do
            if r.id == "ext_probe" then row = r end
        end
        ok(row ~= nil, "extension appears in describe()")
        ok(row.extension == true, "describe() flags the feature as an extension")
        ok(row.name == "Ext Probe",
            "feature.json overlay is read from the EXTENSION root (name)")
        ok(row.category == "utilities",
            "feature.json overlay is read from the EXTENSION root (category)")

        -- The extension is a full citizen: enable it and fire its hotkey.
        registry.setEnabled("ext_probe", true)
        fake.pressHotkey("9", { "cmd", "alt", "shift" })
        local note = fake.notifications[#fake.notifications]
        ok(note and note.text == "extension action fired",
            "an enabled extension's action fires like a built-in's")
        registry.setEnabled("ext_probe", false)
        end

        -- ---------------------------------------------------------------
        -- i18n: the extension's own i18n/<locale>.json resolves against ITS
        -- folder. configure() clears the root map, so re-register via reload
        -- (the real-world order: locale switch -> reload/describe).
        -- ---------------------------------------------------------------
        do
        i18n.configure({ locale = "zh-Hans" })
        registry.reload()
        local row
        for _, r in ipairs(registry.describe()) do
            if r.id == "ext_probe" then row = r end
        end
        ok(row and row.name == "扩展探针",
            "extension i18n catalog resolves from the extension's own folder")
        i18n.configure({ locale = "en" })
        end

        -- ---------------------------------------------------------------
        -- Guards. Preloaded module tables stand in for on-disk folders
        -- (the hot_reload probe idiom) -- require() returns them, so the
        -- register-side checks run without extra fixture directories.
        -- ---------------------------------------------------------------
        do
        registry.reload()   -- back to a clean ext_probe-only extension set

        -- id must equal the folder name, or every sibling require / meta /
        -- i18n lookup would aim at the wrong folder.
        package.loaded["extensions.mismatch"] = { api = 1, id = "other",
            name = "Mismatch", action = function() end }
        ok(registry.load("extensions.mismatch") == nil,
            "an extension whose id differs from its folder name is refused")
        local fs = registry.failures().load
        ok(fs[#fs].error:find("must equal its folder name", 1, true) ~= nil,
            "the mismatch failure names the rule")
        package.loaded["extensions.mismatch"] = nil

        -- A duplicate id shadowing an existing feature is quarantined, the
        -- original stays intact -- and the failure record must NOT carry the
        -- colliding id (describe() keys failed rows by id-or-source; a
        -- duplicate id would hand the UI two rows with one identity).
        registry.load("features.plain_paste")
        package.loaded["extensions.plain_paste"] = { api = 1, id = "plain_paste",
            name = "Shadow", action = function() end }
        ok(registry.load("extensions.plain_paste") == nil,
            "an extension shadowing an existing feature id is refused")
        fs = registry.failures().load
        local rec = fs[#fs]
        ok(rec.source == "extensions.plain_paste" and rec.id == nil,
            "the duplicate-id failure record is keyed by source, not the colliding id")
        local builtin
        for _, r in ipairs(registry.describe()) do
            if r.id == "plain_paste" then builtin = r end
        end
        ok(builtin and builtin.extension == false, "the shadowed built-in stays intact")
        package.loaded["extensions.plain_paste"] = nil

        -- A folder name containing "." cannot map onto the dotted module
        -- namespace; discovery refuses it with a named failure.
        fake.featuresByDir[EXT_DIR] = { "ext_probe", "we.ird" }
        registry.reload()
        local dotFailed = false
        for _, f in ipairs(registry.failures().load) do
            if f.source == "extensions.we.ird"
                and f.error:find("must not contain", 1, true) then dotFailed = true end
        end
        ok(dotFailed, "a dotted extension folder name is refused, not misresolved")

        -- The FAILED row must own up to being an extension. The host counts a
        -- folder's extensions off describe(), so a rejected one reporting as a
        -- built-in makes "nothing was found here" and "all of them were refused"
        -- render identically -- which is the confusion this flag exists to end.
        local dotRow
        for _, r in ipairs(registry.describe()) do
            if r.id == "extensions.we.ird" then dotRow = r end
        end
        ok(dotRow ~= nil, "a refused extension still gets a row in describe()")
        ok(dotRow and dotRow.failed == true, "that row reads as failed")
        ok(dotRow and dotRow.extension == true,
            "a FAILED extension row is marked extension, not mistaken for a built-in")

        fake.featuresByDir[EXT_DIR] = { "ext_probe" }
        end

        -- ---------------------------------------------------------------
        -- Clearing the setting + reload drops the extensions (and detaches
        -- the extensions.* require namespace).
        -- ---------------------------------------------------------------
        do
        fake.settings["hammerdeck.extensionsDir"] = nil
        registry.reload()
        for _, r in ipairs(registry.describe()) do
            ok(r.id ~= "ext_probe", "cleared setting + reload unloads the extension")
        end
        ok(not pcall(require, "extensions.ext_probe"),
            "the extensions.* namespace is detached once the setting is cleared")
        end

        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
            "clean after extensions test")
    end,
}
