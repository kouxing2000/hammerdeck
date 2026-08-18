-- app/loader.lua -- module searcher for the co-located feature layout.
--
-- Each feature (and the platform itself) keeps its Lua under a `lua/` subfolder,
-- a peer of `swift/` (and any future <lang>/ surface). The require NAMES are
-- unchanged by that reshape -- this searcher maps the stable dotted names onto
-- the subfolders, so `require("features.usage_stats.store")` and
-- `require("platform.adapter")` resolve exactly as before:
--
--   platform.X[.Y...]    -> <app>/platform/lua/X[/Y...].lua
--   features.<id>[.Y...] -> <app>/features/<id>/lua/[Y...].lua   (bare id -> init.lua)
--   extensions.<id>[.Y..] -> <extensionsRoot>/<id>/lua/[Y...].lua  (user extensions --
--                            the root is a USER folder, set at boot/reload via
--                            setExtensionsRoot from the hammerdeck.extensionsDir
--                            setting; unresolvable until then)
--
-- The sibling `swift/` dir (and any other non-Lua surface) is invisible to
-- require -- only `lua/` is searched. Install() must run before the first
-- platform/feature require (the entry points -- hammerdeck.lua and the test
-- harness -- call it up front).
local M = {}

-- The app root, derived from THIS file's own location (robust to the launch
-- working directory, like the Swift-side defaultLuaDir). Exposed as M.appdir so
-- the registry can locate a feature's co-located feature.json (<id>/feature.json).
local APPDIR = debug.getinfo(1, "S").source:match("^@(.*)[/\\]loader%.lua$")

-- The user-extensions root (nil until the registry resolves the
-- hammerdeck.extensionsDir setting). While nil, `extensions.*` names simply
-- defer to the other searchers -- a stray require fails as "module not found",
-- not as a loader error.
local EXTROOT = nil

-- Map a dotted module name to its on-disk path under the lua/ subfolder, or nil
-- if it is not one of our two namespaces (then other searchers handle it).
local function resolve(modname)
    local parts = {}
    for p in modname:gmatch("[^.]+") do parts[#parts + 1] = p end
    local base, first
    if parts[1] == "platform" then
        base, first = APPDIR .. "/platform/lua", 2
    elseif parts[1] == "features" then
        if not parts[2] then return nil end
        base, first = APPDIR .. "/features/" .. parts[2] .. "/lua", 3
    elseif parts[1] == "extensions" then
        if not EXTROOT or not parts[2] then return nil end
        base, first = EXTROOT .. "/" .. parts[2] .. "/lua", 3
    else
        return nil
    end
    local rest = {}
    for i = first, #parts do rest[#rest + 1] = parts[i] end
    if #rest == 0 then
        return base .. "/init.lua"
    end
    return base .. "/" .. table.concat(rest, "/") .. ".lua"
end

local function searcher(modname)
    local path = resolve(modname)
    if not path then return nil end            -- not our namespace; defer to the next searcher
    local f = io.open(path, "r")
    if not f then
        return "\n\tno file '" .. path .. "' (hammerdeck loader)"
    end
    f:close()
    local chunk, err = loadfile(path)
    if not chunk then error(err) end
    return chunk, path
end

-- Idempotent: several entry points may call install(); only the first inserts.
-- Position 2 puts us after package.preload (so a preloaded module -- e.g. the
-- test harness's fake `platform.adapter` -- still wins) but before the default
-- path searcher.
function M.install()
    if M._installed then return end
    table.insert(package.searchers, 2, searcher)
    M._installed = true
end

-- Point the `extensions.*` namespace at a user folder (nil detaches it). The
-- registry owns the call: boot/reload resolve the hammerdeck.extensionsDir
-- setting and hand the dir here; registry.reset() clears it between test cases.
function M.setExtensionsRoot(dir)
    EXTROOT = dir
end

-- The resolved app root (absolute in the real app, "app" relative to the repo
-- root in the headless test). Callers append "/features/<id>/..." etc.
M.appdir = APPDIR

return M
