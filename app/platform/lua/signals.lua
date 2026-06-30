-- platform/signals.lua
--
-- STATE SIGNALS -- the "level" half of the world model (events are the "edge"
-- half; see AUTOMATION_FRAMEWORK.md). A state signal is a value you can both
-- READ now and SUBSCRIBE to changes of. Two backings hide behind one interface:
--   * push  -- an adapter observer pushes changes (e.g. onAppActivated)
--   * poll  -- a shared ticker re-reads on an interval (future signals)
-- The rules engine never cares which: it just read()s and subscribe()s.
--
-- M1 ships ONE signal -- frontmostApp -- push-backed by adapter.onAppActivated.
-- displaysPresent / onAC / battery follow the same shape (later milestones).
--
-- Leaf-ish module: requires only the adapter. No state machine of its own beyond
-- fan-out bookkeeping -- one underlying watcher per signal, shared across all
-- subscribers, released when the last unsubscribes.

local adapter = require("platform.adapter")

local signals = {}

-- Build a PUSH-backed signal: `def.read()` returns the current value; `def.observe(emit)`
-- installs the single underlying adapter watcher (returns a .stop() handle) and
-- calls emit(value) on each change. We fan that one watcher out to N subscribers
-- so 10 rules watching frontmostApp cost exactly one onAppActivated registration.
--
-- `def.match(value, target)` decides whether the signal's current value satisfies
-- a rule's target -- defaulting to scalar equality (frontmostApp == "Safari"). A
-- SET-valued signal (displaysPresent, whose value is a list of display names)
-- overrides it with membership, so "becomes DELL" means "DELL entered the set"
-- (a monitor connected) and "leaves DELL" means it left (disconnected).
---@param def { read: fun():any, observe: fun(emit:fun(v:any)):table, match: fun(v:any,t:any):boolean|nil }
local function pushSignal(def)
    local subs = {}       -- token -> cb
    local nextTok = 0
    local watcher = nil   -- the single adapter handle, alive only while subscribed

    local sig = {}

    function sig.read() return def.read() end

    -- Does the current value `v` satisfy target `t`? Scalar equality by default.
    sig.match = def.match or function(v, t) return v == t end

    -- UI metadata (label / value noun / transition verbs) so the Rules form
    -- renders a signal with zero Swift per-signal code, and an optional
    -- candidates() provider for the value dropdown.
    sig.meta = def.meta
    sig.candidates = def.candidates

    -- Opt-in: this signal's value carries { name, bundleId } and a rule may store a
    -- stable `on.bundleId` to match on. The engine (rules.bindOne) honors on.bundleId
    -- ONLY for such signals -- a stray bundleId on a name/enum/set signal would make
    -- the target a bundle id the signal's match never satisfies (a silent dead rule).
    sig.bundleIdMatch = def.bundleIdMatch or false

    --- Subscribe to changes. Returns a handle with .stop().
    function sig.subscribe(cb)
        nextTok = nextTok + 1
        local tok = nextTok
        -- Install the shared watcher BEFORE registering the callback, so if
        -- def.observe throws the subscriber list isn't left holding an orphan cb
        -- that no handle can stop (and that a later subscribe would double-fire).
        -- CONTRACT: an observer must NOT emit() synchronously during install --
        -- this first subscriber isn't registered yet and would miss it (seed the
        -- current value via read() instead, the way bindOne does).
        if not watcher then
            watcher = def.observe(function(v)
                for _, c in pairs(subs) do c(v) end
            end)
        end
        subs[tok] = cb
        return { stop = function()
            if subs[tok] == nil then return end
            subs[tok] = nil
            if watcher and next(subs) == nil then
                watcher.stop()
                watcher = nil
            end
        end }
    end

    return sig
end

