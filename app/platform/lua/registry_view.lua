-- platform/registry_view.lua
--
-- The registry's READ MODEL: everything that turns live registry state into
-- something a human (or the Swift config UI) reads. Split out of registry.lua
-- (CODE-9, 2026-07-24), which had grown to ~1130 lines and roughly fifteen
-- responsibilities.
--
-- The line is lifecycle vs presentation. registry.lua decides what IS -- which
-- features exist, which are enabled, what is bound, what failed. This module
-- only describes it: localized names and labels, the trigger summary, the
-- command list, the Hyper legend, the whole describe() payload. Nothing here
-- mutates anything; every function is a pure projection of state it is handed.
--
-- DEPENDENCY DIRECTION: registry -> view, never the reverse. The read model
-- needs live state (all/isEnabled/triggerFor/...), so registry INJECTS those as
-- accessors at load time via view.configure. That is the same composition-root
-- idiom window_ops already uses for its pointer-follow predicate, and it is what
-- keeps this from becoming a require cycle.
--
-- Localized feature metadata. The English source lives INLINE (feature.json /
-- init.lua); these resolve a per-feature catalog
-- (app/features/<id>/i18n/<locale>.json) keyed by the field PATH, falling back to
-- that inline English (so an untranslated feature/field just shows English).
-- Applied at describe()/emit time, so a language switch needs only a re-describe,
-- never a re-register. The key scheme is the convention feature authors follow:
--   name | description | page.title
--   action.<id>.label | .description | .mnemonic
--   option.<key>.label | .hint | .section | .defaultLabel | .actionLabel
--   option.<key>.values.<value>     (enum labels, parallel to values)

local adapter  = require("platform.adapter")
local triggers = require("platform.triggers")
local ctxlib   = require("platform.ctx")
local json     = require("platform.json")
local i18n     = require("platform.i18n")

local view = {}

---Live registry accessors, injected by registry.lua at load.
---@class RegistryViewDeps
---@field all fun(): table[]                       every registered manifest, id-sorted
---@field isEnabled fun(id: string): boolean
---@field triggerFor fun(m: table, a: table): table|nil   effective spec (stored or default)
---@field storedTrigger fun(m: table, a: table): table|nil user override only, nil if none
---@field startFailures fun(): table<string, string>      id -> start error
---@field loadFailures fun(): table[]                     { source, id?, error }
local deps

---Wire the read model to live registry state. Called once, by registry.lua.
---@param d RegistryViewDeps
function view.configure(d)
    deps = d
end

-- ---------------------------------------------------------------------------
-- Localized metadata (pure: manifest in, string out -- no registry state)
-- ---------------------------------------------------------------------------

function view.locName(m) return i18n.tFeature(m.id, "name", m.name) end

function view.locDesc(m)
    if not m.description or m.description == "" then return "" end
    return i18n.tFeature(m.id, "description", m.description)
end

