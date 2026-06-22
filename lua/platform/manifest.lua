-- platform/manifest.lua
--
-- A feature is a plain Lua table (its "manifest") that DECLARES what it is and
-- how it runs -- it does not wire anything itself. The platform reads the
-- manifest to build the config UI, bind triggers, and manage lifecycle.
--
-- A feature declares any of:
--
--   ACTIONS -- named, independently triggerable entry points. Each gets its own
--   user-rebindable trigger (this is how one plugin supports several shortcuts):
--     actions = {
--       { id = "start", label = "Start countdown",
--         defaultTrigger = { type = "hotkey", mods = {"cmd","alt"}, key = "c" },
--         run = function(ctx) ... end },
--       { id = "pause", label = "Pause / resume", defaultTrigger = {...},
--         run = function(ctx) ... end },
--     }
--   An action without a defaultTrigger is dormant until the user binds one.
--   `automatable = true` (optional, default false) lets an action take an
--   AUTOMATED trigger (schedule / system event) as well as the manual ones
--   (hotkey / chord). Leave it off for any action that reads the live UI
--   context (current selection, focused window, clipboard) -- firing those
--   unattended is nonsensical; the UI then offers only hotkey/chord. Opt in for
--   context-free state-changers (refresh wallpaper, toggle a setting).
--
--   SINGLE-ACTION SUGAR -- the common one-shortcut case, normalized internally
--   to a one-entry `actions` list (id "main"):
--     defaultTrigger = { type = "hotkey", mods = {"alt"}, key = "tab" },
--     action = function(ctx) ... end,
--
--   SERVICE -- long-running; enable calls start(ctx), disable tears down
--   everything the feature created through ctx (scoped cleanup), then calls the
--   OPTIONAL stop(ctx). A service MAY also declare `actions` (manual triggers
--   that poke the running service, e.g. "refresh now"):
--     start = function(ctx) ... end,
--     stop  = function(ctx) ... end,   -- optional
--
-- Rules: at least one of actions/action/start; `action` (sugar) excludes both
-- `actions` and `start` -- a service with shortcuts uses the explicit list.
--
-- Manifest shape:
-- {
--   api         = 1,                     -- ctx contract version (required)
--   id          = "break_reminder",          -- unique, stable, settings key prefix
--   name        = "Rest Timer",          -- shown in config UI
--   description = "Reminds you to rest", -- shown in config UI
--   version     = "1.0.0",               -- feature version (optional)
--   category    = "health",              -- groups features in the UI
--   options     = {                      -- typed -> the settings form generates itself
--     { key = "intervalMin", type = "int", default = 25, label = "Interval (min)", min = 5, max = 90 },
--   },
--   actions / defaultTrigger+action / start / stop = ...,   -- see above
-- }

local manifest = {}

-- The ctx contract version this platform implements. Bump on breaking change
-- to the ctx surface; loaders reject mismatched features with a clear error.
manifest.API_VERSION = 1

-- `secret` is a string stored in the login Keychain (not UserDefaults): masked
-- in Settings and read by features via ctx.secret, never ctx.opt. It must NOT
-- declare a plaintext `default` (enforced below).
local VALID_OPTION_TYPES = {
    bool = true, int = true, string = true, enum = true, time = true, appList = true,
    secret = true,
}

-- Privileged ctx extensions a feature may opt into via `capabilities = {...}`.
-- The registry only injects the matching ctx methods for features that declare
-- the capability (principle of least privilege): `commands` grants
-- ctx.commands() / ctx.runCommand() -- the cross-feature reach the command
-- palette needs and a normal feature must never have.
local KNOWN_CAPABILITIES = { commands = true }

