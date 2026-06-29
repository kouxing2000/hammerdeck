-- platform/rules.lua
--
-- The automation rules engine -- domain logic (pure Lua over the adapter seam).
-- A RULE binds a TRIGGER to an EFFECT, with a per-rule enabled flag:
--
--   { id = "safari-front", enabled = true,
--     on = { type = "state", signal = "frontmostApp", becomes = "Safari" },
--     effect = { kind = "notify", title = "Hammerdeck", text = "Safari is front" } }
--
-- This is the generalization of "any trigger can fire any action": a rule binds
-- ANY trigger to ANY effect, across features, without belonging to one.
--
-- Triggers: the existing hotkey/chord/schedule/event specs (bound via triggers.lua),
-- PLUS `state` triggers (M1) -- a STATE SIGNAL crossing a value, fired on the
-- false->true (`becomes`) or true->false (`leaves`) transition. State triggers are
-- bound HERE (signal subscription), not via triggers.bind (which maps 1:1 to an
-- adapter primitive).
--
-- Effects: command / notify (see effects.lua).
--
-- Persistence: the rule set lives in the `hammerdeck.rules` setting (JSON) -- the
-- same key the Settings Rules tab reads + writes. Mutations (add/remove/setEnabled)
-- persist and re-bind. Lifecycle mirrors the registry's; every binding is a handle
-- with .stop(), tracked so teardown leaks nothing.

local triggers = require("platform.triggers")
local effects  = require("platform.effects")
local signals  = require("platform.signals")
local adapter  = require("platform.adapter")
local json     = require("platform.json")
local windows  = require("platform.windows")

local rules = {}

local specs = {}   -- id -> spec
local live  = {}   -- id -> handle (.stop()), only for ENABLED + bound rules
-- Per-rule fire history (in-memory, this session): id -> { at, via, ok }. Surfaced
-- as the list's "fired 3m ago" / "not fired yet" status so a rule that's silently
-- never firing is visible at a glance. Reset on load (a fresh boot/reload).
local lastFire = {}

local RULES_SETTING = "hammerdeck.rules"

local function isEnabled(spec) return spec.enabled ~= false end

-- PARKED rules: a stored rule whose target isn't present THIS boot (a command
-- effect pointing at a renamed/removed/failed-to-load feature, or a state trigger
-- on a signal that no longer exists) fails validation. Rather than DROP it -- which
-- the next save() would make permanent, silently deleting the user's automation --
-- keep the raw spec here, re-persist it untouched, and surface it as "unavailable"
-- in the list. It re-activates automatically once its target returns (the next
-- load re-validates it), or the user can fix it (edit the JSON) or delete it.
local parked = {}   -- list of { spec = <raw table>, reason = <string> }

local function parkedIndex(id)
    for i, p in ipairs(parked) do
        if type(p.spec) == "table" and p.spec.id == id then return i end
    end
    return nil
end

-- A short, user-facing reason a rule is parked (shown greyed in the list).
local function parkReason(spec)
    if type(spec) ~= "table" then return "rule is malformed" end
    -- Check the VERIFIABLE cause first -- a state trigger on a signal that no longer
    -- exists -- BEFORE the command-effect heuristic, or a gone-signal rule that
    -- also has a command effect would be misattributed to the feature.
    local on = spec.on
    if type(on) == "table" and on.type == "state"
        and type(on.signal) == "string" and not signals.exists(on.signal) then
        return "signal '" .. on.signal .. "' isn't available"
    end
    -- Otherwise a command effect almost always parks because its target feature was
    -- renamed/removed/failed to load this boot (the dominant cause once the signal
    -- is ruled out).
    local e = spec.effect
    if type(e) == "table" and e.kind == "command"
        and type(e.feature) == "string" and #e.feature > 0 then
        return "feature '" .. e.feature .. "' isn't available"
    end
    return "rule is currently unavailable"
end

