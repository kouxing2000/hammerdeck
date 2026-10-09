-- test/cases/_integration/platform/feature_stats.lua -- the opt-in feature
-- statistics an update check carries (registry.statsReport over
-- platform/feature_stats).
--
-- What must hold: nothing is counted or reported while sharing is off; only fires
-- the USER made count -- a manual trigger, or runAction marked byUser (menu bar,
-- palette) -- never a schedule/event trigger, a rule or the agent; a report sends only a
-- COMPLETE day, with its date; a user extension -- whose id is a folder name the
-- user typed -- is never counted and never listed.
--
-- Integration (platform core). Hermetic: freshWorld() clears the catalog and the
-- fake settings before the case; the clock offset is restored at the end.

local EXT_DIR = "test/fixtures/extensions"
local DAY = 24 * 60 * 60

return {
    id = "feature_stats",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry
        local stats = require("platform.feature_stats")
        local clock0 = fake.clockOffset

        registry.register(require("features.plain_paste"))
        registry.setEnabled("plain_paste", true)
        fake.pasteboard = "x"

        -- Off: a fire counts nothing and the report is nil.
        ok(registry.runAction("plain_paste", "main") == true, "the action fires")
        ok(fake.settings[stats.COUNTS_KEY] == nil, "sharing off: nothing is counted")
        ok(registry.statsReport() == nil, "sharing off: no report at all")

        -- On: the user's two fire paths count; the day in progress is not reported yet.
        fake.settings[stats.SHARE_KEY] = true
        registry.runAction("plain_paste", "main", true)
        fake.pressHotkey("v", { "cmd", "shift" })

        -- Fires the user did not make are not use: a rule's command effect or the
        -- agent endpoint (runAction without byUser), and an automated trigger.
        registry.runAction("plain_paste", "main")
        package.loaded["features._stats_auto_probe"] = {
            api = 1, id = "stats_auto_probe", name = "Stats Auto Probe",
            actions = { { id = "main", label = "Fire", automatable = true,
                          defaultTrigger = { type = "event", event = "wake" },
                          run = function() end } },
        }
        registry.load("features._stats_auto_probe")
        registry.setEnabled("stats_auto_probe", true)
        fake.systemEvent("wake")
        local stored = tostring(fake.settings[stats.COUNTS_KEY])
        ok(stored:find('"plain_paste":2', 1, true) ~= nil,
            "the menu-bar run and the shortcut count, the rule/agent run does not")
        ok(not stored:find("stats_auto_probe", 1, true), "an automated trigger's fire is not use")
        registry.setEnabled("stats_auto_probe", false)
        local r = registry.statsReport()
        ok(r ~= nil and r.on == "plain_paste", "on: the enabled built-in feature is listed")
        ok(r.day == nil and r.use == nil, "the day in progress is never sent")

        -- The next UTC day: yesterday is complete and goes out with its date.
        local firstDay = os.date("!%Y-%m-%d", fake.now())
        fake.clockOffset = fake.clockOffset + DAY
        r = registry.statsReport()
        ok(r.day == firstDay, "the report names the complete day it covers")
        ok(r.use == "plain_paste:1", "two fires on that day report bucket 1 (1-9)")

        -- A day with no use leaves the last day with use as the report: the
        -- reader dedupes on (id, day), so a repeat is harmless and a gap is not.
        fake.clockOffset = fake.clockOffset + DAY
        ok(registry.statsReport().day == firstDay, "a quiet day keeps reporting the last day with use")

        -- A new day of use replaces it once that day is complete.
        for _ = 1, 12 do registry.runAction("plain_paste", "main", true) end
        local busyDay = os.date("!%Y-%m-%d", fake.now())
        fake.clockOffset = fake.clockOffset + DAY
        r = registry.statsReport()
        ok(r.day == busyDay and r.use == "plain_paste:2", "12 fires report bucket 2 (10-99)")

        -- Buckets at their edges.
        ok(stats.bucket(1) == "1" and stats.bucket(9) == "1", "1-9 -> 1")
        ok(stats.bucket(10) == "2" and stats.bucket(99) == "2", "10-99 -> 2")
        ok(stats.bucket(100) == "3", "100+ -> 3")

        -- A command-palette pick is the user's too (ctx.runCommand marks it).
        registry.register(require("features.command_palette"))
        registry.setEnabled("command_palette", true)
        fake.pressHotkey("space", { "cmd", "alt", "ctrl" })
        local pch = fake.visibleChooser()
        local row
        for i, c in ipairs(pch and pch.choices or {}) do
            if c.text == "Paste as plain text" then row = i end
        end
        ok(row ~= nil, "the palette lists the plain-paste command")
        pch.userSelect(row)
        fake.fireTimers("after", 0)
        local today = require("platform.json").decode(fake.settings[stats.COUNTS_KEY]).cur
        ok(today and today.counts.plain_paste == 1, "a palette pick counts as use")
        registry.setEnabled("command_palette", false)

        -- Rules: one the user fires with its own shortcut counts; the Test button and
        -- an automatic rule do not.
        local json = require("platform.json")
        local function today(id)
            local raw = fake.settings[stats.COUNTS_KEY]
            local cur = raw and json.decode(raw).cur
            if not cur or cur.day ~= os.date("!%Y-%m-%d", fake.now()) then return 0 end
            return cur.counts[id] or 0
        end
        local rules = require("platform.rules")
        registry.setEnabled("stats_auto_probe", true)
        rules.load({
            { id = "stats-hk", on = { type = "hotkey", mods = { "ctrl" }, key = "f13" },
              effect = { kind = "command", feature = "plain_paste", action = "main" } },
            { id = "stats-wake", on = { type = "event", event = "wake" },
              effect = { kind = "command", feature = "stats_auto_probe", action = "main" } },
        })
        rules.startAll()
        local pp = today("plain_paste")
        fake.pressHotkey("f13", { "ctrl" })
        ok(today("plain_paste") == pp + 1, "a rule fired by the user's own shortcut counts")
        rules.fire("stats-hk")
        ok(today("plain_paste") == pp + 1, "the rule's Test button does not")
        fake.systemEvent("wake")
        ok(today("stats_auto_probe") == 0, "an automatic rule does not")
        rules.stopAll()
        rules.load({})
        registry.setEnabled("stats_auto_probe", false)

        -- A user extension is neither counted nor listed.
        fake.settings["hammerdeck.extensionsDir"] = EXT_DIR
        fake.featuresByDir[EXT_DIR] = { "ext_probe", "ext_cmd" }
        ok(registry.loadExtensions() == 2, "the fixture extensions load")
        registry.setEnabled("ext_probe", true)
        ok(registry.runAction("ext_probe", "main", true) == true, "the extension's action fires")
        ok(not tostring(fake.settings[stats.COUNTS_KEY]):find("ext_probe", 1, true),
            "the extension's fire is not even stored")
        fake.clockOffset = fake.clockOffset + DAY
        r = registry.statsReport()
        ok(not r.on:find("ext_probe", 1, true), "an extension is never in the on list")
        ok(r.use == nil or not r.use:find("ext_probe", 1, true), "an extension is never counted")
        registry.setEnabled("ext_probe", false)

        -- An extension may hold the `commands` capability and run a built-in on its
        -- own schedule, so its runCommand never counts as the user's.
        registry.setEnabled("ext_cmd", true)
        pp = today("plain_paste")
        ok(registry.runAction("ext_cmd", "main", true) == true, "the extension's command runs")
        ok(today("plain_paste") == pp, "a built-in run by an extension is not counted")
        registry.setEnabled("ext_cmd", false)

        -- A malformed stored value is dropped, never trusted, and never fails a fire.
        -- Today's date, so the bad slot is the one a fire would write into.
        fake.settings[stats.COUNTS_KEY] = '{"cur":{"day":"' .. os.date("!%Y-%m-%d", fake.now())
            .. '","counts":"x"},"prev":[1,2]}'
        ok(registry.runAction("plain_paste", "main", true) == true, "a bad stored value does not fail the fire")
        ok(tostring(fake.settings[stats.COUNTS_KEY]):find('"plain_paste":1', 1, true) ~= nil,
            "and counting starts again from a clean slot")

        -- A count that is not a number makes counting raise; the fire still succeeds.
        fake.settings[stats.COUNTS_KEY] = '{"cur":{"day":"' .. os.date("!%Y-%m-%d", fake.now())
            .. '","counts":{"plain_paste":"x"}}}'
        ok(registry.runAction("plain_paste", "main", true) == true, "a failing count never fails the fire")

        -- Clearing (sharing off, or the ID reset) drops every count.
        stats.clear()
        fake.settings[stats.SHARE_KEY] = false
        ok(registry.statsReport() == nil, "off again: no report")

        registry.setEnabled("plain_paste", false)
        fake.clockOffset = clock0
    end,
}
