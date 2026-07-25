-- test/cases/_integration/platform/trigger_types.lua -- the trigger-type
-- registry guard (CODE-11).
--
-- triggers.TYPES replaced seven parallel if-chains over `spec.type`. An
-- INCOMPLETE row is the failure mode that replaced them, and the rows fail in
-- two very different ways -- worth being precise, because the loud ones are the
-- table's doing and the quiet ones are what this guard is really for:
--
--   LOUD (the table improved these -- a nil field is CALLED, so it raises):
--     * no `describe` / `glyph` -> raises inside the settings / palette render
--     * no `bind`               -> raises when the feature is enabled
--     * no `encode`             -> raises out of registry.setTrigger on rebind
--   QUIET (still silent, and the reason this file exists):
--     * no `decode`    -> every stored override of that type reverts to the
--                         manifest default on the next load, no error anywhere
--     * no `automated` -> the type reads as MANUAL, so a context-dependent
--                         action can be scheduled to fire at 3am with nothing
--                         focused -- a policy hole, not a crash
--
-- A loud failure is still a bug you want caught before shipping rather than by a
-- user opening Settings, so this checks both classes.
--
-- It enumerates the registry rather than testing a fixed list: a NEW row is
-- covered the moment it is added, and a row with no SAMPLE below fails instead
-- of passing vacuously (the CODE-4 lesson -- a table-driven refactor whose test
-- only checks the rows it already knew about proves nothing about the next one).

-- One representative spec per type. A type present in TYPES but absent here is
-- a FAILURE, not a skip -- see samplesCoverEveryType below.
local SAMPLES = {
    hotkey   = { type = "hotkey", mods = { "cmd", "alt" }, key = "j" },
    chord    = { type = "chord", mods = { "cmd" }, key = "a", follows = { "b", "c" } },
    schedule = { type = "schedule", everyMin = 25 },
    event    = { type = "event", event = "wake" },
    state    = { type = "state", signal = "frontmostApp", becomes = "Safari" },
}

-- Types whose `bind` raises BY DESIGN because something else binds them. Listing
-- them here (rather than probing "does it raise?") means a new type cannot
-- quietly join them: an unlisted type must really bind through the adapter, and
-- a listed one must really refuse, so neither direction can drift unnoticed.
local BIND_RAISES = {
    state = true,   -- bound by the rules engine's signal watcher (rules.lua bindOne)
}

