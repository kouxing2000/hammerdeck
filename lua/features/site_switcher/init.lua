-- features/site_switcher
--
-- Jump to a website: focus the browser tab whose URL matches a site, or open
-- it in a new tab when absent (generalized from myHammerSpoon
-- modules/misc/miscBindings.lua "locate otter" -- once a single hardcoded
-- site, now a configurable list).
--
-- Configure a LIST of favorite sites (one URL per line). One shortcut pops a
-- searchable chooser (the same picker as Tab Jump / Clipboard History): type
-- to filter, Up/Down + Enter, click, or cmd+<number> to jump straight to a row
-- (cmd+1 = the top row). A single configured site skips the list and jumps
-- straight (the donor's behavior).
--
-- The browser automation is a curated seam call (a fixed AppleScript template
-- in the Swift side); first use triggers the macOS Automation permission
-- prompt for controlling Chrome.
--
-- Storage: ONE multiline option, "sites". Each line's tab-match pattern is its
-- domain (minus any leading www.), so config and match can never drift apart.
-- The legacy single-site key "openURL" is migrated one-way: when the list is
-- empty its stored value seeds the one site. (The pre-2026-06-12 "site" key is
-- retired; a stored value under it is simply ignored.)

local getDomain = require("platform.urls").getDomain

-- Give a bare host a scheme: "bing.com" -> "https://bing.com". Without it the
-- open path (`make new tab {URL:"bing.com"}`) creates a dead tab that never
-- navigates, AND getDomain (which needs http) can't read the host.
local function normalizeURL(url)
    if not url:find("://", 1, true) then url = "https://" .. url end
    return url
end

local function parseSites(raw)
    local list = {}
    for line in ((raw or "") .. "\n"):gmatch("(.-)\n") do
        local s = line:gsub("^%s+", ""):gsub("%s+$", "")
        if s ~= "" then list[#list + 1] = s end
    end
    return list
end

-- The configured sites (each normalized to carry a scheme), falling back to the
-- legacy single-URL key when the list is empty (one-way migration; nothing is
-- rewritten).
local function configuredSites(ctx)
    local list = parseSites(ctx.opt("sites"))
    if #list == 0 then
        local legacy = ctx.opt("openURL")
        if type(legacy) == "string" and legacy ~= "" then list[1] = legacy end
    end
    for i, url in ipairs(list) do list[i] = normalizeURL(url) end
    return list
end

local function siteName(url)
    return (getDomain(url) or url):gsub("^www%.", "")
end

local function jump(ctx, url)
    local pattern = siteName(url)
    if pattern == "" then
        ctx.alert("Not a valid site URL: " .. url)
        return
    end
    local found = ctx.focusBrowserTab(pattern, url)
    ctx.log(found and ("focused " .. pattern) or ("opened " .. url))
end

-- One reusable chooser per enablement (a fresh ctx => fresh chooser, so a
-- disable/enable cycle never reuses a torn-down handle).
local cached = nil
local function picker(ctx)
    if not cached or cached.ctx ~= ctx then
        cached = { ctx = ctx, chooser = nil }
    end
    return cached
end

return {
    api         = 1,
    id          = "site_switcher",
    name        = "Site Switcher",
    description = "Pop a searchable list of your favorite sites; pick one to "
        .. "focus its tab (or open it). cmd+<number> jumps straight to a row.",
    version     = "1.3.0",
    category    = "productivity",
    context     = "web",

    options = {
        { key = "sites", type = "string", multiline = true, default = "",
          label = "Sites (one URL per line)" },
    },

    defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "u" },
    mnemonic = "U for URL",

    action = function(ctx)
        local sites = configuredSites(ctx)
        if #sites == 0 then
            ctx.alert("No sites yet -- add one URL per line in Settings")
            return
        end
        -- One site needs no list: jump straight there.
        if #sites == 1 then
            jump(ctx, sites[1])
            return
        end

        local p = picker(ctx)
        if not p.chooser then
            p.chooser = ctx.chooser {
                searchSubText = true,
                onSelect = function(choice)
                    if choice and choice.url then jump(ctx, choice.url) end
                end,
            }
        end
        local choices = {}
        for _, url in ipairs(sites) do
            choices[#choices + 1] = { text = siteName(url), subText = url, url = url }
        end
        p.chooser.setPlaceholder("Jump to site")
        p.chooser.setChoices(choices)
        p.chooser.setQuery(nil)
        p.chooser.show()
    end,
}