-- Validate a manifest table; raises on error. Normalizes in place (category and
-- options defaults; the single-action sugar becomes a one-entry `actions` list
-- with id "main") and returns the manifest.
function manifest.validate(m)
    assert(type(m) == "table", "feature must return a table")
    assert(type(m.id) == "string" and m.id ~= "", "feature.id must be a non-empty string")
    assert(m.api == manifest.API_VERSION,
        "feature '" .. m.id .. "' declares api=" .. tostring(m.api) ..
        " but this platform implements api=" .. manifest.API_VERSION)
    assert(type(m.name) == "string" and m.name ~= "", "feature '" .. m.id .. "' needs a name")

    local hasAction  = type(m.action) == "function"
    local hasActions = m.actions ~= nil
    local hasStart   = type(m.start) == "function"
    assert(hasAction or hasActions or hasStart,
        "feature '" .. m.id .. "' must define actions, action(ctx), or start(ctx)")
    assert(not (hasAction and hasActions),
        "feature '" .. m.id .. "': declare either action (single sugar) or actions, not both")
    assert(not (hasAction and hasStart),
        "feature '" .. m.id .. "': a service with shortcuts uses actions = {...}, " ..
        "not the single-action sugar")
    if m.stop ~= nil then
        assert(hasStart, "feature '" .. m.id .. "': stop(ctx) only makes sense with start(ctx)")
        assert(type(m.stop) == "function", "feature '" .. m.id .. "': stop must be a function")
    end
    -- Optional: onOptionChange(ctx, key) fires when the user edits one of the
    -- feature's options while it is ENABLED -- for features that act on a
    -- cadence and want the new value to apply instantly instead of on the
    -- next tick (ctx.opt always reads live either way).
    if m.onOptionChange ~= nil then
        assert(type(m.onOptionChange) == "function",
            "feature '" .. m.id .. "': onOptionChange must be a function")
    end
    -- Optional: schedule(ctx) -> list of {label, at|everyMin|event|note, optionKey?}.
    -- A SERVICE that runs its own internal timers (ctx.everySeconds / dailyAt)
    -- is otherwise invisible to the trigger model; this descriptor lets it
    -- SELF-REPORT the wall-clock times / intervals / events it operates on, so
    -- the Automation Timeline can plot them. Pure metadata -- it does not bind
    -- anything; describe() calls it with a read-only ctx (see registry).
    if m.schedule ~= nil then
        assert(type(m.schedule) == "function",
            "feature '" .. m.id .. "': schedule must be a function (ctx) -> entries")
    end
    if m.defaultTrigger ~= nil then
        assert(hasAction,
            "feature '" .. m.id .. "': top-level defaultTrigger goes with the single-action " ..
            "sugar; multi-action features put defaultTrigger on each actions entry")
        assert(type(m.defaultTrigger) == "table" and m.defaultTrigger.type,
            "feature '" .. m.id .. "': defaultTrigger must be a trigger spec table")
    end

    -- Normalize the sugar, then validate the (possibly synthesized) list.
    if hasAction then
        m.actions = { { id = "main", label = m.name, mnemonic = m.mnemonic,
                        defaultTrigger = m.defaultTrigger, run = m.action } }
    end
    m.actions = m.actions or {}
    assert(type(m.actions) == "table", "feature '" .. m.id .. "': actions must be a list")
    local seen = {}
    for _, a in ipairs(m.actions) do
        assert(type(a) == "table", "feature '" .. m.id .. "': each action must be a table")
        assert(type(a.id) == "string" and a.id ~= "",
            "feature '" .. m.id .. "': every action needs a non-empty string id")
        assert(not seen[a.id], "feature '" .. m.id .. "': duplicate action id '" .. a.id .. "'")
        seen[a.id] = true
        assert(type(a.run) == "function",
            "feature '" .. m.id .. "': action '" .. a.id .. "' needs run(ctx)")
        a.label = a.label or a.id
        if a.defaultTrigger ~= nil then
            assert(type(a.defaultTrigger) == "table" and a.defaultTrigger.type,
                "feature '" .. m.id .. "': action '" .. a.id ..
                "' defaultTrigger must be a trigger spec table")
        end
        -- automatable: may this action be driven by a context-free AUTOMATED
        -- trigger (schedule / system event), not just a manual one (hotkey /
        -- chord)? Most actions read the live UI context (current selection,
        -- focused window, clipboard) and are nonsensical -- even harmful --
        -- fired with nobody at the keyboard, so the default is false: the
        -- trigger picker offers only hotkey/chord. State-changers that need no
        -- context (toggle dark mode, lock screen) opt in with automatable=true.
        if a.automatable ~= nil then
            assert(type(a.automatable) == "boolean",
                "feature '" .. m.id .. "': action '" .. a.id ..
                "' automatable must be true/false")
        end
        a.automatable = (a.automatable == true)
        -- mnemonic: optional one-line "why this key" hint for the DEFAULT trigger
        -- (e.g. "P for Password", "arrows = screen edges"). Surfaced read-only in
        -- the Shortcut Map / Settings / palette to make the defaults memorable;
        -- the UI hides it once the user rebinds away from the default (then it
        -- would lie). Pure metadata -- never affects binding.
        if a.mnemonic ~= nil then
            assert(type(a.mnemonic) == "string",
                "feature '" .. m.id .. "': action '" .. a.id ..
                "' mnemonic must be a string")
        end
        -- A declared default that IS an automated trigger implies the action is
        -- automatable -- otherwise the seam would refuse to bind its own default.
        if a.defaultTrigger and not a.automatable then
            local dt = a.defaultTrigger.type
            assert(dt ~= "schedule" and dt ~= "event",
                "feature '" .. m.id .. "': action '" .. a.id ..
                "' has a " .. dt .. " defaultTrigger but is not automatable; " ..
                "set automatable = true")
        end
    end

    if m.capabilities ~= nil then
        assert(type(m.capabilities) == "table",
            "feature '" .. m.id .. "': capabilities must be a list of strings")
        for _, cap in ipairs(m.capabilities) do
            assert(type(cap) == "string",
                "feature '" .. m.id .. "': each capability must be a string")
            assert(KNOWN_CAPABILITIES[cap],
                "feature '" .. m.id .. "': unknown capability '" .. tostring(cap) .. "'")
        end
    end

    m.category = m.category or "general"
    m.options = m.options or {}
    -- Index options by key so cross-references (gatedBy / valuesFrom) can be
    -- checked against real, validate-able options below.
    local optByKey = {}
    for _, o in ipairs(m.options) do
        if type(o.key) == "string" then optByKey[o.key] = o end
    end
    for _, o in ipairs(m.options) do
        assert(type(o.key) == "string", "option in '" .. m.id .. "' needs a key")
        assert(VALID_OPTION_TYPES[o.type], "option '" .. o.key .. "' in '" .. m.id ..
            "' has unknown type '" .. tostring(o.type) .. "'")
        -- A secret lives in the Keychain, never in a manifest: a plaintext
        -- default would defeat the point (and there is no UserDefaults fallback).
        if o.type == "secret" then
            assert(o.default == nil, "secret option '" .. o.key .. "' in '" .. m.id ..
                "': must not declare a plaintext default")
        end
        -- Optional display labels for an enum: a list parallel to `values`,
        -- shown in the Settings picker instead of the raw stored value.
        if o.labels ~= nil then
            assert(o.type == "enum", "option '" .. o.key .. "' in '" .. m.id ..
                "': labels only apply to an enum")
            assert(type(o.labels) == "table" and #o.labels == #(o.values or {}),
                "option '" .. o.key .. "' in '" .. m.id ..
                "': labels must be a list the same length as values")
        end
        -- Optional: render a string option as a multi-line text box (a list
        -- entered one item per line, e.g. site_switcher's sites).
        if o.multiline ~= nil then
            assert(o.type == "string", "option '" .. o.key .. "' in '" .. m.id ..
                "': multiline only applies to a string")
            assert(type(o.multiline) == "boolean", "option '" .. o.key .. "' in '" ..
                m.id .. "': multiline must be true/false")
        end
        -- Optional: render this option's editor inside a collapsed disclosure
        -- (the Settings UI shows just the label + a triangle; expand to edit).
        -- Keeps tall controls -- e.g. multiline prompts -- from bloating a form.
        if o.collapsible ~= nil then
            assert(type(o.collapsible) == "boolean", "option '" .. o.key .. "' in '" ..
                m.id .. "': collapsible must be true/false")
        end
        -- Optional: `validate` marks a secret as externally verifiable -- the
        -- Settings UI renders a "Validate" button that checks the credential
        -- (and unlocks the options gated on it). The value names the provider
        -- the host knows how to check (e.g. "openai"). On success the host
        -- records a feature-state flag (hammerdeck.state.<id>.<key>__validated)
        -- the feature reads via ctx.getState to know the credential is live.
        if o.validate ~= nil then
            assert(o.type == "secret", "option '" .. o.key .. "' in '" .. m.id ..
                "': validate only applies to a secret")
            assert(type(o.validate) == "string" and o.validate ~= "",
                "option '" .. o.key .. "' in '" .. m.id ..
                "': validate must be a non-empty provider name string")
        end
        -- Optional: `gatedBy` names another option key whose successful
        -- validation this option depends on -- the Settings UI grays this
        -- control until that secret validates.
        if o.gatedBy ~= nil then
            assert(type(o.gatedBy) == "string" and o.gatedBy ~= "",
                "option '" .. o.key .. "' in '" .. m.id ..
                "': gatedBy must be an option key string")
            local target = optByKey[o.gatedBy]
            assert(target and target.validate ~= nil,
                "option '" .. o.key .. "' in '" .. m.id .. "': gatedBy '" .. o.gatedBy ..
                "' must name a validate-able secret option (else it grays forever)")
        end
        -- Optional: `valuesFrom` names a (secret) option key whose validation
        -- result supplies this enum's choices dynamically (e.g. the model list
        -- fetched from the provider); the manifest `values` are the seed shown
        -- before validation.
        if o.valuesFrom ~= nil then
            assert(o.type == "enum", "option '" .. o.key .. "' in '" .. m.id ..
                "': valuesFrom only applies to an enum")
            assert(type(o.valuesFrom) == "string" and o.valuesFrom ~= "",
                "option '" .. o.key .. "' in '" .. m.id ..
                "': valuesFrom must be an option key string")
            local target = optByKey[o.valuesFrom]
            assert(target and target.validate ~= nil,
                "option '" .. o.key .. "' in '" .. m.id .. "': valuesFrom '" .. o.valuesFrom ..
                "' must name a validate-able secret option (its validation supplies the choices)")
        end
    end
    return m
end

-- Does this manifest declare the named capability? (registry uses this to
-- decide whether to inject the matching privileged ctx methods.)
function manifest.hasCapability(m, name)
    for _, cap in ipairs(m.capabilities or {}) do
        if cap == name then return true end
    end
    return false
end

-- Return the default value for an option key from a manifest.
function manifest.defaultFor(m, key)
    for _, o in ipairs(m.options or {}) do
        if o.key == key then return o.default end
    end
    return nil
end

return manifest
