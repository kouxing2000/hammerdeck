-- test/cases/site_switcher.lua -- site_switcher / "Quick Sites": a searchable chooser of
-- favorite sites; pick a row (click, Enter, or cmd+<n>) to focus that site's tab, open
-- it, or open it as a standalone app window. Covers the chooser list + subtext, single-
-- site straight-jump, no-match fallback, scheme-less normalization, the legacy openURL
-- migration, `Name | URL [| app]` parsing + favicons, per-site browser/profile routing
-- (plain + JSON storage), Safari's focus-tab path, and the empty-config hint.
--
-- Migrated from run.lua T23 (RUN_LUA_SPLIT_SPEC Phase 2). Hermetic: registers its own
-- feature and seeds its own site list / tabs per assertion; freshWorld() before + handle
-- tripwire after keep it isolated. Dropped the trailing favicon-recorder scrub the
-- monolith did for later sections -- freshWorld() gives every case a pristine world.

return {
    id = "site_switcher",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        registry.register(require("features.site_switcher"))
        registry.setEnabled("site_switcher", true)

        -- several sites: the shortcut pops a chooser listing them (domain text, url sub)
        fake.settings["hammerdeck.opt.site_switcher.sites"] =
            "https://www.otter.ai/\nhttps://github.com/\n"
        fake.browserTabs = { "https://github.com/x", "https://www.otter.ai/meetings" }
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        local ch = fake.visibleChooser()
        ok(ch ~= nil and #ch.choices == 2
            and ch.choices[1].text == "otter.ai"
            and ch.choices[1].subText == "https://www.otter.ai/"
            and ch.choices[2].text == "github.com",
            "the shortcut pops a chooser of the sites (domain text, url subtext)")
        ch.userSelect(1)
        ok(fake.focusedTabs[#fake.focusedTabs] == "https://www.otter.ai/meetings",
            "picking row 1 focuses the first site's tab")
        ok(fake.visibleChooser() == nil, "the chooser closes after a pick")

        -- a later row (what cmd+2 / arrow+Enter resolves to) jumps to its site
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        fake.visibleChooser().userSelect(2)
        ok(fake.focusedTabs[#fake.focusedTabs] == "https://github.com/x",
            "picking row 2 focuses the second site's tab")

        -- dismissing the chooser (Escape -> onSelect(nil)) jumps nothing
        local focusedCount = #fake.focusedTabs
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        fake.visibleChooser().userSelect(0)   -- out-of-range = dismissed
        ok(#fake.focusedTabs == focusedCount, "dismissing the chooser jumps nothing")

        -- a single configured site skips the list and jumps straight (donor behavior)
        fake.settings["hammerdeck.opt.site_switcher.sites"] = "https://github.com/"
        fake.browserTabs = { "https://github.com/x" }
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        ok(fake.visibleChooser() == nil
            and fake.focusedTabs[#fake.focusedTabs] == "https://github.com/x",
            "one site needs no list -- jumps straight")

        -- no match opens the fallback URL in a new tab
        fake.settings["hammerdeck.opt.site_switcher.sites"] = "https://www.otter.ai/"
        fake.browserTabs = { "https://github.com/x" }
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        ok(fake.openedNewTabs[#fake.openedNewTabs] == "https://www.otter.ai/",
            "no match opens the fallback URL")

        -- a scheme-less entry is normalized to https:// so it actually navigates
        -- (the "opened bing.com" dead-tab bug)
        fake.settings["hammerdeck.opt.site_switcher.sites"] = "bing.com"
        fake.browserTabs = {}
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        ok(fake.openedNewTabs[#fake.openedNewTabs] == "https://bing.com",
            "a scheme-less site gets https:// before opening (no more dead tab)")

        -- the legacy single-URL key seeds the one site when the list is empty
        fake.settings["hammerdeck.opt.site_switcher.sites"] = nil
        fake.settings["hammerdeck.opt.site_switcher.openURL"] = "https://www.otter.ai/"
        fake.browserTabs = { "https://www.otter.ai/meetings" }
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        ok(fake.focusedTabs[#fake.focusedTabs] == "https://www.otter.ai/meetings",
            "the legacy openURL migrates as the one site when the list is empty")
        fake.settings["hammerdeck.opt.site_switcher.openURL"] = nil

        -- a `Name | URL` line shows the friendly name (URL as subtext), with a favicon
        -- once it is cached
        fake.settings["hammerdeck.opt.site_switcher.openURL"] = nil
        fake.chromeFavicons = { ["github.com"] = true }
        fake.settings["hammerdeck.opt.site_switcher.sites"] =
            "GitHub | github.com\nGmail | mail.google.com"
        fake.browserTabs = {}
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        local nc = fake.visibleChooser()
        ok(nc ~= nil and nc.choices[1].text == "GitHub"
            and nc.choices[1].subText == "https://github.com"
            and nc.choices[2].text == "Gmail",
            "a `Name | URL` line shows the friendly name (URL as subtext)")
        ok(nc.choices[1].image == "file:/tmp/hammerdeck-fake-cache/favicons/github.com.png",
            "a cached favicon renders next to its row")
        nc.userSelect(0)   -- dismiss

        -- `| app` opens a standalone Chrome app window when Chrome is the default browser
        fake.defaultBrowserBundle = "com.google.Chrome"
        fake.settings["hammerdeck.opt.site_switcher.sites"] = "Gmail | mail.google.com | app"
        fake.browserTabs = {}
        fake.appWindows = {}
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        ok(fake.visibleChooser() == nil
            and fake.appWindows[#fake.appWindows] == "https://mail.google.com",
            "an `| app` site with no open tab opens a standalone app window")

        -- an already-open app site is focused, not relaunched
        fake.appWindows = {}
        fake.browserTabs = { "https://mail.google.com/u/0/inbox" }
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        ok(#fake.appWindows == 0
            and fake.focusedTabs[#fake.focusedTabs] == "https://mail.google.com/u/0/inbox",
            "an open app site is focused instead of relaunched")

        -- when the resolved browser isn't Chrome, an app site routes through openSite to
        -- that browser (which opens a plain tab -- app/profile don't apply there)
        fake.defaultBrowserBundle = "com.apple.Safari"
        fake.appWindows = {}
        fake.siteOpens = {}
        fake.browserTabs = {}
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        ok(#fake.appWindows == 0
            and fake.siteOpens[#fake.siteOpens] ~= nil
            and fake.siteOpens[#fake.siteOpens].bundleId == "com.apple.Safari"
            and fake.siteOpens[#fake.siteOpens].url == "https://mail.google.com",
            "an app site whose browser isn't Chrome routes through openSite (no app window)")
        fake.defaultBrowserBundle = "com.google.Chrome"
        fake.chromeFavicons = {}

        -- JSON storage with per-site browser + Chrome profile routing
        fake.settings["hammerdeck.opt.site_switcher.sites"] =
            '[{"name":"Otter","url":"otter.ai","browser":"com.google.Chrome","profile":"Profile 2","app":true},'
            .. '{"name":"News","url":"news.ycombinator.com","browser":"org.mozilla.firefox"}]'
        fake.browserTabs = {}
        fake.siteOpens = {}
        fake.appWindows = {}
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        local jc = fake.visibleChooser()
        ok(jc ~= nil and jc.choices[1].text == "Otter" and jc.choices[2].text == "News",
            "JSON site records render as named rows")
        jc.userSelect(1)   -- Otter: Chrome + a non-default profile + app -> routed launch
        ok(#fake.siteOpens == 1
            and fake.siteOpens[1].bundleId == "com.google.Chrome"
            and fake.siteOpens[1].profile == "Profile 2"
            and fake.siteOpens[1].app == true
            and fake.siteOpens[1].url == "https://otter.ai",
            "a Chrome-profile app site routes through openSite with the profile + app flag")
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        fake.visibleChooser().userSelect(2)   -- News: Firefox (non-scriptable) -> openSite tab
        ok(#fake.siteOpens == 2
            and fake.siteOpens[2].bundleId == "org.mozilla.firefox"
            and fake.siteOpens[2].app == false
            and fake.siteOpens[2].url == "https://news.ycombinator.com",
            "a site routed to a non-scriptable browser opens via openSite")

        -- a Safari-routed site (no app) focuses its existing Safari tab via focusSafariTab
        -- (NOT openSite), and opens it when absent
        fake.settings["hammerdeck.opt.site_switcher.sites"] =
            '[{"name":"News","url":"news.ycombinator.com","browser":"com.apple.Safari"}]'
        fake.browserTabs = { "https://news.ycombinator.com/item?id=1" }
        fake.siteOpens = {}
        fake.focusedTabs = {}
        fake.openedNewTabs = {}
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })   -- one site -> jumps straight
        ok(#fake.siteOpens == 0
            and fake.focusedTabs[#fake.focusedTabs] == "https://news.ycombinator.com/item?id=1",
            "a Safari-routed site focuses its open Safari tab (not openSite)")
        fake.browserTabs = {}
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        ok(fake.openedNewTabs[#fake.openedNewTabs] == "https://news.ycombinator.com",
            "a Safari-routed site with no open tab opens it")

        -- no sites at all -> a clear hint, not silence
        fake.settings["hammerdeck.opt.site_switcher.sites"] = nil
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        ok(fake.alerts[#fake.alerts]:match("No sites yet") ~= nil,
            "empty config alerts instead of doing nothing")

        registry.setEnabled("site_switcher", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after site_switcher test")
    end,
}
