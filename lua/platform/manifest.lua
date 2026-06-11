-- platform/manifest.lua
--
-- A feature is a plain Lua table (its "manifest") that DECLARES what it is and
-- how it runs -- it does not wire anything itself. The platform reads the
-- manifest to build the config UI, bind triggers, and manage lifecycle.
--
-- Two kinds of feature (exactly one of `action` / `start`):
--
--   ACTION feature -- one-shot, fired by a trigger the registry binds:
--     defaultTrigger = { type = "hotkey", mods = {"alt"}, key = "tab" },
--     action = function(ctx) ... end,
--
--   SERVICE feature -- long-running; enable calls start(ctx), disable tears
--   down everything the feature created through ctx (scoped cleanup), then
--   calls the OPTIONAL stop(ctx) for semantic cleanup:
--     start = function(ctx) ... end,
--     stop  = function(ctx) ... end,   -- optional
--
-- Manifest shape:
-- {
--   api         = 1,                     -- ctx contract version (required)
--   id          = "rest_timer",          -- unique, stable, settings key prefix
--   name        = "Rest Timer",          -- shown in config UI
--   description = "Reminds you to rest", -- shown in config UI
--   version     = "1.0.0",               -- feature version (optional)
--   category    = "health",              -- groups features in the UI
--   options     = {                      -- typed -> the settings form generates itself
--     { key = "intervalMin", type = "int", default = 25, label = "Interval (min)", min = 5, max = 90 },
--   },
--   defaultTrigger = ...,                -- ACTION features only
--   action / start / stop = ...,         -- see above
-- }

local manifest = {}

-- The ctx contract version this platform implements. Bump on breaking change
-- to the ctx surface; loaders reject mismatched features with a clear error.
manifest.API_VERSION = 1

local VALID_OPTION_TYPES = {
    bool = true, int = true, string = true, enum = true, time = true, appList = true,
}

-- Validate a manifest table; raises on error. Returns the manifest unchanged.
function manifest.validate(m)
    assert(type(m) == "table", "feature must return a table")
    assert(type(m.id) == "string" and m.id ~= "", "feature.id must be a non-empty string")
    assert(m.api == manifest.API_VERSION,
        "feature '" .. m.id .. "' declares api=" .. tostring(m.api) ..
        " but this platform implements api=" .. manifest.API_VERSION)
    assert(type(m.name) == "string" and m.name ~= "", "feature '" .. m.id .. "' needs a name")

    local hasAction = type(m.action) == "function"
    local hasStart  = type(m.start) == "function"
    assert(hasAction ~= hasStart,
        "feature '" .. m.id .. "' must define exactly one of action(ctx) or start(ctx)")
    if m.stop ~= nil then
        assert(hasStart, "feature '" .. m.id .. "': stop(ctx) only makes sense with start(ctx)")
        assert(type(m.stop) == "function", "feature '" .. m.id .. "': stop must be a function")
    end
    if m.defaultTrigger ~= nil then
        assert(hasAction,
            "feature '" .. m.id .. "': defaultTrigger requires action(ctx); " ..
            "service features create their own bindings through ctx")
        assert(type(m.defaultTrigger) == "table" and m.defaultTrigger.type,
            "feature '" .. m.id .. "': defaultTrigger must be a trigger spec table")
    end

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
