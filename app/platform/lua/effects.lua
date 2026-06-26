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
        end
    end
    if moved == 0 then
        if #failed > 0 then
            return false, "matched window(s) but every move failed: " .. table.concat(failed, ", ")
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

--- Run an effect node. Returns (true) on success, (false, reason) on failure, or
--- (true, note) on a PARTIAL success the caller should log (e.g. a layout that
--- moved some-but-not-all windows). Never throws for known kinds (registry.runAction
--- is pcall-guarded; notify is contained), so an outcome always surfaces as a return.
---@param node table an effect node
---@return boolean ok
---@return string|nil reasonOrNote  failure reason, or a partial-success note
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
