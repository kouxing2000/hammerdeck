-- features/site_switcher (display name: "Quick Sites")
--
-- A site JUMPER, not a tab switcher. Each row is a DESTINATION you configured:
-- focus the browser tab already showing it, or open it when absent (generalized
-- from a binding in the author's prior Hammerspoon config -- once a
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
-- Every configured site is ALSO its own action (the dynamicActions hook below),
-- so it shows up as a row in the menubar's Quick Sites submenu and the command
-- palette, and can take a shortcut of its own -- the no-picker path for the two
-- or three sites you open all day. The picker stays the one action bound by
-- default; the per-site rows ship dormant.
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
local favicons = require("platform.favicons")

local CHROME_BUNDLE = "com.google.Chrome"
local SAFARI_BUNDLE = "com.apple.Safari"

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
    return { id = "", url = url, name = name, app = app, browser = "", profile = "" }
end

-- New storage: a JSON array of { id, name, url, browser, profile, app } records
-- (written by the Settings row editor). Returns nil when `raw` isn't a JSON
-- array, so the caller can fall back to the legacy text format. `id` is the
-- editor's stable per-row UUID -- what a per-site shortcut binds to (see
-- actionKey); a record from an older write has none, and reads as "".
local function recordsFromJSON(raw)
    local decoded = json.decode(raw)
    if type(decoded) ~= "table" then return nil end
    local sites = {}
    for _, rec in ipairs(decoded) do
        if type(rec) == "table" and type(rec.url) == "string" and trim(rec.url) ~= "" then
            local url = normalizeURL(trim(rec.url))
            local name = (type(rec.name) == "string" and rec.name ~= "") and rec.name or siteName(url)
            sites[#sites + 1] = {
                id = type(rec.id) == "string" and rec.id or "",
                url = url, name = name,
                browser = type(rec.browser) == "string" and rec.browser or "",
                profile = type(rec.profile) == "string" and rec.profile or "",
                app = rec.app == true,
            }
        end
    end
    return sites
end

