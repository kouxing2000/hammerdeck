-- hammerdeck.lua -- Hammerdeck entry point.
--
-- (Named "hammerdeck", NOT "init": Hammerspoon's package.path includes
-- ~/.hammerspoon/?.lua, so a module called "init" can resolve to the user's
-- own config file and recurse.)
--
-- During development, load this from your real ~/.hammerspoon/init.lua with:
--   package.path = package.path
--       .. ";" .. os.getenv("HOME") .. "/workspaces/git/hammerdeck/lua/?.lua"
--       .. ";" .. os.getenv("HOME") .. "/workspaces/git/hammerdeck/lua/?/init.lua"
--   hammerdeck = require("hammerdeck")   -- global, so the HS console can toggle features
--
-- Bootstrap order: register every feature, then bind the enabled ones.

-- Make feature directories (features/<id>/init.lua) requireable regardless of
-- how the caller set up package.path.
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]hammerdeck%.lua$")
if here then
    package.path = package.path .. ";" .. here .. "/?.lua;" .. here .. "/?/init.lua"
end

local adapter  = require("platform.adapter")
local registry = require("platform.registry")

-- ---------------------------------------------------------------------------
-- Feature catalog: autodiscovered by scanning lua/features/ (drop in a folder,
-- Reload, and it appears -- no list to maintain). Loads are quarantined, so one
-- broken plugin is recorded + surfaced in the UI, not fatal to boot.
-- ---------------------------------------------------------------------------
if here then
    registry.loadFromDir(here .. "/features")
else
    -- Fallback only if this file's path couldn't be resolved (shouldn't happen
    -- in a normal boot): a hand-maintained list keeps the app non-empty.
    registry.loadCatalog({
        "features.sleep_schedule", "features.rest_timer", "features.window_jump",
        "features.idle_dimmer", "features.clipboard_clean",
    })
end

-- First run only: enable everything so there's something to dogfood. After
-- that, enabled-state is the user's (toggle via registry.setEnabled until the
-- config UI exists). NOTE: the old "re-enable hello every boot" check was a
-- bug -- it overrode a user's disable on the next reload.
-- HAMMERDECK_NO_FIRSTRUN=1 skips the auto-enable (CI / smoke tests).
if os.getenv("HAMMERDECK_NO_FIRSTRUN") == nil
    and adapter.getSetting("hammerdeck.firstRun.done", false) ~= true then
    adapter.setSetting("hammerdeck.firstRun.done", true)
    for _, m in ipairs(registry.all()) do
        registry.setEnabled(m.id, true)
    end
end

registry.startAll()

print("[hammerdeck] started; features registered=" .. #registry.all())

return registry
