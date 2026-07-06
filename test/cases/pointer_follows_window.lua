-- test/cases/pointer_follows_window.lua -- pointer_follows_window: a focused-window
-- move carries the pointer, keeping its relative position; OFF leaves it; a pointer
-- outside the window is never yanked; and a cross-screen throw agrees with the
-- window-relative carry instead of compounding.
--
-- Migrated from run.lua T24b (RUN_LUA_SPLIT_SPEC Phase 2). The follow lives at the
-- ctx.window.setFrame -> window_ops seam, so ANY mover exercises it; window_snap is
-- the mover under test, so the case registers BOTH (T24b leaned on T24's window_snap
-- registration). freshWorld() + handle tripwire keep it isolated.

return {
    id = "pointer_follows_window",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry, AC = t.ok, t.fake, t.registry, t.AC

        registry.register(require("features.window_snap"))
        registry.register(require("features.pointer_follows_window"))
        registry.setEnabled("window_snap", true)

        -- pointer_follows_window declares itself a global PREFERENCE (feature.json
        -- "preference": true), so the host surfaces it in Settings > General > Behavior
        -- and filters it OUT of the feature catalog -- describe() must carry the flag.
        do
            local pfw
            for _, e in ipairs(registry.describe()) do
                if e.id == "pointer_follows_window" then pfw = e end
            end
            ok(pfw ~= nil and pfw.preference == true, "describe() flags pointer_follows_window as a preference")
        end
        fake.screenList = {
            { x = 0, y = 0, w = 1000, h = 800 },
            { x = 1000, y = 0, w = 2000, h = 1200 },
        }
        local function snapLeftFromCorner()
            fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
            fake.mousePos      = { x = 200, y = 250 }   -- 25% across, 50% down the window
            fake.pressHotkey("left", AC)                 -- -> {0,0,500,800}
        end

        -- toggle OFF: the snap moves the window but leaves the pointer alone
        registry.setEnabled("pointer_follows_window", false)
        snapLeftFromCorner()
        ok(fake.mousePos.x == 200 and fake.mousePos.y == 250,
            "pointer_follows_window OFF: a snap leaves the pointer where it was")

        -- toggle ON: the pointer rides the window, keeping its relative position
        -- (25% across, 50% down -> 0+0.25*500, 0+0.5*800 = 125, 400)
        registry.setEnabled("pointer_follows_window", true)
        snapLeftFromCorner()
        ok(fake.mousePos.x == 125 and fake.mousePos.y == 400,
            "pointer_follows_window ON: pointer keeps its relative spot after a snap")

        -- a pointer parked OUTSIDE the moved window is never yanked
        fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
        fake.mousePos      = { x = 5, y = 5 }
        fake.pressHotkey("left", AC)
        ok(fake.mousePos.x == 5 and fake.mousePos.y == 5,
            "pointer_follows_window: a pointer outside the window is left alone")

        -- moveScreen + pointer_follows_window ON: the mover reads the pointer BEFORE
        -- ctx.window.setFrame (which itself carries it), so the two window-relative
        -- carries AGREE instead of compounding. Throw {100,100,400,300} on screen 1 to
        -- the bigger screen 2 (new frame {1200,150,600,450}); the pointer at 12.5%/33%
        -- lands at 1275,300 -- NOT the 2275 the old read-after-move carry produced.
        registry.setEnabled("pointer_follows_window", true)
        fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
        fake.mousePos      = { x = 150, y = 200 }
        fake.pressHotkey("]", AC)
        ok(fake.mousePos.x == 1275 and fake.mousePos.y == 300,
            "moveScreen + follow ON: pointer tracks the window, no double-carry drift")

        registry.setEnabled("pointer_follows_window", false)
        registry.setEnabled("window_snap", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after pointer_follows_window test")
    end,
}
