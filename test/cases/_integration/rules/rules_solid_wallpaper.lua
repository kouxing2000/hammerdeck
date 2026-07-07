-- test/cases/_integration/rules/rules_solid_wallpaper.lua -- solidWallpaper effect -- paint a solid color on a chosen display; context-
-- free, and its `display` may be a literal/category OR drawn from the trigger
-- ("the connecting display", via the effects.TRIGGER_DISPLAY sentinel).
--
-- Migrated from run.lua T39b (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration: platform subsystem, driven by throwaway features/effects. Hermetic --
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so the catalog
-- and the rules singleton both start empty.

return {
    id = "rules_solid_wallpaper",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
        local effects = require("platform.effects")
        local rules   = require("platform.rules")

        fake.settings["hammerdeck.rules"] = nil
        rules.load({})

        -- context-free + validated (needs a #RRGGBB color and a non-empty display)
        ok(effects.requiresContext({ kind = "solidWallpaper", color = "#FFFFFF", display = "all" }) == false,
            "solidWallpaper is context-free")
        ok(pcall(effects.validate, { kind = "solidWallpaper", display = "all" }) == false,
            "solidWallpaper requires a color")
        ok(pcall(effects.validate, { kind = "solidWallpaper", color = "white", display = "all" }) == false,
            "solidWallpaper rejects a non-#RRGGBB color")
        ok(pcall(effects.validate, { kind = "solidWallpaper", color = "#FFFFFF" }) == false,
            "solidWallpaper requires a display")
        ok(pcall(effects.validate, { kind = "solidWallpaper", color = "#FFFFFF", display = "all" }) == true,
            "solidWallpaper with a #RRGGBB color + display validates")

        -- dispatch routes to the adapter with a LITERAL display name
        local nW = #fake.wallpaperColors
        effects.dispatch({ kind = "solidWallpaper", color = "#FFFFFF", display = "DELL U2720Q" })
        local w = fake.wallpaperColors[#fake.wallpaperColors]
        ok(#fake.wallpaperColors == nW + 1 and w.hex == "#FFFFFF" and w.target == "DELL U2720Q",
            "solidWallpaper dispatch paints the named display")

        -- from-trigger: the sentinel resolves to context.display
        effects.dispatch({ kind = "solidWallpaper", color = "#000000", display = effects.TRIGGER_DISPLAY },
            { display = "Paperlike H D" })
        local w2 = fake.wallpaperColors[#fake.wallpaperColors]
        ok(w2.hex == "#000000" and w2.target == "Paperlike H D",
            "solidWallpaper resolves the from-trigger sentinel from the context")

        -- from-trigger with NO context display -> failure, nothing painted
        local nW2 = #fake.wallpaperColors
        local okNo = effects.dispatch({ kind = "solidWallpaper", color = "#FFFFFF", display = effects.TRIGGER_DISPLAY })
        ok(okNo == false and #fake.wallpaperColors == nW2,
            "solidWallpaper from-trigger with no connecting display does nothing")

        -- describe
        ok(effects.describe({ kind = "solidWallpaper", color = "#FFFFFF", display = "external" })
            == "Set wallpaper white on external displays", "describe labels a literal-display solidWallpaper")
        ok(effects.describe({ kind = "solidWallpaper", color = "#FFFFFF", display = effects.TRIGGER_DISPLAY })
            == "Set wallpaper white on the triggering display", "describe labels a from-trigger solidWallpaper")

        -- end-to-end: "Paperlike H D connects" -> paint THE connecting display white.
        -- triggerContext derives {display = becomes}, so the sentinel resolves to it.
        local _, sid = rules.add({
            on = { type = "state", signal = "displaysPresent", becomes = "Paperlike H D" },
            effect = { kind = "solidWallpaper", color = "#FFFFFF", display = effects.TRIGGER_DISPLAY } })
        local nW3 = #fake.wallpaperColors
        ok(rules.fire(sid) == true, "a solidWallpaper rule fires (Test)")
        local w3 = fake.wallpaperColors[#fake.wallpaperColors]
        ok(#fake.wallpaperColors == nW3 + 1 and w3.hex == "#FFFFFF" and w3.target == "Paperlike H D",
            "the connecting display name flows from the rule's condition into the effect")

        -- the Do dropdown offers it on automated triggers
        local seen = {}
        for _, e in ipairs(effects.catalog(true)) do seen[e.kind] = true end
        ok(seen.solidWallpaper, "catalog offers solidWallpaper on automated triggers")

        rules.load({}); fake.settings["hammerdeck.rules"] = nil
        ok(fake.liveHandles == 0, "no native handle leaked across the solidWallpaper tests")
    end,
}
