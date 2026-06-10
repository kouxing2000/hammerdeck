-- init.lua -- Hammerdeck entry point.
--
-- During development, load this from your real ~/.hammerspoon/init.lua with:
--   package.path = package.path .. ";" .. os.getenv("HOME") .. "/workspaces/git/hammerdeck/?.lua"
--   require("init")   -- (or point hs.configdir here / symlink)
--
-- Bootstrap order: register every feature, then bind the enabled ones.

local registry = require("platform.registry")

-- ---------------------------------------------------------------------------
-- Feature catalog. Add a line per feature module. (A future iteration can
-- auto-discover everything in features/ -- explicit list is fine to start.)
-- ---------------------------------------------------------------------------
local CATALOG = {
    "features.hello",
}

for _, modname in ipairs(CATALOG) do
    registry.register(require(modname))
end

-- For first run / demo: enable hello so there's something to see.
-- Remove once the config UI can toggle features.
if registry.isEnabled("hello") == false then
    registry.setEnabled("hello", true)
end

registry.startAll()

print("[hammerdeck] started; features registered=" .. #registry.all())

return registry
