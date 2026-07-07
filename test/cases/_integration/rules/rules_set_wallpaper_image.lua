-- test/cases/_integration/rules/rules_set_wallpaper_image.lua -- setWallpaperImage effect -- the sibling of solidWallpaper that paints a
-- photo (adapter.setWallpaper) instead of a flat color; same display param model
-- (literal / category / from-trigger), context-free.
--
-- Migrated from run.lua T39b2 (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration: platform subsystem, driven by throwaway features/effects. Hermetic --
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so the catalog
-- and the rules singleton both start empty.

return {
    id = "rules_set_wallpaper_image",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
        local effects = require("platform.effects")

        fake.settings["hammerdeck.rules"] = nil

        ok(effects.requiresContext({ kind = "setWallpaperImage", image = "/x.jpg", display = "all" }) == false,
            "setWallpaperImage is context-free")
        ok(pcall(effects.validate, { kind = "setWallpaperImage", display = "all" }) == false,
            "setWallpaperImage requires an image path")
        ok(pcall(effects.validate, { kind = "setWallpaperImage", image = "/x.jpg" }) == false,
            "setWallpaperImage requires a display")
        ok(pcall(effects.validate, { kind = "setWallpaperImage", image = "/x.jpg", display = "all" }) == true,
            "setWallpaperImage with an image + display validates")

        -- dispatch routes to adapter.setWallpaper(path, target)
        local nW = #fake.wallpapers
        effects.dispatch({ kind = "setWallpaperImage", image = "/Users/me/Pictures/sunset.jpg", display = "DELL U2720Q" })
        ok(#fake.wallpapers == nW + 1
            and fake.wallpapers[#fake.wallpapers] == "/Users/me/Pictures/sunset.jpg"
            and fake.wallpaperModes[#fake.wallpaperModes] == "DELL U2720Q",
            "setWallpaperImage dispatch sets the photo on the named display")

        -- from-trigger sentinel resolves from context.display; missing context -> fail
        effects.dispatch({ kind = "setWallpaperImage", image = "/p.jpg", display = effects.TRIGGER_DISPLAY },
            { display = "Paperlike H D" })
        ok(fake.wallpaperModes[#fake.wallpaperModes] == "Paperlike H D",
            "setWallpaperImage resolves the from-trigger display")
        local nW2 = #fake.wallpapers
        ok(effects.dispatch({ kind = "setWallpaperImage", image = "/p.jpg", display = effects.TRIGGER_DISPLAY }) == false
            and #fake.wallpapers == nW2,
            "setWallpaperImage from-trigger with no connecting display does nothing")

        -- describe shows the file NAME, not the full path
        ok(effects.describe({ kind = "setWallpaperImage", image = "/Users/me/Pictures/sunset.jpg", display = "external" })
            == "Set wallpaper sunset.jpg on external displays", "describe labels setWallpaperImage by basename")
        ok(effects.describe({ kind = "setWallpaperImage", image = "/a/b.png", display = effects.TRIGGER_DISPLAY })
            == "Set wallpaper b.png on the triggering display", "describe: from-trigger setWallpaperImage")

        local seen = {}
        for _, e in ipairs(effects.catalog(true)) do seen[e.kind] = true end
        ok(seen.setWallpaperImage, "catalog offers setWallpaperImage on automated triggers")
    end,
}
