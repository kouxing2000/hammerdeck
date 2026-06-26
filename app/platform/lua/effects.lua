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
--
-- chain / scene arrive in later milestones. `dispatch` and the predicates are a
-- switch on `kind`, so adding a kind is additive (open/closed) -- no caller changes.

local registry = require("platform.registry")
local adapter  = require("platform.adapter")
local windows  = require("platform.windows")

local effects = {}

-- Apply a `layout` effect: for each placement, resolve its target display (a
-- placement whose display is absent is SKIPPED -- self-gating, so a "dock"
-- layout only acts when the monitor is plugged in), compute the rect from the
-- position ratios, and move the FIRST not-yet-placed window matching
-- {app,titlePattern} there. Returns (true) if any window moved, else
-- (false, reason) so a no-op (display unplugged / app not running) is logged
-- rather than silently doing nothing.
local function applyLayout(node)
    local wins    = adapter.listWindows() or {}
    local screens = adapter.screenFrames() or {}
    local used    = {}    -- window id -> true (one window consumed per placement)
    local moved   = 0
    for _, p in ipairs(node.placements) do
        local screen = windows.resolveScreen(screens, p.screen)
        local ratios = windows.ratiosFor(p.pos)
        if screen and ratios then
            local rect = windows.rectFromRatios(screen, ratios.x, ratios.y, ratios.w, ratios.h)
            for _, w in ipairs(wins) do
                if not used[w.id] and windows.windowMatches(w, p) then
                    used[w.id] = true
                    if adapter.setWindowFrame(w.id, rect) then moved = moved + 1 end
                    break
                end
            end
        end
    end
    if moved == 0 then return false, "no matching windows on present displays" end
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
        end
    elseif kind == "runShortcut" then
        assert(type(node.name) == "string" and #node.name > 0,
            "runShortcut effect needs a Shortcut name")
    elseif kind == "openURL" then
        assert(type(node.url) == "string" and #node.url > 0,
            "openURL effect needs a url")
    elseif kind == "lockScreen" then
        -- no parameters
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
    elseif node.kind == "runShortcut" or node.kind == "openURL" or node.kind == "lockScreen" then
        return false   -- context-free: fire-and-forget system actions, no live selection
    end
    return true
end

--- Run an effect node. Returns true on success, or false + reason. Never throws
--- for known kinds (registry.runAction is pcall-guarded; notify is contained),
--- so a failing effect surfaces as a return value the caller can log.
---@param node table an effect node
---@return boolean ok
---@return string|nil reason
function effects.dispatch(node)
    if node.kind == "command" then
        return registry.runAction(node.feature, node.action)
    elseif node.kind == "notify" then
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
    elseif node.kind == "lockScreen" then
        local ok, err = pcall(adapter.lockScreen)
        if not ok then return false, tostring(err) end
        return true
    end
    return false, "unknown effect kind: " .. tostring(node and node.kind)
end

--- A short human label for an effect node (the rules-list "→ ..." column).
---@param node table an effect node
---@return string
function effects.describe(node)
    if type(node) ~= "table" then return "?" end
    if node.kind == "command" then
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
    elseif node.kind == "lockScreen" then
        return "Lock the screen"
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
    local out = {
        { kind = "notify",      label = "Notify (banner)" },
        { kind = "layout",      label = "Arrange windows (layout)" },
        { kind = "runShortcut", label = "Run a Shortcut" },
        { kind = "openURL",     label = "Open a URL" },
        { kind = "lockScreen",  label = "Lock the screen" },
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
--- and its EXACT position ratios on that display (not snapped to the grid).
--- Backs the Settings "Capture current layout" button -- arrange windows by
--- hand, capture, then save as a rule. Windows whose display can't be resolved
--- (or zero-sized) are skipped. Returns the placements array (possibly empty).
---@return table[]
function effects.captureLayout()
    local wins    = adapter.listWindows() or {}
    local screens = adapter.screenFrames() or {}
    local out = {}
    for _, w in ipairs(wins) do
        if type(w.w) == "number" and w.w > 0 and type(w.h) == "number" and w.h > 0
            and type(w.x) == "number" and type(w.y) == "number" then
            local s = windows.screenOfFrame(screens, w)
            if s and s.name and s.w > 0 and s.h > 0 then
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
