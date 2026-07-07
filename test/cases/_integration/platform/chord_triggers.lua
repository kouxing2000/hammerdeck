-- test/cases/_integration/platform/chord_triggers.lua -- chord triggers -- a prefix hotkey arms a follow-key sequence. Codec
-- (sorted mods, ordered follows), validate rejections (no/empty follows,
-- escape), conflict semantics (shared-prefix distinct follows do NOT conflict;
-- prefix-of-another does; a plain hotkey collides with a chord's prefix), and
-- end-to-end binding + rebind + prefix-of-sibling refusal through the registry.
--
-- Migrated from run.lua T19 (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "chord_triggers",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry, triggers = t.ok, t.fake, t.registry, t.triggers

        do

        -- codec round-trip: mods canonicalized (sorted), follow sequence ORDER kept
        local chordEnc = triggers.encode(
            { type = "chord", mods = { "shift", "cmd" }, key = "a", follows = { "b", "c" } })
        ok(chordEnc == "chord|cmd,shift|a|b,c", "chord encodes with sorted mods + ordered follows")
        local chordDec = triggers.decode(chordEnc)
        ok(chordDec.type == "chord" and chordDec.key == "a"
            and chordDec.follows[1] == "b" and chordDec.follows[2] == "c" and #chordDec.follows == 2,
            "chord decodes back to the same spec")
        ok(triggers.decode("chord|cmd|a|") == nil, "a chord string with no follow keys decodes to nil")

        -- validate rejects malformed chords
        ok(pcall(triggers.validate, { type = "chord", mods = { "cmd" }, key = "a" }) == false,
            "chord without follows is rejected")
        ok(pcall(triggers.validate,
            { type = "chord", mods = { "cmd" }, key = "a", follows = {} }) == false,
            "chord with empty follows is rejected")
        ok(pcall(triggers.validate,
            { type = "chord", mods = { "cmd" }, key = "a", follows = { "escape" } }) == false,
            "escape cannot be a chord follow key (it always cancels)")

        -- conflict semantics (the whole reason chords share prefixes)
        local chordAB  = { type = "chord", mods = { "cmd", "shift" }, key = "a", follows = { "b" } }
        local chordAC  = { type = "chord", mods = { "cmd", "shift" }, key = "a", follows = { "c" } }
        local chordABC = { type = "chord", mods = { "cmd", "shift" }, key = "a", follows = { "b", "c" } }
        local plainA   = { type = "hotkey", mods = { "shift", "cmd" }, key = "a" }
        ok(triggers.conflicts(chordAB, chordAC) == false,
            "chords sharing a prefix with distinct follows do NOT conflict")
        ok(triggers.conflicts(chordAB, chordABC) == true,
            "a follow sequence that is a prefix of another (same prefix) conflicts")
        ok(triggers.conflicts(chordAB, plainA) == true,
            "a plain hotkey collides with a chord's prefix combo")
        ok(triggers.conflicts(plainA, { type = "hotkey", mods = { "cmd", "shift" }, key = "b" }) == false,
            "different plain hotkeys do not conflict")

        -- end-to-end binding through the registry: two chords share one prefix
        local chordHits = { x = 0, y = 0 }
        package.loaded["features._chordy"] = {
            api = 1, id = "chordy", name = "Chordy",
            actions = {
                { id = "x", label = "X",
                  defaultTrigger = { type = "chord", mods = { "cmd", "shift" }, key = "a", follows = { "b" } },
                  run = function() chordHits.x = chordHits.x + 1 end },
                { id = "y", label = "Y",   -- SAME prefix, different follow key
                  defaultTrigger = { type = "chord", mods = { "shift", "cmd" }, key = "a", follows = { "c" } },
                  run = function() chordHits.y = chordHits.y + 1 end },
            },
        }
        registry.load("features._chordy")
        registry.setEnabled("chordy", true)
        ok(fake.fireChord({ "cmd", "shift" }, "a", { "b" }) == 1, "prefix cmd+shift+a then b fires action x")
        ok(chordHits.x == 1 and chordHits.y == 0, "only the matching chord ran")
        ok(fake.fireChord({ "shift", "cmd" }, "a", { "c" }) == 1,
            "the sibling chord (same prefix, follow c) fires action y")
        ok(chordHits.y == 1, "follow c ran action y")
        ok(fake.fireChord({ "cmd", "shift" }, "a", { "z" }) == 0, "an unmatched follow fires nothing")

        -- rebind a chord action to a deeper sequence; the old sequence goes dead
        ok(registry.setTrigger("chordy", "x",
            { type = "chord", mods = { "cmd", "shift" }, key = "a", follows = { "d", "e" } }) == true,
            "a chord action rebinds to a deeper sequence")
        fake.fireChord({ "cmd", "shift" }, "a", { "b" })
        ok(chordHits.x == 1, "the old chord sequence is dead after rebind")
        ok(fake.fireChord({ "cmd", "shift" }, "a", { "d", "e" }) == 1, "the new (deeper) sequence fires")
        ok(chordHits.x == 2, "the deeper follow sequence ran action x")
        ok(fake.settings["hammerdeck.trigger.chordy.x"] == "chord|cmd,shift|a|d,e",
            "the chord override persisted encoded")

        -- a chord whose follow seq is a prefix of an enabled sibling is refused
        local okPrefix, whyPrefix = registry.setTrigger("chordy", "y",
            { type = "chord", mods = { "cmd", "shift" }, key = "a", follows = { "d" } })
        ok(okPrefix == false and whyPrefix ~= nil, "a prefix-of-sibling chord is refused as a conflict")

        -- a plain hotkey colliding with an enabled chord's prefix is refused
        package.loaded["features._plain"] = {
            api = 1, id = "plain", name = "Plain",
            defaultTrigger = { type = "hotkey", mods = { "cmd", "shift" }, key = "a" },
            action = function() end,
        }
        registry.load("features._plain")
        local okPlain, whyPlain = registry.setTrigger("plain",
            { type = "hotkey", mods = { "cmd", "shift" }, key = "a" })
        ok(okPlain == false and whyPlain ~= nil, "a plain hotkey on a chord's prefix combo is refused")

        registry.setEnabled("chordy", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after chord tests")

        end
    end,
}
