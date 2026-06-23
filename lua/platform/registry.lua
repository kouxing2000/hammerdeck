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

local adapter  = require("platform.adapter")
local manifest = require("platform.manifest")
local triggers = require("platform.triggers")
local ctxlib   = require("platform.ctx")

local registry = {}

local features = {}   -- id -> manifest
local bound    = {}   -- id -> { ctx, scope } (when enabled)
local catalog  = {}   -- the module-name list, remembered so reload() can re-run it
local discoverDir = nil   -- when set, the catalog is re-scanned from disk on reload

-- Defined below (after specDesc, whose trigger-formatting it reuses). Injected
-- into the ctx of features holding the "commands" capability as ctx.commands().
local buildCommandList

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
local function runActionGuarded(m, a, ctx)
    local key = fireKey(m, a)
    local ok, err = pcall(a.run, ctx)
    if ok then
        fireFailures[key] = nil
        return
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
    end, extra)
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
                b.actionHandles[a.id] =
                    scope.adopt(triggers.bind(spec, function() runActionGuarded(m, a, ctx) end,
                        a.label or a.id))
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
        local okBind, err = pcall(function()
            b.actionHandles[a.id] =
                b.scope.adopt(triggers.bind(spec, function() runActionGuarded(m, a, b.ctx) end,
                    a.label or a.id))
        end)
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
        b.actionHandles[a.id] =
            b.scope.adopt(triggers.bind(a.defaultTrigger, function() runActionGuarded(m, a, b.ctx) end,
                a.label or a.id))
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
        local ok, err = pcall(function()
            b.actionHandles[a.id] =
                b.scope.adopt(triggers.bind(spec, function() runActionGuarded(m, a, b.ctx) end,
                    a.label or a.id))
        end)
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
-- (no functions) -- the Swift settings window renders forms from this.
-- ---------------------------------------------------------------------------

local function specDesc(spec)
    if not spec then return "no trigger" end
    if spec.type == "hotkey" then
        return "hotkey: " .. table.concat(spec.mods or {}, "+") .. "+" .. tostring(spec.key)
    elseif spec.type == "chord" then
        local prefix = table.concat(spec.mods or {}, "+") .. "+" .. tostring(spec.key)
        return "chord: " .. prefix .. " then " .. table.concat(spec.follows or {}, " ")
    elseif spec.type == "schedule" then
        if spec.everyMin then return "schedule: every " .. spec.everyMin .. " min" end
        return "schedule: daily at " .. tostring(spec.at)
    elseif spec.type == "event" then
        return "event: " .. tostring(spec.event)
    end
    return tostring(spec.type)
end

-- Compact, menubar-style glyphs for a trigger (e.g. "⇧⌘V", "every 180m") --
-- the form the command palette shows in its right-flush shortcut column, where
-- the verbose specDesc would just truncate. Mirrors StatusBar's shortcutText.
local function modGlyphs(mods)
    local has = {}
    for _, m in ipairs(mods or {}) do has[m:lower()] = true end
    local s = ""
    if has.ctrl or has.control then s = s .. "⌃" end
    if has.alt or has.option then s = s .. "⌥" end
    if has.shift then s = s .. "⇧" end
    if has.cmd or has.command then s = s .. "⌘" end
    return s
end

local KEY_GLYPHS = {
    tab = "⇥", ["return"] = "↩", enter = "↩", space = "␣",
    delete = "⌫", backspace = "⌫", escape = "⎋", esc = "⎋",
    left = "←", right = "→", up = "↑", down = "↓",
}
local function keyGlyph(key)
    key = tostring(key)
    local g = KEY_GLYPHS[key:lower()]
    if g then return g end
    return #key == 1 and key:upper() or key
end

