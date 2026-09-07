-- test/cases/_integration/platform/curated_spine.lua -- the two curation flags
-- name ONE set (PROD-2).
--
-- `recommended` and `defaultEnabled` are different MECHANISMS with, deliberately,
-- the same membership:
--
--   recommended    -- what the catalog is SOLD on. Drives the Gallery star, the
--                     Tour label, and the Homepage "Enable Essentials" button.
--                     It orders nothing: Settings and the README each rank their
--                     sections from their own declared list, and rows from
--                     `order`.
--   defaultEnabled -- what a stranger gets WORKING on install. A fallback only:
--                     registry.isEnabled lets an explicit user toggle win, so it
--                     is not a stable marker of curation on its own.
--
-- Keeping them identical is what this guard exists for. Turn everything off and
-- the Homepage offers "Enable Essentials", which seeds exactly the `recommended`
-- set -- so a feature that ships ON without being `recommended` is one the user
-- cannot get back, and a feature `recommended` without shipping on is offered as
-- an Essential the install never had. Nothing else notices either case.
--
-- This guard does NOT forbid the two sets differing forever. It forbids them
-- differing SILENTLY: a defensible reason exists (nine features seizing nine
-- default hotkeys on first launch is a real cost), and if that day comes, the
-- fix is to split this assertion and write the reason next to it -- not to
-- delete it.

return {
    id = "curated_spine",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok = t.ok
        local appdir = require("loader").appdir
        local json   = require("platform.json")

        -- Enumerate the catalog from disk, the way the sibling build guards do:
        -- the question is about what each feature.json DECLARES, which is what a
        -- reader opens, not about what the registry resolved at runtime.
        local recommended, defaultOn, seen = {}, {}, 0
        local p = io.popen("ls -1 '" .. appdir .. "/features' 2>/dev/null")
        assert(p, "cannot list the feature directory")
        for id in p:lines() do
            local f = io.open(appdir .. "/features/" .. id .. "/feature.json", "r")
            if f then
                local raw = f:read("a"); f:close()
                local d = json.decode(raw)
                if type(d) == "table" then
                    seen = seen + 1
                    if d.recommended == true then recommended[id] = true end
                    if d.defaultEnabled == true then defaultOn[id] = true end
                end
            end
        end
        p:close()

        -- An empty scan passes every set comparison below vacuously -- the same
        -- trap feature_capabilities calls out in its own header.
        ok(seen >= 20, "curated_spine scanned the real catalog (" .. seen .. " features)")

        -- Non-emptiness only. A floor on the SIZE of the spine, or on how much of
        -- it is window features, would encode today's curation as arithmetic --
        -- and a test whose red means "the product changed its mind" gets edited
        -- to match rather than read. The set comparison below is the invariant;
        -- the roster is PRODUCT.md's business, not this file's.
        local starred = 0
        for _ in pairs(recommended) do starred = starred + 1 end
        ok(starred > 0, "the curated spine is non-empty (" .. starred .. " recommended)")

        local missingOn, missingRec = {}, {}
        for id in pairs(recommended) do
            if not defaultOn[id] then missingOn[#missingOn + 1] = id end
        end
        for id in pairs(defaultOn) do
            if not recommended[id] then missingRec[#missingRec + 1] = id end
        end
        table.sort(missingOn); table.sort(missingRec)

        ok(#missingOn == 0,
            "every `recommended` feature also ships enabled -- otherwise the "
            .. "catalog sells as Essential something a fresh install does not "
            .. "have [" .. table.concat(missingOn, ", ") .. "]")
        ok(#missingRec == 0,
            "every `defaultEnabled` feature is also `recommended` -- otherwise a "
            .. "user who turns everything off cannot get it back from Enable "
            .. "Essentials [" .. table.concat(missingRec, ", ") .. "]")
    end,
}
