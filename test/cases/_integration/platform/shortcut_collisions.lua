-- test/cases/_integration/platform/shortcut_collisions.lua -- no two shipped features declare COLLIDING default shortcuts. There
-- is no single registry of default triggers -- each feature declares its own
-- in init.lua -- so this scans the WHOLE on-disk catalog and fails loudly on
-- any default-vs-default conflict, catching it at authoring/CI time instead of
-- the interactive rebind wall. Runs on both engines.
--
-- Migrated from run.lua T25g (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "shortcut_collisions",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, triggers = t.ok, t.triggers

        do
            local appdir = require("loader").appdir

            -- enumerate every feature dir that has a lua/init.lua (the shipped catalog)
            local ids = {}
            local pipe = io.popen('ls "' .. appdir .. '/features" 2>/dev/null')
            if pipe then
                for name in pipe:lines() do
                    local fh = io.open(appdir .. "/features/" .. name .. "/lua/init.lua", "r")
                    if fh then fh:close(); ids[#ids + 1] = name end
                end
                pipe:close()
            end
            ok(#ids >= 20, "default-trigger scan enumerated the on-disk catalog (" .. #ids .. " features)")

            -- collect every declared default hotkey/chord straight from init.lua (raw,
            -- not validated: feature.json -- the source of `name` -- is overlaid only at
            -- register time, and defaults live in init.lua regardless). Handle both the
            -- actions[] shape and the single-action sugar (top-level action+defaultTrigger).
            local defaults = {}
            local function record(id, action, spec)
                if spec and (spec.type == "hotkey" or spec.type == "chord") then
                    defaults[#defaults + 1] = { feature = id, action = action, spec = spec }
                end
            end
            for _, id in ipairs(ids) do
                local mod = require("features." .. id)
                if type(mod.actions) == "table" then
                    for _, a in ipairs(mod.actions) do record(id, a.id or "?", a.defaultTrigger) end
                else
                    record(id, "main", mod.defaultTrigger)   -- single-action sugar
                end
            end

            -- pairwise: two DIFFERENT features must not default to conflicting shortcuts
            -- (triggers.conflicts encodes the hotkey/chord-prefix rules; same-prefix chords
            -- with different follow keys are legitimately NOT a conflict).
            local clashes = {}
            for i = 1, #defaults do
                for j = i + 1, #defaults do
                    local A, B = defaults[i], defaults[j]
                    if A.feature ~= B.feature and triggers.conflicts(A.spec, B.spec) then
                        clashes[#clashes + 1] = A.feature .. "." .. A.action
                            .. " vs " .. B.feature .. "." .. B.action
                            .. " (" .. triggers.describe(A.spec) .. ")"
                    end
                end
            end
            ok(#clashes == 0,
                "no two features ship colliding default shortcuts"
                .. (#clashes > 0 and (" -- " .. table.concat(clashes, "; ")) or ""))
        end
    end,
}