local function specGlyph(spec)
    if not spec then return nil end
    if spec.type == "hotkey" then
        return modGlyphs(spec.mods) .. keyGlyph(spec.key)
    elseif spec.type == "chord" then
        local follows = {}
        for _, f in ipairs(spec.follows or {}) do follows[#follows + 1] = keyGlyph(f) end
        return modGlyphs(spec.mods) .. keyGlyph(spec.key) .. " " .. table.concat(follows, " ")
    elseif spec.type == "schedule" then
        if spec.everyMin then return "every " .. spec.everyMin .. "m" end
        return "at " .. tostring(spec.at)
    elseif spec.type == "event" then
        return "on " .. tostring(spec.event)
    end
    return nil
end

-- Exposed for the Swift<->Lua glyph parity test: this is the one Lua glyph
-- copy, KeyGlyphs.swift is the one Swift copy, and IntegrationTests asserts the
-- two agree so they can't drift (see REFACTOR_TODO #1).
registry.specGlyph = specGlyph

-- Flatten the catalog into a command list for a "commands"-capability holder:
-- one entry per action of every OTHER ENABLED feature (self excluded -- the
-- palette never lists its own opener). Backs ctx.commands(); rebuilt on each
-- call, so it always reflects the live enabled/rebound state. Stable order
-- (registry.all() is id-sorted; actions stay in declared order).
function buildCommandList(selfId)
    local out = {}
    for _, m in ipairs(registry.all()) do
        if m.id ~= selfId and registry.isEnabled(m.id) then
            for _, a in ipairs(m.actions) do
                out[#out + 1] = {
                    featureId   = m.id,
                    featureName = m.name,
                    actionId    = a.id,
                    -- single-action features read better as the feature name;
                    -- multi-action ones need the per-action label to disambiguate.
                    label       = (#m.actions > 1) and a.label or m.name,
                    triggerDesc = specDesc(triggerFor(m, a)),
                    triggerGlyph = specGlyph(triggerFor(m, a)),
                    -- "why this key" hint, only while the default still holds
                    -- (an override would make the mnemonic lie).
                    mnemonic    = (storedTrigger(m, a) == nil) and a.mnemonic or nil,
                }
            end
        end
    end
    return out
end

-- A "which-key" legend of every ENABLED binding on the Hyper prefix
-- (cmd+alt+ctrl), for the held-Caps HUD. Returns a key-sorted list of rows
-- { key = <raw key>, label = <feature/action name>, chord = <bool> }; the
-- renderer turns `key` into a key-cap glyph (chords get a trailing "…").
function registry.hyperLegend()
    local function isHyper(t)
        if not t or (t.type ~= "hotkey" and t.type ~= "chord") then return false end
        local m = t.mods or {}
        if #m ~= 3 then return false end
        local s = {}
        for _, x in ipairs(m) do s[x:lower()] = true end
        return (s.cmd or s.command) and (s.alt or s.option) and (s.ctrl or s.control)
    end
    local items = {}
    for _, m in ipairs(registry.all()) do
        if registry.isEnabled(m.id) then
            for _, a in ipairs(m.actions) do
                local t = triggerFor(m, a)
                if isHyper(t) then
                    items[#items + 1] = {
                        key = t.key,
                        label = (#m.actions > 1) and a.label or m.name,
                        chord = (t.type == "chord"),
                    }
                end
            end
        end
    end
    table.sort(items, function(a, b) return a.key < b.key end)
    return items
end

local function describeTrigger(m)
    if m.start then return "always-on service" end
    if #m.actions == 1 then return specDesc(triggerFor(m, m.actions[1])) end
    return #m.actions .. " actions"
end

-- Normalize one entry returned by a feature's schedule(ctx) descriptor into a
-- serializable shape the Timeline can plot. Returns the normalized row, or nil
-- to skip a malformed entry (logged by the caller). `kind` is exactly one of
-- everyMin / at / event / note (a non-time-anchored condition, e.g. "after 5m
-- idle"), so the UI can route it to the ruler, a lane, or the events column.
local function normalizeScheduleEntry(e)
    if type(e) ~= "table" or type(e.label) ~= "string" or e.label == "" then return nil end
    local row = { label = e.label, optionKey = e.optionKey, category = e.category }
    if e.everyMin ~= nil then
        local n = tonumber(e.everyMin)
        if not n or n <= 0 then return nil end
        row.kind = "everyMin"; row.everyMin = n
    elseif e.at ~= nil then
        local h, mm = tostring(e.at):match("^(%d%d?):(%d%d)$")
        h, mm = tonumber(h), tonumber(mm)
        if not h or h > 23 or mm > 59 then return nil end   -- shape AND range
        row.kind = "at"; row.at = string.format("%02d:%02d", h, mm)
    elseif e.event ~= nil then
        row.kind = "event"; row.event = tostring(e.event)
    elseif e.note ~= nil then
        row.kind = "note"; row.note = tostring(e.note)
    else
        return nil
    end
    return row
end

-- A feature's self-reported schedule (its internal timers/events made visible),
-- or nil when it declares none. Runs schedule(ctx) under a read-only ctx (no
-- handle is bound -- ctxlib.make only defines closures) and quarantines a throw,
-- so a buggy descriptor never breaks describe(). Reads live option values via
-- ctx.opt, so derived times track the user's settings even while disabled.
local function scheduleFor(m)
    if type(m.schedule) ~= "function" then return nil end
    -- A descriptor is meant to be pure metadata (read ctx.opt / ctx.now, return
    -- a list). It still receives the full ctx, so a buggy one COULD bind a
    -- handle -- and describe() runs on every Timeline/Settings open. Tear the
    -- scope down afterward so any stray handle is stopped instead of leaking.
    local ctx, scope = ctxlib.make(m, nil, nil)
    local ok, entries = pcall(m.schedule, ctx)
    scope.teardown()
    if not ok then
        adapter.log(m.id .. ": schedule() failed: " .. tostring(entries))
        return nil
    end
    if type(entries) ~= "table" then return nil end
    local out = {}
    for _, e in ipairs(entries) do
        local row = normalizeScheduleEntry(e)
        if row then
            row.category = row.category or m.category
            out[#out + 1] = row
        else
            adapter.log(m.id .. ": skipped a malformed schedule entry")
        end
    end
    return out
end

function registry.describe()
    local out = {}
    for _, m in ipairs(registry.all()) do
        local opts = {}
        for _, o in ipairs(m.options or {}) do
            opts[#opts + 1] = {
                key = o.key, type = o.type, label = o.label or o.key,
                default = o.default, min = o.min, max = o.max,
                values = o.values, labels = o.labels, multiline = o.multiline,
                defaultLabel = o.defaultLabel, hint = o.hint,
                section = o.section, actionLabel = o.actionLabel, preview = o.preview,
                validate = o.validate, gatedBy = o.gatedBy, valuesFrom = o.valuesFrom,
                collapsible = o.collapsible,
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
        -- Each action carries its editable trigger (current + default) and
        -- whether a user override is in effect, so the config UI renders one
        -- trigger picker per action. Empty list for pure services.
        local actions = {}
        for _, a in ipairs(m.actions) do
            local current = triggerFor(m, a)
            actions[#actions + 1] = {
                id = a.id, label = a.label, description = a.description,
                mnemonic = a.mnemonic,
                automatable = a.automatable == true,
                trigger = current,
                defaultTrigger = a.defaultTrigger,
                triggerOverridden = storedTrigger(m, a) ~= nil,
                triggerDesc = specDesc(current),
            }
        end
        row.actions = actions
        -- A service's self-reported internal schedule (times/intervals/events it
        -- runs on its own, not via the trigger model). Absent for features that
        -- declare no schedule() descriptor. Powers the Automation Timeline.
        row.schedule = scheduleFor(m)
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