-- The set of currently-connected display names (the value of displaysPresent).
local function readDisplayNames()
    local out = {}
    local ok, screens = pcall(adapter.screenFrames)
    if ok and type(screens) == "table" then
        for _, s in ipairs(screens) do
            if type(s) == "table" and type(s.name) == "string" then out[#out + 1] = s.name end
        end
    end
    return out
end

-- Set-membership match (a value crosses INTO/OUT OF a list): used by signals
-- whose value is a set of strings -- displaysPresent (connected monitor names).
local function membership(v, target)
    if type(v) ~= "table" then return false end
    for _, x in ipairs(v) do if x == target then return true end end
    return false
end

-- Set-membership over a list of { name, bundleId } entries (the runningApps
-- value): the target may be a stable bundle id OR a localized name, matched
-- against either field -- the SET twin of frontmostApp's bundle-id/name match,
-- so a "launches/quits X" rule survives a locale rename like the frontmost one.
local function membershipInfo(v, target)
    if type(v) ~= "table" then return false end
    for _, x in ipairs(v) do
        if type(x) == "table" and (x.bundleId == target or x.name == target) then return true end
    end
    return false
end

-- The signal registry. Built at load (no side effects -- pushSignal installs its
-- watcher lazily, on first subscribe). Each signal: read()+observe(emit), an
-- optional match (default scalar ==), `meta` (Rules-form labels), and an optional
-- candidates() for the value dropdown. An observe that re-reads on a coarse event
-- (the displaysPresent/powerSource/... pattern) keeps every signal one shape.
local REGISTRY = {
    frontmostApp = pushSignal {
        -- Value is { name, bundleId } of the frontmost app, so a rule matches on the
        -- STABLE bundle id (the rule stores `on.bundleId`), not the locale-sensitive
        -- localizedName. The name is still matched too, so a free-typed app name (no
        -- bundle id) keeps working. (The from-trigger / ctx.frontmostApp path stays
        -- name-only via adapter.frontmostApp -- features depend on that shape.)
        read    = function() return adapter.frontmostAppInfo() end,
        observe = function(emit) return adapter.onAppActivatedInfo(emit) end,
        bundleIdMatch = true,   -- value is { name, bundleId }; a rule may store on.bundleId
        match   = function(v, target)
            return type(v) == "table" and (v.bundleId == target or v.name == target)
        end,
        -- enterWhen/leaveWhen: the TIMING subtitle the rules editor's verb popover
        -- shows under each edge -- the footgun-killer (focus-gain fires the instant
        -- you open the app; most rules want the click-away edge). DATA, like the
        -- verbs; optional (a signal without them shows no subtitle).
        -- No candidates() provider: a bundleIdMatch signal is picked through the
        -- host's installed-apps chooser (AppCatalog, Swift-side), not a Lua value
        -- dropdown -- so a value list here would be dead weight (the form ignores it).
        meta    = { label = "Frontmost app", valueLabel = "App name", provides = "app",
                    enterVerb = "gains focus", leaveVerb = "loses focus", example = "Safari",
                    enterWhen = "the moment you switch to it",
                    leaveWhen = "the moment you click away" },
    },
    -- The set of connected displays (by name). Re-read on every screenChanged;
    -- membership match turns "connects <name>" into "that monitor connected" and
    -- "disconnects <name>" into "unplugged". The precise, monitor-named form of
    -- the coarse `screenChanged` event.
    displaysPresent = pushSignal {
        read    = readDisplayNames,
        observe = function(emit)
            return adapter.onSystemEvent("screenChanged", function() emit(readDisplayNames()) end)
        end,
        match   = membership,
        -- `provides = "display"`: this signal publishes the matched entity (the
        -- display name) into the trigger CONTEXT under that key, so an effect param
        -- can bind to it ("@trigger:display"). The host derives the from-trigger
        -- option + label from this one declaration -- no hardcoded signal names.
        meta    = { label = "Connected display", valueLabel = "Display name", provides = "display",
                    enterVerb = "connects", leaveVerb = "disconnects", example = "DELL U2720Q",
                    enterWhen = "the moment it plugs in",
                    leaveWhen = "the moment it unplugs" },
        candidates = readDisplayNames,
    },
    -- System appearance: "dark" / "light". Re-read on the appearance-changed
    -- distributed notification.
    appearance = pushSignal {
        read    = function() return adapter.appearance() end,
        observe = function(emit)
            return adapter.onSystemEvent("appearanceChanged", function() emit(adapter.appearance()) end)
        end,
        -- leaveVerb reads "the appearance is no longer dark" (a PROPERTY signal has
        -- no entity subject, so a bare "leaves dark" is ungrammatical). "is no longer"
        -- flows in both the read-back sentence and the Transition picker (RulesView).
        meta    = { label = "Appearance", valueLabel = "Mode",
                    enterVerb = "becomes", leaveVerb = "is no longer", example = "dark" },
        candidates = function() return { "dark", "light" } end,
    },
    -- The set of running apps, each { name, bundleId }. "launches <app>" = it
    -- started, "quits <app>" = it terminated. Re-read on app launch/quit. Like
    -- frontmostApp, a rule stores the STABLE bundle id (matched by membershipInfo);
    -- the name remains a free-text fallback. The host picks from installed apps
    -- (AppCatalog), so no candidates() provider -- same as frontmostApp.
    runningApps = pushSignal {
        read    = function() return adapter.runningAppsInfo() end,
        observe = function(emit)
            return adapter.onSystemEvent("appsChanged", function() emit(adapter.runningAppsInfo()) end)
        end,
        match   = membershipInfo,
        bundleIdMatch = true,   -- value entries carry bundleId; a rule may store on.bundleId
        meta    = { label = "Running app", valueLabel = "App name", provides = "app",
                    enterVerb = "launches", leaveVerb = "quits", example = "Slack",
                    enterWhen = "the moment it launches",
                    leaveWhen = "the moment it quits" },
    },
    -- Power source: "ac" (plugged in) / "battery". Re-read on power change.
    powerSource = pushSignal {
        read    = function() return adapter.powerSource() end,
        observe = function(emit)
            return adapter.onSystemEvent("powerChanged", function() emit(adapter.powerSource()) end)
        end,
        -- "the power source is no longer battery" (see appearance's note above).
        meta    = { label = "Power source", valueLabel = "Source",
                    enterVerb = "becomes", leaveVerb = "is no longer", example = "battery" },
        candidates = function() return { "ac", "battery" } end,
    },
    -- NOTE: `ssid` (Wi-Fi network) is deferred -- reading the SSID needs the
    -- Location permission on macOS 14+, so it requires CLLocationManager + an
    -- Info.plist usage string + a runtime prompt (a product decision). Wire it as
    -- a follow-up; the shape is identical to the signals above.
}

--- Get a signal by name, or nil if unknown.
---@param name string
---@return table|nil
function signals.get(name) return REGISTRY[name] end

--- Is `name` a known signal?
---@param name string
---@return boolean
function signals.exists(name) return REGISTRY[name] ~= nil end

--- Sorted list of available signal names (for the rules UI).
---@return string[]
function signals.list()
    local out = {}
    for name in pairs(REGISTRY) do out[#out + 1] = name end
    table.sort(out)
    return out
end

--- UI metadata for a signal (label, value noun, transition verbs), or nil. The
--- engine's `bundleIdMatch` capability is composed in (a copy, so the curated meta
--- table is never mutated) -- so the host gates its installed-apps app picker on
--- THIS flag, not a hardcoded signal name (mirrors rules.bindOne's gate).
---@param name string
---@return table|nil
function signals.meta(name)
    local sig = REGISTRY[name]
    if not sig or not sig.meta then return nil end
    local m = { bundleIdMatch = sig.bundleIdMatch or false }
    for k, v in pairs(sig.meta) do m[k] = v end
    return m
end

--- Best-effort candidate values for a signal's value dropdown -- deduped + sorted,
--- pulled from the signal's own candidates() provider (guarded: a provider that
--- needs a permission may yield fewer / none; the UI also allows free text).
---@param name string
---@return string[]
function signals.candidates(name)
    local sig = REGISTRY[name]
    if not sig or type(sig.candidates) ~= "function" then return {} end
    local out, seen = {}, {}
    local ok, list = pcall(sig.candidates)
    if ok and type(list) == "table" then
        for _, s in ipairs(list) do
            if type(s) == "string" and #s > 0 and not seen[s] then
                seen[s] = true; out[#out + 1] = s
            end
        end
    end
    table.sort(out)
    return out
end

return signals
