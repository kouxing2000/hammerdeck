-- hammerdeck.lua -- Hammerdeck entry point.
--
-- (Named "hammerdeck", NOT "init": Hammerspoon's package.path includes
-- ~/.hammerspoon/?.lua, so a module called "init" can resolve to the user's
-- own config file and recurse.)
--
-- During development, load this from your real ~/.hammerspoon/init.lua with:
--   package.path = package.path
--       .. ";" .. os.getenv("HOME") .. "/workspaces/git/hammerdeck/app/?.lua"
--       .. ";" .. os.getenv("HOME") .. "/workspaces/git/hammerdeck/app/?/init.lua"
--   hammerdeck = require("hammerdeck")   -- global, so the HS console can toggle features
--
-- Bootstrap order: register every feature, then bind the enabled ones.

-- Make feature directories (features/<id>/init.lua) requireable regardless of
-- how the caller set up package.path.
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]hammerdeck%.lua$")
if here then
    package.path = package.path .. ";" .. here .. "/?.lua;" .. here .. "/?/init.lua"
end

-- Co-located layout: platform/feature Lua lives under `lua/` subfolders. Install
-- the searcher that maps the require names onto them BEFORE the first such
-- require (loader itself sits at app root, found by the package.path above).
require("loader").install()

local adapter  = require("platform.adapter")
local registry = require("platform.registry")

-- Localization: resolve the UI locale ONCE (the Swift LocaleResolver is the
-- authority, surfaced via adapter.locale()) and hand it to the i18n catalog, so
-- registry.describe() metadata and every ctx.t localize against the same code.
require("platform.i18n").configure({ locale = adapter.locale() })

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
        "features.sleep_schedule", "features.break_reminder", "features.window_switcher",
        "features.display_off", "features.plain_paste",
    })
end

-- First run: start BLANK -- nothing enabled. A new user lands in the Feature
-- Tour (host-side onboarding: a large auto-playing preview per feature, "Add"
-- to enable) instead of being handed all 19 features at once. We still flip the
-- `hammerdeck.firstRun.done` flag here so the host knows it's first launch (it
-- reads the flag BEFORE this boot runs, to decide whether to greet with the
-- tour). HAMMERDECK_NO_FIRSTRUN=1 skips the flip (CI / smoke tests).
if os.getenv("HAMMERDECK_NO_FIRSTRUN") == nil
    and adapter.getSetting("hammerdeck.firstRun.done", false) ~= true then
    adapter.setSetting("hammerdeck.firstRun.done", true)
end

registry.startAll()

-- Automation rules: bind author-configured trigger->effect rules over the live
-- catalog (M0: `command` effects that run a feature action). The rules config is
-- read from the `hammerdeck.rules` setting (JSON) -- the same key a future
-- builder UI will write. Quarantined: a bad rules config logs and is skipped, it
-- never breaks feature boot.
local rules = require("platform.rules")
local okRules, errRules = pcall(function()
    rules.loadFromSettings()
    rules.startAll()
end)
if not okRules then adapter.log("rules engine boot FAILED: " .. tostring(errRules)) end

print("[hammerdeck] started; features=" .. #registry.all()
    .. ", rules=" .. rules.count())

return registry
