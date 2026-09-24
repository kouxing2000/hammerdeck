-- test/cases/app_launcher.lua -- app_launcher: a Raycast-style installed-app
-- launcher (Hyper+A). Enumeration is synchronous (the seam's directory scan),
-- so every open lists the fake "disk" as it is right now. Covers row shape and
-- ordering, type-to-filter + launch, frecency (bump on successful launch ONLY),
-- the empty-scan info row, the uninstalled-since-open alert, and a launch macOS
-- refuses (its reason in the alert; dropped when the feature is disabled first).
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

        -- installed, but macOS refuses the launch (an Xcode too old for this OS):
        -- the alert carries macOS's reason, and a launch that never happened
        -- earns no frecency
        local refused = "The app is incompatible with the current OS"
        fake.launchErrors["com.apple.dt.Xcode"] = refused
        fake.pressHotkey("a", { "cmd", "alt", "ctrl" })
        c.userType("xcode")
        c.userSelect(1)
        ok(fake.alerts[#fake.alerts] == "Could not launch Xcode: " .. refused,
            "a refused launch alerts with macOS's own reason")
        ok(#fake.launchedApps == 1, "the refused launch recorded nothing")
        fake.pressHotkey("a", { "cmd", "alt", "ctrl" })
        ok(c.choices[2].text == "Ghost" and c.choices[4].text == "Xcode",
            "no frecency bump on a refused launch (a bump would lift Xcode to 2nd)")
        c.userSelect(0)
        fake.launchErrors["com.apple.dt.Xcode"] = nil

        -- aliases: an app's short names ride the subText -- the only field besides
        -- the title the panel filter reads, so searchable and visible are the same
        -- thing here.
        fake.settings["hammerdeck.opt.app_launcher.aliases"] =
            '[{"bundleId":"com.apple.dt.Xcode","aliases":["xc","ide"]},'
            .. '{"bundleId":"com.apple.dt.Xcode","aliases":["build"]}]'
        fake.pressHotkey("a", { "cmd", "alt", "ctrl" })
        local function rowFor(bundleId)
            for _, ch in ipairs(c.choices) do
                if ch.bundleId == bundleId then return ch end
            end
        end
        ok(rowFor("com.apple.dt.Xcode")
            and rowFor("com.apple.dt.Xcode").subText == "xc · ide · build",
            "rows sharing a bundle id merge their aliases onto one line")
        ok(rowFor("com.apple.Safari") and rowFor("com.apple.Safari").subText == nil,
            "an app with no alias keeps its one-line row")
        c.userType("ide")   -- appears in no app NAME on the fake disk
        c.userSelect(1)
        ok(fake.launchedApps[#fake.launchedApps] == "com.apple.dt.Xcode",
            "typing an alias finds an app whose name does not contain it")

        -- subText is a SEARCHED field, so it must carry the aliases and NOTHING
        -- else: a label in front of them ("alias: ...") puts its own letters in the
        -- index, and every aliased row then matches "li", "as", "ia"... Xcode is
        -- aliased AND outranks Linear on frecency here, so it would win the row a
        -- "li" search is reaching for.
        fake.installedAppsList[#fake.installedAppsList + 1] =
            { name = "Linear", bundleId = "com.linear", path = "/Applications/Linear.app" }
        fake.pressHotkey("a", { "cmd", "alt", "ctrl" })
        c.userType("li")
        c.userSelect(1)
        ok(fake.launchedApps[#fake.launchedApps] == "com.linear",
            "an alias line adds no searchable text of its own")

        -- a hand-mangled option value must not take the launcher down with it
        fake.settings["hammerdeck.opt.app_launcher.aliases"] = "not json at all"
        fake.pressHotkey("a", { "cmd", "alt", "ctrl" })
        local anySub = false
        for _, ch in ipairs(c.choices) do if ch.subText then anySub = true end end
        ok(not anySub, "an unparseable alias option degrades to no aliases, not a crash")
        c.userSelect(0)
        fake.settings["hammerdeck.opt.app_launcher.aliases"] = nil

        -- empty disk: a single non-selectable info row, not a blank panel
        fake.installedAppsList = {}
        fake.pressHotkey("a", { "cmd", "alt", "ctrl" })
        ok(#c.choices == 1 and c.choices[1].valid == false,
            "an empty scan shows a single info row")
        c.userSelect(0)

        -- disabled while a refused launch is in flight: its answer is dropped, and
        -- the one-shot leaves no handle behind
        fake.installedAppsList = {
            { name = "Xcode", bundleId = "com.apple.dt.Xcode", path = "/Applications/Xcode.app" },
        }
        fake.launchErrors["com.apple.dt.Xcode"] = refused
        fake.deferAsync = true
        fake.pressHotkey("a", { "cmd", "alt", "ctrl" })
        c.userSelect(1)
        ok(#fake.pendingAsync == 1, "the launch answer is in flight")
        local alertsBefore = #fake.alerts
        registry.setEnabled("app_launcher", false)
        fake.deferAsync = false
        fake.deliverAsync()
        ok(#fake.alerts == alertsBefore, "a launch answer landing after disable is dropped")
        fake.launchErrors["com.apple.dt.Xcode"] = nil
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
            "clean after app_launcher test")
    end,
}