function view.locActionLabel(m, a)
    -- `labelFromName` (set by manifest.lua's single-action sugar) says this label is
    -- a COPY of the feature name, frozen to the ENGLISH name because register()
    -- overlays feature.json before validate runs. Falling back to that copy would
    -- print "Password Generator" in an otherwise-Chinese menubar while the translated
    -- name ("密码生成器") sits right there unused -- so fall back to the LOCALIZED name
    -- instead. An action with a label of its OWN is untouched: it looks up its own key
    -- and falls back to its own English source. (Same convention the palette and
    -- hyper-hints apply one screen down: a single-action feature IS its feature.)
    local src = a.labelFromName and view.locName(m) or (a.label or a.id)
    return i18n.tFeature(m.id, "action." .. a.id .. ".label", src)
end

-- The user-facing label for one action, the single command-surface convention:
-- a multi-action feature disambiguates as "Feature -- Action"; a single-action
-- feature IS its feature, so it collapses to the feature name. Shared by the "Do"
-- dropdown (enabledActions), the command palette, and the command effect's
-- read-back (registry.actionLabel) so all three name an action identically.
function view.commandLabel(m, a)
    local fname = view.locName(m)
    if #m.actions > 1 then return fname .. " -- " .. view.locActionLabel(m, a) end
    return fname
end

function view.locActionField(m, a, field, src)
    if src == nil then return nil end
    return i18n.tFeature(m.id, "action." .. a.id .. "." .. field, src)
end

function view.locOptionField(m, o, field, src)
    if src == nil then return nil end
    return i18n.tFeature(m.id, "option." .. o.key .. "." .. field, src)
end

-- Enum labels are an array parallel to o.values; localize each by its VALUE so a
-- reordering of values can't mis-key a translation.
function view.locOptionLabels(m, o)
    if not o.labels then return nil end
    local out = {}
    for i, lbl in ipairs(o.labels) do
        local v = o.values and o.values[i]
        local key = "option." .. o.key .. ".values." .. (v ~= nil and tostring(v) or tostring(i))
        out[i] = i18n.tFeature(m.id, key, lbl)
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Read model (needs live registry state through `deps`)
-- ---------------------------------------------------------------------------

-- Flatten the catalog into a command list for a "commands"-capability holder:
-- one entry per action of every OTHER ENABLED feature (self excluded -- the
-- palette never lists its own opener). Backs ctx.commands(); rebuilt on each
-- call, so it always reflects the live enabled/rebound state. Stable order
-- (deps.all() is id-sorted; actions stay in declared order).
function view.commandList(selfId)
    local out = {}
    for _, m in ipairs(deps.all()) do
        if m.id ~= selfId and deps.isEnabled(m.id) then
            for _, a in ipairs(m.actions) do
                out[#out + 1] = {
                    featureId   = m.id,
                    featureName = view.locName(m),
                    actionId    = a.id,
                    -- single-action features read better as the feature name;
                    -- multi-action ones need the per-action label to disambiguate.
                    label       = (#m.actions > 1) and view.locActionLabel(m, a) or view.locName(m),
                    -- Leading glyph for the palette row: the action's own icon
                    -- when it declares one (distinct per shortcut for a
                    -- multi-action feature), else the feature icon. Always set --
                    -- every feature declares a feature.json `icon`; the literal
                    -- is the generic Swift shows for an unknown category (see
                    -- categoryIcon in FeatureChrome.swift), so the list is never
                    -- ragged even if a future feature omits its icon. A bare SF
                    -- Symbol name (the palette wraps it as a "symbol:" token).
                    icon        = a.icon or m.icon or "puzzlepiece.fill",
                    triggerDesc = triggers.describe(deps.triggerFor(m, a)),
                    triggerGlyph = triggers.glyph(deps.triggerFor(m, a)),
                    -- "why this key" hint, only while the default still holds
                    -- (an override would make the mnemonic lie).
                    mnemonic    = (deps.storedTrigger(m, a) == nil)
                        and view.locActionField(m, a, "mnemonic", a.mnemonic) or nil,
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
function view.hyperLegend()
    local function isHyper(t)
        if not t or (t.type ~= "hotkey" and t.type ~= "chord") then return false end
        local m = t.mods or {}
        if #m ~= 3 then return false end
        local s = {}
        for _, x in ipairs(m) do s[x:lower()] = true end
        return (s.cmd or s.command) and (s.alt or s.option) and (s.ctrl or s.control)
    end
    local items = {}
    for _, m in ipairs(deps.all()) do
        if deps.isEnabled(m.id) then
            for _, a in ipairs(m.actions) do
                local t = deps.triggerFor(m, a)
                if isHyper(t) then
                    local desc = view.locActionField(m, a, "description", a.description)
                    if desc == nil or desc == "" then desc = view.locDesc(m) end
                    items[#items + 1] = {
                        key = t.key,
                        label = (#m.actions > 1) and view.locActionLabel(m, a) or view.locName(m),
                        chord = (t.type == "chord"),
                        -- Leading glyph for the Hyper cheat-sheet row; resolved
                        -- action icon -> feature icon, the same glyph the palette
                        -- / menubar / chord hint show for this action.
                        icon = a.icon or m.icon,
                        -- One-line "what it does", shown in the keyboard HUD's
                        -- hover hint (falls back to the feature description).
                        desc = desc,
                    }
                end
            end
        end
    end
    table.sort(items, function(a, b) return a.key < b.key end)
    return items
end

function view.describeTrigger(m)
    -- Actions first: a service that ALSO declares actions (window_deck,
    -- window_fan, bing_daily, ...) is, from the user's side, TRIGGERED -- its
    -- start() is plumbing (an idle controller so disable can tear down /
    -- restore), not what this summary should read. Only a PURE service (no
    -- actions: sleep_schedule, pointer_follows_window, ...) is truly always-on.
    local n = #m.actions
    if n == 1 then
        -- A DORMANT single action (no stored trigger, no defaultTrigger -- the
        -- "no uninvited hotkey grabs" shape) describes as "no trigger", which
        -- would read as "does nothing" for a feature whose start() runs the
        -- whole time. Fall through to the always-on label instead.
        local spec = deps.triggerFor(m, m.actions[1])
        if spec or not m.start then return triggers.describe(spec) end
    elseif n > 1 then
        return i18n.format("trigger.actions", "%d actions", n)
    end
    return i18n.t("trigger.alwaysOn", "always-on service")
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
        local h, mm = triggers.parseTimeOfDay(e.at)   -- shape AND range
        if not h then return nil end
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

-- The whole catalog as the config UI renders it: one row per feature, with its
-- localized text, options, per-action trigger editors, and self-reported
-- schedule. Rebuilt on every call, so a locale switch or a rebind is reflected
-- by re-describing -- never by re-registering.
function view.describe()
    local startFailures = deps.startFailures()
    local out = {}
    for _, m in ipairs(deps.all()) do
        local opts = {}
        for _, o in ipairs(m.options or {}) do
            opts[#opts + 1] = {
                key = o.key, type = o.type,
                label = view.locOptionField(m, o, "label", o.label or o.key),
                default = o.default, min = o.min, max = o.max,
                values = o.values, labels = view.locOptionLabels(m, o), multiline = o.multiline,
                defaultLabel = view.locOptionField(m, o, "defaultLabel", o.defaultLabel),
                hint = view.locOptionField(m, o, "hint", o.hint),
                section = view.locOptionField(m, o, "section", o.section),
                actionLabel = view.locOptionField(m, o, "actionLabel", o.actionLabel),
                preview = o.preview,
                validate = o.validate, gatedBy = o.gatedBy, valuesFrom = o.valuesFrom,
                collapsible = o.collapsible,
            }
        end
        local row = {
            id = m.id, name = view.locName(m), description = view.locDesc(m),
            category = m.category, version = m.version or "",
            -- Slot within the category section, low first; nil (the common case)
            -- means "sort me after the ranked ones, alphabetically". Carried to
            -- the host as-is so Settings and the README order identically.
            order = m.order,
            -- Optional per-feature SF Symbol; nil falls back host-side to the
            -- shared category glyph (see featureIcon in FeatureChrome.swift).
            icon = m.icon,
            context = m.context or "anywhere",
            requires = json.asArray(m.requires or {}),
            -- What this feature is allowed to reach (network / input / power /
            -- browser / files / commands). Empty for the majority, which is the
            -- informative part: most features touch nothing but windows and
            -- panels. Carried to the host so the config UI can show it -- a
            -- declaration nobody can see is only half of the auditability this
            -- gate exists for. asArray so an empty list crosses the bridge as
            -- [] rather than {} (see json.asArray / LuaState.any).
            capabilities = json.asArray(m.capabilities or {}),
            recommended = m.recommended == true,
            -- A global BEHAVIOR PREFERENCE (feature.json "preference": true), not a
            -- catalog capability: the Settings UI surfaces it in General > Behavior
            -- and filters it OUT of the feature list. Still a normal registered,
            -- enable/disable-able feature -- only its presentation differs.
            preference = m.preference == true,
            kind = m.start and "service" or "action",
            enabled = deps.isEnabled(m.id),
            triggerDesc = view.describeTrigger(m),
            options = opts,
            failed = startFailures[m.id] ~= nil,
            error = startFailures[m.id],
            -- A feature-contributed native page (Homepage sidebar), if declared.
            -- Pure metadata; the host renders the view registered for this id.
            page = m.page and { title = i18n.tFeature(m.id, "page.title", m.page.title),
                                icon = m.page.icon or "doc" } or nil,
        }
        -- Each action carries its editable trigger (current + default) and
        -- whether a user override is in effect, so the config UI renders one
        -- trigger picker per action. Empty list for pure services.
        local actions = {}
        for _, a in ipairs(m.actions) do
            local current = deps.triggerFor(m, a)
            actions[#actions + 1] = {
                id = a.id, label = view.locActionLabel(m, a),
                description = view.locActionField(m, a, "description", a.description),
                mnemonic = view.locActionField(m, a, "mnemonic", a.mnemonic),
                -- Optional per-action SF Symbol; nil falls back host-side to the
                -- feature glyph (see actionImage in StatusBar.swift). Same field
                -- the command palette resolves via view.commandList.
                icon = a.icon,
                automatable = a.automatable == true,
                trigger = current,
                defaultTrigger = a.defaultTrigger,
                triggerOverridden = deps.storedTrigger(m, a) ~= nil,
                triggerDesc = triggers.describe(current),
                -- Created + bound by an option editor (its inline shortcut), so the
                -- UI hides it from the generic per-action trigger sections.
                dynamic = a.dynamic == true,
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
    for _, f in ipairs(deps.loadFailures()) do
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

return view
