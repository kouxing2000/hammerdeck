-- platform/manifest.lua
--
-- A feature is a plain Lua table (its "manifest") that DECLARES what it is and
-- how it can be triggered -- it does not wire anything itself. The platform
-- reads the manifest to build the config UI and to bind triggers.
--
-- Manifest shape:
-- {
--   id          = "rest_timer",          -- unique, stable, used as settings key prefix
--   name        = "Rest Timer",          -- shown in config UI
--   description = "Reminds you to rest", -- shown in config UI
--   category    = "health",              -- groups features in the UI
--   options     = {                      -- typed -> the settings form generates itself
--     { key = "intervalMin", type = "int",    default = 25, label = "Interval (min)", min = 5, max = 90 },
--     { key = "message",     type = "string", default = "Time to rest", label = "Message" },
--   },
--   defaultTrigger = { type = "schedule", everyMin = 25 },  -- see triggers.lua for trigger types
--   action = function(ctx) ... end,       -- ctx.opt("intervalMin"), ctx.adapter, ctx.log
-- }

local manifest = {}

local VALID_OPTION_TYPES = {
    bool = true, int = true, string = true, enum = true, time = true, appList = true,
}

-- Validate a manifest table; raises on error. Returns the manifest unchanged.
function manifest.validate(m)
    assert(type(m) == "table", "feature must return a table")
    assert(type(m.id) == "string" and m.id ~= "", "feature.id must be a non-empty string")
    assert(type(m.name) == "string" and m.name ~= "", "feature '" .. tostring(m.id) .. "' needs a name")
    assert(type(m.action) == "function", "feature '" .. m.id .. "' needs an action function")

    m.category = m.category or "general"
    m.options = m.options or {}
    for _, o in ipairs(m.options) do
        assert(type(o.key) == "string", "option in '" .. m.id .. "' needs a key")
        assert(VALID_OPTION_TYPES[o.type], "option '" .. o.key .. "' in '" .. m.id ..
            "' has unknown type '" .. tostring(o.type) .. "'")
    end
    return m
end

-- Return the default value for an option key from a manifest.
function manifest.defaultFor(m, key)
    for _, o in ipairs(m.options or {}) do
        if o.key == key then return o.default end
    end
    return nil
end

return manifest
