-- platform/effects.lua
--
-- The effect layer -- the OUTPUT port of the rules engine. It interprets an
-- EFFECT node (declarative, JSON-encodable -- no functions) and runs it. Domain
-- logic: it reaches the OS only through the registry / adapter, never the seam.
--
-- Effect kinds (all context-free unless noted -- a context-free effect is safe on
-- an automated trigger; see requiresContext):
--   command      -- run a feature action: { kind="command", feature=<id>, action=<actionId?> }
--   notify       -- show a notification:   { kind="notify", title=<str>, text=<str?> }
--   layout       -- arrange windows:       { kind="layout", placements={ {app,titlePattern?,screen,pos}, ... } }
--   runShortcut  -- run a macOS Shortcut:  { kind="runShortcut", name=<str> }  (the escape hatch)
--   openURL      -- open a url / app:       { kind="openURL", url=<str> }
--   lockScreen   -- lock the screen:        { kind="lockScreen" }
--   startScreensaver -- start the screensaver: { kind="startScreensaver" }
--   speak        -- speak a line aloud:      { kind="speak", text=<str> }
--   emptyTrash   -- empty the home Trash:    { kind="emptyTrash" }
--   eject        -- eject external disks:    { kind="eject" }
--   solidWallpaper -- paint a solid color:  { kind="solidWallpaper", color="#RRGGBB",
--                   display=<name|"all"|"external"|"primary"|"@trigger:display"> }
--   setWallpaperImage -- set a wallpaper photo: { kind="setWallpaperImage", image=<path>,
--                   display=<name|"all"|"external"|"primary"|"@trigger:display"> }
--   minimizeApp  -- minimize an app's window: { kind="minimizeApp", app=<name|"@trigger:app"> }
--   hideApp      -- hide an app:             { kind="hideApp", app=<name|"@trigger:app"> }
--   quitApp      -- quit an app:             { kind="quitApp", app=<name|"@trigger:app"> }
--   launchApp    -- open (launch) an app:    { kind="launchApp", app=<name>, appBundleId=<id> }
--                   -- the positive counterpart to quit; bundle id is the launch key
--   moveAppToDisplay -- move an app's window to another display, keeping its size:
--                   { kind="moveAppToDisplay", app=<name|"@trigger:app">,
--                     display=<name|"@trigger:display"> }
--
-- `scene` arrives in a later milestone. dispatch / validate / describe /
-- requiresContext / catalog are GENERIC over the EFFECT_KINDS descriptor table
-- below, so adding a kind is genuinely additive (open/closed): one table entry
-- (plus a CATALOG_ORDER slot if it's a curated atom), no function to edit.

local registry = require("platform.registry")
local adapter  = require("platform.adapter")
local windows  = require("platform.windows")

local effects = {}

-- Sentinels for an effect param drawn from the firing TRIGGER's context (see
-- rules.lua triggerContext) instead of a literal. The value is "@trigger:<field>"
-- where <field> is a key the trigger provides: `display` (Connected display) or
-- `app` (Frontmost/Running app). resolveParam turns it into the live value at
-- dispatch; a display's/app's name never collides with the "@trigger:" prefix.
local TRIGGER_PREFIX = "@trigger:"
effects.TRIGGER_DISPLAY = TRIGGER_PREFIX .. "display"
effects.TRIGGER_APP     = TRIGGER_PREFIX .. "app"

