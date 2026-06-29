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
--   solidWallpaper -- paint a solid color:  { kind="solidWallpaper", color="#RRGGBB",
--                   display=<name|"all"|"external"|"primary"|"@trigger:display"> }
--   setWallpaperImage -- set a wallpaper photo: { kind="setWallpaperImage", image=<path>,
--                   display=<name|"all"|"external"|"primary"|"@trigger:display"> }
--   minimizeApp  -- minimize an app's window: { kind="minimizeApp", app=<name|"@trigger:app"> }
--   hideApp      -- hide an app:             { kind="hideApp", app=<name|"@trigger:app"> }
--   quitApp      -- quit an app:             { kind="quitApp", app=<name|"@trigger:app"> }
--   moveAppToDisplay -- move an app's window to another display, keeping its size:
--                   { kind="moveAppToDisplay", app=<name|"@trigger:app">,
--                     display=<name|"@trigger:display"> }
--
-- chain / scene arrive in later milestones. `dispatch` and the predicates are a
-- switch on `kind`, so adding a kind is additive (open/closed) -- no caller changes.

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

-- Lowercase only the first character (so a step reads mid-sentence: "Notify ..."
-- -> "notify ..."). Used by the chain read-back, where every step after the
-- first joins as a lowercase clause. ASCII-first; mirrors rules.lua's helper.
local function lowerFirst(s)
    if type(s) ~= "string" or #s == 0 then return s end
    return s:sub(1, 1):lower() .. s:sub(2)
end

-- Run an app-target effect (minimize / hide / quit): resolve its `app` (a literal
-- or "@trigger:app") and apply `fn(app)`. One helper for all three -- they differ
-- only in the adapter call. Returns (true) / (false, reason).
local function appAction(node, context, fn, verb)
    local app, reason = effects.resolveParam(node.app, context)
    if not app then return false, reason end
    local ok, res = pcall(fn, app)
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
    local target, dreason = effects.resolveParam(node.display, context)
    if not target then return false, dreason end
    local screens = adapter.screenFrames() or {}
    local dest = windows.resolveScreen(screens, target)
    if not dest then return false, "display not connected: " .. tostring(target) end
    local wins = adapter.listWindows() or {}
    local moved, failed = 0, 0
    for _, w in ipairs(wins) do
        if w.appName == app then
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

--- Validate an effect node. Throws on a malformed node; returns it on success.
---@param node table an effect node
---@return table
function effects.validate(node)
    assert(type(node) == "table", "effect must be a table")
    local kind = node.kind
    if kind == "command" then
        assert(type(node.feature) == "string" and #node.feature > 0,
            "command effect needs a feature id")
        assert(node.action == nil or type(node.action) == "string",
            "command effect action must be a string id (or nil for a sole action)")
    elseif kind == "notify" then
        assert(type(node.title) == "string" and #node.title > 0,
            "notify effect needs a title")
        assert(node.text == nil or type(node.text) == "string",
            "notify effect text must be a string")
        -- Optional delivery channel: "system" (Notification Center) or "app" (the
        -- in-app banner). Absent = app (back-compat with rules authored before this).
        assert(node.channel == nil or node.channel == "system" or node.channel == "app",
            "notify channel must be 'system' or 'app'")
    elseif kind == "layout" then
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
    elseif kind == "runShortcut" then
        assert(type(node.name) == "string" and #node.name > 0,
            "runShortcut effect needs a Shortcut name")
    elseif kind == "openURL" then
        assert(type(node.url) == "string" and #node.url > 0,
            "openURL effect needs a url")
    elseif kind == "solidWallpaper" then
        assert(type(node.color) == "string" and node.color:match("^#%x%x%x%x%x%x$"),
            "solidWallpaper effect needs a #RRGGBB color")
        assert(type(node.display) == "string" and #node.display > 0,
            "solidWallpaper effect needs a display (a name, 'all'/'external'/'primary', "
            .. "or '" .. effects.TRIGGER_DISPLAY .. "')")
    elseif kind == "setWallpaperImage" then
        assert(type(node.image) == "string" and #node.image > 0,
            "setWallpaperImage effect needs an image file path")
        assert(type(node.display) == "string" and #node.display > 0,
            "setWallpaperImage effect needs a display (a name, 'all'/'external'/'primary', "
            .. "or '" .. effects.TRIGGER_DISPLAY .. "')")
    elseif kind == "minimizeApp" or kind == "hideApp" or kind == "quitApp" then
        assert(type(node.app) == "string" and #node.app > 0,
            kind .. " effect needs an app (a name or '" .. effects.TRIGGER_APP .. "')")
    elseif kind == "moveAppToDisplay" then
        assert(type(node.app) == "string" and #node.app > 0,
            "moveAppToDisplay effect needs an app (a name or '" .. effects.TRIGGER_APP .. "')")
        assert(type(node.display) == "string" and #node.display > 0,
            "moveAppToDisplay effect needs a display (a name or '" .. effects.TRIGGER_DISPLAY .. "')")
    elseif kind == "lockScreen" then
        -- no parameters
    elseif kind == "startScreensaver" then
        -- no parameters
    elseif kind == "chain" then
        assert(type(node.effects) == "table" and #node.effects > 0,
            "chain effect needs at least one step")
        for i, step in ipairs(node.effects) do
            assert(type(step) == "table", "chain step #" .. i .. " must be a table")
            -- No nesting: a chain of chains buys nothing and complicates the editor.
            assert(step.kind ~= "chain", "a chain step cannot itself be a chain")
            local okS, errS = pcall(effects.validate, step)
            assert(okS, "chain step #" .. i .. ": " .. tostring(errS))
        end
    else
        error("unknown effect kind '" .. tostring(kind) .. "'")
    end
    return node
