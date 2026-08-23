-- test/cases/_integration/platform/feature_requires.lua -- the feature require-ALLOWLIST guard,
-- the mirror image of the leaf-guard in i18n_catalog.lua. That guard proves the
-- leaf utils stay require-free; NOTHING guarded the other direction -- a feature
-- quietly requiring platform.registry / platform.i18n / another feature would
-- ship without a test noticing (the 2026-07-23 audit's highest-value rule gap).
-- This case scans every .lua under app/features/*/lua/ on disk, RECURSIVELY --
-- the loader resolves nested modules (features.<id>.a.b -> <id>/lua/a/b.lua),
-- so a flat scan would leave subfolder code unguarded. Real files, like the
-- leaf guard -- the fake adapter's catalog is irrelevant here. Each `require`
-- must be within the CLAUDE.md allowlist:
--
--   * the leaf utils: platform.{json,urls,hotkeys,windows,cyclingChooser}
--   * the pure factory subsystem: platform.favicons
--   * the feature's OWN submodules: features.<same id>.*
--   * platform.adapter ONLY in a module whose header self-declares the
--     host-callable reporter role (CLAUDE.md's one sanctioned exception --
--     "explicit and greppable"; usage_stats/lua/report.lua today). The guard
--     enforces the self-declaration, not a hardcoded filename.
--
-- Comment lines are skipped so prose never trips the guard; empty-scan is a
-- loud failure, never a false green.

return {
    id = "feature_requires",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok = t.ok
        local appdir = require("loader").appdir

        -- Derived from manifest.FEATURE_REQUIRABLE, which registry's own require
        -- walk also reads: a second copy here would eventually disagree with the
        -- one the running app enforces.
        local ALLOWED = {}
        for mod in pairs(require("platform.manifest").FEATURE_REQUIRABLE) do
            ALLOWED["platform." .. mod] = true
        end
        ok(next(ALLOWED) ~= nil, "require guard: the allowlist is non-empty (no false green)")

        ---@param path string
        ---@return string[]
        local function listDir(path)
            local out = {}
            local fh = io.popen("ls -1 '" .. path .. "' 2>/dev/null")
            if fh then
                for name in fh:lines() do out[#out + 1] = name end
                fh:close()
            end
            return out
        end

        -- A feature is a folder with a lua/init.lua (the discovery contract).
        local features = {}
        for _, id in ipairs(listDir(appdir .. "/features")) do
            local init = io.open(appdir .. "/features/" .. id .. "/lua/init.lua", "r")
            if init then
                init:close()
                features[#features + 1] = id
            end
        end
        ok(#features > 0, "require-guard: found feature folders to scan (no false green)")

        ---Recursive .lua listing (the loader maps nested module names onto
        ---nested files, so the guard must see them too).
        ---@param dir string
        ---@return string[] # paths relative to dir
        local function listLuaFiles(dir)
            local out = {}
            local fh = io.popen("find '" .. dir .. "' -name '*.lua' 2>/dev/null")
            if fh then
                for path in fh:lines() do out[#out + 1] = path:sub(#dir + 2) end
                fh:close()
            end
            return out
        end

        local violations, emptyFeatures = {}, {}
        for _, id in ipairs(features) do
            local ownPrefix = "features." .. id .. "."
            local luaDir = appdir .. "/features/" .. id .. "/lua"
            local files = listLuaFiles(luaDir)
            if #files == 0 then emptyFeatures[#emptyFeatures + 1] = id end
            for _, fname in ipairs(files) do
                local path = luaDir .. "/" .. fname
                local fh = assert(io.open(path, "r"), "require-guard: cannot open " .. path)
                local lineno, hostCallable = 0, false
                for line in fh:lines() do
                    lineno = lineno + 1
                    -- The sanctioned reporter role must be declared up top
                    -- (before any require can rely on it).
                    if lineno <= 15 and line:match("[Hh]ost%-callable") then
                        hostCallable = true
                    end
                    if not line:match("^%s*%-%-") then
                        -- Quoted form is the house style; the long-bracket form
                        -- (require [[x]]) is matched too so it cannot slip past.
                        local mod = line:match("require%s*%(?%s*[\"']([^\"']+)[\"']")
                            or line:match("require%s*%(?%s*%[%[(.-)%]%]")
                        if mod then
                            local allowed = ALLOWED[mod]
                                or mod:sub(1, #ownPrefix) == ownPrefix
                                or (mod == "platform.adapter" and hostCallable)
                            if not allowed then
                                violations[#violations + 1] =
                                    id .. "/" .. fname .. ":" .. lineno .. " requires '" .. mod .. "'"
                            end
                        end
                    end
                end
                fh:close()
            end
        end
        ok(#emptyFeatures == 0,
            "require-guard: every feature folder yielded lua files to scan"
            .. (#emptyFeatures > 0 and (" -- empty: " .. table.concat(emptyFeatures, ", ")) or ""))
        ok(#violations == 0,
            "features require only the leaf set + favicons + own submodules "
            .. "(platform.adapter only under a self-declared host-callable header)"
            .. (#violations > 0 and (" -- " .. table.concat(violations, "; ")) or ""))
    end,
}
