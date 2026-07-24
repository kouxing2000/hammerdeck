-- test/cases/_integration/platform/feature_capabilities.lua -- the capability
-- DECLARATION guard (CODE-3), sibling to feature_requires.lua.
--
-- The runtime gate in ctx.make already withholds an undeclared method, so a
-- feature that under-declares fails when that code path runs. That is the wrong
-- moment: the path may be a rare branch (a network retry, an error handler) that
-- no one exercises until a user does. This guard moves the failure to build time
-- by scanning what each feature ACTUALLY calls and comparing it to what
-- feature.json claims.
--
-- It checks BOTH directions, and the second one is the point:
--
--   UNDER-declared -- calls a gated method it never declared. A latent crash.
--   OVER-declared  -- declares a capability nothing in it uses. Harmless at
--                     runtime, corrosive to the whole exercise: capabilities are
--                     only worth reading if they are true, and a stale "network"
--                     left behind after a refactor is exactly how a label set
--                     rots into decoration. Removing it is the fix.
--
-- TRANSITIVE reach is included. platform.favicons takes a feature's ctx and
-- calls ctx.downloadFile / ctx.extractFavicons / file IO through it, so a
-- feature that requires favicons genuinely does reach the network -- and must
-- say so. Attributing only a feature's own file text would under-report exactly
-- the indirect reach a reader most wants declared.
--
-- Source-scanning, so it cannot see dynamic dispatch (`ctx[name]()`); the
-- runtime stub in ctx.make stays the backstop for that. Empty scans fail loudly
-- rather than passing vacuously.

return {
    id = "feature_capabilities",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok = t.ok
        local appdir   = require("loader").appdir
        local manifest = require("platform.manifest")
        local json     = require("platform.json")

        -- ctx method -> the capability gating it (inverted from the one map that
        -- ctx.make itself gates on, so the guard cannot drift from the gate).
        local capOf = {}
        for cap, methods in pairs(manifest.CAPABILITY_METHODS) do
            for _, name in ipairs(methods) do capOf[name] = cap end
        end
        ok(next(capOf) ~= nil, "capability guard: the capability map is non-empty (no false green)")

        local function shell(cmd)
            local out, fh = {}, io.popen(cmd .. " 2>/dev/null")
            if fh then
                for line in fh:lines() do out[#out + 1] = line end
                fh:close()
            end
            return out
        end

        local function readFile(path)
            local fh = io.open(path, "r")
            if not fh then return nil end
            local s = fh:read("*a")
            fh:close()
            return s
        end

        ---Gated ctx.* method names called anywhere in `dir`, plus the
        ---platform.* modules it requires. Comment lines are skipped so the prose
        ---in a header ("calls ctx.httpGet") never fabricates a requirement.
        local function scan(dir)
            local calls, requires = {}, {}
            for _, path in ipairs(shell("find '" .. dir .. "' -name '*.lua'")) do
                local src = readFile(path) or ""
                for line in src:gmatch("[^\n]*") do
                    if not line:match("^%s*%-%-") then
                        for name in line:gmatch("ctx%.(%w+)") do
                            if capOf[name] then calls[name] = true end
                        end
                        local mod = line:match("require%s*%(?%s*[\"']platform%.(%w+)[\"']")
                        if mod then requires[mod] = true end
                    end
                end
            end
            return calls, requires
        end

        -- Gated calls each platform module makes through a ctx handed to it.
        local platformCalls = {}
        for _, path in ipairs(shell("find '" .. appdir .. "/platform/lua' -name '*.lua'")) do
            local mod = path:match("([^/]+)%.lua$")
            if mod and mod ~= "ctx" then   -- ctx.lua DEFINES them; it is not a caller
                local calls = scan(path)
                if next(calls) then platformCalls[mod] = calls end
            end
        end
        ok(platformCalls.favicons ~= nil,
            "capability guard: favicons is seen to reach gated methods through ctx "
            .. "(if this fails the transitive scan found nothing -- a false green)")

        local features, missing, extra = {}, {}, {}
        for _, id in ipairs(shell("ls -1 '" .. appdir .. "/features'")) do
            local init = io.open(appdir .. "/features/" .. id .. "/lua/init.lua", "r")
            if init then init:close(); features[#features + 1] = id end
        end
        ok(#features > 0, "capability guard: found feature folders to scan (no false green)")

        for _, id in ipairs(features) do
            local calls, requires = scan(appdir .. "/features/" .. id .. "/lua")
            -- Fold in what the platform modules this feature requires reach
            -- through its ctx (favicons -> network/browser/files).
            for mod in pairs(requires) do
                for name in pairs(platformCalls[mod] or {}) do calls[name] = true end
            end

            local needed = {}
            for name in pairs(calls) do needed[capOf[name]] = true end

            local declared = {}
            local raw = readFile(appdir .. "/features/" .. id .. "/feature.json")
            local meta = raw and json.decode(raw) or nil
            for _, cap in ipairs((meta or {}).capabilities or {}) do declared[cap] = true end

            for cap in pairs(needed) do
                if not declared[cap] then
                    missing[#missing + 1] = id .. " needs '" .. cap .. "'"
                end
            end
            for cap in pairs(declared) do
                -- `commands` is ADDITIVE (ctx.commands/runCommand are injected,
                -- not gated), so it is outside this map and never "extra".
                if cap ~= "commands" and not needed[cap] then
                    extra[#extra + 1] = id .. " declares unused '" .. cap .. "'"
                end
            end
        end

        ok(#missing == 0,
            "every feature declares the capabilities it actually uses"
            .. (#missing > 0 and (" -- " .. table.concat(missing, "; ")) or ""))
        ok(#extra == 0,
            "no feature declares a capability it does not use (stale labels rot the signal)"
            .. (#extra > 0 and (" -- " .. table.concat(extra, "; ")) or ""))

        -- Every declared capability must be a KNOWN one -- manifest.validate
        -- enforces this at load, but only for features that actually load; a typo
        -- in a disabled/broken feature's json would otherwise sit unnoticed.
        local unknown = {}
        for _, id in ipairs(features) do
            local raw = readFile(appdir .. "/features/" .. id .. "/feature.json")
            local meta = raw and json.decode(raw) or nil
            for _, cap in ipairs((meta or {}).capabilities or {}) do
                if not manifest.KNOWN_CAPABILITIES[cap] then
                    unknown[#unknown + 1] = id .. ": '" .. tostring(cap) .. "'"
                end
            end
        end
        ok(#unknown == 0,
            "no feature.json declares an unknown capability"
            .. (#unknown > 0 and (" -- " .. table.concat(unknown, "; ")) or ""))
    end,
}
