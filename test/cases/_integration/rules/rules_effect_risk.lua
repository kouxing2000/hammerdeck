-- test/cases/_integration/rules/rules_effect_risk.lua -- which effects are RISKY, the
-- label the breaker, the save-time refusal and the form's warning all key on.
-- runShortcut is an exec risk (a Shortcut can run a script, lock, shut down);
-- openURL is one only for a scheme that hands the URL to an app that can act on
-- it (shortcuts://, file://, ...) -- a web page or a mail draft stays ordinary.
-- rules.riskJSON is the form's window onto the same rule, so it is asserted to
-- agree with effects.risk on the full rule spec the form sends.
--
-- Integration: platform subsystem. Hermetic -- freshWorld() runs registry.reset()
-- + rules.load({}) before the case.

return {
    id = "rules_effect_risk",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
        local rules   = require("platform.rules")
        local effects = require("platform.effects")
        local json    = require("platform.json")

        local function urlRisk(url) return effects.risk({ kind = "openURL", url = url }) end

        -- runShortcut ----------------------------------------------------------
        ok(effects.risk({ kind = "runShortcut", name = "Wind Down" }) == "exec",
            "runShortcut is an exec risk")

        -- openURL, by scheme ---------------------------------------------------
        ok(urlRisk("https://example.com") == nil, "an https page is ordinary")
        ok(urlRisk("http://localhost:3000") == nil, "an http page is ordinary")
        ok(urlRisk("HTTPS://EXAMPLE.COM") == nil, "the scheme is matched case-insensitively")
        ok(urlRisk("mailto:me@example.com") == nil, "a mail draft is ordinary")
        ok(urlRisk("shortcuts://run-shortcut?name=Lock") == "exec",
            "shortcuts:// runs a Shortcut -- an exec risk")
        ok(urlRisk("file:///Users/me/cleanup.command") == "exec",
            "file:// can run a script -- an exec risk")
        ok(urlRisk("raycast://extensions/x/y") == "exec", "an app scheme is an exec risk")
        ok(urlRisk("  facetime://+15550100") == "exec", "leading space does not hide the scheme")
        ok(urlRisk("example.com") == nil, "no scheme opens nothing, so it is ordinary")

        -- The catalog badges only fixed risks: openURL is risky for SOME urls, so the
        -- Do list does not mark it; runShortcut is always risky, so it does.
        local byKind = {}
        for _, e in ipairs(effects.catalog(true)) do byKind[e.kind] = e end
        ok(byKind.runShortcut and byKind.runShortcut.risk == "exec", "the Do list marks runShortcut")
        ok(byKind.openURL and byKind.openURL.risk == nil, "the Do list does not mark openURL")

        -- riskJSON: the form's view, on the whole rule spec ------------------------
        local function riskOf(effect)
            local spec = json.encode({ on = { type = "event", event = "wake" }, effect = effect })
            return rules.riskJSON(assert(spec, "the rule spec encodes"))
        end
        ok(riskOf({ kind = "openURL", url = "shortcuts://run-shortcut?name=X" }) == "exec",
            "riskJSON judges openURL by its scheme")
        ok(riskOf({ kind = "openURL", url = "https://example.com" }) == "",
            "riskJSON returns empty for an ordinary rule")
        ok(riskOf({ kind = "chain", effects = { { kind = "openURL", url = "https://a.dev" },
                                                { kind = "lockScreen" } } }) == "lockout",
            "riskJSON ranks a chain by its most severe step")
        ok(rules.riskJSON("{not json") == "", "unreadable JSON is empty, never a throw")

        -- The breaker now covers them: a non-web openURL rule trips, a web one does not.
        rules.load({})
        local _, sid = rules.add({ on = { type = "event", event = "wake" },
                                   effect = { kind = "openURL", url = "shortcuts://run-shortcut?name=X" } })
        local _, wid = rules.add({ on = { type = "event", event = "sleep" },
                                   effect = { kind = "openURL", url = "https://example.com" } })
        rules.startAll()
        for _ = 1, 5 do fake.systemEvent("wake"); fake.systemEvent("sleep") end
        local state = {}
        for _, r in ipairs(rules.describe()) do state[r.id] = r end
        ok(state[sid].enabled == false and state[sid].risk == "exec",
            "a shortcuts:// rule firing 5 times in 2 minutes is switched off")
        ok(state[wid].enabled == true and state[wid].risk == nil,
            "a web-page rule firing just as often stays on")

        -- cleanup
        rules.stopAll(); rules.load({})
        fake.settings["hammerdeck.rules"] = nil
        ok(fake.liveHandles == 0, "no native handle leaked across the effect-risk test")
    end,
}
