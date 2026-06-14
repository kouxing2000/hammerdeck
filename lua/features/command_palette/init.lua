-- features/command_palette
--
-- A Spotlight/Raycast-style fuzzy launcher over the whole catalog: one hotkey
-- opens a chooser listing every action of every ENABLED feature; type to
-- filter (feature name + action label), Enter runs it. It is the menubar's
-- QUICK TRIGGERS re-rendered as a keyboard-first fuzzy chooser.
-- Design + rationale: docs/COMMAND_PALETTE_SPEC.md.
--
-- The cross-feature reach (ctx.commands / ctx.runCommand) exists ONLY because
-- this feature declares `capabilities = { "commands" }`; the registry injects
-- those two methods for capability holders. A normal feature never sees, let
-- alone runs, another feature.

-- Closure state, reused across invocations; rebuilt when ctx changes (a
-- disable -> enable cycle invalidated the old chooser handle).
local st = nil

local function buildChoices(ctx)
    local choices = {}
    for _, cmd in ipairs(ctx.commands()) do
        local sub = cmd.featureName
        if ctx.opt("showShortcuts") and cmd.triggerDesc
            and cmd.triggerDesc ~= "" and cmd.triggerDesc ~= "no trigger" then
            sub = sub .. "  --  " .. cmd.triggerDesc
        end
        choices[#choices + 1] = {
            text     = cmd.label,        -- action label is the primary line
            subText  = sub,              -- feature name (+ its shortcut)
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
                if not choice then return end   -- Escape / dismissed
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

    defaultTrigger = { type = "hotkey", mods = { "cmd", "alt" }, key = "space" },
    action = function(ctx) openPalette(ctx) end,
}
