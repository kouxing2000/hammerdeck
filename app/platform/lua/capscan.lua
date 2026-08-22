-- app/platform/lua/capscan.lua -- the capability DECLARATION rule, in one place.
--
-- "Which capabilities does this code actually need, and does its feature.json
-- say so?" is asked from two places that cannot share a caller: the build guard
-- (test/cases/_integration/platform/feature_capabilities.lua, over the
-- first-party catalog) and the running app (registry.validateExtension, over a
-- user extension an agent just wrote). Answering it twice would let the two
-- answers drift, and a guard that disagrees with the app it guards is worse than
-- no guard -- so the RULE lives here and the callers differ only in how they
-- hand over source text.
--
-- Nothing here touches the adapter, the filesystem, or native: it is text in,
-- verdict out. That is what lets the build guard read files with `find` while
-- the runtime walks the require graph through the seam.
--
-- Source-scanning, so it cannot see dynamic dispatch (`ctx[name]()`); the
-- runtime stub in ctx.make stays the backstop for that.

local manifest = require("platform.manifest")

local M = {}

---Inverted view of manifest.CAPABILITY_METHODS: gated ctx method -> capability.
---Derived from the same table ctx.make gates on, so the check cannot drift from
---the gate it describes.
---@return table<string,string>
function M.capabilityOf()
    local capOf = {}
    for cap, methods in pairs(manifest.CAPABILITY_METHODS) do
        for _, name in ipairs(methods) do capOf[name] = cap end
    end
    return capOf
end

---Gated ctx.* calls and platform/extension requires in ONE file's text.
---Comment lines are skipped so prose in a header ("calls ctx.httpGet") never
---fabricates a requirement.
---@param src string             file contents
---@param capOf table<string,string>
---@return table<string,boolean> calls     gated ctx method names
---@return table<string,boolean> requires  required module paths, whole and dotted
---        ("platform.json", "extensions.my_feature.helper") -- the caller splits
---        them, because the namespaces have different depths.
function M.scanSource(src, capOf)
    local calls, requires = {}, {}
    for line in (src or ""):gmatch("[^\n]*") do
        if not line:match("^%s*%-%-") then
            for name in line:gmatch("ctx%.(%w+)") do
                if capOf[name] then calls[name] = true end
            end
            -- The WHOLE dotted path: platform.* is two segments while
            -- extensions.<id>.* and features.<id>.* are three, so a
            -- fixed-arity pattern silently truncates the deeper ones and the
            -- sibling module is never followed.
            local mod = line:match("require%s*%(?%s*[\"']([%w_%.]+)[\"']")
            if mod and mod:find("%.") then requires[mod] = true end
        end
    end
    return calls, requires
end

---Compare what the code reaches against what feature.json claims.
---@param calls table<string,boolean>     gated ctx methods actually called
---@param declared string[]               the feature.json `capabilities` list
---@param capOf table<string,string>
---@return string[] under  needed but not declared -- a latent crash
---@return string[] over   declared but unused -- a label rotting into decoration
function M.compare(calls, declared, capOf)
    local needed, have = {}, {}
    for name in pairs(calls) do needed[capOf[name]] = true end
    for _, cap in ipairs(declared or {}) do have[cap] = true end

    local under, over = {}, {}
    for cap in pairs(needed) do
        if not have[cap] then under[#under + 1] = cap end
    end
    for cap in pairs(have) do
        -- `commands` is ADDITIVE (ctx.commands/runCommand are INJECTED, not
        -- gated), so it never appears in the map and is never "unused".
        if cap ~= "commands" and not needed[cap] then over[#over + 1] = cap end
    end
    table.sort(under)
    table.sort(over)
    return under, over
end

return M