end

--- Does this effect need live UI context (selection / focused window / clipboard)?
--- Context-FREE only if every action it runs is `automatable`. The rules engine
--- uses this to keep context-dependent effects off automated triggers (schedule/
--- event/state -- fired with nobody present). An unknown command target (a typo'd
--- feature/action) is treated as context-dependent -- the safe default.
---@param node table an effect node
---@return boolean
function effects.requiresContext(node)
    if type(node) ~= "table" then return true end
    if node.kind == "command" then
        return registry.isActionAutomatable(node.feature, node.action) ~= true
    elseif node.kind == "notify" then
        return false   -- context-free: just shows a notification
    elseif node.kind == "layout" then
        return false   -- context-free: places windows by declared rules, no live selection
    elseif node.kind == "runShortcut" or node.kind == "openURL" or node.kind == "lockScreen"
        or node.kind == "solidWallpaper" or node.kind == "setWallpaperImage" or node.kind == "minimizeApp"
        or node.kind == "hideApp" or node.kind == "quitApp" or node.kind == "startScreensaver"
        or node.kind == "moveAppToDisplay" then
        return false   -- context-free: fire-and-forget system actions, no live selection
    elseif node.kind == "chain" then
        -- A chain is context-free only if EVERY step is -- so a chain on an
        -- automated trigger is allowed iff none of its steps needs live context.
        if type(node.effects) ~= "table" then return true end
        for _, step in ipairs(node.effects) do
            if effects.requiresContext(step) then return true end
        end
        return false
    end
    return true
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
    if node.kind == "command" then
        return registry.runAction(node.feature, node.action)
    elseif node.kind == "notify" then
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
    elseif node.kind == "layout" then
        local ok, res, reason = pcall(applyLayout, node)
        if not ok then return false, tostring(res) end
        return res, reason
    elseif node.kind == "runShortcut" then
        local ok, err = pcall(adapter.runShortcut, node.name)
        if not ok then return false, tostring(err) end
        return true
    elseif node.kind == "openURL" then
        local ok, err = pcall(adapter.openURL, node.url)
        if not ok then return false, tostring(err) end
        return true
    elseif node.kind == "solidWallpaper" then
        local target, reason = effects.resolveParam(node.display, context)
        if not target then return false, reason end
        -- Check the adapter's success boolean (parity with appAction): a typo'd or
        -- now-disconnected display matches no screen -> paint nothing, which must
        -- read as a FAILURE in the rule's fire log, not a silent green "fired".
        local ok, res = pcall(adapter.setWallpaperColor, node.color, target)
        if not ok then return false, tostring(res) end
        if not res then return false, "no display to paint: " .. tostring(target) end
        return true
    elseif node.kind == "setWallpaperImage" then
        local target, reason = effects.resolveParam(node.display, context)
        if not target then return false, reason end
        -- Same success-boolean contract as solidWallpaper: a typo'd/disconnected
        -- display matches no screen -> nothing set -> a FAILURE in the fire log.
        local ok, res = pcall(adapter.setWallpaper, node.image, target)
        if not ok then return false, tostring(res) end
        if not res then return false, "no display for the wallpaper: " .. tostring(target) end
        return true
    elseif node.kind == "minimizeApp" then
        return appAction(node, context, adapter.minimizeApp, "minimize")
    elseif node.kind == "hideApp" then
        return appAction(node, context, adapter.hideApp, "hide")
    elseif node.kind == "quitApp" then
        return appAction(node, context, adapter.quitApp, "quit")
    elseif node.kind == "moveAppToDisplay" then
        local ok, res, reason = pcall(applyMoveToDisplay, node, context)
        if not ok then return false, tostring(res) end
        return res, reason
    elseif node.kind == "lockScreen" then
        local ok, err = pcall(adapter.lockScreen)
        if not ok then return false, tostring(err) end
        return true
    elseif node.kind == "startScreensaver" then
        local ok, err = pcall(adapter.startScreensaver)
        if not ok then return false, tostring(err) end
        return true
    elseif node.kind == "chain" then
        local ok, res, reason = pcall(applyChain, node, context)
        if not ok then return false, tostring(res) end
        return res, reason
    end
    return false, "unknown effect kind: " .. tostring(node and node.kind)
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
    local pronoun = opts and opts.pronoun
    if node.kind == "command" then
        -- Prefer the action's friendly "Do"-dropdown label (the feature name for a
        -- sole action, e.g. "Run Bing Daily Wallpaper") over the raw "feature.action"
        -- id; fall back to the ids when the target feature isn't loaded this boot (a
        -- parked rule). The label is feature-localized DATA -- the same class as a
        -- notify title / app name / display name already shown verbatim in the
        -- sentence -- NOT English glue, so it intentionally echoes the localized
        -- label the user picked in the dropdown (Chinese in a zh-Hans build); the
        -- glue around it ("run", "when") stays English like the rest of describe.
        local label = registry.actionLabel(node.feature, node.action)
        if label then return "Run " .. label end
        return "Run " .. tostring(node.feature)
            .. (node.action and ("." .. node.action) or "")
    elseif node.kind == "notify" then
        return 'Notify "' .. tostring(node.title or "") .. '"'
    elseif node.kind == "layout" then
        local n = (type(node.placements) == "table") and #node.placements or 0
        return "Arrange " .. n .. (n == 1 and " window" or " windows")
    elseif node.kind == "runShortcut" then
        return 'Run Shortcut "' .. tostring(node.name or "") .. '"'
    elseif node.kind == "openURL" then
        return "Open " .. tostring(node.url or "")
    elseif node.kind == "solidWallpaper" then
        local f = triggerField(node.display)
        local where = f and (pronoun and "it" or ("the triggering " .. f))
            or DISPLAY_TARGETS[node.display] or tostring(node.display or "")
        return "Set wallpaper " .. colorName(node.color) .. " on " .. where
    elseif node.kind == "setWallpaperImage" then
        local f = triggerField(node.display)
        local where = f and (pronoun and "it" or ("the triggering " .. f))
            or DISPLAY_TARGETS[node.display] or tostring(node.display or "")
        return "Set wallpaper " .. baseName(node.image) .. " on " .. where
    elseif node.kind == "minimizeApp" or node.kind == "hideApp" or node.kind == "quitApp" then
        local f = triggerField(node.app)
        local who = f and (pronoun and "it" or ("the triggering " .. f)) or tostring(node.app or "")
        local verb = (node.kind == "hideApp" and "Hide")
            or (node.kind == "quitApp" and "Quit") or "Minimize"
        return verb .. " " .. who
    elseif node.kind == "moveAppToDisplay" then
        local af = triggerField(node.app)
        local who = af and (pronoun and "it" or ("the triggering " .. af)) or tostring(node.app or "")
        local df = triggerField(node.display)
        local where = df and (pronoun and "it" or ("the triggering " .. df))
            or DISPLAY_TARGETS[node.display] or tostring(node.display or "")
        return "Move " .. who .. " to " .. where
    elseif node.kind == "lockScreen" then
        return "Lock the screen"
    elseif node.kind == "startScreensaver" then
        return "Start the screensaver"
    elseif node.kind == "chain" then
        local parts = {}
        if type(node.effects) == "table" then
            for _, step in ipairs(node.effects) do parts[#parts + 1] = effects.describe(step, opts) end
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
    end
    return tostring(node.kind)
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
    local out = {
        { kind = "notify",      label = "Notify (banner)" },
        { kind = "layout",      label = "Arrange windows (layout)" },
        { kind = "runShortcut", label = "Run a Shortcut" },
        { kind = "openURL",     label = "Open a URL" },
        { kind = "lockScreen",  label = "Lock the screen" },
        { kind = "startScreensaver", label = "Start the screensaver" },
        { kind = "solidWallpaper", label = "Set solid wallpaper" },
        { kind = "setWallpaperImage", label = "Set wallpaper image" },
        { kind = "moveAppToDisplay", label = "Move an app to a display" },
        { kind = "minimizeApp", label = "Minimize an app's window" },
        { kind = "hideApp",     label = "Hide an app" },
        { kind = "quitApp",     label = "Quit an app" },
        { kind = "chain",       label = "Do several things (chain)" },
    }
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
