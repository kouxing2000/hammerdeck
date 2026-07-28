-- platform/registry.lua
--
-- The registry knows every available feature, which ones are enabled, and is
-- responsible for a feature's lifecycle:
--
--   enable  -> start(ctx) if the feature is a service, then bind a trigger for
--              each of its declared actions (a plugin may have several -- each
--              independently rebindable)
--   disable -> optional stop(ctx), then scope teardown -- every handle the
--              feature created through ctx is stopped by the platform
--
-- Enabled-state, option values, and per-action trigger overrides persist via
-- the adapter, keyed by feature id (+ action id), so a restart restores exactly
-- what the user selected.

local adapter   = require("platform.adapter")
local manifest  = require("platform.manifest")
local triggers  = require("platform.triggers")
local ctxlib    = require("platform.ctx")
local json      = require("platform.json")
local i18n      = require("platform.i18n")
local window_ops = require("platform.window_ops")
-- The READ MODEL (localized metadata, describe(), the command list, the Hyper
-- legend). Split out so this file is lifecycle only; wired to live state via
-- view.configure at the bottom. See registry_view.lua for the direction rule.
local view      = require("platform.registry_view")

-- Defined below (a thin delegation to view.commandList). Injected into the ctx
-- of features holding the "commands" capability as ctx.commands().
local buildCommandList

local registry = {}

local features = {}   -- id -> manifest
local bound    = {}   -- id -> { ctx, scope } (when enabled)
local catalog  = {}   -- the module-name list, remembered so reload() can re-run it
local discoverDir = nil   -- when set, the catalog is re-scanned from disk on reload

-- Quarantine bookkeeping: a broken plugin must never take the whole app down.
local loadFailures  = {}   -- list of { source, id?, error } -- never registered
local startFailures = {}   -- id -> error string -- registered but failed to start

local function enabledKey(id) return "hammerdeck.enabled." .. id end

-- Localized metadata + every read-model projection live in registry_view.lua
-- (CODE-9). Aliased locally because the lifecycle code below also names actions
-- for its notify/flash/menu surfaces -- the view owns the wording, this file
-- just uses it.
local locName        = view.locName
local locDesc        = view.locDesc
local locActionLabel = view.locActionLabel
local locActionField = view.locActionField
local commandLabel   = view.commandLabel

-- feature.json fields overlaid onto the manifest at register time. Only these:
-- an unknown key in feature.json is IGNORED rather than merged, so a typo can't
-- silently redefine part of the manifest.
local META_FIELDS = {
    "name", "version", "description", "category", "context", "order",
    "requires", "recommended", "page", "preference", "icon", "defaultEnabled",
    "selfEvident",
    -- What the feature is allowed to reach (see manifest.CAPABILITY_METHODS).
    -- feature.json is its HOME: the declarative file a reader opens to see what a
    -- feature can do, without reading its Lua. A synthetic test feature with no
    -- feature.json on disk may still declare it in the manifest table (this
    -- overlay only replaces the key when the JSON actually carries one).
    "capabilities",
}

--- Read <appdir>/features/<id>/feature.json, or nil if absent. Read with plain
--- io (like the module loader / require), NOT via the adapter seam: feature.json
--- is a co-located build-time asset, read once at feature-load time.
local function readFeatureMeta(id)
    local path = require("loader").appdir .. "/features/" .. id .. "/feature.json"
    local f = io.open(path, "r")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()
    local data, err = json.decode(raw)
    assert(data ~= nil, "feature.json at " .. path .. " is not valid JSON: " .. tostring(err))
    assert(type(data) == "table" and #data == 0,
        "feature.json at " .. path .. " must be a JSON object (not an array or scalar)")
    return data
end

-- Overlay a feature's feature.json metadata onto its manifest table, if present.
local function applyFeatureMeta(m)
    if type(m) ~= "table" or type(m.id) ~= "string" then return end
    local meta = readFeatureMeta(m.id)
    if not meta then return end
    for _, k in ipairs(META_FIELDS) do
        if meta[k] ~= nil then m[k] = meta[k] end
    end
end

