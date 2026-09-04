-- features/tab_switcher
--
-- The flagship: a searchable switcher across ALL browser tabs (Chrome +
-- Safari), most-recently-focused first (ported from the author's prior
-- Hammerspoon config). Invoke to open; invoke again to cycle;
-- release the cycle modifier to jump. Selecting activates the browser,
-- raises the window, and switches to the tab.
--
-- MRU: every 3s the active browser tab's URL is stamped (real web pages only --
-- favorites://, chrome://, error pages never rank); stamps persist to
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
-- 3s, so even a short look at a tab gets sampled (10s missed quick visits and
-- the tab then ranked as never-seen). The tick itself is one cheap native
-- frontmost-app read; the AppleScript url read runs ONLY while a browser is
-- frontmost, so the shorter interval costs nothing when not browsing.
local POLL_SECONDS = 3
local PRUNE_AGE = 30 * 24 * 3600

local json = require("platform.json")
local getDomain = require("platform.urls").getDomain
local favicons = require("platform.favicons")
-- Release-to-jump watches the modifier of the hotkey that fired this action
-- (shared with window_switcher; nil when fired without a hotkey -> pick on Enter).
local cycleModifier = require("platform.hotkeys").cycleModifier
-- Shared release-to-pick mechanics (also drives window_switcher).
local cyclingChooser = require("platform.cyclingChooser")

