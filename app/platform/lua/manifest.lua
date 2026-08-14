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
-- Manifest shape -- split across two co-located files:
--
--   feature.json (DECLARATIVE identity / presentation -- no code, overlaid onto
--   the manifest at register time by the registry; the JSON wins):
--     {
--       "name":        "Rest Timer",          -- shown in config UI
--       "description": "Reminds you to rest",
--       "version":     "1.0.0",
--       "category":    "health",              -- domain tag: the Settings/README section
--       "context":     "automatic",           -- WHEN it applies: textField|window|web|anywhere|automatic
--       "requires":    ["accessibility"],     -- OS preconditions the user must grant
--       "recommended": false,                 -- part of the curated Essentials set?
--       "icon":        "bolt.fill",            -- SF Symbol glyph (falls back to category)
--       "page":        { "title": "...", "icon": "..." }   -- contributes a native Homepage page
--     }
--
--   lua/init.lua (id + api + BEHAVIOR -- returns the manifest table):
--     {
--       api     = 1,                     -- ctx contract version (required)
--       id      = "break_reminder",      -- unique, stable, settings key prefix + the anchor
--                                         --   that locates this feature's feature.json
--       options = {                      -- typed -> the settings form generates itself
--         { key = "intervalMin", type = "int", default = 25, label = "Interval (min)", min = 5, max = 90 },
--       },
--       actions / defaultTrigger+action / start / stop = ...,   -- see above
--     }
--
-- validate() runs on the MERGED table, so name/category/... below are required
-- via feature.json (a feature may also still declare them inline -- the merge
-- overlays JSON on top, and test fixtures with no feature.json keep inline values).

local manifest = {}

-- The ctx contract version this platform implements. Bump on breaking change
-- to the ctx surface; loaders reject mismatched features with a clear error.
manifest.API_VERSION = 1

-- `secret` is a string stored in the login Keychain (not UserDefaults): masked
-- in Settings and read by features via ctx.secret, never ctx.opt. It must NOT
-- declare a plaintext `default` (enforced below).
local VALID_OPTION_TYPES = {
    bool = true, int = true, string = true, enum = true, time = true, appList = true,
    siteList = true, placementList = true, aliasList = true, secret = true,
}

