-- test/cases/app_launcher.lua -- app_launcher: a Raycast-style installed-app
-- launcher (Hyper+A). Enumeration is synchronous (the seam's directory scan),
-- so every open lists the fake "disk" as it is right now. Covers row shape and
-- ordering, type-to-filter + launch, frecency (bump on successful launch ONLY),
-- the empty-scan info row, and the uninstalled-since-open alert.
--
-- Hermetic: registers app_launcher itself; the "disk" is fake.installedAppsList.

return {
    id = "app_launcher",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        registry.register(require("features.app_launcher"))
        fake.installedAppsList = {
            { name = "Xcode",    bundleId = "com.apple.dt.Xcode", path = "/Applications/Xcode.app" },
            { name = "Safari",   bundleId = "com.apple.Safari",   path = "/Applications/Safari.app" },
            { name = "Terminal", bundleId = "com.apple.Terminal", path = "/System/Applications/Utilities/Terminal.app" },
        }
        registry.setEnabled("app_launcher", true)

        fake.pressHotkey("a", { "cmd", "alt", "ctrl" })
        local c = fake.visibleChooser()
        ok(c ~= nil, "launcher opened a chooser")
        ok(fake.installedAppsScans == 1, "opening enumerated the disk once")
        ok(#c.choices == 3, "one row per installed app")
        ok(c.choices[1].text == "Safari" and c.choices[2].text == "Terminal"
            and c.choices[3].text == "Xcode", "no launches yet: name order")
        ok(c.choices[1].image == "icon:com.apple.Safari",
            "rows carry the bundle-id icon token (the fake's appIcon shape)")

        -- type-to-filter, Enter launches
        c.userType("term")
        c.userSelect(1)
        ok(fake.launchedApps[1] == "com.apple.Terminal", "Enter launches the filtered app")

        -- next open: frecency first, and a just-installed app is already there
        fake.installedAppsList[#fake.installedAppsList + 1] =
            { name = "Ghost", bundleId = "com.gone", path = "/Applications/Ghost.app" }
        fake.pressHotkey("a", { "cmd", "alt", "ctrl" })
        ok(c.choices[1].text == "Terminal", "frecency: the launched app sorts first")
        ok(#c.choices == 4, "a fresh install appears on the open where you look for it")
        ok(fake.installedAppsScans == 2, "every open re-enumerates (no cache to go stale)")

        -- an app gone since the open: alert, and no frecency bump
        fake.uninstalledApps["com.gone"] = true
        c.userType("ghost")
        c.userSelect(1)
        ok(fake.alerts[#fake.alerts] == "Could not launch Ghost",
            "an app gone since the open alerts instead of silently failing")
        ok(#fake.launchedApps == 1, "the failed launch recorded nothing")
        fake.pressHotkey("a", { "cmd", "alt", "ctrl" })
        ok(c.choices[1].text == "Terminal",
            "no frecency bump on a failed launch (a bump would tie and resort)")
        c.userSelect(0)   -- dismiss (Escape)
        fake.uninstalledApps["com.gone"] = nil

        -- empty disk: a single non-selectable info row, not a blank panel
        fake.installedAppsList = {}
        fake.pressHotkey("a", { "cmd", "alt", "ctrl" })
        ok(#c.choices == 1 and c.choices[1].valid == false,
            "an empty scan shows a single info row")
        c.userSelect(0)

        registry.setEnabled("app_launcher", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
            "clean after app_launcher test")
    end,
}
