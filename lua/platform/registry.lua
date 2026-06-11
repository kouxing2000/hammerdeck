-- platform/registry.lua
--
-- The registry knows every available feature, which ones are enabled, and is
-- responsible for a feature's lifecycle:
--
--   ACTION feature:  enable -> bind its trigger to its action
--   SERVICE feature: enable -> start(ctx)
--   disable (both):  optional stop(ctx), then scope teardown -- every handle
--                    the feature created through ctx is stopped by the platform
--
-- Enabled-state and per-feature option values persist via the adapter, keyed
-- by feature id, so a restart restores exactly what the user selected.

local adapter  = require("platform.adapter")
local manifest = require("platform.manifest")
local triggers = require("platform.triggers")
local ctxlib   = require("platform.ctx")

local registry = {}

local features = {}   -- id -> manifest
local bound    = {}   -- id -> { ctx, scope } (when enabled)

local function enabledKey(id) return "hammerdeck.enabled." .. id end

-- Register a feature module (its validated manifest).
function registry.register(m)
    manifest.validate(m)
    assert(not features[m.id], "duplicate feature id: " .. m.id)
    features[m.id] = m
    return m
end

function registry.all()
    local out = {}
    for _, m in pairs(features) do out[#out + 1] = m end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function registry.isEnabled(id)
    return adapter.getSetting(enabledKey(id), false) == true
end

-- The feature's chosen trigger (user override falls back to its default).
-- TODO(M4): the "hammerdeck.trigger.<id>" override key is read here but has no
-- writer yet. The config UI should add registry.setTrigger(id, spec) =
-- unbind; setSetting(...); if enabled: bind.
local function triggerFor(m)
    return adapter.getSetting("hammerdeck.trigger." .. m.id, nil) or m.defaultTrigger
end

local function bindFeature(m)
    if bound[m.id] then return end               -- already live
    local ctx, scope = ctxlib.make(m)
    bound[m.id] = { ctx = ctx, scope = scope }

    if m.action then
        local spec = triggerFor(m)
        if not spec then
            adapter.log(m.id .. ": enabled but has no trigger; skipping")
            return
        end
        scope.adopt(triggers.bind(spec, function() m.action(ctx) end))
        adapter.log(m.id .. ": bound (" .. spec.type .. ")")
    else
        m.start(ctx)
        adapter.log(m.id .. ": started")
    end
end

local function unbindFeature(m)
    local b = bound[m.id]
    if not b then return end
    if m.stop then
        local ok, err = pcall(m.stop, b.ctx)
        if not ok then adapter.log(m.id .. ": stop() failed: " .. tostring(err)) end
    end
    b.scope.teardown()
    bound[m.id] = nil
    adapter.log(m.id .. ": stopped")
end

function registry.setEnabled(id, on)
    local m = features[id]
    assert(m, "no such feature: " .. id)
    adapter.setSetting(enabledKey(id), on == true)
    if on then bindFeature(m) else unbindFeature(m) end
end

-- Bind every currently-enabled feature. Call once at startup.
function registry.startAll()
    for _, m in ipairs(registry.all()) do
        if registry.isEnabled(m.id) then bindFeature(m) end
    end
end

-- Tear everything down (config reload / shutdown).
function registry.stopAll()
    for _, m in ipairs(registry.all()) do unbindFeature(m) end
end

-- ---------------------------------------------------------------------------
-- Catalog description for the config UI. Returns plain serializable tables
-- (no functions) -- the Swift settings window renders forms from this.
-- ---------------------------------------------------------------------------

local function describeTrigger(m)
    if m.start then return "always-on service" end
    local spec = triggerFor(m)
    if not spec then return "no trigger" end
    if spec.type == "hotkey" then
        return "hotkey: " .. table.concat(spec.mods or {}, "+") .. "+" .. tostring(spec.key)
    elseif spec.type == "schedule" then
        if spec.everyMin then return "schedule: every " .. spec.everyMin .. " min" end
        return "schedule: daily at " .. tostring(spec.at)
    elseif spec.type == "event" then
        return "event: " .. tostring(spec.event)
    end
    return tostring(spec.type)
end

function registry.describe()
    local out = {}
    for _, m in ipairs(registry.all()) do
        local opts = {}
        for _, o in ipairs(m.options or {}) do
            opts[#opts + 1] = {
                key = o.key, type = o.type, label = o.label or o.key,
                default = o.default, min = o.min, max = o.max, values = o.values,
            }
        end
        out[#out + 1] = {
            id = m.id, name = m.name, description = m.description or "",
            category = m.category, version = m.version or "",
            kind = m.start and "service" or "action",
            enabled = registry.isEnabled(m.id),
            triggerDesc = describeTrigger(m),
            options = opts,
        }
    end
    return out
end

-- For tests: total live handles across all enabled features.
function registry.liveHandleCount()
    local n = 0
    for _, b in pairs(bound) do n = n + b.scope.liveCount() end
    return n
end

return registry
