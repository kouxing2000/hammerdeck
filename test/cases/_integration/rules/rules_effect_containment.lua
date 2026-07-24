-- test/cases/_integration/rules/rules_effect_containment.lua
--
-- effects.dispatch is THE containment point (CODE-6, 2026-07-24): a throw from
-- anywhere inside an effect's `run` -- typically the adapter call it makes --
-- comes back as (false, reason), never as an error escaping into the firing rule.
--
-- Why this is a test and not a comment: containment used to be ~12 copies of the
-- same pcall prologue, one per effect kind, so it held only as long as every
-- author remembered to write it. Now that it lives in dispatch alone, this case
-- is what keeps it honest -- and it exercises the property through kinds that
-- carry NO pcall of their own, which is exactly the shape a newly-added effect
-- kind will have.
--
-- Note the deliberate coverage of BOTH return shapes: a kind that returns bare
-- `true` (speak) and one that returns (ok, note) (chain), since dispatch now
-- forwards two values through pcall and a sloppy forwarding would drop the note.

local effects = require("platform.effects")

return {
    id = "rules_effect_containment",
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake

        -- A seam call that blows up (a real one can: a missing Automation grant, a
        -- bad argument reaching AppleScript) inside a kind with no pcall of its own.
        local realSay = fake.adapter.say
        fake.adapter.say = function() error("boom from the seam", 0) end
        local fired, reason = effects.dispatch({ kind = "speak", text = "hello" })
        ok(fired == false, "a throwing effect returns false, it does not propagate")
        ok(tostring(reason):find("boom from the seam", 1, true) ~= nil,
            "the thrown message survives as the failure reason: " .. tostring(reason))
        fake.adapter.say = realSay

        -- Same, one level down: a throwing step inside a chain is contained by the
        -- nested dispatch, so the chain reports a failure rather than exploding.
        local realLock = fake.adapter.lockScreen
        fake.adapter.lockScreen = function() error("lock exploded", 0) end
        local chainOk, chainReason = effects.dispatch({
            kind = "chain",
            effects = { { kind = "lockScreen" } },
        })
        ok(chainOk == false, "a throwing step fails its chain instead of escaping")
        ok(chainReason ~= nil, "the chain reports why it failed: " .. tostring(chainReason))
        fake.adapter.lockScreen = realLock

        -- Containment must not swallow the SUCCESS path's second return value --
        -- dispatch forwards (ok, note) through pcall, and effects lean on the note
        -- for partial successes ("emptied 3 items", "shown in-app").
        fake.trashReturn = 3
        local emptied, note = effects.dispatch({ kind = "emptyTrash" })
        ok(emptied == true, "a normal effect still succeeds through dispatch")
        ok(note ~= nil and tostring(note):find("3", 1, true) ~= nil,
            "the partial-success note survives dispatch: " .. tostring(note))

        -- And an unknown kind is still a clean failure, not a nil-index crash.
        local unknownOk, unknownWhy = effects.dispatch({ kind = "no_such_effect" })
        ok(unknownOk == false and tostring(unknownWhy):find("unknown effect kind") ~= nil,
            "an unknown kind fails cleanly")
    end,
}