-- CAPABILITIES -- what a feature is allowed to reach, declared up front.
--
-- A feature gets the ordinary ctx surface (windows, panels, timers, options,
-- clipboard, its own dataDir) for free. Everything below is withheld unless the
-- feature NAMES it, so `capabilities` in feature.json answers "what can this
-- thing actually do to my machine?" without reading its code -- which is the
-- point, now that the source is public. It is honest labelling, not a sandbox:
-- the catalog is first-party, and a feature that wanted to lie could simply
-- declare everything. What it buys is that the declaration is greppable, is
-- checked against real usage by a test, and cannot silently drift.
--
-- Two shapes:
--   GATED (below)  -- the method exists on ctx and is REMOVED unless declared.
--   ADDITIVE       -- `commands` grants ctx.commands()/ctx.runCommand(), which
--                     do not otherwise exist (the registry injects them). That
--                     is cross-feature reach the palette needs and a normal
--                     feature must never have.
--
-- Adding a method to ctx? If it touches the network, synthesizes input, powers
-- the machine down, reads the browser, or writes outside the feature's own
-- dataDir, it belongs in a tier here. ctx.make asserts every name below really
-- exists, so a typo fails loudly instead of gating nothing.
local CAPABILITY_METHODS = {
    -- Synthesizes keystrokes into whatever app is focused -- the highest-trust
    -- surface here: it can drive any application as the user.
    input = { "keyStroke", "typeText" },
    -- Outbound network. Note platform.favicons downloads icons, so a feature
    -- that uses it needs this too (the stub below says so by name).
    network = { "httpGet", "httpPost", "httpRequest", "downloadFile" },
    -- Puts the machine or its display to sleep / locks it.
    power = { "systemSleep", "lockScreen", "displaySleep", "startScreensaver" },
    -- Reads or drives the browser. The privacy-relevant tier: browserListTabs
    -- enumerates every open tab's title and URL.
    browser = { "browserListTabs", "browserFocusTab", "browserActiveURL",
                "extractFavicons", "focusBrowserTab", "focusSafariTab",
                "openSiteApp", "openSite" },
    -- Filesystem beyond the feature's own sandbox. dataDir()/cacheDir() stay
    -- ungated (a feature's own storage); these can address any path, and
    -- homeDir() is the door to the user's documents.
    files = { "homeDir", "fileRead", "fileWrite", "fileAppend", "fileExists",
              "mkdir", "removeSubdir" },
    -- Enumerates every installed application -- an inventory read outside any
    -- feature's dataDir, and what software a user has installed is
    -- fingerprinting-relevant, so it is declared, like the browser reads.
    apps = { "installedApps" },
}
local KNOWN_CAPABILITIES = { commands = true }
for cap in pairs(CAPABILITY_METHODS) do KNOWN_CAPABILITIES[cap] = true end

-- `context` is the PRIMARY way features are grouped in the UI (Gallery sections,
-- Tour order): it answers "when does this apply / what must I be doing for it to
-- be useful," which matters more to a new user than the domain. Orthogonal to
-- `category` (the domain tag). Controlled vocabulary so the host can map each to
-- a fixed label + icon and the buckets stay balanced:
--   textField -- acts on / types into a focused text field (insert date, plain paste)
--   window    -- needs a focused window (snap, switch, modal)
--   web       -- operates on the browser (tab/site switchers)
--   anywhere  -- ambient, no precondition (clipboard, palette, password)
--   automatic -- runs itself on a schedule/event, no user action (wallpaper, sleep)
local KNOWN_CONTEXTS = {
    textField = true, window = true, web = true, anywhere = true, automatic = true,
}

-- `category` is the DOMAIN tag -- "what kind of thing is this" -- and is what the
-- Settings sidebar and the generated README group by. Orthogonal to `context`
-- above (WHEN it applies): a switcher is `switching` whether it switches windows,
-- tabs or clipboard entries, though those sit in three different contexts.
--
-- Controlled vocabulary, ENFORCED. It was free-form until 2026-07-28, and drifted
-- into a single 18-of-25 `productivity` bucket that grouped nothing; an unchecked
-- typo is worse than the drift, because Swift's `categoryLabel` falls back to the
-- raw value capitalized, so a misspelling silently mints a section with no
-- translation, no tint and no glyph. Keep this list in step with categoryLabel /
-- categoryColor / categoryIcon + CATEGORY_ORDER (FeatureChrome.swift) and GROUPS
-- (scripts/gen-readme-features.py).
--   windows    -- arranging the focused window / a screen's windows (snap, grid, deck)
--   switching  -- pick one of many from a searchable panel (windows, tabs, sites,
--                 clipboard, commands) -- the chooser family, whatever it lists
--   text       -- acts on the selection or types into the focused field
--   health     -- looks after the person, not the machine (breaks, sleep, display off)
--   utilities  -- self-contained one-offs (password, countdown, pointer)
--   visibility -- shows what the app itself did (confirm chip, run notice, usage)
--   appearance -- how the desktop looks (wallpaper)
--   general    -- the default when a feature.json omits the field
local KNOWN_CATEGORIES = {
    windows = true, switching = true, text = true, health = true,
    utilities = true, visibility = true, appearance = true, general = true,
}

-- `requires` lists OS preconditions a user must grant before the feature works
-- (distinct from `context`: WHEN it applies vs WHAT it needs). Controlled vocab
-- so the host surfaces a consistent "Needs Accessibility" badge and can check
-- the live grant. Keystroke synthesis and window manipulation both need it.
local KNOWN_REQUIREMENTS = { accessibility = true }

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
    -- Optional: dynamicActions(read) -> a list of extra action tables, expanded by
    -- the REGISTRY at register time (it passes a scoped option reader so the
    -- feature stays off the adapter seam). Lets a feature derive actions from its
    -- own stored data -- e.g. window_snap turning each user placement preset into
    -- its own rebindable action. The returned actions are appended to m.actions
    -- BEFORE the validation below, so they pass the same id-uniqueness / run
    -- checks as static ones. Pure metadata here; the registry owns the invocation.
    if m.dynamicActions ~= nil then
        assert(type(m.dynamicActions) == "function",
            "feature '" .. m.id .. "': dynamicActions must be a function (read) -> actions")
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
    -- Optional: page = { title, icon } declares that this feature contributes a
    -- NATIVE host PAGE (a full SwiftUI view docked in the Homepage sidebar), not
    -- just the manifest-generated Settings form. Pure metadata -- Lua cannot
    -- author SwiftUI, so it only NAMES the page (title + SF Symbol); the host
    -- renders whatever view is registered for this feature id (the Swift-side
    -- FeaturePageRegistry). describe() surfaces it so the sidebar is data-driven:
    -- a feature "plugs in" its native page by declaring this, with no central
    -- enum/switch to edit. The page reads its data via a feature reader module
    -- (e.g. usage_stats' report.lua), so it works even when the feature is off.
    if m.page ~= nil then
        assert(type(m.page) == "table",
            "feature '" .. m.id .. "': page must be a table { title, icon }")
        assert(type(m.page.title) == "string" and m.page.title ~= "",
            "feature '" .. m.id .. "': page.title must be a non-empty string")
        assert(m.page.icon == nil or type(m.page.icon) == "string",
            "feature '" .. m.id .. "': page.icon must be a string (SF Symbol name)")
    end

    -- Optional: icon = an SF Symbol name shown as this feature's glyph in the
    -- menubar quick-triggers, the Settings list, and the Gallery card. Pure
    -- presentation metadata (usually set in feature.json); when absent the host
    -- falls back to a shared per-category glyph. Only NAMES the symbol -- the
    -- host renders it (SF Symbols are an Apple-platform asset, not authorable in
    -- Lua), mirroring how page.icon works.
    if m.icon ~= nil then
        assert(type(m.icon) == "string" and m.icon ~= "",
            "feature '" .. m.id .. "': icon must be a non-empty string (SF Symbol name)")
    end

    -- Normalize the sugar, then validate the (possibly synthesized) list.
    -- labelFromName MARKS the label as a copy of the feature name rather than a
    -- label of its own. It matters at localization time: register() overlays
    -- feature.json BEFORE this runs, so `m.name` here is the ENGLISH name, and a
    -- describe() under zh must fall back to the LOCALIZED name -- not to this frozen
    -- English copy (which once put "Password Generator" in an all-Chinese menubar).
    -- The marker lets registry.locActionLabel READ that intent instead of inferring
    -- it from `a.label == m.name`, which is true only by coincidence.
    if hasAction then
        m.actions = { { id = "main", label = m.name, labelFromName = true,
                        mnemonic = m.mnemonic,
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
        -- icon: optional per-action SF Symbol name, shown as this action's glyph
        -- in the command palette. Overrides the feature-level `icon` for THIS
        -- action -- lets a multi-action feature give each shortcut a distinct
        -- glyph (e.g. window_snap's left/right halves). Absent -> the row falls
        -- back to the feature icon (see buildCommandList). Pure presentation
        -- metadata; only NAMES the symbol (the host renders it), like m.icon.
        if a.icon ~= nil then
            assert(type(a.icon) == "string" and a.icon ~= "",
                "feature '" .. m.id .. "': action '" .. a.id ..
                "' icon must be a non-empty string (SF Symbol name)")
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

    -- category: the domain tag (Settings sidebar + README sections). Optional;
    -- defaults to "general" so an unannotated feature still lands somewhere.
    if m.category ~= nil then
        assert(type(m.category) == "string" and KNOWN_CATEGORIES[m.category],
            "feature '" .. m.id .. "': unknown category '" .. tostring(m.category) ..
            "' (expected windows|switching|text|health|utilities|visibility|appearance|general)")
    end
    m.category = m.category or "general"

    -- order: this feature's slot WITHIN its category section (Settings sidebar +
    -- the generated README), low first. Optional, and most features should omit
    -- it: unranked ones sort after every ranked one, alphabetically, which is the
    -- right default for a bag of peers. Declare it only where a section has a real
    -- reading order -- the window suite runs snap -> grid -> mode -> deck -> fan ->
    -- rewind -> pointer-follow, simplest to most specialized, and alphabetical put
    -- the comfort setting first and the one-key workhorse last.
    --
    -- Deliberately NOT applied to the Gallery, which groups by `context`: a rank
    -- that means "position among my category siblings" is noise once the members
    -- are drawn from a different axis.
    if m.order ~= nil then
        assert(type(m.order) == "number" and m.order == math.floor(m.order),
            "feature '" .. m.id .. "': order must be an integer, got " .. tostring(m.order))
    end

    -- preview: which Gallery animation stands in for this feature --
    -- { archetype = "chooser", sample = "windows" }. Only the SHAPE is checked
    -- here, deliberately: the archetype and sample names are a Swift vocabulary
    -- (the scenes and their fixture payloads live there), and re-listing them in
    -- Lua would create another copy to keep in step -- the exact failure mode this
    -- field was introduced to remove. An unknown name resolves to no preview
    -- host-side, which testEveryGalleryFeatureHasAPreview already fails on, so the
    -- gate exists without the duplication.
    if m.preview ~= nil then
        assert(type(m.preview) == "table",
            "feature '" .. m.id .. "': preview must be a table { archetype = ..., sample = ... }")
        assert(type(m.preview.archetype) == "string" and m.preview.archetype ~= "",
            "feature '" .. m.id .. "': preview.archetype must be a non-empty string")
        -- Non-EMPTY, mirroring archetype above. An empty string is not a missing
        -- field: it survives to the host as a real value, and for the one
        -- archetype that used to take free content it resolved to a scene that
        -- typed nothing -- a blank animation, with every gate green.
        assert(m.preview.sample == nil
                   or (type(m.preview.sample) == "string" and m.preview.sample ~= ""),
            "feature '" .. m.id .. "': preview.sample must be a non-empty string when present")
    end

    -- context: the primary grouping axis (when the feature applies). Optional;
    -- defaults to "anywhere" (ambient) so an unannotated feature still slots in.
    if m.context ~= nil then
        assert(type(m.context) == "string" and KNOWN_CONTEXTS[m.context],
            "feature '" .. m.id .. "': unknown context '" .. tostring(m.context) ..
            "' (expected textField|window|web|anywhere|automatic)")
    end
    m.context = m.context or "anywhere"

    -- requires: OS preconditions (Accessibility, ...). Optional; defaults to none.
    if m.requires ~= nil then
        assert(type(m.requires) == "table",
            "feature '" .. m.id .. "': requires must be a list of strings")
        for _, r in ipairs(m.requires) do
            assert(type(r) == "string" and KNOWN_REQUIREMENTS[r],
                "feature '" .. m.id .. "': unknown requirement '" .. tostring(r) ..
                "' (expected one of: accessibility)")
        end
    end
    m.requires = m.requires or {}

    -- recommended: part of the curated "Essentials" starter set the blank-start
    -- UI offers to enable in one click. Optional boolean, default false.
    if m.recommended ~= nil then
        assert(type(m.recommended) == "boolean",
            "feature '" .. m.id .. "': recommended must be true/false")
    end
    m.recommended = (m.recommended == true)

    -- preference: a global BEHAVIOR PREFERENCE surfaced in Settings > General,
    -- not a catalog feature (the host filters it out of the feature list).
    -- Optional boolean, default false.
    if m.preference ~= nil then
        assert(type(m.preference) == "boolean",
            "feature '" .. m.id .. "': preference must be true/false")
    end
    m.preference = (m.preference == true)

    -- defaultEnabled: does this ship ENABLED on a fresh install, before the user
    -- has toggled it? The catalog is blank-slate by default (everything off; opt
    -- in via the Essentials one-click or the per-feature toggle) -- but a quiet,
    -- SELF-GATING system behavior (e.g. confirm_shortcut, which does nothing until
    -- other features are on) may opt to ship on so a new user discovers it. The
    -- user's explicit choice always overrides: registry.isEnabled reads this ONLY
    -- as the fallback when no stored value exists. Optional boolean, default false.
    if m.defaultEnabled ~= nil then
        assert(type(m.defaultEnabled) == "boolean",
            "feature '" .. m.id .. "': defaultEnabled must be true/false")
    end
    m.defaultEnabled = (m.defaultEnabled == true)

    -- selfEvident: do this feature's manual triggers already produce an obvious
    -- on-screen result -- a chooser/palette opening, a browser tab or window coming
    -- to the front? If so the "confirm shortcut" flash would just repeat what you can
    -- plainly see, so it is SUPPRESSED for this feature (the flash is kept for silent
    -- actions -- copy, plain-paste, an off-screen window move -- where it is the only
    -- feedback). Consumed by registry.flashManualFire. Optional boolean, default false.
    if m.selfEvident ~= nil then
        assert(type(m.selfEvident) == "boolean",
            "feature '" .. m.id .. "': selfEvident must be true/false")
    end
    m.selfEvident = (m.selfEvident == true)

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
-- capability -> the ctx method names it gates. ctx.make consumes this to strip
-- what a feature did not declare; the capability guard test consumes it to check
-- declarations against real usage. Read-only by convention.
---@type table<string, string[]>
manifest.CAPABILITY_METHODS = CAPABILITY_METHODS

-- Every capability name a feature may declare (the gated tiers plus the
-- additive `commands`), as a set. Exposed so a test can enumerate the full set
-- rather than re-listing it and drifting.
---@type table<string, boolean>
manifest.KNOWN_CAPABILITIES = KNOWN_CAPABILITIES

-- Every category a feature may declare, as a set. Exposed for the SAME reason as
-- the capabilities above -- so the gate that keeps the Swift and Python copies of
-- this vocabulary honest (testCategoryVocabularyIsConsistent) can enumerate the
-- real set instead of re-listing it here and drifting, which is precisely the
-- failure this whole re-cut exists to fix.
---@type table<string, boolean>
manifest.KNOWN_CATEGORIES = KNOWN_CATEGORIES

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
