-- features/tab_switcher
--
-- The flagship: a searchable switcher across ALL browser tabs (Chrome +
-- Safari), most-recently-focused first (ported from myHammerSpoon
-- modules/window/tabsJumper.lua). Invoke to open; invoke again to cycle;
-- release the cycle modifier to jump. Selecting activates the browser,
-- raises the window, and switches to the tab.
--
-- MRU: every 10s the active browser tab's URL is stamped; stamps persist to
-- <dataDir>/tab_switcher/mru.json (pruned at 30 days) so the ordering
-- survives restarts. After a jump the landed URL is stamped immediately.
--
-- Favicons: cached as <cacheDir>/favicons/<domain>.png and shown next to
-- tabs; missing ones are fetched in the background and appear on the NEXT
-- open. Chrome's local icon DB is tried first (the donor's mechanism: REAL
-- icons, offline, covers sites that declare icons only via <link rel>),
-- then the site's own /favicon.ico for whatever Chrome doesn't know (no
-- third-party service ever sees the browsing domains). Cached files are
-- magic-byte checked before use, so an HTML 200-for-404 page never renders
-- as an icon.
--
-- Donor quirks dropped: the pinned "Filter Tabs" row (typing already
-- filters) and Chrome shortcut-app windows (invisible windows are skipped,
-- same as the donor).

local BROWSERS = {
    { name = "Google Chrome", bundle = "com.google.Chrome" },
    { name = "Safari", bundle = "com.apple.Safari" },
}
local BUNDLE_BY_NAME = {}
for _, b in ipairs(BROWSERS) do BUNDLE_BY_NAME[b.name] = b.bundle end
local POLL_SECONDS = 10
local PRUNE_AGE = 30 * 24 * 3600
local FAVICON_URL = "https://%s/favicon.ico"

-- Image magic bytes (PNG / ICO / GIF / JPEG / BMP / RIFF-WEBP): a cached
-- favicon must start like an image or it is ignored (some sites answer
-- /favicon.ico with an HTML page and status 200).
local function looksLikeImage(bytes)
    if not bytes or #bytes < 4 then return false end
    local b4 = bytes:sub(1, 4)
    return b4 == "\137PNG" or b4 == "\0\0\1\0" or b4:sub(1, 3) == "GIF8"
        or bytes:byte(1) == 255 and bytes:byte(2) == 216   -- JPEG
        or b4:sub(1, 2) == "BM" or b4 == "RIFF"
end

local json = require("platform.json")
local getDomain = require("platform.urls").getDomain
-- Release-to-jump watches the modifier of the hotkey that fired this action
-- (shared with window_switcher; nil when fired without a hotkey -> pick on Enter).
local cycleModifier = require("platform.hotkeys").cycleModifier

