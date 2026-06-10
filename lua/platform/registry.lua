-- platform/registry.lua
--
-- The registry knows every available feature, which ones are enabled, and is
-- responsible for wiring an enabled feature's trigger to its action. It is the
-- bridge between manifests (declaration) and triggers (live binding).
--
-- Enabled-state and per-feature option values persist via the adapter, keyed by
-- feature id, so a restart restores exactly what the user selected.

local adapter  = require("platform.adapter")
local manifest = require("platform.manifest")
local triggers = require("platform.triggers")

local registry = {}

local features = {}   -- id -> manifest
local bindings = {}   -- id -> live trigger handle (when enabled)

local function enabledKey(id)    return "hammerdeck.enabled." .. id end
local function optionKey(id, k)  return "hammerdeck.opt." .. id .. "." .. k end

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

-- Build the ctx passed to a feature's action: option accessors + adapter + log.
local function makeContext(m)
    return {
        adapter = adapter,
        opt = function(key)
            return adapter.getSetting(optionKey(m.id, key), manifest.defaultFor(m, key))
        end,
        log = function(...) adapter.log("[" .. m.id .. "]", ...) end,
    }
end

-- The feature's chosen trigger (user override falls back to its default).
-- TODO(M2): the "hammerdeck.trigger.<id>" override key is read here but has no
-- writer yet, and there is no rebind path when a trigger changes while enabled
-- (only disable->enable re-applies it). The config UI should add
-- registry.setTrigger(id, spec) = unbind(m); setSetting(...); if enabled: bind(m).
local function triggerFor(m)
    return adapter.getSetting("hammerdeck.trigger." .. m.id, nil) or m.defaultTrigger
end

local function bind(m)
    if bindings[m.id] then return end             -- already bound
    local spec = triggerFor(m)
    if not spec then
        adapter.log(m.id .. ": enabled but has no trigger; skipping")
        return
    end
    local ctx = makeContext(m)
    bindings[m.id] = triggers.bind(spec, function() m.action(ctx) end)
    adapter.log(m.id .. ": bound (" .. spec.type .. ")")
end

local function unbind(m)
    local b = bindings[m.id]
    if b then b.stop(); bindings[m.id] = nil end
end

function registry.setEnabled(id, on)
    local m = features[id]
    assert(m, "no such feature: " .. id)
    adapter.setSetting(enabledKey(id), on == true)
    if on then bind(m) else unbind(m) end
end

-- Bind every currently-enabled feature. Call once at startup.
function registry.startAll()
    for _, m in ipairs(registry.all()) do
        if registry.isEnabled(m.id) then bind(m) end
    end
end

return registry
