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
---@param def { read: fun():any, observe: fun(emit:fun(v:any)):table }
local function pushSignal(def)
    local subs = {}       -- token -> cb
    local nextTok = 0
    local watcher = nil   -- the single adapter handle, alive only while subscribed

    local sig = {}

    function sig.read() return def.read() end

    --- Subscribe to changes. Returns a handle with .stop().
    function sig.subscribe(cb)
        nextTok = nextTok + 1
        local tok = nextTok
        subs[tok] = cb
        if not watcher then
            watcher = def.observe(function(v)
                for _, c in pairs(subs) do c(v) end
            end)
        end
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

-- The signal registry. Built at load (no side effects -- pushSignal installs its
-- watcher lazily, on first subscribe).
local REGISTRY = {
    frontmostApp = pushSignal {
        read    = function() return adapter.frontmostApp() end,
        observe = function(emit) return adapter.onAppActivated(emit) end,
    },
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

--- Best-effort candidate values for a signal, for the UI dropdown. For
--- frontmostApp: the current frontmost + the app names of open windows (the
--- window scan is guarded -- it needs Accessibility, so a denial just yields the
--- frontmost alone; the UI also allows free text).
---@param name string
---@return string[]
function signals.candidates(name)
    local out, seen = {}, {}
    local function add(s)
        if type(s) == "string" and #s > 0 and not seen[s] then
            seen[s] = true; out[#out + 1] = s
        end
    end
    if name == "frontmostApp" then
        add(adapter.frontmostApp())
        local ok, wins = pcall(adapter.listWindows)
        if ok and type(wins) == "table" then
            for _, w in ipairs(wins) do add(w.appName) end
        end
    end
    table.sort(out)
    return out
end

return signals