local function jumperFor(ctx)
    local st = {
        mru = {},          -- browser name -> { url -> ts }
        choices = nil,     -- cached chooser choices (donor's stale-then-refresh)
        dirty = true,
        chooser = nil,
        altTimer = nil,
        lastActive = {},   -- browser name -> last polled url
        fetching = {},     -- domain -> true (favicon download in flight)
        refreshing = false,
    }

    local dataDir = ctx.dataDir() .. "/tab_switcher"
    local mruPath = dataDir .. "/mru.json"
    local iconsDir = ctx.cacheDir() .. "/favicons"

    -- MRU persistence ---------------------------------------------------------

    local function loadMru()
        local body = ctx.fileRead(mruPath)
        local doc = body and json.decode(body) or nil
        local now = ctx.now()
        for _, b in ipairs(BROWSERS) do
            local m = doc and doc[b.name] or {}
            local kept = {}
            for url, ts in pairs(m) do
                if type(ts) == "number" and now - ts <= PRUNE_AGE then
                    kept[url] = ts
                end
            end
            st.mru[b.name] = kept
        end
    end

    local function saveMru()
        local s = json.encode(st.mru)
        if s then
            ctx.mkdir(dataDir)
            ctx.fileWrite(mruPath, s)
        end
    end

    local function stamp(browser, url)
        if not url or url == "" then return end
        st.mru[browser][url] = ctx.now()
        saveMru()
    end

    -- Favicons ----------------------------------------------------------------

    local function iconPath(domain) return iconsDir .. "/" .. domain .. ".png" end

    -- Validity cache: domain -> true/false (checked once per enablement).
    local iconValid = {}

    local function iconFor(url, bundle)
        local domain = getDomain(url)
        if domain then
            if iconValid[domain] == nil then
                local p = iconPath(domain)
                iconValid[domain] = ctx.fileExists(p)
                    and looksLikeImage(ctx.fileRead(p)) or false
            end
            if iconValid[domain] then return "file:" .. iconPath(domain) end
        end
        return ctx.appIcon(bundle)
    end

    -- Fetch missing favicons in the background (shown on the next open):
    -- Chrome's local icon DB first (REAL icons, offline, covers <link rel>
    -- sites -- the donor's mechanism), then the site's own /favicon.ico for
    -- whatever Chrome doesn't know (e.g. Safari-only sites).
    local function fetchMissingFavicons(urls)
        ctx.mkdir(iconsDir)
        local missing, seen = {}, {}
        for _, url in ipairs(urls) do
            local domain = getDomain(url)
            if domain and not seen[domain] and not st.fetching[domain]
                and not ctx.fileExists(iconPath(domain)) then
                seen[domain] = true
                st.fetching[domain] = true
                missing[#missing + 1] = domain
            end
        end
        if #missing == 0 then return end
        ctx.extractFavicons(iconsDir, missing, function(saved)
            local got = {}
            for _, d in ipairs(saved or {}) do
                got[d] = true
                iconValid[d] = nil          -- re-validate on next open
                st.fetching[d] = nil
            end
            ctx.log("favicons: " .. #(saved or {}) .. "/" .. #missing
                .. " from the Chrome icon DB")
            for _, d in ipairs(missing) do
                if not got[d] then
                    ctx.downloadFile(FAVICON_URL:format(d), iconPath(d),
                        function(okDl)
                            st.fetching[d] = nil
                            iconValid[d] = nil
                            if not okDl then
                                ctx.log("favicon fetch failed: " .. d)
                            end
                        end)
                end
            end
        end)
    end

    -- Choices -----------------------------------------------------------------

    local function sortChoices(list)
        table.sort(list, function(a, b) return a.ts > b.ts end)
        return list
    end

    -- List every running browser's tabs, then cb(choices). Async fan-in.
    local function buildChoices(cb)
        local active = {}
        for _, b in ipairs(BROWSERS) do
            if ctx.isAppRunning(b.name) then active[#active + 1] = b end
        end
        if #active == 0 then return cb({}) end

        local out, pending = {}, #active
        for _, b in ipairs(active) do
            ctx.browserListTabs(b.name, function(tabs)
                for _, tab in ipairs(tabs or {}) do
                    if tab.visible ~= false and tab.url and tab.url ~= "" then
                        local title = tab.title ~= "" and tab.title or tab.url
                        if b.name == "Safari" then title = "[Safari] " .. title end
                        out[#out + 1] = {
                            text = title,
                            subText = tab.url,
                            image = iconFor(tab.url, b.bundle),
                            id = b.name .. "|" .. tab.winId .. "|" .. tab.tabIndex,
                            browser = b.name,
                            winId = tab.winId,
                            tabIndex = tab.tabIndex,
                            ts = st.mru[b.name][tab.url] or 0,
                        }
                    end
                end
                pending = pending - 1
                if pending == 0 then cb(sortChoices(out)) end
            end)
        end
    end

    local function refreshChoices(done)
        if st.refreshing then return end
        st.refreshing = true
        buildChoices(function(choices)
            st.refreshing = false
            st.choices = choices
            st.dirty = false
            local urls = {}
            for _, c in ipairs(choices) do urls[#urls + 1] = c.subText end
            fetchMissingFavicons(urls)
            if done then done() end
        end)
    end

    -- Jumping -----------------------------------------------------------------

    local function onPick(choice)
        if not choice then return end
        ctx.browserFocusTab(choice.browser, choice.winId, choice.tabIndex,
            function(url)
                if not url then
                    -- The tab moved or closed since listing: relist and say so.
                    ctx.alert("That tab moved -- try again")
                    refreshChoices()
                    return
                end
                stamp(choice.browser, url)
                choice.ts = ctx.now()
                if getDomain(url) ~= getDomain(choice.subText) then
                    st.dirty = true   -- the tab navigated away; relist next open
                else
                    choice.subText = url
                end
                if st.choices then sortChoices(st.choices) end
            end)
    end

    local function stopAltTimer()
        if st.altTimer then st.altTimer.stop(); st.altTimer = nil end
    end

    -- Release-to-jump: poll the cycle modifier while cycling (window_switcher's
    -- pattern, donor's autoJump). st.cycleMod is derived from the trigger
    -- that fired (set in open()).
    local function armAutoJump()
        local mod = st.cycleMod
        if not mod or st.altTimer or not ctx.isModifierHeld(mod) then return end
        st.altTimer = ctx.everySeconds(0.1, function()
            if not ctx.isModifierHeld(mod) then
                stopAltTimer()
                st.chooser.select(st.chooser.getSelectedRow())
            end
        end)
    end

    local function showChooser()
        -- Icons resolve at SHOW time: a favicon that landed after the last
        -- tab relist upgrades its rows on the next open -- no relist needed
        -- (otherwise cached choices keep their stale app-icon tokens).
        for _, c in ipairs(st.choices) do
            c.image = iconFor(c.subText, BUNDLE_BY_NAME[c.browser])
        end
        st.chooser.setPlaceholder("Search tabs")
        st.chooser.setChoices(st.choices)
        st.chooser.setQuery(nil)
        st.chooser.show()
        if #st.choices >= 2 then st.chooser.setSelectedRow(2) end
        armAutoJump()
    end

    function st.open(actionId, backward)
        st.cycleMod = cycleModifier(ctx.actionTrigger(actionId))
        if not st.chooser then
            st.chooser = ctx.chooser {
                searchSubText = true,
                onHide = function() stopAltTimer() end,
                onSelect = function(choice)
                    stopAltTimer()
                    onPick(choice)
                end,
            }
        end

        if st.chooser.isVisible() then
            -- Repeat invocation: cycle (wrap against the visible rows).
            st.chooser.setPlaceholder(st.cycleMod
                and ("Release " .. st.cycleMod .. " to jump")
                or "Press Enter to jump")
            local row = st.chooser.getSelectedRow() + (backward and -1 or 1)
            st.chooser.setSelectedRow(row)
            if st.chooser.getSelectedRow() ~= row then
                st.chooser.setSelectedRow(backward and #st.choices or 1)
            end
            armAutoJump()
            return
        end

        if not st.choices then
            ctx.alert("Loading tabs...")
            refreshChoices(showChooser)
        elseif st.dirty then
            -- Show the stale list instantly, refresh behind it (donor UX).
            showChooser()
            refreshChoices(function()
                if st.chooser.isVisible() then st.chooser.setChoices(st.choices) end
            end)
        else
            showChooser()
        end
    end

    -- Service: MRU poll -------------------------------------------------------

    loadMru()
    ctx.everySeconds(POLL_SECONDS, function()
        local front = ctx.frontmostApp()
        for _, b in ipairs(BROWSERS) do
            if b.name == front then
                local url = ctx.browserActiveURL(b.name)
                if url and url ~= st.lastActive[b.name] then
                    st.lastActive[b.name] = url
                    stamp(b.name, url)
                    st.dirty = true
                end
                return
            end
        end
    end)
    ctx.log("started (MRU entries loaded)")

    return st
end

local cached = nil
local function with(ctx)
    if not cached or cached.ctx ~= ctx then
        cached = { ctx = ctx, st = jumperFor(ctx) }
    end
    return cached.st
end

return {
    api         = 1,
    id          = "tab_switcher",
    name        = "Tab Switcher",
    description = "Searchable switcher across all Chrome + Safari tabs, "
        .. "most recently used first, with favicons.",
    version     = "1.1.0",
    category    = "productivity",

    options = {},

    start = function(ctx) with(ctx) end,

    actions = {
        { id = "open", label = "Switch to a tab",
          defaultTrigger = { type = "hotkey", mods = { "ctrl", "alt" }, key = "tab" },
          run = function(ctx) with(ctx).open("open", false) end },
        { id = "open_backward", label = "Cycle backward",
          defaultTrigger = { type = "hotkey", mods = { "ctrl", "alt" }, key = "`" },
          run = function(ctx) with(ctx).open("open_backward", true) end },
    },
}
