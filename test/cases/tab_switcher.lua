-- test/cases/tab_switcher.lua -- cross-browser tab switcher (MRU-first ordering,
-- favicon resolution, modifier-release auto-jump, pruning, cycling).
--
-- Migrated from run.lua T26 (RUN_LUA_SPLIT_SPEC Phase 2). Hermetic: registers its
-- own feature and seeds its own MRU file / running apps / browser tabs; freshWorld()
-- before + handle tripwire after keep it isolated.

return {
    id = "tab_switcher",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry
        local jsonlib = require("platform.json")

        -- the new encoder round-trips what the feature persists
        local encT = jsonlib.encode({ b = { ["https://x.y/z?a=1"] = 123 }, n = 1.5, s = 'q"q' })
        local decT = jsonlib.decode(encT)
        ok(decT.b["https://x.y/z?a=1"] == 123 and decT.n == 1.5 and decT.s == 'q"q',
            "json.encode round-trips nested tables, floats, and quotes")
        ok(jsonlib.encode({ 1, 2, 3 }) == "[1,2,3]", "arrays encode as arrays")
        ok(jsonlib.encode(function() end) == nil, "unencodable values return nil, not a throw")

        registry.register(require("features.tab_switcher"))

        local mruPath = "/fake/data/tab_switcher/mru.json"
        local nowT = fake.now()
        fake.files[mruPath] = jsonlib.encode({
            ["Google Chrome"] = {
                ["https://github.com/x"] = nowT - 60,             -- fresh: sorts first
                ["https://dead.example/old"] = nowT - 40 * 86400, -- stale: pruned
            },
            ["Safari"] = { ["https://apple.com/"] = nowT - 3600 },
        })
        fake.runningApps["Google Chrome"] = true
        fake.runningApps["Safari"] = true
        fake.chromeFavicons["github.com"] = true   -- Chrome's icon DB knows github
        fake.browserTabsByApp = {
            ["Google Chrome"] = {
                { title = "Docs", url = "https://docs.example/d", winId = 1, tabIndex = 1, id = 101, visible = true },
                { title = "GitHub", url = "https://github.com/x", winId = 1, tabIndex = 2, id = 102, visible = true },
                { title = "Shortcut App", url = "https://app.example/", winId = 7, tabIndex = 1, id = 103, visible = false },
            },
            ["Safari"] = {   -- Safari tabs have no stable id (0) -> url + winId resolution
                { title = "Apple", url = "https://apple.com/", winId = 9, tabIndex = 1, id = 0, visible = true },
            },
        }

        registry.setEnabled("tab_switcher", true)

        fake.modifiers.alt = true
        fake.pressHotkey("tab", { "ctrl", "alt" })
        local tch = fake.visibleChooser()
        ok(tch ~= nil, "tab chooser opened")
        ok(#tch.choices == 3, "visible tabs listed; invisible shortcut-app window skipped")
        ok(tch.choices[1].text == "GitHub", "freshest MRU stamp sorts first")
        ok(tch.choices[2].text == "[Safari] Apple", "Safari tabs are prefixed and ranked by stamp")
        ok(tch.choices[1].image == "file:/tmp/hammerdeck-fake-cache/favicons/github.com.png",
            "a Chrome-DB icon shows as soon as extraction lands (show-time resolution)")
        ok(tch.choices[3].image == "icon:com.google.Chrome",
            "no cached favicon -> the browser's app icon")
        ok(tch.selectedRow == 2, "the previous tab is preselected")
        ok(#fake.extractedBatches >= 1 and #fake.extractedBatches[1].domains >= 2,
            "missing favicons go to Chrome's icon DB first")
        local dlSeen = {}
        for _, d in ipairs(fake.downloads) do dlSeen[d.path] = d.url end
        ok(dlSeen["/tmp/hammerdeck-fake-cache/favicons/docs.example.png"]
                == "https://docs.example/favicon.ico",
            "domains Chrome doesn't know fall back to the site's own /favicon.ico")
        ok(dlSeen["/tmp/hammerdeck-fake-cache/favicons/github.com.png"] == nil,
            "extracted domains are not re-downloaded")

        -- release the modifier: the armed auto-jump picks the selected row
        fake.modifiers.alt = false
        fake.fireTimers("every", 0.1)
        ok(fake.tabJumps[#fake.tabJumps].app == "Safari" and fake.tabJumps[#fake.tabJumps].winId == 9,
            "releasing the modifier jumps to the selected tab")
        ok(fake.files[mruPath]:find("apple.com", 1, true) ~= nil
            and fake.files[mruPath]:find("dead.example", 1, true) == nil,
            "the landed tab is stamped; 30-day-old entries were pruned")

        -- the extracted favicon upgrades the row on the next open (show-time icon
        -- re-resolution -- no relist needed)
        fake.frontmost = "Google Chrome"
        fake.activeUrls["Google Chrome"] = "https://news.example/today"
        fake.fireTimers("every", 10)   -- the MRU poll stamps + marks dirty
        ok(fake.files[mruPath]:find("news.example", 1, true) ~= nil,
            "the 10s poll stamps the active browser url")
        fake.modifiers.alt = true
        fake.pressHotkey("tab", { "ctrl", "alt" })
        tch = fake.visibleChooser()
        ok(tch.choices[1].text == "[Safari] Apple",
            "the jumped-to tab now ranks first (stamped at jump time)")
        local ghChoice
        for _, c in ipairs(tch.choices) do if c.text == "GitHub" then ghChoice = c end end
        ok(ghChoice and ghChoice.image == "file:/tmp/hammerdeck-fake-cache/favicons/github.com.png",
            "a cached favicon replaces the app icon after refresh")

        -- cycling: a second invocation advances the row; wrap works
        local rowBefore = tch.selectedRow
        fake.pressHotkey("tab", { "ctrl", "alt" })
        ok(tch.selectedRow == rowBefore + 1, "repeat invocation cycles forward")
        fake.pressHotkey("`", { "ctrl", "alt" })
        ok(tch.selectedRow == rowBefore, "the backward action cycles back")

        -- a drifted/closed tab alerts and triggers a relist
        fake.jumpUrlOverride = false
        tch.userSelect(1)
        ok(fake.alerts[#fake.alerts]:match("moved") ~= nil, "a vanished tab alerts to retry")
        fake.jumpUrlOverride = nil
        fake.modifiers.alt = false

        registry.setEnabled("tab_switcher", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after tab_switcher test")
    end,
}