--- Validate a rule spec. Throws on malformed; returns the spec on success.
--- Enforces the CONTEXT POLICY: an automated trigger (schedule/event/state --
--- nobody present) may only run a context-free effect (mirrors the registry's
--- per-action automatable gate, applied to the whole effect).
---@param spec table a rule spec
---@return table
function rules.validate(spec)
    assert(type(spec) == "table", "rule must be a table")
    assert(type(spec.id) == "string" and #spec.id > 0, "rule needs a string id")
    assert(type(spec.on) == "table", "rule '" .. spec.id .. "' needs an `on` trigger spec")
    if spec.enabled ~= nil then
        assert(type(spec.enabled) == "boolean", "rule '" .. spec.id .. "' enabled must be boolean")
    end
    if spec.name ~= nil then
        assert(type(spec.name) == "string", "rule '" .. spec.id .. "' name must be a string")
    end
    triggers.validate(spec.on)
    if spec.on.type == "state" then
        assert(signals.exists(spec.on.signal),
            "rule '" .. spec.id .. "': unknown signal '" .. tostring(spec.on.signal) .. "'")
    end
    effects.validate(spec.effect)
    if triggers.isAutomated(spec.on) and effects.requiresContext(spec.effect) then
        error("rule '" .. spec.id .. "': an automated trigger (" .. spec.on.type
            .. ") cannot run a context-dependent effect -- its action is not automatable. "
            .. "Use a hotkey/chord trigger, or mark the action automatable.")
    end
    return spec
end

local function loadOne(spec)
    rules.validate(spec)
    assert(not specs[spec.id], "duplicate rule id: " .. spec.id)
    specs[spec.id] = spec
end

--- Replace the rule set with `list` (stops running rules first; does NOT start
--- the new ones -- call startAll). Each rule is validated under quarantine: a
--- malformed rule is logged and skipped so one typo never drops the rest. Does
--- NOT persist (it is the LOAD direction). Returns the count kept.
---@param list table[]|nil
---@return integer
function rules.load(list)
    rules.stopAll()
    specs = {}
    parked = {}
    lastFire = {}   -- a fresh boot/reload starts the fire history clean
    for _, spec in ipairs(list or {}) do
        local ok, err = pcall(loadOne, spec)
        if not ok then
            local who = (type(spec) == "table" and spec.id) or "?"
            -- Don't drop it -- PARK it (preserved + surfaced as unavailable), so a
            -- transient target absence never silently deletes a user's rule. Only a
            -- table (a real rule) is worth keeping; raw corruption is let go.
            adapter.log("rule load PARKED [" .. tostring(who) .. "]: " .. tostring(err))
            if type(spec) == "table" then
                parked[#parked + 1] = { spec = spec, reason = parkReason(spec) }
            end
        end
    end
    return rules.count()
end

-- The values a rule's TRIGGER makes available to its effect (for params bound to
-- the trigger rather than a literal -- see effects.resolveParam / TRIGGER_*). The
-- matched entity comes from whichever transition the rule uses (`becomes` OR
-- `leaves`): a Connected-display rule yields {display=...} (meaningful on connect,
-- not on disconnect -- a gone monitor); a Frontmost/Running-app rule yields
-- {app=...}, meaningful on BOTH edges -- the app that gained OR lost focus is
-- still alive to act on (e.g. minimize-on-focus-loss). Spec-derived, so it works
-- on a real fire AND the Test button (both go through `fire`). The "any X -> the
-- entered one" case is future work (it needs bindOne to diff the live set).
local function triggerContext(spec)
    local on = spec.on
    if type(on) ~= "table" or on.type ~= "state" then return {} end
    local value
    if on.becomes ~= nil then value = on.becomes
    elseif on.leaves ~= nil then value = on.leaves end
    if value == nil then return {} end
    -- The signal declares which context key it publishes (meta.provides) -- so this
    -- never hardcodes "displaysPresent -> display". A signal with no `provides`
    -- (an enum like appearance) contributes nothing bindable.
    local m = signals.meta(on.signal)
    local field = m and m.provides
    if field then return { [field] = value } end
    return {}
end

-- Dispatch a rule's effect, logging the outcome either way. The SUCCESS log
-- matters: a rule that silently never runs (a typo'd app name that no app ever
-- matches, an effect targeting a now-disabled feature) is otherwise impossible
-- to diagnose -- this trace ("Open Logs" in the menubar) is the only window in.
local function fire(id, spec, via)
    local ok, note = effects.dispatch(spec.effect, triggerContext(spec))
    -- Stamp the fire history (the list's "fired/not-fired" status). A real trigger
    -- fire has no `via`; the Test button passes "test" so the UI can distinguish.
    lastFire[id] = { at = adapter.now(), via = via, ok = ok }
    -- A manual test ("Test" button) tags the trace as [test] so it never reads
    -- like the trigger itself fired -- this log is the only window into what ran.
    local tag = (type(via) == "string" and via ~= "") and (" [" .. via .. "]") or ""
    if ok then
        local msg = "rule '" .. id .. "'" .. tag .. " fired -> " .. effects.describe(spec.effect)
        -- A partial success (e.g. a layout that moved some-but-not-all windows)
        -- carries a note -- append it so a half-firing rule isn't silently "fired".
        if type(note) == "string" and note ~= "" then msg = msg .. " (" .. note .. ")" end
        adapter.log(msg)
    else
        adapter.log("rule '" .. id .. "'" .. tag .. " effect FAILED: " .. tostring(note))
    end
    return ok, note
end

-- Bind one rule's trigger to its effect, returning a .stop() handle. State
-- triggers subscribe to the signal and fire on the matching transition; all
-- other types go through the adapter via triggers.bind.
local function bindOne(id, spec)
    if spec.on.type == "state" then
        local sig = signals.get(spec.on.signal)   -- existence guaranteed by validate
        local wantEnter = spec.on.becomes ~= nil
        -- NB: explicit branch, not `wantEnter and spec.on.becomes or spec.on.leaves`
        -- -- that idiom collapses to leaves when becomes is the boolean `false`
        -- (e.g. a future "onAC becomes false" rule).
        local target
        if wantEnter then target = spec.on.becomes else target = spec.on.leaves end
        -- `sig.match` is scalar `==` for frontmostApp, set-membership for
        -- displaysPresent ("DELL" is IN the connected-displays list). Seed from the
        -- CURRENT value so we only fire on a real change, never on bind.
        local matched = sig.match(sig.read(), target)
        return sig.subscribe(function(v)
            local now = sig.match(v, target)
            if now ~= matched then
                if (wantEnter and now) or ((not wantEnter) and (not now)) then
                    fire(id, spec)
                end
                matched = now
            end
        end)
    end
    return triggers.bind(spec.on, function() fire(id, spec) end, "rule:" .. id)
end

--- Bind every ENABLED rule that is not already live. A bind throw is quarantined
--- per-rule, not fatal to the rest.
function rules.startAll()
    for id, spec in pairs(specs) do
        if isEnabled(spec) and not live[id] then
            local ok, handle = pcall(bindOne, id, spec)
            if ok then
                live[id] = handle
                adapter.log("rule '" .. id .. "' bound (" .. spec.on.type .. ")")
            else
                adapter.log("rule '" .. id .. "' bind FAILED: " .. tostring(handle))
            end
        end
    end
end

--- Stop every live rule binding. Idempotent.
function rules.stopAll()
    for id, handle in pairs(live) do
        if handle and handle.stop then handle.stop() end
        live[id] = nil
    end
end

-- Persist the current set (id-sorted) to the settings store, and re-bind. A full
-- rebuild on each mutation (the set is small) avoids partial-state bugs.
local function save()
    -- Persist the live rules AND the parked ones (verbatim), so a mutation never
    -- drops a rule that's merely unavailable this boot.
    local all = rules.all()
    for _, p in ipairs(parked) do
        if type(p.spec) == "table" then all[#all + 1] = p.spec end
    end
    local encoded = json.encode(all)
    if type(encoded) ~= "string" then
        -- Never write a nil (which would CLEAR the key and wipe every rule); a
        -- valid rule set always encodes, so this only guards a genuine bug.
        adapter.log("rules save FAILED: encode returned non-string; persisted rules left untouched")
        return
    end
    adapter.setSetting(RULES_SETTING, encoded)
end
local function restart()
    rules.stopAll()
    rules.startAll()
end

--- Read the rules config from the `hammerdeck.rules` setting (a JSON array),
--- decode, and load it -- the source the boot uses and the Settings UI writes.
--- Missing / empty / malformed -> zero rules (logged), never a throw.
---@return integer
function rules.loadFromSettings()
    local raw = adapter.getSetting(RULES_SETTING, nil)
    if type(raw) ~= "string" or #raw == 0 then return 0 end
    local data, err = json.decode(raw)
    if type(data) ~= "table" then
        adapter.log("rules config is not valid JSON: " .. tostring(err))
        return 0
    end
    return rules.load(data)
end

-- The lowest unused "ruleN" id (so generated ids stay stable + collision-free).
local function freshId()
    local n = 1
    while specs["rule" .. n] or parkedIndex("rule" .. n) do n = n + 1 end
    return "rule" .. n
end

--- Add a rule (the UI "Add" action). Assigns an id if absent, validates, then
--- persists + binds. Returns (true, id) or (false, reason).
---@param spec table
---@return boolean ok
---@return string reason_or_id
function rules.add(spec)
    if type(spec) ~= "table" then return false, "rule must be a table" end
    if spec.id == nil then spec.id = freshId() end
    local okV, err = pcall(rules.validate, spec)
    if not okV then return false, tostring(err) end
    if specs[spec.id] or parkedIndex(spec.id) then
        return false, "duplicate rule id: " .. spec.id
    end
    specs[spec.id] = spec
    save(); restart()
    return true, spec.id
end

--- Add a rule from a JSON string (the host builds the spec, passes JSON).
---@param str string
---@return boolean ok
---@return string reason_or_id
function rules.addJSON(str)
    local data, err = json.decode(tostring(str))
    if type(data) ~= "table" then return false, "invalid JSON: " .. tostring(err) end
    return rules.add(data)
end

--- Remove a rule by id. Returns (true) or (false, reason).
function rules.remove(id)
    lastFire[id] = nil   -- drop its fire history too
    if specs[id] then
        specs[id] = nil
        save(); restart()
        return true
    end
    -- a parked (unavailable) rule: drop it too -- no rebind needed (it was never bound)
    local pi = parkedIndex(id)
    if pi then
        table.remove(parked, pi)
        save()
        return true
    end
    return false, "no such rule: " .. tostring(id)
end

--- Toggle a rule on/off (kept in the set either way). Returns (true) or (false, reason).
function rules.setEnabled(id, on)
    local spec = specs[id]
    if not spec then return false, "no such rule: " .. tostring(id) end
    spec.enabled = (on == true)
    save(); restart()
    return true
end

--- Replace an EXISTING rule's spec in place (the UI "Save changes" on edit). The
--- id is preserved -- editing keeps the rule's identity and list position --
--- whatever id the incoming spec carried. Validated under the same policy as add.
--- Returns (true) or (false, reason).
---@param id string
---@param spec table
---@return boolean ok
---@return string|nil reason
function rules.update(id, spec)
    local pi = parkedIndex(id)
    if not specs[id] and not pi then return false, "no such rule: " .. tostring(id) end
    if type(spec) ~= "table" then return false, "rule must be a table" end
    spec.id = id
    local okV, err = pcall(rules.validate, spec)
    if not okV then return false, tostring(err) end
    if pi then table.remove(parked, pi) end   -- the edit fixed it: un-park into the live set
    lastFire[id] = nil                         -- behavior changed: the old fire no longer applies
    specs[id] = spec
    save(); restart()
    return true
end

--- Update a rule from a JSON spec string (the host builds the spec, passes JSON).
---@param id string
---@param str string
---@return boolean ok
---@return string|nil reason
function rules.updateJSON(id, str)
    local data, err = json.decode(tostring(str))
    if type(data) ~= "table" then return false, "invalid JSON: " .. tostring(err) end
    return rules.update(id, data)
end

--- The canonical JSON of ONE rule's stored spec (the advanced "Edit as JSON"
--- editor loads this, so it sees the rule's FULL shape -- including advanced
--- fields the guided form can't represent, e.g. a placement's titlePattern).
--- Returns (json) or (nil, reason).
---@param id string
---@return string|nil json
---@return string|nil reason
function rules.specJSON(id)
    local spec = specs[id]
    if not spec then
        local pi = parkedIndex(id)   -- a parked rule is editable too (fix its JSON to un-park)
        if pi then spec = parked[pi].spec end
    end
    if not spec then return nil, "no such rule: " .. tostring(id) end
    local str, err = json.encode(spec)
    if not str then return nil, "encode failed: " .. tostring(err) end
    return str
end

--- Fire a rule's effect ON DEMAND -- the Settings "Test" button. Bypasses the
--- trigger entirely, so a user can verify the effect works WITHOUT staging the
--- real-world condition (plugging in a monitor, switching apps). Works on a
--- DISABLED rule too (you're testing the effect, not the binding). Returns
--- (ok, note_or_reason): `note` is a partial-success message (e.g. a layout that
--- moved some-but-not-all windows), `reason` is the failure cause.
---@param id string
---@return boolean ok
---@return string|nil noteOrReason
function rules.fire(id)
    local spec = specs[id]
    if not spec then return false, "no such rule: " .. tostring(id) end
    return fire(id, spec, "test")
end

--- Number of loaded rules.
---@return integer
function rules.count()
    local n = 0
    for _ in pairs(specs) do n = n + 1 end
    return n
end

--- Number of currently-bound rules (tests / diagnostics).
---@return integer
function rules.liveCount()
    local n = 0
    for _ in pairs(live) do n = n + 1 end
    return n
end

--- The loaded rules (full specs), id-sorted. Backs persistence + describe.
---@return table[]
function rules.all()
    local out = {}
    for _, spec in pairs(specs) do out[#out + 1] = spec end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Serializable rows for the Settings Rules list: { id, enabled, triggerDesc,
--- effectDesc }. The host renders this; the spec -> string formatting lives in
--- triggers.describe / effects.describe.
---@return table[]
function rules.describe()
    local out = {}
    for _, spec in ipairs(rules.all()) do
        -- The plain-English sentence (same one the editor's Name placeholder shows),
        -- so an UNNAMED rule lists as that sentence -- the placeholder is then a true
        -- preview of the row. pcall-guarded: a spec the grammar can't phrase falls back
        -- to "" and the host shows trigger -> effect instead.
        local okSent, sent = pcall(rules.sentence, spec)
        local row = {
            id          = spec.id,
            name        = spec.name or "",   -- the user's label (blank if unnamed)
            enabled     = isEnabled(spec),
            sentence    = okSent and sent or "",
            triggerDesc = triggers.describe(spec.on),
            effectDesc  = effects.describe(spec.effect),
            -- the raw spec halves, so the Settings Rules tab can PRE-FILL the edit
            -- form (the reverse of the Add form's buildSpec).
            on          = spec.on,
            effect      = spec.effect,
            -- a "from the trigger" effect reacts to its trigger, so it can't be
            -- fired in isolation -- the host hides the Test button for it.
            contextBound = effects.usesTriggerContext(spec.effect),
        }
        -- Fire status (this session): present only once the rule has fired.
        local lf = lastFire[spec.id]
        if lf then
            row.lastFired     = lf.at
            row.lastFiredTest = (lf.via == "test")
            row.lastFiredOk   = (lf.ok ~= false)
        end
        out[#out + 1] = row
    end
    -- Parked (unavailable) rules, surfaced AFTER the live ones so the user sees a
    -- rule preserved-but-not-firing (with the reason) instead of a silent gap. Only
    -- id'd specs are listed (an id is needed to select/edit/delete the row); an
    -- id-less corrupt spec is still preserved on disk by save(), just not shown.
    for _, p in ipairs(parked) do
        local spec = p.spec
        if type(spec.id) == "string" and #spec.id > 0 then
            local okSent, sent = pcall(rules.sentence, spec)
            out[#out + 1] = {
                id          = spec.id,
                name        = (type(spec.name) == "string") and spec.name or "",
                enabled     = false,
                sentence    = okSent and sent or "",
                triggerDesc = triggers.describe(type(spec.on) == "table" and spec.on or nil),
                effectDesc  = effects.describe(spec.effect),
                on          = (type(spec.on) == "table") and spec.on or {},
                effect      = (type(spec.effect) == "table") and spec.effect or {},
                unavailable = true,
                reason      = p.reason,
            }
        end
    end
    return out
end

-- Lowercase only the first character (so an effect fragment reads mid-sentence:
-- "Minimize it" -> "minimize it"). ASCII-first; non-English is left as-is (the
-- whole read-back is English, like the rest of the describe layer).
local function lowerFirst(s)
    if type(s) ~= "string" or #s == 0 then return s end
    return s:sub(1, 1):lower() .. s:sub(2)
end

-- A friendly clause for a system event in the read-back ("the Mac wakes").
local EVENT_PHRASES = {
    wake = "the Mac wakes", sleep = "the Mac sleeps",
    screenLock = "the screen locks", screenUnlock = "the screen unlocks",
    screenChanged = "the displays change",
}
local function eventPhrase(ev) return EVENT_PHRASES[ev] or tostring(ev) end

--- A plain-language read-back of a rule spec, e.g. "When Slack loses focus,
--- minimize it." Composed HERE (not in triggers.describe) because natural phrasing
--- needs BOTH the signal's verbs (signals.meta) and the effect (effects.describe) --
--- only this layer sees both. The effect half uses pronoun mode so a from-trigger
--- param reads as "it" (its antecedent is the trigger value earlier in the line).
--- An ENTITY signal (provides app/display) reads "<value> <verb>" ("Slack loses
--- focus"); a PROPERTY signal reads "the <name> <verb> <value>" ("the power source
--- becomes battery"); a schedule LEADS the line without "When". Returns "" when the
--- spec is too incomplete to read (the host then shows a placeholder).
---
--- DELIBERATELY ENGLISH (bare string literals, no i18n) -- the signal verbs
--- (signals.meta) and the effect words (effects.describe) are English literals too,
--- so the whole read-back stays one language. Routing only the GLUE through i18n
--- would yield a half-translated "当 the power source becomes battery 时" the moment
--- a key landed. If the rules describe layer is ever localized, do it holistically
--- (verbs + effects + this), not piecemeal here.
---@param spec table
---@return string
function rules.sentence(spec)
    if type(spec) ~= "table" or type(spec.on) ~= "table" or type(spec.effect) ~= "table" then
        return ""
    end
    local effectClause = lowerFirst(effects.describe(spec.effect, { pronoun = true }))
    if effectClause == "" then return "" end
    local on = spec.on
    if on.type == "state" then
        local m = signals.meta(on.signal) or {}
        local enter = on.becomes ~= nil
        local value = enter and on.becomes or on.leaves
        if value == nil or value == "" then return "" end
        local verb = enter and (m.enterVerb or "becomes")
                            or (m.leaveVerb or "leaves")
        local clause
        if m.provides then
            clause = tostring(value) .. " " .. verb               -- "Slack loses focus"
        else
            clause = "the " .. lowerFirst(m.label or on.signal)   -- "the power source becomes battery"
                .. " " .. verb .. " " .. tostring(value)
        end
        return string.format("When %s, %s.",clause, effectClause)
    elseif on.type == "event" then
        return string.format("When %s, %s.",eventPhrase(on.event), effectClause)
    elseif on.type == "schedule" then
        local clause
        if on.everyMin then
            clause = string.format("Every %d minutes", on.everyMin)
        elseif on.at then
            clause = string.format("Every day at %s", tostring(on.at))
        else
            return ""
        end
        return string.format("%s, %s.", clause, effectClause)
    end
    return ""
end

--- The read-back sentence for a JSON-encoded spec -- the host builds the in-progress
--- rule, passes JSON, and shows the result live above the form. "" on bad input.
---@param str string
---@return string
function rules.sentenceJSON(str)
    local data = json.decode(tostring(str))
    if type(data) ~= "table" then return "" end
    local ok, s = pcall(rules.sentence, data)
    return ok and s or ""
end

--- Everything the Add-rule form needs to populate its dropdowns, in one call:
--- the supported trigger types, the state signals + their candidate values, the
--- system events, and the selectable effects. Effects are the CONTEXT-FREE set
--- (`catalog(true)`): the form only offers AUTOMATED triggers (state/event/
--- schedule), and the context policy refuses a context-dependent effect on any
--- automated trigger -- so listing one would be a guaranteed dead-end "Run ..."
--- the user could never add. The engine still validates on add as the backstop.
---@return table
function rules.formOptions()
    local cand, meta = {}, {}
    for _, name in ipairs(signals.list()) do
        cand[name] = signals.candidates(name)
        meta[name] = signals.meta(name)
    end
    -- Connected displays (names) for the layout editor's display picker.
    local displays = {}
    local okS, screens = pcall(adapter.screenFrames)
    if okS and type(screens) == "table" then
        for _, s in ipairs(screens) do
            if type(s) == "table" and s.name then displays[#displays + 1] = s.name end
        end
    end
    -- The named snap positions (id + label) for the layout editor's position picker.
    local positions = {}
    for _, key in ipairs(windows.POSITION_ORDER) do
        positions[#positions + 1] = { id = key, label = windows.POSITION_LABELS[key] or key }
    end
    return {
        triggerTypes     = { "state", "event", "schedule" },
        signals          = signals.list(),
        signalCandidates = json.asObject(cand),
        signalMeta       = json.asObject(meta),
        events           = { "wake", "sleep", "screenLock", "screenUnlock", "screenChanged" },
        effects          = effects.catalog(true),
        layoutDisplays   = json.asArray(displays),
        layoutPositions  = positions,
    }
end

--- Snapshot the current window arrangement as a layout placement list (the
--- Settings "Capture current layout" button). `onlyDisplay` (a display name, e.g.
--- the rule's trigger display) restricts the snapshot to that one display;
--- nil/empty captures every external display. Delegates to effects.captureLayout;
--- tagged as an array so an empty capture still crosses the bridge as `[]`.
---@param onlyDisplay string|nil restrict capture to this display's windows
---@return table[]
function rules.captureLayout(onlyDisplay)
    return json.asArray(effects.captureLayout(onlyDisplay))
end

return rules