return {
    id = "trigger_types",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, triggers = t.ok, t.fake, t.triggers
        local TYPES = triggers.TYPES

        ok(type(TYPES) == "table" and next(TYPES) ~= nil,
            "triggers.TYPES is a non-empty registry")

        -- Every type has a sample here, and every sample names a real type. Both
        -- directions: the first catches a new row nobody covered, the second
        -- catches a sample left behind by a deleted row.
        for kind in pairs(TYPES) do
            ok(SAMPLES[kind] ~= nil,
                "trigger type '" .. kind .. "' has a sample spec in this test "
                .. "(add one to SAMPLES -- a row with no sample is untested)")
        end
        for kind in pairs(SAMPLES) do
            ok(TYPES[kind] ~= nil,
                "sample '" .. kind .. "' names a type that still exists in TYPES")
        end

        for kind, row in pairs(TYPES) do
            local spec = SAMPLES[kind]
            if spec then
                -- Required on every row: the fields with no sensible default.
                ok(type(row.automated) == "boolean",
                    kind .. ": declares `automated` as a boolean")
                ok(type(row.validate) == "function", kind .. ": has validate")
                ok(type(row.describe) == "function", kind .. ": has describe")
                ok(type(row.glyph) == "function", kind .. ": has glyph")
                -- `bind` is REQUIRED on every row, including types bound
                -- elsewhere (they supply a stub that raises with the reason).
                -- The dispatcher calls it unconditionally, so a missing one is a
                -- nil-call at feature-enable time.
                ok(type(row.bind) == "function", kind .. ": has bind")

                -- encode and decode are a PAIR. One without the other is the
                -- silent-data-loss bug: a spec that persists but never loads
                -- back reverts to the default with no error shown anywhere.
                ok((row.encode ~= nil) == (row.decode ~= nil),
                    kind .. ": encode and decode are both present or both absent")

                -- The sample must actually satisfy its own validator, or every
                -- assertion below it is testing a spec the system would reject.
                ok(pcall(triggers.validate, spec), kind .. ": sample spec validates")

                -- Presentation is never empty -- these render UI, and a blank
                -- trigger cell reads as "unbound" to a user.
                local desc = triggers.describe(spec)
                ok(type(desc) == "string" and #desc > 0, kind .. ": describe returns a non-empty string")
                local glyph = triggers.glyph(spec)
                ok(type(glyph) == "string" and #glyph > 0, kind .. ": glyph returns a non-empty string")

                if row.encode then
                    -- Round-trip STABILITY, not just "decode returns something":
                    -- re-encoding the decoded spec must reproduce the same
                    -- string, which is what proves no field was dropped on the
                    -- way through. (A decode that silently loses `follows`
                    -- still returns a table.)
                    local enc = triggers.encode(spec)
                    ok(type(enc) == "string" and #enc > 0, kind .. ": encodes to a non-empty string")
                    ok(enc:match("^([^|]+)|") == kind,
                        kind .. ": encoding is prefixed with its own type name (decode dispatches on it)")
                    local back = triggers.decode(enc)
                    ok(type(back) == "table", kind .. ": decodes back to a table")
                    ok(back.type == kind, kind .. ": decoded spec keeps its type")
                    ok(triggers.encode(back) == enc, kind .. ": encode -> decode -> encode is stable")
                else
                    -- A non-encodable type must be REFUSED, not silently encoded
                    -- to something the decoder will never understand.
                    ok(not pcall(triggers.encode, spec),
                        kind .. ": encode refuses a type with no codec")
                end

                -- decode takes UNTRUSTED input (a stored settings string a user
                -- or an older build wrote), and its documented contract is that
                -- it NEVER throws -- a bad override must degrade to the manifest
                -- default, not break the whole feature's load. The round-trip
                -- above only ever feeds it strings encode produced, so probe the
                -- malformed shapes explicitly. Applies to every kind, including
                -- the ones with no decode (they must return nil, not raise).
                for _, bad in ipairs({ kind, kind .. "|", kind .. "|||",
                                       kind .. "|garbage",
                                       kind .. "|" .. string.rep("x", 200) }) do
                    ok(pcall(triggers.decode, bad),
                        kind .. ": decode does not throw on malformed input '" .. bad:sub(1, 24) .. "'")
                end

                -- BIND, for real -- not just "the field exists". This is the
                -- field with the widest blast radius (a broken one means the
                -- trigger simply never fires) and it had no coverage here at all
                -- until a review caught it.
                if BIND_RAISES[kind] then
                    ok(not pcall(triggers.bind, spec, function() end),
                        kind .. ": bind raises (it is bound elsewhere by design)")
                else
                    local before = fake.liveHandles
                    local h = triggers.bind(spec, function() end)
                    ok(type(h) == "table" and type(h.stop) == "function",
                        kind .. ": bind returns a handle with .stop()")
                    -- Reaching the adapter is the point: a bind that quietly did
                    -- nothing would still return a table, but would not claim a
                    -- native resource.
                    ok(fake.liveHandles == before + 1,
                        kind .. ": bind claims exactly one native resource")
                    h.stop()
                    ok(fake.liveHandles == before,
                        kind .. ": stopping the handle releases it")
                end

                -- isAutomated is driven by the row, not by a separate list that
                -- could drift from it.
                ok(triggers.isAutomated(spec) == row.automated,
                    kind .. ": isAutomated agrees with the row's `automated` flag")
            end
        end

        -- Unknown types: the dispatcher fallbacks are the contract, not an
        -- accident. A spec from a NEWER version must degrade, never crash the UI.
        local alien = { type = "no_such_trigger_type", key = "x" }
        ok(triggers.isAutomated(alien) == false,
            "an unknown type is NOT automated (the safe answer -- it gates unattended firing)")
        ok(not pcall(triggers.validate, alien), "validate rejects an unknown type")
        ok(not pcall(triggers.encode, alien), "encode rejects an unknown type")
        ok(triggers.decode("no_such_trigger_type|x") == nil, "decode returns nil for an unknown type")
        ok(not pcall(triggers.bind, alien, function() end), "bind rejects an unknown type")
        ok(triggers.describe(alien) == "no_such_trigger_type",
            "describe degrades to the bare type name (never blanks the settings row)")
        ok(triggers.glyph(alien) == nil, "glyph returns nil for an unknown type")

        -- `state` is bound by the rules engine, and triggers.bind must say so
        -- rather than pretending the type does not exist.
        local okBind, err = pcall(triggers.bind, SAMPLES.state, function() end)
        ok(okBind == false, "bind refuses a state trigger")
        ok(tostring(err):find("rules engine", 1, true) ~= nil,
            "the state bind error names the rules engine, not 'unknown type'")
    end,
}
