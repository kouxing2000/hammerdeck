-- features/app_launcher
--
-- Raycast-style installed-app launcher: one hotkey opens a chooser listing
-- every installed .app bundle; type to filter, Enter launches or focuses it.
-- Enumeration is ctx.installedApps -- a plain directory scan in the seam,
-- deliberately NOT Spotlight-backed, so it works when indexing is disabled or
-- broken (the reason this feature exists). The scan is synchronous and cheap,
-- so every open lists what is on disk right now -- no cache to go stale.
-- Most-launched apps sort first (the command_palette frecency pattern, keyed
-- by bundle id).
--
-- Aliases (the `aliases` option) let you type a short name for an app -- "vsc"
-- for Visual Studio Code, "finder" for 访达 on a Chinese-locale Mac. They ride
-- the row's subText because that is the only field the panel filter searches
-- besides the title, so being searchable and being visible are the same thing
-- here.

local json = require("platform.json")

-- bundleId -> "vsc · code", read from the aliasList option (a JSON array of
-- { bundleId, aliases } written by AliasListEditor). Rows sharing a bundle id
-- MERGE rather than overwrite, so a duplicate row costs nothing.
---@param ctx Ctx
---@return table<string, string>
local function aliasIndex(ctx)
    local raw = ctx.opt("aliases")
    if type(raw) ~= "string" or raw == "" then return {} end
    local rows = json.decode(raw)
    if type(rows) ~= "table" then return {} end
    local out = {}
    for _, r in ipairs(rows) do
        if type(r) == "table" and type(r.bundleId) == "string" and r.bundleId ~= ""
                and type(r.aliases) == "table" then
            for _, a in ipairs(r.aliases) do
                if type(a) == "string" and a ~= "" then
                    out[r.bundleId] = out[r.bundleId] and (out[r.bundleId] .. " · " .. a) or a
                end
            end
        end
    end
    return out
end

-- counts: bundleId -> launch count. Tagged as a JSON object so it never
-- serializes as [] -- even empty, even if an older build persisted "[]".
---@param ctx Ctx
local function loadCounts(ctx)
    local raw = ctx.getState("counts")
    if type(raw) == "string" then
        local t = json.decode(raw)
        if type(t) == "table" then return json.asObject(t) end
    end
    return json.asObject({})
end

---@param ctx Ctx
local function bumpCount(ctx, bundleId)
    local counts = loadCounts(ctx)
    counts[bundleId] = (counts[bundleId] or 0) + 1
    -- json.encode returns nil, err on failure; persisting nil would silently
    -- wipe the stored ranking (command_palette's guard, kept on purpose).
    local encoded = json.encode(counts)
    if encoded then
        ctx.setState("counts", encoded)
    else
        ctx.log("could not encode launch counts; ranking left untouched")
    end
end

---@param ctx Ctx
---@param apps { name: string, bundleId: string, path: string }[]
local function buildChoices(ctx, apps)
    local counts, aliases, rows = loadCounts(ctx), aliasIndex(ctx), {}
    for _, a in ipairs(apps) do
        rows[#rows + 1] = { name = a.name, bundleId = a.bundleId,
                            _count = counts[a.bundleId] or 0 }
    end
    -- Most-launched first; ties in case-folded name order, then bundle id, so
    -- the list is fully deterministic and never jumps between opens.
    table.sort(rows, function(a, b)
        if a._count ~= b._count then return a._count > b._count end
        local an, bn = a.name:lower(), b.name:lower()
        if an ~= bn then return an < bn end
        return a.bundleId < b.bundleId
    end)
    local choices = {}
    for _, a in ipairs(rows) do
        -- The bare aliases, with NO label in front of them: subText is a SEARCHED
        -- field, so a prefix like "alias: " would put its own letters in the index
        -- and make every aliased row match "li", "as", "ia"...  -- the more aliases
        -- you set, the worse the launcher would get.
        choices[#choices + 1] = {
            text     = a.name,
            subText  = aliases[a.bundleId],
            image    = ctx.appIcon(a.bundleId),
            bundleId = a.bundleId,   -- Lua-side only; carried back on select
        }
    end
    return choices
end

---@param ctx Ctx
local function openLauncher(ctx)
    local st = ctx.perEnable(function() return { chooser = nil } end)
    if not st.chooser then
        st.chooser = ctx.chooser {
            -- The alias line lives in subText, so searching it IS searching the
            -- aliases -- the panel filter reads no other field.
            searchSubText = true,
            onSelect = function(choice)
                if not choice or not choice.bundleId then return end  -- Esc / info row
                local id, name = choice.bundleId, choice.text
                -- Found is only "still installed"; the launch lands later, and
                -- macOS can still refuse it (an Xcode too old for this macOS).
                -- Frecency counts launches that actually happened.
                local found = ctx.launchOrFocusApp(id, function(ok, reason)
                    if ok then
                        bumpCount(ctx, id)
                        ctx.log("launched", id)
                    else
                        ctx.log("launch refused", id, reason)
                        ctx.alert(reason
                            and ctx.t("alert.launchRefused", "Could not launch %1$s: %2$s", name, reason)
                            or ctx.t("alert.launchFailed", "Could not launch %s", name))
                    end
                end)
                if found then
                    ctx.log("launch", id)
                else
                    -- The id stopped resolving (uninstalled since the open).
                    ctx.log("launch failed, app gone", id)
                    ctx.alert(ctx.t("alert.launchFailed", "Could not launch %s", name))
                end
            end,
        }
    end

    local apps = ctx.installedApps()
    ctx.log("scan", #apps)
    st.chooser.setPlaceholder(ctx.t("chooser.placeholder", "Launch an application"))
    if #apps > 0 then
        st.chooser.setChoices(buildChoices(ctx, apps))
    else
        -- A non-selectable info row beats an empty, confusing panel.
        st.chooser.setChoices({
            { text = ctx.t("empty.title", "No applications found"),
              subText = ctx.t("empty.subtitle", "Nothing found in the Applications folders"),
              valid = false },
        })
    end
    st.chooser.setQuery(nil)
    st.chooser.show()
end

return {
    api = 1,
    id  = "app_launcher",
    -- capabilities (["apps"]) live in feature.json, the declarative file.
    defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "a" },
    mnemonic = "A for App",
    options = {
        { key = "aliases", type = "aliasList", default = "",
          label = "Aliases",
          hint = "Short names you can type to find an app -- \"vsc\" for Visual Studio Code." },
    },
    ---@param ctx Ctx
    action = function(ctx) openLauncher(ctx) end,
}
