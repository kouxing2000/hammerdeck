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
local catalog  = {}   -- the module-name list, remembered so reload() can re-run it
local discoverDir = nil   -- when set, the catalog is re-scanned from disk on reload

-- Quarantine bookkeeping: a broken plugin must never take the whole app down.
local loadFailures  = {}   -- list of { source, id?, error } -- never registered
local startFailures = {}   -- id -> error string -- registered but failed to start

local function enabledKey(id) return "hammerdeck.enabled." .. id end

-- Register a feature module (its validated manifest). Throws on a bad manifest
-- or duplicate id -- callers that must survive a broken plugin use
-- registry.load() (below), which quarantines those throws.
function registry.register(m)
    manifest.validate(m)
    assert(not features[m.id], "duplicate feature id: " .. m.id)
    features[m.id] = m
    return m
end

-- Load + register one catalog module under quarantine. A broken module (require
-- error, validate failure, duplicate id) is recorded and skipped instead of
-- aborting the boot; the rest of the catalog still loads. Returns the manifest
-- on success, nil on failure.
function registry.load(source)
    local okReq, mod = pcall(require, source)
    if not okReq then
        loadFailures[#loadFailures + 1] = { source = source, error = tostring(mod) }
        adapter.log("feature load FAILED [" .. source .. "]: " .. tostring(mod))
        return nil
    end
    local okReg, err = pcall(registry.register, mod)
    if not okReg then
        loadFailures[#loadFailures + 1] = {
            source = source,
            id = type(mod) == "table" and mod.id or nil,
            error = tostring(err),
        }
        adapter.log("feature register FAILED [" .. source .. "]: " .. tostring(err))
        return nil
    end
    return mod
end

-- Load a catalog (list of module names) under quarantine, and remember it so
-- registry.reload() can re-run the same list. The bootstrap calls this once.
function registry.loadCatalog(list)
    catalog = list
    for _, modname in ipairs(list) do registry.load(modname) end
end

-- Scan a directory for feature modules: a "<name>/init.lua" subdir or a flat
-- "<name>.lua" file each yields the module name "features.<name>". Returns a
-- sorted module-name list (the OS scan lives behind the adapter seam).
function registry.discover(dir)
    local mods = {}
    for _, name in ipairs(adapter.discoverFeatures(dir) or {}) do
        mods[#mods + 1] = "features." .. name
    end
    table.sort(mods)
    return mods
end

-- Remember a directory to (re)discover features from. reload() re-scans it, so
-- dropping in a new feature folder + Reload makes it appear (hot-plug).
function registry.setFeatureDir(dir) discoverDir = dir end

-- Discover + load every feature in `dir` (and remember it for reload). The
-- bootstrap calls this instead of a hand-maintained catalog list.
function registry.loadFromDir(dir)
    registry.setFeatureDir(dir)
    registry.loadCatalog(registry.discover(dir))
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

local function triggerKey(id) return "hammerdeck.trigger." .. id end

-- The feature's chosen trigger: the user's override (stored encoded), else the
-- manifest default. Writers are registry.setTrigger / clearTrigger below.
local function triggerFor(m)
    local stored = adapter.getSetting(triggerKey(m.id), nil)
    return (stored and triggers.decode(stored)) or m.defaultTrigger
end

local function bindFeature(m)
    if bound[m.id] then return end               -- already live
    startFailures[m.id] = nil                     -- a retry clears the prior failure
    local ctx, scope = ctxlib.make(m)
    bound[m.id] = { ctx = ctx, scope = scope }

    -- Quarantine the feature's own start/bind code: a throw here (bad trigger
    -- spec, exception in start(ctx)) must not abort startAll() and strand the
    -- rest of the catalog. Fire-time errors in an action handler are contained
    -- separately at the bridge's callRef boundary.
    local ok, err = pcall(function()
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
    end)

    if not ok then
        -- A partial start may have created handles before throwing; tear the
        -- scope down so a broken feature leaks nothing, and drop the binding so
        -- it reads as not-live. The enabled flag stays set, so describe() can
        -- surface it as "enabled but failed".
        scope.teardown()
        bound[m.id] = nil
        startFailures[m.id] = tostring(err)
        adapter.log(m.id .. ": start/bind FAILED: " .. tostring(err))
    end
end

local function unbindFeature(m)
    startFailures[m.id] = nil
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

-- Remove a feature entirely: stop it if live, then drop its registration so it
-- can be re-registered fresh. Settings (enabled-state, options, trigger
-- override) are keyed by id and left untouched, so they survive a reload.
function registry.unregister(id)
    local m = features[id]
    if not m then return false end
    if bound[id] then unbindFeature(m) end
    features[id] = nil
    startFailures[id] = nil
    return true
end

-- Hot reload: tear every feature down, drop the cached feature modules so
-- `require` re-reads them from disk, then re-load the catalog and re-bind
-- whatever was enabled. Enabled-state/options persist (they live in settings),
-- so the user's selections survive. Returns { count, failures }.
function registry.reload()
    for _, m in ipairs(registry.all()) do registry.unregister(m.id) end
    loadFailures = {}
    for name in pairs(package.loaded) do
        if tostring(name):match("^features%.") then package.loaded[name] = nil end
    end
    -- In discovery mode, re-scan disk so added/removed feature folders take
    -- effect on reload (true hot-plug); otherwise replay the explicit catalog.
    if discoverDir then catalog = registry.discover(discoverDir) end
    for _, modname in ipairs(catalog) do registry.load(modname) end
    registry.startAll()
    adapter.log("reloaded catalog: " .. #registry.all() .. " features, "
        .. #loadFailures .. " failed")
    return { count = #registry.all(), failures = #loadFailures }
end

function registry.setEnabled(id, on)
    local m = features[id]
    assert(m, "no such feature: " .. id)
    adapter.setSetting(enabledKey(id), on == true)
    if on then bindFeature(m) else unbindFeature(m) end
end

-- Does `spec` collide with another ENABLED feature's trigger? Only hotkeys can
-- conflict (many features may legitimately share a schedule or system event).
-- Comparison is on the canonical encoding, so alt+cmd matches cmd+alt. Returns
-- a human-readable reason string, or nil if there is no conflict.
function registry.triggerConflict(id, spec)
    if type(spec) ~= "table" or spec.type ~= "hotkey" then return nil end
    local target = triggers.encode(spec)
    for _, m in ipairs(registry.all()) do
        if m.id ~= id and m.action and registry.isEnabled(m.id) then
            local other = triggerFor(m)
            if other and other.type == "hotkey" and triggers.encode(other) == target then
                return "hotkey already bound to '" .. m.name .. "'"
            end
        end
    end
    return nil
end

-- Rebind an action feature to a new trigger spec -- the core "any trigger can
-- fire any action" promise. Validates the spec, refuses a hotkey already taken
-- by another enabled feature, persists the override (encoded), and live-rebinds
-- if the feature is currently enabled. Returns true on success, or
-- (false, reason) on a conflict.
function registry.setTrigger(id, spec)
    local m = features[id]
    assert(m, "no such feature: " .. id)
    assert(m.action, "only action features have a rebindable trigger: " .. id)
    triggers.validate(spec)

    local conflict = registry.triggerConflict(id, spec)
    if conflict then return false, conflict end

    if bound[id] then unbindFeature(m) end
    adapter.setSetting(triggerKey(id), triggers.encode(spec))
    if registry.isEnabled(id) then bindFeature(m) end
    return true
end

-- Drop a user override, reverting the feature to its manifest default trigger.
function registry.clearTrigger(id)
    local m = features[id]
    assert(m, "no such feature: " .. id)
    if bound[id] then unbindFeature(m) end
    adapter.setSetting(triggerKey(id), nil)
    if registry.isEnabled(id) then bindFeature(m) end
    return true
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
        local row = {
            id = m.id, name = m.name, description = m.description or "",
            category = m.category, version = m.version or "",
            kind = m.start and "service" or "action",
            enabled = registry.isEnabled(m.id),
            triggerDesc = describeTrigger(m),
            options = opts,
            failed = startFailures[m.id] ~= nil,
            error = startFailures[m.id],
        }
        -- Action features carry the editable trigger spec (current + default)
        -- and whether it's a user override, so the config UI can drive a picker.
        if m.action then
            row.trigger = triggerFor(m)
            row.defaultTrigger = m.defaultTrigger
            row.triggerOverridden = adapter.getSetting(triggerKey(m.id), nil) ~= nil
        end
        out[#out + 1] = row
    end
    -- Modules that failed to even load/register: surface as inert "failed" rows
    -- so a broken plugin is visible in the UI rather than silently missing.
    for _, f in ipairs(loadFailures) do
        out[#out + 1] = {
            id = f.id or f.source, name = f.id or f.source,
            description = "Failed to load: " .. tostring(f.error),
            category = "failed", version = "",
            kind = "failed", enabled = false,
            triggerDesc = "load error", options = {},
            failed = true, error = tostring(f.error),
        }
    end
    return out
end

-- For tests / diagnostics: { load = { {source,id?,error}... }, start = { id->err } }.
function registry.failures()
    return { load = loadFailures, start = startFailures }
end

-- For tests: total live handles across all enabled features.
function registry.liveHandleCount()
    local n = 0
    for _, b in pairs(bound) do n = n + b.scope.liveCount() end
    return n
end

return registry