---@param ctx Ctx
local function jumperFor(ctx)
    local st = {
        mru = {},          -- browser name -> { url -> ts }
        choices = nil,     -- the list currently shown / shown next (stable per open)
        pending = nil,     -- fresh list staged by a background relist, for the NEXT open
        chooser = nil,
        altTimer = nil,
        lastActive = {},   -- browser name -> last polled url
        urlReading = {},   -- browser name -> true while an active-url read is in flight
        refreshing = false,
    }

    local dataDir = ctx.dataDir() .. "/tab_switcher"
    local mruPath = dataDir .. "/mru.json"
    local fav = favicons.new(ctx)   -- shared favicon cache (see platform.favicons)

    -- MRU persistence ---------------------------------------------------------

    local function loadMru()
        local body = ctx.fileRead(mruPath)
        local doc = body and json.decode(body) or nil
        local now = ctx.now()
        for _, b in ipairs(BROWSERS) do
            local m = doc and doc[b.name] or {}
            local kept = {}
            for url, ts in pairs(m) do
                -- The scheme check also self-cleans junk stamped before the
                -- guard in stamp() existed (favorites://, safari-resource:).
                if type(ts) == "number" and now - ts <= PRUNE_AGE
                    and url:find("^https?://") then
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
        -- Web pages only, by SCHEME: favorites://, chrome://, safari-resource:
        -- error pages etc. must never earn an MRU rank. Deliberately NOT
        -- getDomain (it also rejects localhost -- a dev's http://localhost:3000
        -- is a real page and must keep ranking).
        if not url:find("^https?://") then return end
        st.mru[browser][url] = ctx.now()
        saveMru()
    end

    -- Favicons: a "file:<domain>.png" icon token when cached, else the browser's
    -- app icon. `fav.prefetch` fills the shared cache (Chrome's icon DB first,
    -- then /favicon.ico) -- see platform.favicons.
    local function iconFor(url, bundle)
        return fav.iconFor(url, ctx.appIcon(bundle))
    end

    -- Choices -----------------------------------------------------------------

    local function sortChoices(list)
        -- MRU-desc, with a stable tie-break by text: Lua's table.sort is NOT stable,
        -- and now that we re-sort on every show, unstamped tabs (ts == 0) would
        -- otherwise shuffle order between opens.
        table.sort(list, function(a, b)
            if a.ts ~= b.ts then return a.ts > b.ts end
            return a.text < b.text
        end)
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
                        if b.name == "Safari" then title = ctx.t("row.safariPrefix", "[Safari] %s", title) end
                        out[#out + 1] = {
                            text = title,
                            subText = tab.url,
                            image = iconFor(tab.url, b.bundle),
                            browser = b.name,
                            -- Stable identity for re-resolution at pick time:
                            -- Chrome's tab id survives reorder / close-before /
                            -- window-move; Safari has none (0), so the pick falls
                            -- back to the url with winId as a tie-break hint, and
                            -- the listed (winId, tabIndex) as the resolver's
                            -- last-resort tertiary (an in-place navigation).
                            tabId = tab.id or 0,
                            winId = tab.winId,
                            tabIndex = tab.tabIndex or 0,
                            ts = st.mru[b.name][tab.url] or 0,
                        }
                    end
                end
                pending = pending - 1
                if pending == 0 then cb(sortChoices(out)) end
            end)
        end
    end

    -- Rebuild the tab list, then hand the fresh choices to `apply`, which decides
    -- WHERE they land. Two callers, two sinks: the loading path installs them as the
    -- LIVE list and shows; a background refresh STAGES them in st.pending for the NEXT
    -- open. A background relist must NEVER setChoices the visible chooser -- that runs
    -- ChooserPanel.applyFilter -> selectFirstValid, resetting the selection to row 1,
    -- which would yank release-to-jump onto the wrong tab mid-hold. st.refreshing
    -- serializes overlapping relists.
    local function relist(apply)
        if st.refreshing then return end
        st.refreshing = true
        buildChoices(function(choices)
            st.refreshing = false
            local urls = {}
            for _, c in ipairs(choices) do urls[#urls + 1] = c.subText end
            fav.prefetch(urls)
            apply(choices)
        end)
    end

    -- Jumping -----------------------------------------------------------------

    local function onPick(choice)
        if not choice then return end
        -- Re-resolve by STABLE IDENTITY (id first, else url + winId hint), searching
        -- all windows. Position is never primary identity (it drifts on any tab
        -- churn) -- the listed (winId, tabIndex) rides along only as the resolver's
        -- last-resort tertiary, for a Safari tab that navigated in place since
        -- listing (no id, url changed; its position is all that's left).
        ctx.browserFocusTab(choice.browser, choice.tabId or 0, choice.winId, choice.subText,
            choice.tabIndex or 0,
            function(url, via)
                if not url then
                    -- The tab is genuinely gone since listing: stage a relist for the
                    -- next open and say so. Log the DOMAIN only -- a full url (incognito
                    -- included) must not land in the on-disk logs.
                    ctx.log(string.format("jump miss (moved/closed): %s %s",
                        choice.browser, getDomain(choice.subText) or "?"))
                    ctx.alert(ctx.t("alert.tabMoved", "That tab moved -- try again"))
                    relist(function(choices) st.pending = choices end)
                    return
                end
                ctx.log(string.format("jump ok via %s (%s): %s", choice.browser,
                    via or "?", getDomain(url) or "?"))
                stamp(choice.browser, url)   -- MRU rank; showChooser re-ranks from it
                -- `and d` first: getDomain returns nil for anything it will not
                -- vouch for (localhost, a port, an IPv6 literal), and two nils
                -- compare EQUAL -- which would call two unrelated URLs the same
                -- site and stamp one of them onto the other's row. An unknown
                -- domain is not a match with another unknown domain.
                local d = getDomain(url)
                if d and d == getDomain(choice.subText) then
                    choice.subText = url   -- same site: refresh the exact url on the row
                end
                -- (a domain change is picked up by the next open's background relist)
            end)
    end

    -- Release-to-jump: poll the cycle modifier (donor's autoJump). Arms on OPEN
    -- too (the held-modifier preview -- both switchers do, since 2026-07-20),
    -- gated on the modifier actually being held before arming -- a fire with
    -- no modifier held (menubar / chord) must wait for Enter, not jump instantly.
    -- st.cycleMod is derived from the trigger that fired (set in open()).
    local function armAutoJump()
        local mod = st.cycleMod
        if not mod or not ctx.isModifierHeld(mod) then return end
        -- Armed = releasing will jump; say so (otherwise the open path's
        -- "Search tabs" placeholder lies during a held-modifier preview).
        st.chooser.setPlaceholder(
            ctx.t("chooser.releaseToJump", "Release %s to jump · type to filter · ⇧⇥ back", mod))
        cyclingChooser.armRelease(ctx, st.chooser, st, mod)
    end

    local function showChooser()
        -- Icons AND MRU rank resolve at SHOW time, so the order reflects the CURRENT
        -- state no matter which list is showing (cached, or one promoted from
        -- st.pending): a favicon that landed since upgrades its row, and the last
        -- jump's restamp floats that tab to the top. The ts refresh is load-bearing
        -- for the flick-to-previous gesture -- a promoted list carries the ts values
        -- from when it was BUILT (possibly pre-jump), so without re-ranking here row
        -- 2 would not be the tab you were just on.
        for _, c in ipairs(st.choices) do
            c.image = iconFor(c.subText, BUNDLE_BY_NAME[c.browser])
            c.ts = st.mru[c.browser][c.subText] or 0
        end
        sortChoices(st.choices)
        st.chooser.setPlaceholder(ctx.t("chooser.placeholder", "Search tabs"))
        st.chooser.setChoices(st.choices)
        st.chooser.setQuery(nil)
        st.chooser.show()
        if #st.choices >= 2 then st.chooser.setSelectedRow(2) end
        -- Tap grace: a release within the first ticks keeps the panel open
        -- (filter mode) instead of jumping -- see cyclingChooser.armRelease.
        st.releaseGrace = 3
        armAutoJump()
    end

    function st.open(actionId)
        st.cycleMod = cycleModifier(ctx.actionTrigger(actionId))
        if not st.chooser then
            st.chooser = ctx.chooser {
                searchSubText = true,
                onHide = function() cyclingChooser.stop(st) end,
                onSelect = function(choice)
                    cyclingChooser.stop(st)
                    onPick(choice)
                end,
            }
        end

        if st.chooser.isVisible() then
            -- Repeat invocation: cycle forward (backward is the panel's own
            -- shift+tab / option+arrows; the panel wraps the visible rows).
            st.chooser.setPlaceholder(st.cycleMod
                and ctx.t("chooser.releaseToJump", "Release %s to jump · type to filter · ⇧⇥ back", st.cycleMod)
                or ctx.t("chooser.pressEnter", "Press Enter to jump"))
            st.chooser.step(1)
            st.releaseGrace = 0   -- cycling expressed intent: release commits at once
            armAutoJump()
            return
        end

        if not st.choices then
            ctx.alert(ctx.t("alert.loading", "Loading tabs..."))
            relist(function(choices) st.choices = choices; showChooser() end)
        else
            -- Promote any completed background relist BEFORE showing, then show the
            -- cached list -- which stays STABLE for this entire interaction (never
            -- swapped under the user). Kick a fresh relist for the NEXT open, staged
            -- into st.pending. So a closed/opened tab self-heals one open later
            -- WITHOUT ever moving the live selection (stable-id resolution already
            -- makes a pick from a slightly-stale list land correctly).
            if st.pending then st.choices = st.pending; st.pending = nil end
            showChooser()
            relist(function(choices) st.pending = choices end)
        end
    end

    -- Service: MRU poll -------------------------------------------------------

    loadMru()
    ctx.everySeconds(POLL_SECONDS, function()
        local front = ctx.frontmostApp()
        for _, b in ipairs(BROWSERS) do
            if b.name == front then
                -- Async (a subprocess read -- the sync form blocked the main
                -- thread for ~1s per call; see the seam comment in
                -- Native+Browser).
                --
                -- SERIALIZED per browser, the same way relist guards itself with
                -- st.refreshing. Without this the poll fires every POLL_SECONDS
                -- while a read may live up to the runJXA watchdog, so a slow
                -- browser accumulates concurrent subprocesses AND their answers can
                -- land OUT OF ORDER -- an older url then wins the `~= lastActive`
                -- test and gets stamped with a fresh timestamp, inverting the very
                -- MRU ranking this poll exists to maintain. One in flight at a time
                -- makes ordering impossible to violate; the callback always fires
                -- (or is dropped wholesale on teardown), so the flag cannot stick.
                if st.urlReading[b.name] then return end
                st.urlReading[b.name] = true
                ctx.browserActiveURL(b.name, function(url)
                    st.urlReading[b.name] = nil
                    -- Re-check the front app: the user may have switched away
                    -- mid-flight, and stamping then would record a tab they are no
                    -- longer looking at.
                    if ctx.frontmostApp() ~= b.name then return end
                    if url and url ~= st.lastActive[b.name] then
                        st.lastActive[b.name] = url
                        stamp(b.name, url)
                    end
                end)
                return
            end
        end
    end)
    ctx.log("started (MRU entries loaded)")

    return st
end

---@param ctx Ctx
local function with(ctx)
    return ctx.perEnable(jumperFor)
end

return {
    api         = 1,
    id          = "tab_switcher",

    options = {},

    ---@param ctx Ctx
    start = function(ctx) with(ctx) end,

    actions = {
        { id = "open", label = "Switch to a tab", icon = "rectangle.stack",
          description = "Tap to browse -- type to filter, Enter to jump. Hold and "
              .. "release once the panel shows to jump straight to the previous "
              .. "tab. Press again to cycle; ⇧Tab steps back.",
          defaultTrigger = { type = "hotkey", mods = { "ctrl", "alt" }, key = "tab" },
          mnemonic = "⌃⌥Tab — the window-switch keys + Ctrl, for tabs",
          ---@param ctx Ctx
          run = function(ctx) with(ctx).open("open") end },
    },
}