-- Resolve an effect param that may be a "@trigger:<field>" reference into the
-- value the trigger supplied; a literal (a name, a category) passes through
-- unchanged. Returns (value), or (nil, reason) when a trigger-ref has nothing in
-- context (e.g. fired by a trigger that doesn't provide that field).
---@param value any
---@param context table|nil
---@return any|nil value
---@return string|nil reason
function effects.resolveParam(value, context)
    if type(value) == "string" and value:sub(1, #TRIGGER_PREFIX) == TRIGGER_PREFIX then
        local field = value:sub(#TRIGGER_PREFIX + 1)
        local v = context and context[field]
        if v == nil or v == "" then
            return nil, "no " .. field .. " in the trigger context"
        end
        return v
    end
    return value
end

-- Does this effect draw any param from the TRIGGER context (a "@trigger:<field>"
-- reference)? Such a rule REACTS to its trigger and can't be meaningfully fired in
-- isolation, so the host hides the "Test" button for it (a manual fire has no live
-- trigger to supply the value). Recurses into nested nodes (e.g. chain steps).
function effects.usesTriggerContext(node)
    if type(node) ~= "table" then return false end
    for _, v in pairs(node) do
        if type(v) == "string" and v:sub(1, #TRIGGER_PREFIX) == TRIGGER_PREFIX then
            return true
        elseif type(v) == "table" and effects.usesTriggerContext(v) then
            return true
        end
    end
    return false
end

-- The context field a "@trigger:<field>" param references (e.g. "display"), or nil
-- for a literal. Lets describe() render "the triggering <field>" generically.
local function triggerField(value)
    return type(value) == "string" and value:match("^@trigger:(.+)") or nil
end

-- Friendly names for the wallpaper presets the rule editor offers, so describe()
-- (the list row + the fire log + the read-back sentence) reads "white" instead of
-- "#FFFFFF". A custom hex falls back to itself.
local COLOR_NAMES = {
    ["#FFFFFF"] = "white", ["#F2F2F2"] = "light gray",
    ["#808080"] = "mid gray", ["#000000"] = "black",
}
local function colorName(hex)
    if type(hex) ~= "string" then return "?" end
    return COLOR_NAMES[hex:upper()] or hex
end

-- The file NAME of a path, so describe() reads "Set wallpaper sunset.jpg" rather
-- than the full "/Users/.../Pictures/sunset.jpg". A pathless value passes through.
local function baseName(path)
    if type(path) ~= "string" then return "?" end
    return path:match("[^/]+$") or path
end

-- Friendly names for the wallpaper display CATEGORIES (a literal monitor name
-- passes through unchanged). "external" -> "external displays" reads in a sentence.
local DISPLAY_TARGETS = {
    all = "all displays", external = "external displays", primary = "the main display",
}

-- describe(): render a DISPLAY param -- "it" (pronoun read-back) or "the
-- triggering <field>" for a from-trigger ref, a friendly category, else the
-- literal name. Shared by every effect that names a display.
local function displayWhere(value, pronoun)
    local f = triggerField(value)
    return f and (pronoun and "it" or ("the triggering " .. f))
        or DISPLAY_TARGETS[value] or tostring(value or "")
end

-- describe(): render an APP param the same way (no friendly-category map).
local function appWho(value, pronoun)
    local f = triggerField(value)
    return f and (pronoun and "it" or ("the triggering " .. f)) or tostring(value or "")
end

-- Lowercase only the first character (so a step reads mid-sentence: "Notify ..."
-- -> "notify ..."). Used by the chain read-back, where every step after the
-- first joins as a lowercase clause. Shared with rules.lua via platform.text.
local lowerFirst = require("platform.text").lowerFirst

-- Run an app-target effect (minimize / hide / quit): resolve its `app` (the
-- readable name, a literal or "@trigger:app") and apply `fn(target)`. One helper
-- for all three -- they differ only in the adapter call. `target` prefers the
-- stored bundle id (stable across locale + app rename), falling back to the
-- resolved name for legacy rules and the from-trigger path (no bundle id); the
-- native seam dual-matches either. The failure note keeps the readable name.
-- Returns (true) / (false, reason).
local function appAction(node, context, fn, verb)
    local app, reason = effects.resolveParam(node.app, context)
    if not app then return false, reason end
    local target = (type(node.appBundleId) == "string" and #node.appBundleId > 0)
        and node.appBundleId or app
    local ok, res = pcall(fn, target)
    if not ok then return false, tostring(res) end
    if not res then return false, "no app to " .. verb .. ": " .. tostring(app) end
    return true
end

-- A placement's human label for the diagnostic note: "Safari 'Docs' on DELL".
local function placementLabel(p)
    local who = tostring(p.app or "?")
    if type(p.titlePattern) == "string" and #p.titlePattern > 0 then
        who = who .. " '" .. p.titlePattern .. "'"
    end
    return who .. " on " .. tostring(p.screen)
end

-- Apply a `layout` effect: for each placement, resolve its target display (a
-- placement whose display is absent is SKIPPED -- self-gating, so a "dock"
-- layout only acts when the monitor is plugged in), compute the rect from the
-- position ratios, and move the FIRST not-yet-placed window matching
-- {app,titlePattern} there.
--
-- Three counts, kept DISTINCT so the diagnostic never lies:
--   present -- placements whose target display is connected (the note's denominator;
--              an ABSENT-display placement is self-gated, NOT counted as a failure).
--   moved   -- of those, the move (setWindowFrame) actually succeeded.
--   misses  -- present-display placements that matched NO window (app closed).
--   failed  -- matched a window but the move itself failed (AX can refuse).
-- Returns:
--   (false, reason)  -- moved nothing: reason distinguishes no-match from all-moves-failed.
--   (true, note)     -- moved some but not all: note names the misses AND move-failures,
--                       so a partial fire is visible in the log, never silently dropped.
--   (true)           -- every present-display placement moved cleanly.
local function applyLayout(node)
    local wins    = adapter.listWindows() or {}
    local screens = adapter.screenFrames() or {}
    local used    = {}    -- window id -> true (one window consumed per placement)
    local present = 0
    local moved   = 0
    local misses  = {}
    local failed  = {}
    local absent  = {}    -- distinct target displays that aren't connected (self-gated)
    local seenAbsent = {}
    for _, p in ipairs(node.placements) do
        local screen = windows.resolveScreen(screens, p.screen)
        local ratios = windows.ratiosFor(p.pos)
        if screen and ratios then
            present = present + 1
            local rect = windows.rectFromRatios(screen, ratios.x, ratios.y, ratios.w, ratios.h)
            local matched = false
            for _, w in ipairs(wins) do
                if not used[w.id] and windows.windowMatches(w, p) then
                    used[w.id] = true
                    matched = true
                    if adapter.setWindowFrame(w.id, rect) then moved = moved + 1
                    else failed[#failed + 1] = placementLabel(p) end
                    break
                end
            end
            if not matched then misses[#misses + 1] = placementLabel(p) end
        elseif ratios and type(p.screen) == "string" and not seenAbsent[p.screen] then
            -- Target display isn't connected: the placement self-gates (silent by
            -- design). Remember its NAME so an all-absent layout can say WHY nothing
            -- moved -- the Test button must point at "the monitor is unplugged",
            -- never the misleading "no matching windows" (which means a closed app).
            seenAbsent[p.screen] = true
            absent[#absent + 1] = p.screen
        end
    end
    if moved == 0 then
        if #failed > 0 then
            return false, "matched window(s) but every move failed: " .. table.concat(failed, ", ")
        end
        if present == 0 and #absent > 0 then
            return false, "target display not connected: " .. table.concat(absent, ", ")
        end
        return false, "no matching windows on present displays"
    end
    local notes = {}
    if #misses > 0 then notes[#notes + 1] = "no window for: " .. table.concat(misses, ", ") end
    if #failed > 0 then notes[#notes + 1] = "move failed: " .. table.concat(failed, ", ") end
    if #notes > 0 then
        return true, "moved " .. moved .. "/" .. present .. " -- " .. table.concat(notes, "; ")
    end
    return true
end

-- Run a `chain` effect: dispatch each sub-effect IN ORDER. Like applyLayout, the
-- result never lies -- it reports how many steps ran and names the ones that
-- failed, so a half-working chain is visible instead of a flat "fired".
--   (false, reason) -- every step failed.
--   (true, note)    -- some failed: note names them (ran K/N).
--   (true)          -- every step succeeded.
local function applyChain(node, context)
    local ran, okCount = 0, 0
    local failed = {}
    for i, step in ipairs(node.effects) do
        ran = ran + 1
        local okStep, note = effects.dispatch(step, context)
        if okStep then
            okCount = okCount + 1
        else
            failed[#failed + 1] = "step " .. i .. " (" .. effects.describe(step)
                .. "): " .. tostring(note)
        end
    end
    if okCount == 0 then
        return false, "every step failed: " .. table.concat(failed, "; ")
    end
    if #failed > 0 then
        return true, "ran " .. okCount .. "/" .. ran .. " -- " .. table.concat(failed, "; ")
    end
    return true
end

-- Move an app's window(s) to another display, KEEPING their size -- the distinct
-- value over `layout`, which always resizes to a snap position. Preserves each
-- window's offset within its current screen, re-applied to the destination, then
-- clamps so the window stays fully on it. The destination is a display NAME (or
-- "@trigger:display"); an absent display fails (nothing to move onto). app may be
-- a literal name or "@trigger:app". Returns (true) / (false, reason).
local function applyMoveToDisplay(node, context)
    local app, areason = effects.resolveParam(node.app, context)
    if not app then return false, areason end
    -- The canonical match key (stable); nil for legacy rules + the from-trigger
    -- path, which fall back to the readable name below.
    local bid = type(node.appBundleId) == "string" and #node.appBundleId > 0
        and node.appBundleId or nil
    local target, dreason = effects.resolveParam(node.display, context)
    if not target then return false, dreason end
    local screens = adapter.screenFrames() or {}
    local dest = windows.resolveScreen(screens, target)
    if not dest then return false, "display not connected: " .. tostring(target) end
    local wins = adapter.listWindows() or {}
    local moved, failed = 0, 0
    for _, w in ipairs(wins) do
        -- With a stored bundle id (`node.appBundleId`), match STRICTLY on it -- so a
        -- different app that merely shares the display name isn't moved too. Without
        -- one, `app` is either a bundle id (the @trigger:app path, which now resolves
        -- to the frontmost app's id) OR a free-typed name, so match on either field.
        -- listWindows carries both.
        local hit
        if bid then
            hit = (w.bundleID == bid)
        else
            hit = (w.bundleID == app) or (w.appName == app)
        end
        if hit then
            local cur = windows.screenOfFrame(screens, w)
            local nx = cur and (dest.x + (w.x - cur.x)) or dest.x
            local ny = cur and (dest.y + (w.y - cur.y)) or dest.y
            -- keep the window fully on the destination (it may be smaller).
            nx = math.max(dest.x, math.min(nx, dest.x + dest.w - w.w))
            ny = math.max(dest.y, math.min(ny, dest.y + dest.h - w.h))
            if adapter.setWindowFrame(w.id, { x = nx, y = ny, w = w.w, h = w.h }) then
                moved = moved + 1
            else
                failed = failed + 1
            end
        end
    end
    if moved == 0 then
        if failed > 0 then return false, "matched " .. app .. " window(s) but the move failed" end
        return false, "no window of " .. tostring(app) .. " to move"
    end
    return true
end

-- The per-kind descriptor table -- the single source of truth Theme A asked for.
-- Each entry carries everything the five generic dispatchers below need:
--   validate(node)            -- assertions (nil = the kind takes no params)
--   run(node, context)        -- dispatch; returns ok[, reasonOrNote] like effects.dispatch
--   describe(node, pronoun)   -- the short human label
--   contextFree = true        -- safe on an automated trigger (no live selection)
--   requiresContext(node)     -- OR a dynamic computation (command/chain), overrides contextFree
--   label                     -- the "Do"-dropdown caption (nil = not a catalog atom, e.g. command)
-- Adding an effect kind is now genuinely additive: one entry here, plus its slot
-- in CATALOG_ORDER if it's a curated atom -- no switch in any of the five
-- functions to touch. A kind that omits contextFree/requiresContext defaults to
-- context-DEPENDENT (un-schedulable) -- the safe side, declared right where the
-- kind is, so a context-free kind can't be silently forgotten in a shared chain.
local EFFECT_KINDS

-- minimize / hide / quit share validate (one app param), run (appAction with a
-- different adapter call + verb), describe (only the verb differs), and context-
-- freeness -- so build the three entries from one factory.
local function appTargetKind(verb, displayVerb, fn, label)
    return {
        validate = function(node)
            assert(type(node.app) == "string" and #node.app > 0,
                node.kind .. " effect needs an app (a name or '" .. effects.TRIGGER_APP .. "')")
        end,
        run = function(node, context) return appAction(node, context, fn, verb) end,
        describe = function(node, pronoun) return displayVerb .. " " .. appWho(node.app, pronoun) end,
        contextFree = true,
        label = label,
    }
end

EFFECT_KINDS = {
    command = {
        validate = function(node)
            assert(type(node.feature) == "string" and #node.feature > 0,
                "command effect needs a feature id")
            assert(node.action == nil or type(node.action) == "string",
                "command effect action must be a string id (or nil for a sole action)")
        end,
        run = function(node) return registry.runAction(node.feature, node.action) end,
        describe = function(node)
            -- Prefer the action's friendly "Do"-dropdown label (the feature name for
            -- a sole action, e.g. "Run Bing Daily Wallpaper") over the raw
            -- "feature.action" id; fall back to the ids when the target feature isn't
            -- loaded this boot (a parked rule). The label is feature-localized DATA --
            -- the same class as a notify title / app name / display name already shown
            -- verbatim -- NOT English glue, so it echoes the localized dropdown label
            -- (Chinese in a zh-Hans build); the glue ("Run") stays English.
            local label = registry.actionLabel(node.feature, node.action)
            if label then return "Run " .. label end
            return "Run " .. tostring(node.feature)
                .. (node.action and ("." .. node.action) or "")
        end,
        -- An unknown command target (a typo'd feature/action) reads as
        -- context-dependent -- the safe default.
        requiresContext = function(node)
            return registry.isActionAutomatable(node.feature, node.action) ~= true
        end,
    },
    notify = {
        validate = function(node)
            assert(type(node.title) == "string" and #node.title > 0,
                "notify effect needs a title")
            assert(node.text == nil or type(node.text) == "string",
                "notify effect text must be a string")
            -- Optional delivery channel: "system" (Notification Center) or "app" (the
            -- in-app banner). Absent = app (back-compat with rules authored before this).
            assert(node.channel == nil or node.channel == "system" or node.channel == "app",
                "notify channel must be 'system' or 'app'")
        end,
        run = function(node)
            if node.channel == "system" then
                -- Deliver to Notification Center; fall back to the in-app banner when
                -- the system path is unavailable (dev `swift run` -- no app bundle).
                local okS, delivered = pcall(adapter.systemNotify, node.title, node.text or "")
                if okS and delivered then return true end
                local okB, errB = pcall(adapter.notify, node.title, node.text or "")
                if not okB then return false, tostring(errB) end
                return true, "shown in-app (system notification unavailable)"
            end
            local ok, err = pcall(adapter.notify, node.title, node.text or "")
            if not ok then return false, tostring(err) end
            return true
        end,
        describe = function(node) return 'Notify "' .. tostring(node.title or "") .. '"' end,
        contextFree = true,
        label = "Notify (banner)",
    },
    layout = {
        validate = function(node)
            assert(type(node.placements) == "table" and #node.placements > 0,
                "layout effect needs at least one placement")
            for i, p in ipairs(node.placements) do
                assert(type(p) == "table", "layout placement #" .. i .. " must be a table")
                assert(type(p.app) == "string" and #p.app > 0,
                    "layout placement #" .. i .. " needs an app name")
                assert(type(p.screen) == "string" and #p.screen > 0,
                    "layout placement #" .. i .. " needs a screen (display name)")
                assert(windows.ratiosFor(p.pos) ~= nil,
                    "layout placement #" .. i .. " needs a valid position")
                -- Optional window disambiguator: a plain substring of the title (lets
                -- a rule target ONE of several same-app windows). The advanced JSON
                -- editor is the way to set it; the guided form doesn't expose it.
                assert(p.titlePattern == nil or type(p.titlePattern) == "string",
                    "layout placement #" .. i .. " titlePattern must be a string")
            end
        end,
        run = function(node)
            local ok, res, reason = pcall(applyLayout, node)
            if not ok then return false, tostring(res) end
            return res, reason
        end,
        describe = function(node)
            local n = (type(node.placements) == "table") and #node.placements or 0
            return "Arrange " .. n .. (n == 1 and " window" or " windows")
        end,
        contextFree = true,
        label = "Arrange windows (layout)",
    },
    runShortcut = {
        validate = function(node)
            assert(type(node.name) == "string" and #node.name > 0,
                "runShortcut effect needs a Shortcut name")
        end,
        run = function(node)
            local ok, err = pcall(adapter.runShortcut, node.name)
            if not ok then return false, tostring(err) end
            return true
        end,
        describe = function(node) return 'Run Shortcut "' .. tostring(node.name or "") .. '"' end,
        contextFree = true,
        label = "Run a Shortcut",
    },
    openURL = {
        validate = function(node)
            assert(type(node.url) == "string" and #node.url > 0,
                "openURL effect needs a url")
        end,
        run = function(node)
            local ok, err = pcall(adapter.openURL, node.url)
            if not ok then return false, tostring(err) end
            return true
        end,
        describe = function(node) return "Open " .. tostring(node.url or "") end,
        contextFree = true,
        label = "Open a URL",
    },
    solidWallpaper = {
        validate = function(node)
            assert(type(node.color) == "string" and node.color:match("^#%x%x%x%x%x%x$"),
                "solidWallpaper effect needs a #RRGGBB color")
            assert(type(node.display) == "string" and #node.display > 0,
                "solidWallpaper effect needs a display (a name, 'all'/'external'/'primary', "
                .. "or '" .. effects.TRIGGER_DISPLAY .. "')")
        end,
        run = function(node, context)
            local target, reason = effects.resolveParam(node.display, context)
            if not target then return false, reason end
            -- Check the adapter's success boolean (parity with appAction): a typo'd or
            -- now-disconnected display matches no screen -> paint nothing, which must
            -- read as a FAILURE in the rule's fire log, not a silent green "fired".
            local ok, res = pcall(adapter.setWallpaperColor, node.color, target)
            if not ok then return false, tostring(res) end
            if not res then return false, "no display to paint: " .. tostring(target) end
            return true
        end,
        describe = function(node, pronoun)
            return "Set wallpaper " .. colorName(node.color) .. " on " .. displayWhere(node.display, pronoun)
        end,
        contextFree = true,
        label = "Set solid wallpaper",
    },
    setWallpaperImage = {
        validate = function(node)
            assert(type(node.image) == "string" and #node.image > 0,
                "setWallpaperImage effect needs an image file path")
            assert(type(node.display) == "string" and #node.display > 0,
                "setWallpaperImage effect needs a display (a name, 'all'/'external'/'primary', "
                .. "or '" .. effects.TRIGGER_DISPLAY .. "')")
        end,
        run = function(node, context)
            local target, reason = effects.resolveParam(node.display, context)
            if not target then return false, reason end
            -- Same success-boolean contract as solidWallpaper: a typo'd/disconnected
            -- display matches no screen -> nothing set -> a FAILURE in the fire log.
            local ok, res = pcall(adapter.setWallpaper, node.image, target)
            if not ok then return false, tostring(res) end
            if not res then return false, "no display for the wallpaper: " .. tostring(target) end
            return true
        end,
        describe = function(node, pronoun)
            return "Set wallpaper " .. baseName(node.image) .. " on " .. displayWhere(node.display, pronoun)
        end,
        contextFree = true,
        label = "Set wallpaper image",
    },
    minimizeApp = appTargetKind("minimize", "Minimize", adapter.minimizeApp, "Minimize an app's window"),
    hideApp     = appTargetKind("hide", "Hide", adapter.hideApp, "Hide an app"),
    quitApp     = appTargetKind("quit", "Quit", adapter.quitApp, "Quit an app"),
    launchApp = {
        validate = function(node)
            -- Unlike minimize/hide/quit (which act on a RUNNING app, found by name or
            -- id), launch needs the bundle id -- the only identifier that resolves to a
            -- launchable app URL. `app` is the readable name for the sentence/log;
            -- appBundleId is required. No "@trigger:app": launch targets a SPECIFIC
            -- installed app (the form never emits the sentinel) -- reject a hand-authored
            -- one loudly, rather than launching the bundle id while the sentence reads
            -- the raw "@trigger:app" literal.
            assert(node.app ~= effects.TRIGGER_APP,
                "launchApp does not support '" .. effects.TRIGGER_APP .. "' -- it targets a specific app")
            assert(type(node.app) == "string" and #node.app > 0,
                "launchApp effect needs an app name")
            assert(type(node.appBundleId) == "string" and #node.appBundleId > 0,
                "launchApp effect needs the app's bundle id (pick it from the installed-apps list)")
        end,
        run = function(node)
            -- Launch (or focus, if already running) the app by its bundle id. A false
            -- return means no installed app carries that id -- surface it as a real
            -- failure in the fire log, not a lying green "fired" (parity with appAction).
            local ok, res = pcall(adapter.launchOrFocusApp, node.appBundleId)
            if not ok then return false, tostring(res) end
            if not res then return false, "no installed app: " .. tostring(node.app) end
            return true
        end,
        describe = function(node) return "Open " .. tostring(node.app or "") end,
        contextFree = true,
        label = "Open an app",
    },
    moveAppToDisplay = {
        validate = function(node)
            assert(type(node.app) == "string" and #node.app > 0,
                "moveAppToDisplay effect needs an app (a name or '" .. effects.TRIGGER_APP .. "')")
            assert(type(node.display) == "string" and #node.display > 0,
                "moveAppToDisplay effect needs a display (a name or '" .. effects.TRIGGER_DISPLAY .. "')")
        end,
        run = function(node, context)
            local ok, res, reason = pcall(applyMoveToDisplay, node, context)
            if not ok then return false, tostring(res) end
            return res, reason
        end,
        describe = function(node, pronoun)
            return "Move " .. appWho(node.app, pronoun) .. " to " .. displayWhere(node.display, pronoun)
        end,
        contextFree = true,
        label = "Move an app to a display",
    },
    speak = {
        validate = function(node)
            assert(type(node.text) == "string" and #node.text > 0,
                "speak effect needs text to say")
        end,
        run = function(node)
            local ok, err = pcall(adapter.say, node.text)
            if not ok then return false, tostring(err) end
            return true
        end,
        describe = function(node) return 'Say "' .. tostring(node.text or "") .. '"' end,
        contextFree = true,
        label = "Speak text aloud",
    },
    lockScreen = {
        run = function()
            local ok, err = pcall(adapter.lockScreen)
            if not ok then return false, tostring(err) end
            return true
        end,
        describe = function() return "Lock the screen" end,
        contextFree = true,
        label = "Lock the screen",
    },
    startScreensaver = {
        run = function()
            local ok, err = pcall(adapter.startScreensaver)
            if not ok then return false, tostring(err) end
            return true
        end,
        describe = function() return "Start the screensaver" end,
        contextFree = true,
        label = "Start the screensaver",
    },
    emptyTrash = {
        run = function()
            local ok, n = pcall(adapter.emptyTrash)
            if not ok then return false, tostring(n) end
            -- -1 = found items but removed none (a Full Disk Access denial); surface it
            -- as a real failure, not a lying green "fired". A count > 0 rides as a note.
            if n == -1 then
                return false, "couldn't empty the Trash -- grant Full Disk Access in System Settings > Privacy & Security"
            end
            if type(n) == "number" and n > 0 then
                return true, "emptied " .. n .. (n == 1 and " item" or " items")
            end
            return true   -- the Trash was already empty
        end,
        describe = function() return "Empty the Trash" end,
        contextFree = true,
        label = "Empty the Trash",
    },
    eject = {
        run = function()
            local ok, n = pcall(adapter.eject)
            if not ok then return false, tostring(n) end
            if n == -1 then return false, "external disk(s) busy -- nothing ejected" end
            if type(n) == "number" and n > 0 then
                return true, "ejected " .. n .. (n == 1 and " disk" or " disks")
            end
            return true   -- no external disks connected
        end,
        describe = function() return "Eject external disks" end,
        contextFree = true,
        label = "Eject external disks",
    },
    chain = {
        validate = function(node)
            assert(type(node.effects) == "table" and #node.effects > 0,
                "chain effect needs at least one step")
            for i, step in ipairs(node.effects) do
                assert(type(step) == "table", "chain step #" .. i .. " must be a table")
                -- No nesting: a chain of chains buys nothing and complicates the editor.
                assert(step.kind ~= "chain", "a chain step cannot itself be a chain")
                local okS, errS = pcall(effects.validate, step)
                assert(okS, "chain step #" .. i .. ": " .. tostring(errS))
            end
        end,
        run = function(node, context)
            local ok, res, reason = pcall(applyChain, node, context)
            if not ok then return false, tostring(res) end
            return res, reason
        end,
        describe = function(node, pronoun)
            local parts = {}
            if type(node.effects) == "table" then
                for _, step in ipairs(node.effects) do
                    parts[#parts + 1] = effects.describe(step, pronoun and { pronoun = true } or nil)
                end
            end
            local n = #parts
            if n == 0 then return "Chain (empty)" end
            if pronoun then
                -- Read-back SENTENCE form: "minimize it, then notify ...". The outer
                -- rules.sentence lowercases the first char; lowercase each SUBSEQUENT
                -- step so the joined steps stay one flowing sentence (vs the compact
                -- "N steps: A -> B" the list row / fire log keep below).
                for i = 2, n do parts[i] = lowerFirst(parts[i]) end
                return table.concat(parts, ", then ")
            end
            return n .. (n == 1 and " step: " or " steps: ") .. table.concat(parts, " -> ")
        end,
        -- A chain is context-free only if EVERY step is -- so a chain on an automated
        -- trigger is allowed iff none of its steps needs live context.
        requiresContext = function(node)
            if type(node.effects) ~= "table" then return true end
            for _, step in ipairs(node.effects) do
                if effects.requiresContext(step) then return true end
            end
            return false
        end,
    },
}

-- The "Do"-dropdown ORDER (a Lua map is unordered, so the curated atom sequence
-- lives here). `command` is appended per-action by catalog(), not listed here.
local CATALOG_ORDER = {
    "notify", "layout", "runShortcut", "openURL", "lockScreen", "startScreensaver",
    "speak", "emptyTrash", "eject", "solidWallpaper", "setWallpaperImage",
    "moveAppToDisplay", "launchApp", "minimizeApp", "hideApp", "quitApp", "chain",
}

--- Validate an effect node. Throws on a malformed node; returns it on success.
---@param node table an effect node
---@return table
function effects.validate(node)
    assert(type(node) == "table", "effect must be a table")
    local spec = EFFECT_KINDS[node.kind]
    if not spec then error("unknown effect kind '" .. tostring(node.kind) .. "'") end
    if spec.validate then spec.validate(node) end
    return node
end

--- Does this effect need live UI context (selection / focused window / clipboard)?
--- Context-FREE only if every action it runs is `automatable`. The rules engine
--- uses this to keep context-dependent effects off automated triggers (schedule/
--- event/state -- fired with nobody present). An unknown kind, or a kind that
--- declares neither contextFree nor requiresContext, is treated as context-
--- dependent -- the safe default.
---@param node table an effect node
---@return boolean
function effects.requiresContext(node)
    if type(node) ~= "table" then return true end
    local spec = EFFECT_KINDS[node.kind]
    if not spec then return true end
    if spec.requiresContext then return spec.requiresContext(node) end
    return not spec.contextFree
end

--- Run an effect node. Returns (true) on success, (false, reason) on failure, or
--- (true, note) on a PARTIAL success the caller should log (e.g. a layout that
--- moved some-but-not-all windows). Never throws for known kinds (registry.runAction
--- is pcall-guarded; notify is contained), so an outcome always surfaces as a return.
---@param node table an effect node
---@param context table|nil values the firing TRIGGER provides (e.g. {display=...}),
---       consumed by params bound to the trigger (see effects.TRIGGER_DISPLAY)
---@return boolean ok
---@return string|nil reasonOrNote  failure reason, or a partial-success note
function effects.dispatch(node, context)
    local spec = EFFECT_KINDS[node.kind]
    if not spec then return false, "unknown effect kind: " .. tostring(node and node.kind) end
    return spec.run(node, context)
end

--- A short human label for an effect node (the rules-list "→ ..." column).
--- `opts.pronoun` renders a from-trigger param as "it" instead of "the triggering
--- <field>" -- used by the read-back SENTENCE, where the trigger value earlier in
--- the line is the antecedent ("When Slack loses focus, minimize it"). The default
--- (no opts) keeps "the triggering app", which the list/log show without an antecedent.
---@param node table an effect node
---@param opts { pronoun: boolean }|nil
---@return string
function effects.describe(node, opts)
    if type(node) ~= "table" then return "?" end
    local spec = EFFECT_KINDS[node.kind]
    if not spec then return tostring(node.kind) end
    return spec.describe(node, opts and opts.pronoun)
end

--- Selectable effects for the rules UI's "Do" dropdown. `automatedOnly` keeps
--- only context-free options (notify + automatable command targets) -- the form
--- passes true once the chosen trigger is automated. Each entry:
--- { kind, label, feature?, action? }.
---@param automatedOnly boolean|nil
---@return table[]
function effects.catalog(automatedOnly)
    -- These curated effects are all context-free, so they survive `automatedOnly`.
    -- (chain's context-freeness depends on its steps -- the form editor only offers
    -- context-free atoms, and validate is the backstop, so it's safe to list here.)
    local out = {}
    for _, kind in ipairs(CATALOG_ORDER) do
        out[#out + 1] = { kind = kind, label = EFFECT_KINDS[kind].label }
    end
    for _, a in ipairs(registry.enabledActions()) do
        if (not automatedOnly) or a.automatable then
            out[#out + 1] = {
                kind = "command", feature = a.featureId, action = a.actionId,
                label = "Run: " .. a.label,
            }
        end
    end
    return out
end

--- Snapshot the CURRENT window arrangement as a layout effect's placement list:
--- one entry per on-screen window, tagged with its app, the display it sits on,
--- and its EXACT position ratios on that display (not snapped to the grid). Backs
--- the Settings "Capture current layout" button -- arrange windows by hand,
--- capture, then save as a rule.
---
--- Scope:
---  * `onlyDisplay` set (a display NAME) -- capture ONLY windows on that one
---    display. This is what a "when <display> connects" rule wants: with 3
---    monitors, it grabs just the display the rule is about, not the others.
---  * `onlyDisplay` nil/empty -- capture every EXTERNAL display's windows; the
---    BUILT-IN panel is skipped (a captured layout restores a display that comes
---    and goes, and the built-in is always present, so it's never the subject).
--- Either way, windows whose display can't be resolved (or zero-sized) are
--- skipped. Returns the placements array (possibly empty).
---@param onlyDisplay string|nil restrict capture to this display's windows
---@return table[]
function effects.captureLayout(onlyDisplay)
    local wins    = adapter.listWindows() or {}
    local screens = adapter.screenFrames() or {}
    local scoped  = type(onlyDisplay) == "string" and onlyDisplay ~= ""
    local out = {}
    for _, w in ipairs(wins) do
        if type(w.w) == "number" and w.w > 0 and type(w.h) == "number" and w.h > 0
            and type(w.x) == "number" and type(w.y) == "number" then
            local s = windows.screenOfFrame(screens, w)
            local keep = s and s.name and s.w > 0 and s.h > 0
                and (scoped and (s.name == onlyDisplay) or (not scoped and not s.builtin))
            if keep then
                out[#out + 1] = {
                    app    = w.appName,
                    screen = s.name,
                    pos    = {
                        x = (w.x - s.x) / s.w, y = (w.y - s.y) / s.h,
                        w = w.w / s.w,         h = w.h / s.h,
                    },
                }
            end
        end
    end
    return out
end

return effects
