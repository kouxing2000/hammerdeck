-- test/cases/_integration/modal_repeat.lua -- platform.modal auto-repeat: Carbon delivers no
-- native key-repeat, so modal.lua synthesizes one from the press+release EDGES and a
-- delay-then-tick timer pair. A `repeats = true` binding fires once on press, stays quiet
-- through the hold delay, then ticks steadily until key-up (or mode exit) cancels it; a plain
-- binding fires once and arms no timers. Exiting mid-hold must tear the repeat timers down.
--
-- Migrated from run.lua T31 (RUN_LUA_SPLIT_SPEC). Integration of a CORE platform module (not a
-- feature, no registry): it enters a modal directly and drives the fake's press/release/timer
-- edges. Hermetic -- freshWorld() gives it a pristine clock + zero handles, and m.stop() plus
-- the runner tripwire prove the synthesized timers leave nothing behind.

return {
    id = "modal_repeat",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake

        local modal = require("platform.modal")
        local repHits, plainHits = 0, 0
        local m = modal.enter {
            name = "RepeatTest",
            bindings = {
                { key = "w", repeats = true, fn = function() repHits = repHits + 1 end },
                { key = "f", fn = function() plainHits = plainHits + 1 end },
            },
        }

        fake.pressHotkey("w", {})
        ok(repHits == 1, "press fires a repeating key once immediately")
        ok(fake.fireTimers("every", 0.04) == 0, "no steady tick until the hold delay elapses")

        fake.fireTimers("after", 0.3)                  -- hold delay elapses -> tick arms
        ok(repHits == 1, "the delay itself does not fire the action again")
        fake.fireTimers("every", 0.04)
        ok(repHits == 2, "after the delay, each tick fires the action")
        fake.fireTimers("every", 0.04)
        ok(repHits == 3, "and keeps firing while held")

        fake.releaseHotkey("w", {})                    -- key up cancels the repeat
        local heldTo = repHits
        ok(fake.fireTimers("every", 0.04) == 0, "release cancels the steady tick")
        ok(repHits == heldTo, "no further fires after release")

        fake.pressHotkey("f", {})
        ok(plainHits == 1, "a non-repeating key still fires")
        ok(fake.fireTimers("after", 0.3) == 0 and fake.fireTimers("every", 0.04) == 0,
            "a non-repeating key arms no repeat timers")

        -- holding a key, then exiting the mode, must not leak the repeat timers
        fake.pressHotkey("w", {})
        fake.fireTimers("after", 0.3)                  -- tick armed and live
        m.stop()
        ok(fake.liveHandles == 0, "exiting mid-hold tears down the repeat timers")
    end,
}