-- The option-setting key for a feature's option value (mirrors ctx.opt's read
-- path, hammerdeck.opt.<id>.<key>), used to feed a feature's dynamicActions hook.
local function optSettingKey(id, key) return "hammerdeck.opt." .. id .. "." .. key end

-- Expand a feature's dynamicActions(read) hook into extra actions appended to
-- m.actions, BEFORE manifest.validate runs (so the generated actions get the same
-- id-uniqueness / run checks as static ones). The REGISTRY -- not the feature --
-- reads the stored option value (a feature must never touch the adapter seam),
-- passing a reader scoped to this feature's option namespace. This is the
-- sanctioned way a feature derives actions from its own persisted data (e.g.
-- window_snap turning each placement preset into a bindable action). Re-runs on
-- every register (incl. reload()), so a fresh module's static list is expanded
-- anew from the CURRENT setting -- no stale or double-appended actions. A hook
-- throw propagates to registry.load's pcall (which quarantines the feature); the
-- hook itself should be tolerant so a corrupt setting yields no actions rather
-- than disabling the feature.
local function expandDynamicActions(m)
    if type(m) ~= "table" or type(m.dynamicActions) ~= "function" then return end
    local read = function(key)
        return adapter.getSetting(optSettingKey(m.id, key), manifest.defaultFor(m, key))
    end
    local extra = m.dynamicActions(read)
    if type(extra) ~= "table" then return end
    m.actions = m.actions or {}
    for _, a in ipairs(extra) do
        -- Tag as dynamic so the config UI can hide it from the generic per-action
        -- trigger sections: a dynamic action (e.g. a window_snap placement preset)
        -- is created + bound by the OPTION editor that owns it (the Saved
        -- placements list, with its inline shortcut), so a second system-style
        -- "Trigger -- X" section would just duplicate it.
        a.dynamic = true
        m.actions[#m.actions + 1] = a
    end
end

-- Register a feature module (its validated manifest). First overlays the
-- feature's co-located feature.json (applyFeatureMeta), then expands any
-- dynamicActions hook, so it now also reads a file and a setting and THROWS on
-- malformed JSON / a non-object root -- on top of throwing on a bad manifest or
-- duplicate id. Callers that must survive a broken plugin use registry.load()
-- (below), which quarantines all of those throws.
function registry.register(m)
    applyFeatureMeta(m)
    expandDynamicActions(m)
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

-- Scan a directory for feature modules: a subdir holding "<name>/lua/init.lua"
-- yields the module name "features.<name>" (the co-located layout -- there is
-- no flat "<name>.lua" form). Returns a sorted module-name list (the OS scan
-- lives behind the adapter seam).
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
    -- A feature may ship enabled (m.defaultEnabled) -- but that is only the
    -- FALLBACK when the user has never toggled it; an explicit stored choice
    -- (getSetting returns it) always wins, so a user opt-out is never overridden.
    local m = features[id]
    return adapter.getSetting(enabledKey(id), m and m.defaultEnabled or false) == true
end

local function triggerKey(id, actionId)
    return "hammerdeck.trigger." .. id .. "." .. actionId
end

-- The stored (encoded) trigger override for one action, honoring the legacy
-- pre-multi-action key "hammerdeck.trigger.<id>" for single-action features.
local function storedTrigger(m, a)
    local s = adapter.getSetting(triggerKey(m.id, a.id), nil)
    if s == nil and a.id == "main" then
        s = adapter.getSetting("hammerdeck.trigger." .. m.id, nil)
    end
    return s
end

-- One action's chosen trigger: the user's override, else its declared default.
-- Writers are registry.setTrigger / clearTrigger below.
--
-- This is the single read point feeding bind-on-load, describe(), and conflict
-- detection, so the automatable policy is enforced HERE rather than only at the
-- setTrigger write path: a stored override that is an AUTOMATED trigger on an
-- action that is not automatable is ignored (falls back to the declared
-- default, which manifest.validate guarantees is manual-or-nil for such an
-- action). This closes the gap where a stale/hand-edited override -- or one
-- left behind after an author drops automatable -- would otherwise bind a
-- schedule/event to a context-dependent action and fire it unattended.
local function triggerFor(m, a)
    local stored = storedTrigger(m, a)
    local spec = (stored and triggers.decode(stored)) or nil
    if spec and triggers.isAutomated(spec) and not a.automatable then
        spec = nil
    end
    return spec or a.defaultTrigger
end

-- Fire-time error surfacing. A trigger fires an action's run(ctx) on its own
-- (schedule/event/hotkey) -- the user isn't watching, so a throw only reaching
-- the log is easy to miss. Count consecutive failures per action; on the Nth in
-- a row, surface one visible alert (then stay quiet until a success resets it,
-- so a persistently broken feature doesn't spam). Success clears the streak.
local fireFailures = {}   -- "id.actionId" -> consecutive failure count
local FAIL_ALERT_AFTER = 3

local function fireKey(m, a) return m.id .. "." .. a.id end

-- Run an action's handler from a trigger, contained: a throw is caught, logged,
-- counted, and (on a sustained streak) alerted -- never propagated to the bridge.
-- The trigger-fired streak is a separate channel from the manual menubar path
-- (registry.runAction) on purpose: a manual run neither increments nor resets
-- it, so its failures surface via runAction's return value, not this alert.
-- Returns true iff the action ran cleanly -- callers (the fire-feedback path)
-- use it to avoid reporting a crashed run as a successful one.
local function runActionGuarded(m, a, ctx)
    local key = fireKey(m, a)
    local ok, err = pcall(a.run, ctx)
    if ok then
        fireFailures[key] = nil
        return true
    end
    local n = (fireFailures[key] or 0) + 1
    fireFailures[key] = n
    adapter.log(m.id .. "." .. a.id .. ": fire failed (" .. n .. "): " .. tostring(err))
    if n == FAIL_ALERT_AFTER then
        local who = m.name or m.id
        if #m.actions > 1 then who = who .. " -- " .. (a.label or a.id) end
        adapter.alert(who .. " keeps failing:\n" .. tostring(err)
            .. "\n\nSee \"Open Logs\" in the menubar for details.")
    end
    return false
end

-- When the global "Notify on Automated Run" preference (the notify_on_trigger
-- feature) is on, show a brief toast naming the feature whose action just fired
-- from an automated trigger -- the unattended case a user can't see. ONLY the
-- automated bind path calls this (see bindAction); manual hotkey/chord fires and
-- menubar/palette runs never do, so a shortcut you pressed yourself is never
-- echoed back as noise. Best-effort: a notify failure must not disturb the fire.
local function notifyAutomatedFire(m, a)
    if not registry.isEnabled("notify_on_trigger") then return end
    pcall(adapter.notify, commandLabel(m, a), i18n.t("notify.autoFired", "Ran automatically"))
    adapter.log(m.id .. "." .. a.id .. ": notified automated run")
end

-- The quiet twin of notifyAutomatedFire: when "Confirm Shortcut Presses"
-- (the confirm_shortcut feature) is on, a MANUAL trigger (hotkey / chord) briefly
-- flashes which action just ran -- a single-slot chip that confirms the press
-- and, on a mis-remembered shortcut, reveals what actually fired. Automated
-- triggers take notifyAutomatedFire instead; menubar/palette runs never get here.
-- Best-effort: a flash failure must not disturb the fire.
local function flashManualFire(m, a)
    -- A self-evident feature (a chooser/palette opens, a window/tab fronts, or a
    -- keyboard mode with its own banner is entered) shows its own result -- the
    -- flash would just echo what you can already see. Such a feature that has a
    -- discrete later "landing" moment (window_grid) instead confirms it itself via
    -- ctx.confirmAction (below), so the flash reports the RESULT, not mode-entry.
    if m.selfEvident then return end
    if not registry.isEnabled("confirm_shortcut") then return end
    -- Per-action glyph when the action declares one (so a multi-action feature's
    -- flash matches the palette/menubar/hint), else the feature icon.
    pcall(adapter.flash, a.icon or m.icon, commandLabel(m, a))
end

-- The confirm-flash a MODAL feature fires ITSELF at its real-action moment (the
-- key inside the mode that finally acts) -- injected into its ctx as
-- ctx.confirmAction. Gated on the confirm_shortcut preference and stamped with the
-- feature icon, exactly like the automatic manual-fire flash; label defaults to
-- the feature name. This is how a self-evident, two-step feature reports the
-- RESULT rather than mode-entry (window_grid: Hyper+4 arms, then "3" lands + flashes).
local function makeConfirmFlash(m)
    return function(label)
        if not registry.isEnabled("confirm_shortcut") then return end
        pcall(adapter.flash, m.icon, label or locName(m))
    end
end

-- Bind one action's trigger inside the feature's scope and record the live
-- handle. The lifecycle's subtlest line -- kept in one place so the four call
-- sites can't drift. ASSIGNMENT-ONLY by contract: it must NOT pcall internally,
-- because each caller owns failure isolation at its own granularity (bindFeature
-- wraps the whole action loop in one pcall; setTrigger/swapTriggers wrap per
-- action; clearTrigger trusts its own default trigger and wraps nothing).
local function bindAction(b, m, a, spec)
    -- The hotkey combo that fires this action, so a modal the action enters can
    -- accept its bare keys with those modifiers STILL held (the Hyper-leader
    -- "sticky key" motion -- ctx.modal reads these). ONLY a plain hotkey qualifies:
    -- a chord RELEASES its prefix before the follow keys (nothing is held), and an
    -- automated trigger (schedule/event) has nobody at the keys; a menubar/palette
    -- run goes through registry.runAction (not this path) and leaves them nil.
    -- `leaderKey` lets the modal skip a sticky twin on the entry combo itself --
    -- which would otherwise shadow this very hotkey (e.g. break Window Mode's
    -- Hyper+w toggle-off).
    local leaderMods = spec.type == "hotkey" and spec.mods or nil
    local leaderKey  = spec.type == "hotkey" and spec.key or nil
    -- Automated = fired with nobody present (schedule / system event). Only these
    -- get the optional "which feature ran" toast; manual hotkey/chord fires don't.
    local isAutomated = spec.type == "schedule" or spec.type == "event"
    b.actionHandles[a.id] =
        b.scope.adopt(triggers.bind(spec, function()
            b.ctx._leaderMods, b.ctx._leaderKey = leaderMods, leaderKey
            local fired = runActionGuarded(m, a, b.ctx)
            b.ctx._leaderMods, b.ctx._leaderKey = nil, nil
            -- Trigger-fire feedback (two independent prefs). Automated triggers
            -- (schedule/event) NOTIFY -- but ONLY on success: that path exists to
            -- surface unattended runs faithfully, so a crashed run must not read as
            -- a clean one. Manual triggers (hotkey/chord) FLASH regardless -- the
            -- value is "the press registered + which action", true even if the
            -- action then threw (and a sustained failure still alerts separately).
            if isAutomated then
                if fired then notifyAutomatedFire(m, a) end
            else
                flashManualFire(m, a)
            end
        -- 4th arg: the which-key hint glyph. Resolve action icon -> feature icon
        -- (same as the palette's buildCommandList), so an action bound to a chord
        -- shows the SAME glyph in the hint that it shows in the palette/menubar.
        end, a.label or a.id, a.icon or m.icon))
end

-- Find an action by id; with actionId == nil, resolve the feature's sole
-- action (the legacy single-action call shape). Raises on a miss.
local function resolveAction(m, actionId)
    assert(#m.actions > 0, "feature '" .. m.id .. "' has no rebindable actions")
    if actionId == nil then
        assert(#m.actions == 1,
            "feature '" .. m.id .. "' has several actions; specify an actionId")
        return m.actions[1]
    end
    for _, a in ipairs(m.actions) do
        if a.id == actionId then return a end
    end
    error("feature '" .. m.id .. "' has no action '" .. tostring(actionId) .. "'")
end

local function bindFeature(m)
    if bound[m.id] then return end               -- already live
    startFailures[m.id] = nil                     -- a retry clears the prior failure
    -- Capability gate: only a feature that declared `commands` gets the
    -- cross-feature reach (the palette). runCommand IS runAction -- the palette
    -- inherits its "enabled? exists? pcall-wrapped" guards for free.
    local extra = nil
    if manifest.hasCapability(m, "commands") then
        extra = {
            commands   = function() return buildCommandList(m.id) end,
            runCommand = function(id, actionId) return registry.runAction(id, actionId) end,
        }
    end
    local ctx, scope = ctxlib.make(m, function(actionId)
        local okR, a = pcall(resolveAction, m, actionId)
        if not okR then return nil end
        return triggerFor(m, a)
    end, extra, makeConfirmFlash(m))
    local b = { ctx = ctx, scope = scope, actionHandles = {} }
    bound[m.id] = b

    -- Quarantine the feature's own start/bind code: a throw here (bad trigger
    -- spec, exception in start(ctx)) must not abort startAll() and strand the
    -- rest of the catalog. Fire-time errors in an action handler are contained
    -- separately at the bridge's callRef boundary.
    local ok, err = pcall(function()
        if m.start then
            m.start(ctx)
            adapter.log(m.id .. ": started")
        end
        for _, a in ipairs(m.actions) do
            local spec = triggerFor(m, a)
            if spec then
                bindAction(b, m, a, spec)
                adapter.log(m.id .. "." .. a.id .. ": bound (" .. spec.type .. ")")
            else
                adapter.log(m.id .. "." .. a.id .. ": no trigger; manual only")
            end
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
    for _, a in ipairs(m.actions) do fireFailures[fireKey(m, a)] = nil end
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
    -- Re-read i18n catalogs too, so "Reload Features" also picks up edited
    -- translations (same locale; a language CHANGE still needs a relaunch).
    i18n.configure({ locale = i18n.locale() })
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

-- TEST-SUPPORT: return the platform to a pristine, EMPTY-catalog state -- the
-- teardown half of reload() without the re-populate. Used by the hermetic
-- case runner to start every case on an empty catalog. Three things must all
-- happen (a raw `features, bound = {}, {}` is WRONG and silently corrupts the
-- next case):
--   1. Tear every feature down through the real stop path (unregister ->
--      unbindFeature -> m.stop + scope.teardown), so a transitively-held
--      singleton is released -- e.g. window_rewind:stop() -> window_history
--      clear(); a dropped table would strand window_history's pending group.
--   2. Purge the cached feature modules, so a re-register re-reads a pristine
--      manifest. register() mutates the manifest in place (expandDynamicActions
--      appends to m.actions), and require() caches that mutated table -- without
--      this purge, re-registering a dynamicActions feature (window_snap) would
--      double-append its placement actions.
--   3. Clear every catalog upvalue.
-- Persisted per-feature settings (enabled/opt/trigger/state) live in the
-- adapter and are deliberately NOT touched here (unregister leaves them, so a
-- reload preserves the user's selections); a test that wants a blank slate
-- resets the adapter (fake.resetWorld) alongside this.
function registry.reset()
    for _, m in ipairs(registry.all()) do registry.unregister(m.id) end   -- (1) stop path
    for name in pairs(package.loaded) do                                  -- (2) the same purge reload() does
        if tostring(name):match("^features%.") then package.loaded[name] = nil end
    end
    loadFailures, startFailures, fireFailures = {}, {}, {}                 -- (3) catalog upvalues
    catalog, discoverDir = {}, nil
end

function registry.setEnabled(id, on)
    local m = features[id]
    assert(m, "no such feature: " .. id)
    adapter.setSetting(enabledKey(id), on == true)
    if on then bindFeature(m) else unbindFeature(m) end
end

-- Does `spec` collide with the trigger of any other ENABLED action (across all
-- features, and across sibling actions of the same feature)? Only hotkey/chord
-- triggers can conflict (many actions may legitimately share a schedule or
-- system event); chords sharing a prefix but with distinct follow keys do NOT
-- conflict -- that is the point of chords. See triggers.conflicts for the rules.
-- Returns a human-readable reason string, or nil if there is no conflict.
-- Call shapes: (id, actionId, spec) or legacy (id, spec) for sole-action features.
function registry.triggerConflict(id, actionId, spec)
    if type(actionId) == "table" and spec == nil then
        spec, actionId = actionId, nil
    end
    if type(spec) ~= "table" or not (spec.type == "hotkey" or spec.type == "chord") then
        return nil
    end
    if actionId == nil and features[id] then
        local okA, a = pcall(resolveAction, features[id], nil)
        if okA then actionId = a.id end
    end
    for _, m in ipairs(registry.all()) do
        if registry.isEnabled(m.id) then
            for _, a in ipairs(m.actions) do
                if not (m.id == id and a.id == actionId) then
                    local other = triggerFor(m, a)
                    if other and triggers.conflicts(spec, other) then
                        local who = m.name
                        if #m.actions > 1 then who = who .. ": " .. a.label end
                        -- Name WHY it clashes (and, for the common case, the fix)
                        -- rather than a flat "already bound": a plain hotkey on a
                        -- chord's prefix just needs a follow key to coexist.
                        if spec.type == "hotkey" and other.type == "chord" then
                            return "this combo is the chord prefix for '" .. who
                                .. "' -- add a follow key to make it a chord"
                        elseif spec.type == "chord" and other.type == "hotkey" then
                            return "the chord prefix is already the hotkey for '" .. who .. "'"
                        elseif spec.type == "chord" and other.type == "chord" then
                            return "chord clashes with '" .. who
                                .. "' (same prefix, overlapping follow keys)"
                        end
                        return "shortcut already bound to '" .. who .. "'"
                    end
                end
            end
        end
    end
    return nil
end

-- Stop one action's live binding (if any) and forget its handle.
local function dropActionBinding(b, actionId)
    if not b then return end
    local h = b.actionHandles[actionId]
    if h then h.stop() end
    b.actionHandles[actionId] = nil
end

-- Rebind one action to a new trigger spec -- the core "any trigger can fire any
-- action" promise. Validates the spec, refuses a hotkey already taken by
-- another enabled action, persists the override (encoded, per action), and
-- live-rebinds JUST that action (a running service and sibling actions are not
-- disturbed). Returns true on success, or (false, reason) on refusal.
-- Call shapes: setTrigger(id, actionId, spec) or legacy setTrigger(id, spec).
function registry.setTrigger(id, actionId, spec)
    if type(actionId) == "table" and spec == nil then
        spec, actionId = actionId, nil
    end
    local m = features[id]
    assert(m, "no such feature: " .. id)
    local a = resolveAction(m, actionId)
    triggers.validate(spec)

    -- Enforce the action's automatable policy: a context-dependent action
    -- (the default) accepts only manual triggers (hotkey/chord). The UI hides
    -- the automated types for such actions; this guards the seam in case a spec
    -- arrives any other way (a hand-edited setting, a test, a future caller).
    if triggers.isAutomated(spec) and not a.automatable then
        return false, "action '" .. a.id .. "' is not automatable; " ..
            "it accepts only hotkey/chord triggers"
    end

    local conflict = registry.triggerConflict(id, a.id, spec)
    if conflict then return false, conflict end

    local b = bound[id]
    dropActionBinding(b, a.id)
    adapter.setSetting(triggerKey(id, a.id), triggers.encode(spec))
    if a.id == "main" then
        adapter.setSetting("hammerdeck.trigger." .. id, nil)   -- retire the legacy key
    end
    if b then
        local okBind, err = pcall(bindAction, b, m, a, spec)
        if not okBind then return false, "bind failed: " .. tostring(err) end
    end
    return true
end

-- Drop one action's user override, reverting it to its declared default
-- trigger (which may be none -- the action then waits for a manual bind).
-- Call shapes: clearTrigger(id, actionId) or legacy clearTrigger(id).
function registry.clearTrigger(id, actionId)
    local m = features[id]
    assert(m, "no such feature: " .. id)
    local a = resolveAction(m, actionId)
    local b = bound[id]
    dropActionBinding(b, a.id)
    adapter.setSetting(triggerKey(id, a.id), nil)
    if a.id == "main" then
        adapter.setSetting("hammerdeck.trigger." .. id, nil)
    end
    if b and a.defaultTrigger then
        bindAction(b, m, a, a.defaultTrigger)
    end
    return true
end

-- Swap the triggers of two actions (the Shortcut Map's drag-one-row-onto-
-- another gesture): A takes B's current trigger and B takes A's. Safe by
-- construction -- swapping leaves the SET of bound combos unchanged, so no new
-- third-party conflict can arise, and the mutual A<->B "conflict" is the whole
-- point, so it bypasses triggerConflict. Both bindings are dropped before
-- either is re-registered, so the same combo is never live twice (which Carbon
-- would reject). Persists both as overrides and live-rebinds whichever feature
-- is enabled. Returns true (no-op when A and B are the same action).
function registry.swapTriggers(idA, actA, idB, actB)
    local mA = features[idA]; assert(mA, "no such feature: " .. tostring(idA))
    local mB = features[idB]; assert(mB, "no such feature: " .. tostring(idB))
    local aA = resolveAction(mA, actA)
    local aB = resolveAction(mB, actB)
    if idA == idB and aA.id == aB.id then return true end

    local specA = triggerFor(mA, aA)
    local specB = triggerFor(mB, aB)

    -- Drop both live bindings and write the swapped overrides (encode, or clear
    -- when the other side had no trigger at all).
    local function place(m, a, spec)
        dropActionBinding(bound[m.id], a.id)
        adapter.setSetting(triggerKey(m.id, a.id), spec and triggers.encode(spec) or nil)
        if a.id == "main" then adapter.setSetting("hammerdeck.trigger." .. m.id, nil) end
    end
    place(mA, aA, specB)
    place(mB, aB, specA)

    -- Re-register each (now both target combos are free). Quarantined: a failed
    -- rebind is logged, not fatal.
    local function rebind(m, a)
        local b = bound[m.id]
        if not b then return end
        local spec = triggerFor(m, a)
        if not spec then return end
        local ok, err = pcall(bindAction, b, m, a, spec)
        if not ok then adapter.log(m.id .. "." .. a.id .. ": swap rebind failed: " .. tostring(err)) end
    end
    rebind(mA, aA)
    rebind(mB, aB)
    return true
end

-- Run one action of an ENABLED feature on demand (the menubar's quick
-- triggers; also the only way to fire a dormant action that has no trigger
-- bound). Returns true, or false + reason. Quarantined like trigger firing.
function registry.runAction(id, actionId)
    local m = features[id]
    if not m then return false, "no such feature: " .. tostring(id) end
    local b = bound[id]
    if not b then return false, "feature not enabled: " .. id end
    local okResolve, a = pcall(resolveAction, m, actionId)
    if not okResolve then return false, tostring(a) end
    local okRun, err = pcall(a.run, b.ctx)
    if not okRun then
        adapter.log(id .. "." .. a.id .. ": manual run failed: " .. tostring(err))
        return false, tostring(err)
    end
    return true
end

-- Is one action automatable -- may it be fired by an AUTOMATED trigger
-- (schedule/event) with nobody present? Resolves from the REGISTERED manifest
-- (independent of enabled-state), so the rules engine can apply the same
-- context policy the registry enforces per action. Returns nil for an unknown
-- feature/action (caller treats the unknown as context-dependent -- the safe
-- default). This is the single public read of the `automatable` flag.
function registry.isActionAutomatable(id, actionId)
    local m = features[id]
    if not m then return nil end
    local okA, a = pcall(resolveAction, m, actionId)
    if not okA then return nil end
    return a.automatable == true
end

-- The user-facing label of one of a feature's actions (the sole action when
-- actionId is nil) -- the human name the command effect's read-back shows
-- ("M1 Auto" instead of the raw "m1_auto.go"), echoing the "Do" dropdown via the
-- shared commandLabel convention. Returns nil for an unknown/parked feature or a
-- bad action id so the caller falls back to the raw ids. Read-only,
-- enabled-state-independent (mirrors isActionAutomatable).
function registry.actionLabel(id, actionId)
    local m = features[id]
    if not m then return nil end
    local okA, a = pcall(resolveAction, m, actionId)
    if not okA then return nil end
    return commandLabel(m, a)
end

-- Every action of every ENABLED feature, flattened -- the data source for the
-- rules UI's "Do: Run ..." effect picker. Each row: { featureId, featureName,
-- actionId, label, automatable }. `label` disambiguates multi-action features
-- ("Feature -- Action") and collapses single-action ones to the feature name,
-- matching the command palette's convention.
function registry.enabledActions()
    local out = {}
    for _, m in ipairs(registry.all()) do
        if registry.isEnabled(m.id) then
            for _, a in ipairs(m.actions) do
                out[#out + 1] = {
                    featureId   = m.id,
                    featureName = locName(m),
                    actionId    = a.id,
                    label       = commandLabel(m, a),
                    automatable = a.automatable == true,
                }
            end
        end
    end
    return out
end

-- Run a feature's option-action (the handler behind a Settings "Test" button,
-- declared in m.optionActions[optKey]) with the feature's live ctx. Requires the
-- feature enabled (it needs a bound ctx). Errors are contained + logged.
function registry.runOptionAction(id, optKey)
    local m = features[id]
    if not m then return false, "no such feature: " .. tostring(id) end
    local fn = m.optionActions and m.optionActions[optKey]
    if type(fn) ~= "function" then return false, "no option action for " .. tostring(optKey) end
    local b = bound[id]
    if not b then return false, "feature not enabled: " .. id end
    local okRun, err = pcall(fn, b.ctx)
    if not okRun then
        adapter.log(id .. ".optionAction." .. optKey .. ": failed: " .. tostring(err))
        return false, tostring(err)
    end
    return true
end

-- The config UI calls this after writing hammerdeck.opt.<id>.<key>: an
-- ENABLED feature that declared onOptionChange(ctx, key) reacts immediately
-- (e.g. the usage widget hiding the moment its toggle flips) instead of on
-- its next timer tick. Quarantined -- a throwing handler is logged, not fatal.
function registry.optionChanged(id, key)
    local m = features[id]
    local b = bound[id]
    if not (m and b and m.onOptionChange) then return end
    local okCall, err = pcall(m.onOptionChange, b.ctx, key)
    if not okCall then
        adapter.log(id .. ": onOptionChange failed: " .. tostring(err))
    end
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
-- (no functions) -- the Swift settings window renders forms from this. The
-- spec -> string formatting lives in triggers.lua (triggers.describe / .glyph);
-- this layer just aggregates the live registry state.
-- ---------------------------------------------------------------------------

-- The read model lives in registry_view.lua; these are the registry's public
-- face for it, kept here so callers (ctx, the Swift bridge, the HUD) keep one
-- entry point and do not need to know about the split.

-- Command list for a "commands"-capability holder -- backs ctx.commands().
function buildCommandList(selfId) return view.commandList(selfId) end

-- A "which-key" legend of every ENABLED binding on the Hyper prefix, for the
-- held-Caps HUD.
function registry.hyperLegend() return view.hyperLegend() end

-- The whole catalog as the config UI renders it.
function registry.describe() return view.describe() end

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

-- Composition-root wiring: window_ops owns the focused-window move + pointer-
-- follow policy (ctx.window.setFrame delegates to it), but the "is pointer-follow
-- on?" answer is the pointer_follows_window feature's enabled-state, which lives
-- here. Inject it as a predicate so window_ops stays feature-agnostic and we avoid
-- the ctx -> registry require cycle. Done once at module load; the predicate reads
-- the live state on every move. This is the single place that names the feature id.
window_ops.configure({
    pointerFollowEnabled = function() return registry.isEnabled("pointer_follows_window") end,
})

-- Same composition-root wiring for the read model: registry_view projects live
-- registry state but must not require this module back (that would be a cycle),
-- so it receives the accessors it needs. Functions, not snapshots -- the view is
-- rebuilt on every describe()/commands() call and has to see current state.
view.configure({
    all           = function() return registry.all() end,
    isEnabled     = function(id) return registry.isEnabled(id) end,
    triggerFor    = function(m, a) return triggerFor(m, a) end,
    storedTrigger = function(m, a) return storedTrigger(m, a) end,
    startFailures = function() return startFailures end,
    loadFailures  = function() return loadFailures end,
})

return registry
