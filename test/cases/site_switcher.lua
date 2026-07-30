-- test/cases/site_switcher.lua -- site_switcher / "Quick Sites": a searchable chooser of
-- favorite sites; pick a row (click, Enter, or cmd+<n>) to focus that site's tab, open
-- it, or open it as a standalone app window. Covers the chooser list + subtext, single-
-- site straight-jump, no-match fallback, scheme-less normalization, the legacy openURL
-- migration, `Name | URL [| app]` parsing + favicons, per-site browser/profile routing
-- (plain + JSON storage), Safari's focus-tab path, and the empty-config hint. The final
-- block covers the dynamicActions hook that gives each site its own action (its menubar
-- submenu row / palette entry / bindable shortcut).
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
            "https://www.example.com/\nhttps://github.com/\n"
        fake.browserTabs = { "https://github.com/x", "https://www.example.com/meetings" }
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        local ch = fake.visibleChooser()
        ok(ch ~= nil and #ch.choices == 2
            and ch.choices[1].text == "example.com"
            and ch.choices[1].subText == "https://www.example.com/"
            and ch.choices[2].text == "github.com",
            "the shortcut pops a chooser of the sites (domain text, url subtext)")
        ch.userSelect(1)
        ok(fake.focusedTabs[#fake.focusedTabs] == "https://www.example.com/meetings",
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
        fake.settings["hammerdeck.opt.site_switcher.sites"] = "https://www.example.com/"
        fake.browserTabs = { "https://github.com/x" }
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        ok(fake.openedNewTabs[#fake.openedNewTabs] == "https://www.example.com/",
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
        fake.settings["hammerdeck.opt.site_switcher.openURL"] = "https://www.example.com/"
        fake.browserTabs = { "https://www.example.com/meetings" }
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        ok(fake.focusedTabs[#fake.focusedTabs] == "https://www.example.com/meetings",
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
            '[{"name":"Example","url":"example.com","browser":"com.google.Chrome","profile":"Profile 2","app":true},'
            .. '{"name":"News","url":"news.ycombinator.com","browser":"org.mozilla.firefox"}]'
        fake.browserTabs = {}
        fake.siteOpens = {}
        fake.appWindows = {}
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        local jc = fake.visibleChooser()
        ok(jc ~= nil and jc.choices[1].text == "Example" and jc.choices[2].text == "News",
            "JSON site records render as named rows")
        jc.userSelect(1)   -- Example: Chrome + a non-default profile + app -> routed launch
        ok(#fake.siteOpens == 1
            and fake.siteOpens[1].bundleId == "com.google.Chrome"
            and fake.siteOpens[1].profile == "Profile 2"
            and fake.siteOpens[1].app == true
            and fake.siteOpens[1].url == "https://example.com",
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

        -- PRIVATE WINDOWS: a site marked incognito always OPENS a fresh private
        -- window and NEVER focuses an existing tab -- the seam refuses to look inside
        -- a private window at all (which is what stops usage_stats recording the
        -- visit), so there is nothing to focus. It therefore always routes through
        -- openSite, the only path that can pass the flag, even for the Chrome /
        -- default-profile / tab combination that otherwise takes the AppleScript
        -- focus path.
        fake.settings["hammerdeck.opt.site_switcher.sites"] =
            '[{"id":"p1","name":"Search","url":"duckduckgo.com",'
            .. '"browser":"com.google.Chrome","incognito":true}]'
        fake.browserTabs = { "https://duckduckgo.com/?q=x" }   -- a MATCHING tab is open
        fake.siteOpens = {}
        fake.focusedTabs = {}
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        ok(#fake.siteOpens == 1 and fake.siteOpens[1].incognito == true
            and fake.siteOpens[1].url == "https://duckduckgo.com",
            "a private site opens through openSite with the incognito flag")
        ok(#fake.focusedTabs == 0,
            "... and never focuses the matching open tab (nothing can see a private window)")

        -- a Chrome profile still applies: each profile has its own private session
        fake.settings["hammerdeck.opt.site_switcher.sites"] =
            '[{"id":"p1","name":"Work","url":"mail.google.com","browser":"com.google.Chrome",'
            .. '"profile":"Profile 2","incognito":true}]'
        fake.siteOpens = {}
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        ok(#fake.siteOpens == 1 and fake.siteOpens[1].profile == "Profile 2"
            and fake.siteOpens[1].incognito == true,
            "a private site keeps its Chrome profile")

        -- a browser with no private-window switch (Safari, Firefox) makes the seam
        -- REFUSE. Say so, rather than let the user believe a recorded visit was
        -- private -- the one failure mode this whole path exists to avoid.
        fake.refuseSiteOpen = true
        fake.siteOpens = {}
        fake.alerts = {}
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        ok(#fake.siteOpens == 1 and #fake.alerts == 1
            and fake.alerts[1]:match("private window") ~= nil,
            "a refused private open alerts instead of silently opening a normal window")
        fake.refuseSiteOpen = false

        -- picking a private row from the CHOOSER carries the flag through: a row
        -- carries its action id and the site is re-resolved on select, so no field
        -- can be dropped between the list and the jump.
        fake.settings["hammerdeck.opt.site_switcher.sites"] =
            '[{"id":"n1","name":"Normal","url":"example.com","browser":"com.google.Chrome"},'
            .. '{"id":"p2","name":"Private","url":"duckduckgo.com",'
            .. '"browser":"com.google.Chrome","incognito":true}]'
        fake.browserTabs = {}
        fake.siteOpens = {}
        fake.openedNewTabs = {}
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        fake.visibleChooser().userSelect(2)
        ok(#fake.siteOpens == 1 and fake.siteOpens[1].incognito == true
            and fake.siteOpens[1].url == "https://duckduckgo.com",
            "picking a private row from the chooser opens it privately")
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        fake.visibleChooser().userSelect(1)
        ok(#fake.siteOpens == 1
            and fake.openedNewTabs[#fake.openedNewTabs] == "https://example.com",
            "... and a normal row still takes the focus-or-open path, not openSite")

        -- no sites at all -> a clear hint, not silence
        fake.settings["hammerdeck.opt.site_switcher.sites"] = nil
        fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
        ok(fake.alerts[#fake.alerts]:match("No sites yet") ~= nil,
            "empty config alerts instead of doing nothing")

        -- PER-SITE ACTIONS: the dynamicActions hook turns each configured site into
        -- its own action ("site_<key>"), which is what puts every site in the
        -- menubar's Quick Sites submenu / the command palette and lets it take a
        -- shortcut of its own. Exercises expansion, firing one, the stable id
        -- (a binding survives a re-register and a rename), the slug fallback for a
        -- config with no ids, same-domain uniqueness, and tolerance of a corrupt
        -- value -- plus that the picker action is untouched by all of it.
        do
            local sitesKey = "hammerdeck.opt.site_switcher.sites"

            -- Re-register from a FRESH module (what reload() does): register()
            -- appends the dynamic actions to the manifest IN PLACE, so a cached
            -- module would double-append them on the next register.
            local function reregister()
                pcall(registry.setEnabled, "site_switcher", false)
                registry.unregister("site_switcher")
                package.loaded["features.site_switcher"] = nil
                registry.register(require("features.site_switcher"))
                registry.setEnabled("site_switcher", true)
            end
            -- How many actions the feature describes (the picker + one per site).
            local function actionCount()
                for _, f in ipairs(registry.describe()) do
                    if f.id == "site_switcher" then return #f.actions end
                end
                return 0
            end
            -- The described action row for an id, or nil.
            local function siteAction(id)
                for _, f in ipairs(registry.describe()) do
                    if f.id == "site_switcher" then
                        for _, a in ipairs(f.actions) do
                            if a.id == id then return a end
                        end
                    end
                end
                return nil
            end

            -- (1) each stored site becomes an action, labelled with its name
            fake.settings[sitesKey] =
                '[{"id":"aaa","name":"GitHub","url":"github.com"},'
                .. '{"id":"bbb","name":"Example","url":"example.com"}]'
            reregister()
            ok(siteAction("site_aaa") ~= nil and siteAction("site_bbb") ~= nil,
                "each configured site becomes its own action")
            ok(siteAction("site_aaa").label == "GitHub",
                "the action takes the site's name as its label")
            ok(siteAction("site_aaa").dynamic == true,
                "a site action is tagged dynamic (Settings hides its duplicate trigger section)")
            ok(siteAction("site_aaa").defaultTrigger == nil,
                "a site ships dormant -- no default trigger (no uninvited hotkey grab)")
            ok(registry.isActionAutomatable("site_switcher", "site_aaa") == true,
                "a site action is automatable -- a schedule/event rule can open it")
            -- The picker is unaffected: same id (so an existing rebind still
            -- applies), still bound to Hyper+U, still not dynamic.
            local main = siteAction("main")
            ok(main ~= nil and main.dynamic == false and main.trigger
                and main.trigger.type == "hotkey" and main.trigger.key == "u",
                "the picker action keeps its id and its Hyper+U default")

            -- (2) firing a site action jumps to that site (no chooser in between)
            fake.browserTabs = { "https://github.com/pulls" }
            fake.focusedTabs = {}
            assert(registry.runAction("site_switcher", "site_aaa"))
            ok(fake.visibleChooser() == nil
                and fake.focusedTabs[#fake.focusedTabs] == "https://github.com/pulls",
                "running a site action focuses that site's tab directly")

            -- (2b) the action resolves its site WHEN IT FIRES, not from a record
            -- captured at register time: re-point the URL with NO re-register and
            -- the same action must open the new destination. A closure over the
            -- register-time record would still open github.com here -- and the
            -- label would agree with it, so nothing would look wrong.
            fake.settings[sitesKey] =
                '[{"id":"aaa","name":"GitHub","url":"example.com"},'
                .. '{"id":"bbb","name":"Example","url":"example.com"}]'
            fake.browserTabs = { "https://example.com/moved" }
            fake.focusedTabs = {}
            assert(registry.runAction("site_switcher", "site_aaa"))
            ok(fake.focusedTabs[#fake.focusedTabs] == "https://example.com/moved",
                "a site action re-reads the live config on every fire (an edited URL " ..
                "applies with no reload)")

            -- ... and a leftover action whose site was DELETED does nothing, rather
            -- than opening a destination the user removed.
            fake.settings[sitesKey] = '[{"id":"bbb","name":"Example","url":"example.com"}]'
            fake.focusedTabs = {}
            fake.siteOpens = {}
            fake.openedNewTabs = {}
            assert(registry.runAction("site_switcher", "site_aaa"))
            ok(#fake.focusedTabs == 0 and #fake.siteOpens == 0 and #fake.openedNewTabs == 0,
                "a site action whose site was deleted no-ops instead of jumping")

            fake.settings[sitesKey] =
                '[{"id":"aaa","name":"GitHub","url":"github.com"},'
                .. '{"id":"bbb","name":"Example","url":"example.com"}]'

            -- (3) stable id: a bound shortcut survives a re-register (reload's
            -- essence), because the trigger override keys on the site's id.
            ok(registry.setTrigger("site_switcher", "site_aaa",
                { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "1" }),
                "a site action binds a hotkey")
            reregister()
            local a = siteAction("site_aaa")
            ok(a ~= nil and a.triggerOverridden == true and a.trigger and a.trigger.key == "1",
                "the bound shortcut survives a re-register (stable site id)")

            -- (4) rename + re-point the URL (same id) -> new label, SAME binding
            fake.settings[sitesKey] =
                '[{"id":"aaa","name":"Pull requests","url":"github.com/pulls"},'
                .. '{"id":"bbb","name":"Example","url":"example.com"}]'
            reregister()
            a = siteAction("site_aaa")
            ok(a ~= nil and a.label == "Pull requests", "a rename updates the action label")
            ok(a.triggerOverridden == true,
                "a rename / URL edit keeps the shortcut (the id is unchanged)")
            fake.settings["hammerdeck.trigger.site_switcher.site_aaa"] = nil

            -- (5) a config with no ids (legacy text, or JSON written before them)
            -- still binds: the key falls back to a slug of the URL.
            fake.settings[sitesKey] = "GitHub | github.com\nExample | example.com\n"
            reregister()
            ok(siteAction("site_github_com") ~= nil and siteAction("site_example_com") ~= nil,
                "an id-less config keys its site actions off a URL slug")

            -- (6) two sites on ONE domain (e.g. two Chrome profiles) slug to the
            -- same key -- they must still get distinct ids, because a duplicate
            -- would fail validation and quarantine the whole feature.
            fake.settings[sitesKey] =
                '[{"name":"Work","url":"mail.google.com","profile":"Profile 1"},'
                .. '{"name":"Personal","url":"mail.google.com","profile":"Profile 2"}]'
            reregister()
            local first, second = siteAction("site_mail_google_com"), siteAction("site_mail_google_com_2")
            ok(first ~= nil and first.label == "Work"
                and second ~= nil and second.label == "Personal",
                "two sites on one domain get distinct action ids")
            ok(actionCount() == 3,
                "... and both survive alongside the picker (a duplicate id would " ..
                "have thrown at register and quarantined the feature)")

            -- (7) a half-written row -- what "Add site" leaves in the stored JSON
            -- until a URL is typed -- must contribute NO action. An empty url would
            -- otherwise mint an action with an empty label (and, with two of them,
            -- a duplicate id that quarantines the feature at register).
            fake.settings[sitesKey] =
                '[{"id":"aaa","name":"GitHub","url":"github.com"},'
                .. '{"id":"new1","name":"","url":""},{"id":"new2","name":"","url":""}]'
            reregister()
            ok(actionCount() == 2 and siteAction("site_aaa") ~= nil,
                "a blank row contributes no action (and two of them cannot collide)")

            -- (8) tolerance: a corrupt value yields NO site actions, but the picker
            -- still binds (a bad setting must never disable the feature). Counted,
            -- not spot-checked: broken JSON must not read as one absurd site either.
            fake.settings[sitesKey] = "[{ not json"
            reregister()
            ok(actionCount() == 1 and siteAction("main") ~= nil,
                "a corrupt sites value drops the site actions, leaving just the picker")

            fake.settings[sitesKey] = nil
            pcall(registry.setEnabled, "site_switcher", false)
            ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
                "clean after the per-site actions block")
            registry.setEnabled("site_switcher", true)
        end

        registry.setEnabled("site_switcher", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after site_switcher test")
    end,
}
