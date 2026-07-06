-- test/cases/locate_pointer.lua -- locate_pointer (flash the cursor; center it on
-- the focused window / a screen / the active display).
--
-- Migrated from run.lua T17 (RUN_LUA_SPLIT_SPEC Phase 2). Hermetic: registers its
-- own feature and seeds its own screen/pointer fixtures; the freshWorld() before it
-- and the handle tripwire after keep it isolated. No cross-section state -- the old
-- section's trailing single-screen restore (for the NEXT section) is dropped.

return {
    id = "locate_pointer",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        registry.register(require("features.locate_pointer"))
        registry.setEnabled("locate_pointer", true)
        fake.mouseLocates = {}   -- fresh recorder: this block asserts absolute counts/indices
        fake.fireChord({ "cmd", "alt", "ctrl" }, "m", { "m" })
        ok(#fake.mouseLocates == 1 and fake.mouseLocates[1] == 3,
            "locate-pointer fires with the configured duration")
        fake.settings["hammerdeck.opt.locate_pointer.seconds"] = 7
        fake.fireChord({ "cmd", "alt", "ctrl" }, "m", { "m" })
        ok(fake.mouseLocates[2] == 7, "duration option applies live")
        -- center the pointer on the focused window (sibling chord Hyper+M C)
        fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
        fake.fireChord({ "cmd", "alt", "ctrl" }, "m", { "c" })
        ok(fake.mousePos.x == 300 and fake.mousePos.y == 250, "Hyper+M C centers the pointer on the window")
        ok(fake.mouseLocates[#fake.mouseLocates] == 1, "and flashes the locator")
        -- center the pointer on a screen (Hyper+M N = next display, wraps; Hyper+M S = main)
        fake.screenList = {
            { x = 0,    y = 0, w = 1440, h = 900,  name = "Built-in", index = 1 },
            { x = 1440, y = 0, w = 2560, h = 1440, name = "DELL",     index = 2 },
        }
        fake.mousePos = { x = 10, y = 10 }   -- pointer parked on the Built-in screen
        fake.fireChord({ "cmd", "alt", "ctrl" }, "m", { "n" })
        ok(fake.mousePos.x == 2720 and fake.mousePos.y == 720, "Hyper+M N flings the pointer to the next display's center")
        ok(fake.mouseLocates[#fake.mouseLocates] == 1, "and flashes the locator")
        fake.fireChord({ "cmd", "alt", "ctrl" }, "m", { "n" })   -- now on DELL -> wraps back to the first
        ok(fake.mousePos.x == 720 and fake.mousePos.y == 450, "Hyper+M N wraps from the last display back to the first")
        fake.mousePos = { x = 2000, y = 100 }   -- pointer parked on DELL
        fake.fireChord({ "cmd", "alt", "ctrl" }, "m", { "s" })
        ok(fake.mousePos.x == 720 and fake.mousePos.y == 450, "Hyper+M S centers the pointer on the main screen")
        -- active screen (Hyper+M A) = the screen holding the focused window; falls back
        -- to the main screen when nothing is focused.
        fake.focusedWindow = { x = 1500, y = 100, w = 400, h = 300, screenIndex = 2 }  -- on DELL
        fake.mousePos = { x = 10, y = 10 }
        fake.fireChord({ "cmd", "alt", "ctrl" }, "m", { "a" })
        ok(fake.mousePos.x == 2720 and fake.mousePos.y == 720,
            "Hyper+M A centers the pointer on the active window's screen (DELL)")
        fake.focusedWindow = nil
        fake.mousePos = { x = 2000, y = 100 }   -- pointer parked on DELL
        fake.fireChord({ "cmd", "alt", "ctrl" }, "m", { "a" })
        ok(fake.mousePos.x == 2720 and fake.mousePos.y == 720,
            "Hyper+M A falls back to the pointer's screen (DELL) when nothing is focused")

        registry.setEnabled("locate_pointer", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after locate_pointer test")
    end,
}