-- The configured sites, from the stored option values: the JSON record list when
-- present, else the legacy multiline text (`Name | URL | app`, one per line) or
-- the even older single-URL "openURL" key. One-way migration -- nothing is
-- rewritten until the user edits in Settings (which then saves JSON).
--
-- Takes the RAW values rather than a ctx, so the register-time dynamicActions
-- hook (which has no ctx -- the registry hands it an option reader) and the live
-- chooser parse a site identically: the menu row and the picker row can never
-- disagree about what a site is. Tolerant by design -- a corrupt value yields an
-- empty list, never an error, because a throw inside the hook would quarantine
-- the whole feature.
---@param raw any     the "sites" option: a JSON array, or the legacy text
---@param legacy any  the retired single-site "openURL" key
local function sitesFromRaw(raw, legacy)
    -- A value that opens with "[" is the JSON format, full stop: if it fails to
    -- decode it yields NO sites rather than falling through to the line parser,
    -- which would read the broken JSON as one absurd site ("https://[{ not json").
    -- The fallback exists for the legacy `Name | URL` text, and that never starts
    -- with a bracket.
    if type(raw) == "string" and raw:match("^%s*%[") then
        return recordsFromJSON(raw) or {}
    end
    if type(raw) ~= "string" or trim(raw) == "" then
        raw = (type(legacy) == "string" and legacy ~= "") and legacy or ""
    end
    local sites = {}
    for line in (raw .. "\n"):gmatch("(.-)\n") do
        local site = parseSite(line)
        if site then sites[#sites + 1] = site end
    end
    return sites
end

---@param ctx Ctx
local function configuredSites(ctx)
    return sitesFromRaw(ctx.opt("sites"), ctx.opt("openURL"))
end

-- The action key for one site (the action id is "site_" .. this). Prefers the
-- record's stable id -- the Settings editor persists a UUID per row -- so a
-- shortcut bound to a site survives renaming it, editing its URL, and reordering
-- the list. A config written before ids (legacy text, or older JSON) falls back
-- to a slug of the URL: stable enough to bind. Non-alphanumerics collapse to "_"
-- because the key becomes part of a settings key
-- (hammerdeck.trigger.site_switcher.site_<key>).
--
-- The slug -> id transition is NOT migrated: when an id-less config gains ids (on
-- the user's next real edit in Settings), a site's key changes from its slug to
-- its UUID, and a shortcut bound to the slug is orphaned rather than carried
-- across. That is why the editor mints ids only on a real edit and never on a
-- read-only visit (see SiteListEditor) -- the transition happens once, when the
-- user is already editing, instead of behind their back.
local function actionKey(site)
    local key = (site.id ~= nil and site.id ~= "") and site.id or site.url
    key = key:gsub("^https?://", ""):gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    return key ~= "" and key or "site"
end

-- Assign every site its action id, in list order: "site_" .. actionKey, with a
-- numeric suffix when two sites share a key (one domain, two Chrome profiles) --
-- a duplicate action id would fail validation and quarantine the whole feature.
-- ONE walk, shared by the dynamicActions hook and the fire-time lookup below, so
-- an id can never name one site at register time and a different one when the
-- action fires.
---@return string[] ids ordered action ids
---@return table byId id -> site record
local function assignActionIds(sites)
    local ids, byId = {}, {}
    for _, site in ipairs(sites) do
        local base = "site_" .. actionKey(site)
        local id, n = base, 1
        while byId[id] do n = n + 1; id = base .. "_" .. n end
        byId[id] = site
        ids[#ids + 1] = id
    end
    return ids, byId
end


-- Jump to a site. Behaviors, picked by the site's routing:
--   * Chrome, default profile, tab  -> focus the exact existing tab, else open
--     it (the precise AppleScript "jumper" -- the common case).
--   * Chrome, default profile, app  -> focus the existing app window, else open
--     a chromeless app window.
--   * Safari, no app                -> focus the existing Safari tab, else open
--     it (Safari's own AppleScript; profile/app don't apply).
--   * anything else (a Chrome profile, app on a non-Chrome browser, Firefox,
--     ...) -> launch into that browser (Chrome profile / app window) via the CLI
--     seam. Routing is authoritative; focus-if-already-open is best-effort.
--     Non-scriptable browsers (Firefox) just open a plain tab.
-- An unset browser falls back to the system default browser.
---@param ctx Ctx
local function jump(ctx, site)
    local pattern = siteName(site.url)
    if pattern == "" then
        ctx.alert(ctx.t("alert.invalidURL", "Not a valid site URL: %s", site.url))
        return
    end
    local browser = (site.browser and site.browser ~= "") and site.browser
        or ctx.defaultBrowser()
    local isChrome = browser == CHROME_BUNDLE
    local isSafari = browser == SAFARI_BUNDLE
    local hasProfile = site.profile ~= nil and site.profile ~= ""

    if isChrome and not hasProfile and not site.app then
        local found = ctx.focusBrowserTab(pattern, site.url)
        ctx.log(found and ("focused " .. pattern) or ("opened " .. site.url))
    elseif isChrome and not hasProfile and site.app then
        local found = ctx.openSiteApp(pattern, site.url)
        ctx.log(found and ("focused app window " .. pattern)
            or ("opened app window " .. site.url))
    elseif isSafari and not site.app then
        local found = ctx.focusSafariTab(pattern, site.url)
        ctx.log(found and ("focused Safari " .. pattern) or ("opened Safari " .. site.url))
    else
        ctx.openSite(browser or "", site.profile or "", site.app == true, site.url)
        ctx.log(("opened %s [%s]%s%s"):format(site.url, browser or "default",
            hasProfile and (" /" .. site.profile) or "",
            site.app and " (app)" or ""))
    end
end

-- One reusable chooser + favicon cache per enablement (a fresh ctx => fresh
-- state, so a disable/enable cycle never reuses a torn-down handle; ctx.perEnable
-- memoizes it on the ctx).
---@param ctx Ctx
local function state(ctx)
    return ctx.perEnable(function(ctx)
        return { chooser = nil, fav = favicons.new(ctx) }
    end)
end

return {
    api         = 1,
    id          = "site_switcher",

    options = {
        { key = "sites", type = "siteList", default = "",
          label = "Sites",
          hint = "Each site: a name, its URL, the browser to open it in, a Chrome "
              .. "profile (Chrome only), and whether to open it as a standalone app window." },
    },

    -- Turn each configured site into its own action, so it gets a row in the
    -- menubar's Quick Sites submenu + the command palette and can take a shortcut
    -- of its own (bind it in the Shortcut Map). Invoked by the REGISTRY at
    -- register time with a reader scoped to this feature's options, so the feature
    -- never touches the seam. Sites ship DORMANT (no defaultTrigger) -- the picker
    -- is the one binding this feature takes uninvited.
    ---@param read fun(key: string): any
    dynamicActions = function(read)
        local out = {}
        local ids, byId = assignActionIds(sitesFromRaw(read("sites"), read("openURL")))
        for _, id in ipairs(ids) do
            out[#out + 1] = {
                id    = id,
                label = byId[id].name,
                -- No live UI context to read -- the destination is configured, not
                -- selected -- so an automated trigger may fire it: "open the
                -- dashboard every weekday morning" is a rule, not a keypress.
                automatable = true,
                ---@param ctx Ctx
                run   = function(ctx)
                    -- Resolve the site when the action FIRES, never from a record
                    -- captured up here. An action set is only re-derived at
                    -- register time, so a closure over the register-time record
                    -- would keep opening the OLD url after the user edits it,
                    -- until something reloaded the catalog -- and the label would
                    -- agree with it, so nothing would look wrong. The picker
                    -- action re-reads the live config on every fire too: one
                    -- answer to "what is a site", not two.
                    local _, live = assignActionIds(configuredSites(ctx))
                    local site = live[id]
                    if not site then
                        -- Deleted, and this leftover action has not been re-derived
                        -- away yet: do nothing rather than open a destination the
                        -- user removed.
                        ctx.log(id .. ": no longer configured, ignoring")
                        return
                    end
                    jump(ctx, site)
                end,
            }
        end
        return out
    end,

    actions = {
        -- The picker. Keeps the id "main" that the single-action sugar used to
        -- synthesize, so a shortcut the user already rebound (stored under
        -- ".main", or the legacy pre-multi-action key) still applies now that the
        -- feature has more than one action.
        { id = "main", label = "Search sites…",
          description = "Open the searchable list of your sites and jump to one.",
          defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "u" },
          mnemonic = "U for URL",
          ---@param ctx Ctx
          run = function(ctx)
            local sites = configuredSites(ctx)
            if #sites == 0 then
                ctx.alert(ctx.t("alert.noSites", "No sites yet -- add one per line in Settings"))
                return
            end
            -- One site needs no list: jump straight there (no chooser, no favicons).
            if #sites == 1 then
                jump(ctx, sites[1])
                return
            end

            local st = state(ctx)
            local urls = {}
            for _, site in ipairs(sites) do urls[#urls + 1] = site.url end
            st.fav.prefetch(urls)
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
                    image = st.fav.iconFor(site.url),
                }
            end
            st.chooser.setPlaceholder(ctx.t("chooser.placeholder", "Jump to site"))
            st.chooser.setChoices(choices)
            st.chooser.setQuery(nil)
            st.chooser.show()
          end },
    },
}
