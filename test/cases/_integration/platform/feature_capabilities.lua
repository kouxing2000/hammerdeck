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
        local json     = require("platform.json")
        local manifest = require("platform.manifest")   -- KNOWN_CAPABILITIES, below
        -- The RULE (map inversion, per-file scan, both-directions compare) lives
        -- in platform.capscan, shared with registry.validateExtension so the
        -- build guard and the running app cannot answer this question
        -- differently. What stays here is the ENUMERATION: `find` over a folder,
        -- which reaches files no require does.
        local capscan  = require("platform.capscan")

        local capOf = capscan.capabilityOf()
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
            local calls, requires, raw = {}, {}, {}
            for _, path in ipairs(shell("find '" .. dir .. "' -name '*.lua'")) do
                local c, r, w = capscan.scanSource(readFile(path) or "", capOf)
                for name in pairs(c) do calls[name] = true end
                for name, cap in pairs(w) do raw[name] = cap end
                for mod in pairs(r) do
                    local leaf = mod:match("^platform%.([%w_]+)$")
                    if leaf then requires[leaf] = true end
                end
            end
            return calls, requires, raw
        end

        -- Gated calls each platform module makes through a ctx handed to it, and
        -- the stdlib reach it makes around ctx. Every module is scanned; the fold
        -- below is keyed on what a feature actually requires, and feature_requires
        -- is what keeps that to the allowlist -- so the seam's own io.open
        -- (adapter, i18n) reaches a feature only if that guard is already red.
        local platformCalls, platformRaw = {}, {}
        for _, path in ipairs(shell("find '" .. appdir .. "/platform/lua' -name '*.lua'")) do
            local mod = path:match("([^/]+)%.lua$")
            if mod and mod ~= "ctx" then   -- ctx.lua DEFINES them; it is not a caller
                local calls, _, raw = scan(path)
                if next(calls) then platformCalls[mod] = calls end
                if next(raw) then platformRaw[mod] = raw end
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

        -- `exec` is for USER EXTENSIONS. A catalog feature that needs to run
        -- something grows the surface in the seam (Native+*.swift), where the call
        -- is one reviewed, named thing rather than a general-purpose exit from the
        -- whole capability model -- see the one inviolable rule in CLAUDE.md.
        local catalogExec, gone = {}, {}

        for _, id in ipairs(features) do
            local calls, requires, rawReach = scan(appdir .. "/features/" .. id .. "/lua")
            -- Fold in what the platform modules this feature requires reach
            -- through its ctx (favicons -> network/browser/files).
            for mod in pairs(requires) do
                for name in pairs(platformCalls[mod] or {}) do calls[name] = true end
                -- Raw reach folds only from the ALLOWLISTED modules, the same set
                -- registry.validateExtension walks. `platform.adapter` is the
                -- seam, and CLAUDE.md sanctions exactly one feature module for
                -- requiring it (usage_stats' host-callable reporter) -- without
                -- this gate every one of the adapter's own native.* calls lands
                -- on that feature. Gated calls above are safe to fold either way:
                -- they go through the ctx the feature was handed.
                if manifest.FEATURE_REQUIRABLE[mod] then
                    for name, reach in pairs(platformRaw[mod] or {}) do rawReach[name] = reach end
                end
            end

            local src = readFile(appdir .. "/features/" .. id .. "/feature.json")
            local meta = src and json.decode(src) or nil
            local under, over, withdrawn =
                capscan.compare(calls, (meta or {}).capabilities, capOf, rawReach)
            for _, cap in ipairs(under) do
                missing[#missing + 1] = id .. " needs '" .. cap .. "'"
            end
            for _, cap in ipairs(over) do
                extra[#extra + 1] = id .. " declares unused '" .. cap .. "'"
            end
            for _, w in ipairs(withdrawn) do
                gone[#gone + 1] = id .. ": " .. w
            end
            for _, cap in ipairs((meta or {}).capabilities or {}) do
                if cap == "exec" then catalogExec[#catalogExec + 1] = id .. " (declares it)" end
            end
            -- The CALL, not a raw-stdlib tier: every RAW_REACH entry is either
            -- `files` or withdrawn, so keying on reach.cap == "exec" would be a
            -- branch that can never fire. A catalog feature that calls ctx.run
            -- undeclared would otherwise be caught only by the generic #missing
            -- check below, which would tell the author to add the very
            -- declaration this assertion forbids.
            if calls.run then
                catalogExec[#catalogExec + 1] = id .. " (calls ctx.run)"
            end
        end

        ok(#catalogExec == 0,
            "no first-party feature declares or reaches 'exec' -- catalog features grow OS "
            .. "surface in the seam, not through a general command runner"
            .. (#catalogExec > 0 and (" -- " .. table.concat(catalogExec, "; ")) or ""))
        ok(#gone == 0,
            "no feature calls a stdlib name the embedded interpreter withdrew (it would raise "
            .. "at runtime whatever feature.json says)"
            .. (#gone > 0 and (" -- " .. table.concat(gone, "; ")) or ""))

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
