-- features/command_palette
--
-- A Spotlight/Raycast-style fuzzy launcher over the whole catalog: one hotkey
-- opens a chooser listing every action of every ENABLED feature; type to
-- filter (feature name + action label), Enter runs it. It is the menubar's
-- QUICK TRIGGERS re-rendered as a keyboard-first fuzzy chooser.
-- Design + rationale: docs/archive/COMMAND_PALETTE_SPEC.md (capability gate in
-- docs/PLUGIN_SYSTEM.md).
--
-- The cross-feature reach (ctx.commands / ctx.runCommand) exists ONLY because
-- this feature declares `capabilities = { "commands" }`; the registry injects
-- those two methods for capability holders. A normal feature never sees, let
-- alone runs, another feature.

local json = require("platform.json")

-- Closure state, reused across invocations; rebuilt when ctx changes (a
-- disable -> enable cycle invalidated the old chooser handle).
local st = nil

-- Frecency: a persisted count of how often each command was run, so the ones
-- you reach for surface to the top. Keyed by feature + action.
local function cmdKey(featureId, actionId) return featureId .. "\0" .. actionId end

-- `counts` is a string-keyed map (cmdKey -> run count). Tag it as a JSON object
-- so it always serializes as `{}`/`{...}` -- never as an array -- even when
-- empty or when an older build persisted an empty map as "[]".
local function loadCounts(ctx)
    local raw = ctx.getState("counts")
    if type(raw) == "string" then
        local t = json.decode(raw)
        if type(t) == "table" then return json.asObject(t) end
    end
    return json.asObject({})
end

local function bumpCount(ctx, featureId, actionId)
    local counts = loadCounts(ctx)
    local k = cmdKey(featureId, actionId)
    counts[k] = (counts[k] or 0) + 1
    ctx.setState("counts", json.encode(counts))
end

local function buildChoices(ctx)
    local counts = loadCounts(ctx)
    local cmds = {}
    for _, cmd in ipairs(ctx.commands()) do
        cmd._count = counts[cmdKey(cmd.featureId, cmd.actionId)] or 0
        cmds[#cmds + 1] = cmd
    end
    -- Most-run first; ties fall back to a stable name order so the list does
    -- not jump around between opens.
    table.sort(cmds, function(a, b)
        if a._count ~= b._count then return a._count > b._count end
        if a.featureName ~= b.featureName then return a.featureName < b.featureName end
        return a.label < b.label
    end)

    local choices = {}
    for _, cmd in ipairs(cmds) do
        -- Source feature as dim context, but only when it adds information --
        -- for single-action features the label already IS the feature name, so
        -- repeating it is noise.
        -- Dim subtitle: the source feature (when it adds info) and the "why this
        -- key" mnemonic, joined when both are present.
        local parts = {}
        if cmd.featureName and cmd.featureName ~= cmd.label then
            parts[#parts + 1] = cmd.featureName
        end
        if cmd.mnemonic and cmd.mnemonic ~= "" then
            parts[#parts + 1] = cmd.mnemonic
        end
        local source = (#parts > 0) and table.concat(parts, " · ") or nil
        local shortcut = nil
        if ctx.opt("showShortcuts") and cmd.triggerGlyph and cmd.triggerGlyph ~= "" then
            shortcut = cmd.triggerGlyph
        end
        choices[#choices + 1] = {
            text     = cmd.label,        -- action label is the primary line
            subText  = source,           -- dim source-feature context column
            shortcut = shortcut,         -- trigger preview, flush-right
            id       = cmd.featureId,    -- carried back on select
            actionId = cmd.actionId,
        }
    end
    return choices
end

local function openPalette(ctx)
    if not st or st.ctx ~= ctx then st = { ctx = ctx } end
    if not st.chooser then
        st.chooser = ctx.chooser {
            searchSubText = true,        -- also match the feature name in the subtitle
            onSelect = function(choice)
                if not choice or not choice.id then return end   -- Escape / info row
                bumpCount(ctx, choice.id, choice.actionId)        -- frecency
                -- Run AFTER the panel has yielded the key window, so commands
                -- that open their OWN chooser (window_switcher, tab_switcher)
                -- don't contend with the palette's panel for focus.
                ctx.afterSeconds(0, function()
                    local ok, err = ctx.runCommand(choice.id, choice.actionId)
                    if not ok then ctx.alert("Command failed: " .. tostring(err)) end
                end)
            end,
        }
    end
    local choices = buildChoices(ctx)
    st.chooser.setPlaceholder("Run a command")
    if #choices == 0 then
        -- A non-selectable info row beats an empty, confusing panel.
        st.chooser.setChoices({
            { text = "No enabled commands",
              subText = "Enable features in Settings", valid = false },
        })
    else
        st.chooser.setChoices(choices)
    end
    st.chooser.setQuery(nil)
    st.chooser.show()
end

return {
    api          = 1,
    id           = "command_palette",
    name         = "Command Palette",
    description  = "Fuzzy-search and run any action of any enabled feature "
        .. "from one keystroke.",
    version      = "1.0.0",
    category     = "platform",
    capabilities = { "commands" },   -- opts into the cross-feature ctx methods

    options = {
        { key = "showShortcuts", type = "bool", default = true,
          label = "Show each command's shortcut in the subtitle" },
    },

    -- Hyper+Space: the Hammerdeck namespace's front-door launcher. Hyper
    -- (⌘⌥⌃) is effectively unclaimed by macOS/apps, so it sidesteps the taken
    -- Space combos (⌘Space Spotlight, ⌥⌘Space Finder search, ⌃Space/⌃⌥Space
    -- input source, ⌃⌘Space emoji) and keeps our conflict warning clean.
    defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "space" },
    mnemonic = "Space — the everything launcher",
    action = function(ctx) openPalette(ctx) end,
}
