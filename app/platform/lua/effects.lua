-- platform/effects.lua
--
-- The effect layer -- the OUTPUT port of the rules engine. It interprets an
-- EFFECT node (declarative, JSON-encodable -- no functions) and runs it. Domain
-- logic: it reaches the OS only through the registry / adapter, never the seam.
--
-- Effect kinds:
--   command  -- run a feature action:  { kind="command", feature=<id>, action=<actionId?> }
--   notify   -- show a notification:    { kind="notify", title=<str>, text=<str?> }
--
-- chain / layout / scene / runShortcut arrive in later milestones. `dispatch`
-- and the predicates are a switch on `kind`, so adding a kind is additive
-- (open/closed) -- no caller changes.

local registry = require("platform.registry")
local adapter  = require("platform.adapter")

local effects = {}

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
    local out = { { kind = "notify", label = "Notify (banner)" } }
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

return effects
