-- features/site_switcher (display name: "Quick Sites")
--
-- A site JUMPER, not a tab switcher. Each row is a DESTINATION you configured:
-- focus the browser tab already showing it, or open it when absent (generalized
-- from myHammerSpoon modules/misc/miscBindings.lua "locate otter" -- once a
-- single hardcoded site, now a configurable favorites list). This is why it is
-- not grouped with Tab/Window Switcher: those pick among LIVE things that
-- already exist; this one navigates to a fixed favorite, creating it if needed.
--
-- One shortcut pops a searchable chooser (the same picker as Tab Switcher /
-- Clipboard History): type to filter, Up/Down + Enter, click, or cmd+<number>
-- to jump straight to a row (cmd+1 = the top row). Favicons render next to each
-- row (shared cache with Tab Switcher). A single configured site skips the list
-- and jumps straight (the donor's behavior).
--
-- Per-line format ("sites" option, one site per line; all parts optional but
-- the URL):
--     github.com                       -- bare URL; name derived from the domain
--     GitHub | github.com              -- friendly name | URL
--     Gmail | mail.google.com | app    -- ... | app => open as a standalone
--                                         chromeless Chrome APP WINDOW
-- App mode only applies when Chrome is the default browser (the curated browser
-- automation targets Chrome); otherwise an `| app` site silently falls back to a
-- normal tab. A bare-URL line behaves exactly as before (backward compatible).
--
-- The browser automation is a curated seam call (a fixed AppleScript template
-- in the Swift side); first use triggers the macOS Automation permission prompt
-- for controlling Chrome.
--
-- Storage: ONE multiline option, "sites". Each line's tab-match pattern is its
-- domain (minus any leading www.), so config and match can never drift apart.
-- The legacy single-site key "openURL" is migrated one-way: when the list is
-- empty its stored value seeds the one site. (The pre-2026-06-12 "site" key is
-- retired; a stored value under it is simply ignored.)

local getDomain = require("platform.urls").getDomain
local json = require("platform.json")

local CHROME_BUNDLE = "com.google.Chrome"
local FAVICON_URL = "https://%s/favicon.ico"

-- Image magic bytes (PNG / ICO / GIF / JPEG / BMP / RIFF-WEBP): a cached
-- favicon must start like an image or it is ignored (some sites answer
-- /favicon.ico with an HTML page and status 200). Mirrors tab_switcher.
local function looksLikeImage(bytes)
    if not bytes or #bytes < 4 then return false end
    local b4 = bytes:sub(1, 4)
    return b4 == "\137PNG" or b4 == "\0\0\1\0" or b4:sub(1, 3) == "GIF8"
        or bytes:byte(1) == 255 and bytes:byte(2) == 216   -- JPEG
        or b4:sub(1, 2) == "BM" or b4 == "RIFF"
end

-- Give a bare host a scheme: "bing.com" -> "https://bing.com". Without it the
-- open path (`make new tab {URL:"bing.com"}`) creates a dead tab that never
-- navigates, AND getDomain (which needs http) can't read the host.
local function normalizeURL(url)
    if not url:find("://", 1, true) then url = "https://" .. url end
    return url
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function siteName(url)
    return (getDomain(url) or url):gsub("^www%.", "")
end

-- Parse one config line into { url=, name=, app= }. Splits on "|" (URLs never
-- contain it): a trailing "app" token sets app mode; of the remaining parts,
-- a single one is the URL (name derived from the domain), two or more are
-- "Name | URL" (extras ignored). Returns nil for a blank line.
local function parseSite(line)
    local parts = {}
    for p in (line .. "|"):gmatch("(.-)|") do
        local t = trim(p)
        if t ~= "" then parts[#parts + 1] = t end
    end
    if #parts == 0 then return nil end

    local app = false
    if #parts > 1 and parts[#parts]:lower() == "app" then
        app = true
        parts[#parts] = nil
    end
    if #parts == 0 then return nil end   -- a lone "app" token is not a site

    local name, url
    if #parts >= 2 then
        name, url = parts[1], parts[2]
    else
        url = parts[1]
    end
    url = normalizeURL(url)
    if name == nil or name == "" then name = siteName(url) end
    return { url = url, name = name, app = app, browser = "", profile = "" }
end

-- New storage: a JSON array of { name, url, browser, profile, app } records
-- (written by the Settings row editor). Returns nil when `raw` isn't a JSON
-- array, so the caller can fall back to the legacy text format.
local function recordsFromJSON(raw)
    local decoded = json.decode(raw)
    if type(decoded) ~= "table" then return nil end
    local sites = {}
    for _, rec in ipairs(decoded) do
        if type(rec) == "table" and type(rec.url) == "string" and trim(rec.url) ~= "" then
            local url = normalizeURL(trim(rec.url))
            local name = (type(rec.name) == "string" and rec.name ~= "") and rec.name or siteName(url)
            sites[#sites + 1] = {
                url = url, name = name,
                browser = type(rec.browser) == "string" and rec.browser or "",
                profile = type(rec.profile) == "string" and rec.profile or "",
                app = rec.app == true,
            }
        end
    end
    return sites
end

-- The configured sites: the JSON record list when present, else the legacy
-- multiline text (`Name | URL | app`, one per line) or the even older single-URL
-- "openURL" key. One-way migration -- nothing is rewritten until the user edits
-- in Settings (which then saves JSON).
local function configuredSites(ctx)
    local raw = ctx.opt("sites")
    if type(raw) == "string" and raw:match("^%s*%[") then
        local sites = recordsFromJSON(raw)
        if sites then return sites end
    end
    if type(raw) ~= "string" or trim(raw) == "" then
        local legacy = ctx.opt("openURL")
        raw = (type(legacy) == "string" and legacy ~= "") and legacy or ""
    end
    local sites = {}
    for line in (raw .. "\n"):gmatch("(.-)\n") do
        local site = parseSite(line)
        if site then sites[#sites + 1] = site end
    end
    return sites
end

-- Favicons -------------------------------------------------------------------
-- Read-from / fetch-into the cache Tab Switcher already populates, so a favicon
-- either feature pulled shows for both.

local function iconsDir(ctx) return ctx.cacheDir() .. "/favicons" end
local function iconPath(ctx, domain) return iconsDir(ctx) .. "/" .. domain .. ".png" end

local function iconFor(ctx, url)
    local domain = getDomain(url)
    if not domain then return nil end
    local p = iconPath(ctx, domain)
    if ctx.fileExists(p) and looksLikeImage(ctx.fileRead(p)) then
        return "file:" .. p
    end
    return nil
end

-- Fetch any missing favicons in the background (shown on the next open):
-- Chrome's local icon DB first, then the site's own /favicon.ico. `st.fetching`
-- dedupes in-flight downloads across opens.
local function prefetchFavicons(ctx, st, sites)
    ctx.mkdir(iconsDir(ctx))
    local missing, seen = {}, {}
    for _, site in ipairs(sites) do
        local domain = getDomain(site.url)
        if domain and not seen[domain] and not st.fetching[domain]
            and not ctx.fileExists(iconPath(ctx, domain)) then
            seen[domain] = true
            st.fetching[domain] = true
            missing[#missing + 1] = domain
        end
    end
    if #missing == 0 then return end
    ctx.extractFavicons(iconsDir(ctx), missing, function(saved)
        local got = {}
        for _, d in ipairs(saved or {}) do
            got[d] = true
            st.fetching[d] = nil
        end
        for _, d in ipairs(missing) do
            if not got[d] then
                ctx.downloadFile(FAVICON_URL:format(d), iconPath(ctx, d),
                    function() st.fetching[d] = nil end)
            end
        end
    end)
end

-- Jump to a site. Four behaviors, picked by the site's routing:
--   * Chrome, default profile, tab  -> focus the exact existing tab, else open
--     it (the precise AppleScript "jumper" -- the common case).
--   * Chrome, default profile, app  -> focus the existing app window, else open
--     a chromeless app window.
--   * any other browser/profile     -> launch into that browser (and Chrome
--     profile / app window) via the CLI seam. Routing is authoritative;
--     focus-if-already-open is best-effort. Non-Chromium browsers (Safari,
--     Firefox) open a plain tab -- profile/app don't apply.
-- An unset browser falls back to the system default browser.
local function jump(ctx, site)
    local pattern = siteName(site.url)
    if pattern == "" then
        ctx.alert("Not a valid site URL: " .. site.url)
        return
    end
    local browser = (site.browser and site.browser ~= "") and site.browser
        or ctx.defaultBrowser()
    local isChrome = browser == CHROME_BUNDLE
    local hasProfile = site.profile ~= nil and site.profile ~= ""

    if isChrome and not hasProfile and not site.app then
        local found = ctx.focusBrowserTab(pattern, site.url)
        ctx.log(found and ("focused " .. pattern) or ("opened " .. site.url))
    elseif isChrome and not hasProfile and site.app then
        local found = ctx.openSiteApp(pattern, site.url)
        ctx.log(found and ("focused app window " .. pattern)
            or ("opened app window " .. site.url))
    else
        ctx.openSite(browser or "", site.profile or "", site.app == true, site.url)
        ctx.log(("opened %s [%s]%s%s"):format(site.url, browser or "default",
            hasProfile and (" /" .. site.profile) or "",
            site.app and " (app)" or ""))
    end
end

-- One reusable chooser + favicon-fetch state per enablement (a fresh ctx =>
-- fresh state, so a disable/enable cycle never reuses a torn-down handle).
local cached = nil
local function state(ctx)
    if not cached or cached.ctx ~= ctx then
        cached = { ctx = ctx, chooser = nil, fetching = {} }
    end
    return cached
end

return {
    api         = 1,
    id          = "site_switcher",
    name        = "Quick Sites",
    description = "Jump to a favorite site -- focuses its tab if it's already "
        .. "open, opens it if not. Per site, pick the browser, a Chrome profile, "
        .. "and whether to open it as a standalone app window. cmd+<number> "
        .. "jumps straight to a row.",
    version     = "1.4.0",
    category    = "productivity",
    context     = "web",

    options = {
        { key = "sites", type = "siteList", default = "",
          label = "Sites",
          hint = "Each site: a name, its URL, the browser to open it in, a Chrome "
              .. "profile (Chrome only), and whether to open it as a standalone app window." },
    },

    defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "u" },
    mnemonic = "U for URL",

    action = function(ctx)
        local sites = configuredSites(ctx)
        if #sites == 0 then
            ctx.alert("No sites yet -- add one per line in Settings")
            return
        end
        -- One site needs no list: jump straight there (no chooser, no favicons).
        if #sites == 1 then
            jump(ctx, sites[1])
            return
        end

        local st = state(ctx)
        prefetchFavicons(ctx, st, sites)
        if not st.chooser then
            st.chooser = ctx.chooser {
                searchSubText = true,
                onSelect = function(choice)
                    if choice and choice.url then
                        jump(ctx, {
                            url = choice.url, name = choice.text, app = choice.app,
                            browser = choice.browser, profile = choice.profile,
                        })
                    end
                end,
            }
        end
        local choices = {}
        for _, site in ipairs(sites) do
            choices[#choices + 1] = {
                text = site.name, subText = site.url, url = site.url,
                app = site.app, browser = site.browser, profile = site.profile,
                image = iconFor(ctx, site.url),
            }
        end
        st.chooser.setPlaceholder("Jump to site")
        st.chooser.setChoices(choices)
        st.chooser.setQuery(nil)
        st.chooser.show()
    end,
}
