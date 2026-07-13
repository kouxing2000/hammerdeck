-- test/cases/_integration/platform/i18n_format.lua -- the formatting layer: positional
-- specifiers, and the guarantee that a broken TRANSLATION can never raise.
--
-- Why this exists. Lua's string.format has no positional specifiers -- "%2$s" raises
-- `invalid conversion '%2$' to 'format'` (lstrlib.c checkformat: flags, width, precision,
-- then an ALPHA conversion char -- '$' can never appear) -- and it consumes arguments
-- strictly in order. That is a localization bug: word order is not universal ("Set
-- wallpaper <color> on <display>" -> "把 <display> 的壁纸设为 <color>"), and a translator
-- handed only "%s %s" cannot express it.
--
-- Worse, "%1$s" is exactly what a translator WILL write -- Apple .strings, gettext, and
-- the Swift half of this same catalog (String(format:)) all accept it -- and in Lua it did
-- not degrade, it THREW: out of effects.describe, which rules.lua renders while a rule is
-- FIRING (rules.lua:226) and when the Rules tab merely opens (rules.lua:526). One mistyped
-- placeholder in a translation file could take down the rules UI and a firing rule.
--
-- So i18n.format owns formatting: it honours "%n$s" by reordering the arguments itself,
-- and it NEVER raises -- a broken template warns once and falls back to the English source.

return {
    id = "i18n_format",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok = t.ok
        local i18n = require("platform.i18n")

        local logged = {}
        i18n.configure({ locale = "en", appdir = "app",
                         log = function(m) logged[#logged + 1] = m end })
        i18n.resetTemplateWarnings()

        -- Plain templates behave exactly like string.format (the common path).
        ok(i18n.format("x.missing", "Set wallpaper %s on %s", "black", "all displays")
            == "Set wallpaper black on all displays",
            "i18n.format formats a plain template like string.format")
        ok(i18n.format("x.missing", "100%% of %s", "it") == "100% of it",
            "i18n.format preserves an escaped %% (it is not a conversion)")

        -- POSITIONAL: the whole point. A locale reorders the arguments; the args at the
        -- CALL SITE are unchanged (color, display) -- only the template moves them.
        ok(i18n.format("x.missing", "%2$s takes %1$s", "a", "b") == "b takes a",
            "i18n.format honours positional specifiers (%1$s / %2$s)")
        ok(i18n.format("x.missing", "%1$s and %1$s again", "x") == "x and x again",
            "a positional slot may be reused")
        ok(i18n.format("x.missing", "%2$d of %1$d", 7, 9) == "9 of 7",
            "positional works for %d as well as %s")

        -- NEVER RAISES. Each of these used to be an uncaught error out of a firing rule.
        local BAD = {
            { "too many slots",        "say %s %s",        { "hi" } },
            { "mixed positional/plain", "%1$s and %s",     { "a", "b" } },
            { "positional out of range", "%3$s",           { "a" } },
            { "not a conversion",      "%q%z",             { "a" } },
        }
        for _, case in ipairs(BAD) do
            local why, tpl, args = case[1], case[2], case[3]
            local okCall, res = pcall(i18n.format, "x.bad." .. why, tpl, table.unpack(args))
            ok(okCall, "i18n.format does not raise on a broken template (" .. why .. ")")
            ok(type(res) == "string" and res ~= "",
                "i18n.format still returns a string on a broken template (" .. why .. ")")
        end

        -- A broken TRANSLATION falls back to the ENGLISH source (not to a raw key, and not
        -- to a half-rendered string), and says so ONCE -- a rule firing every minute must
        -- not spray the log.
        i18n.resetTemplateWarnings()
        logged = {}
        -- zh-Hans has no such key, so the "translation" IS the English source here; the
        -- fallback path is exercised by handing format a template that cannot take the args.
        local out = i18n.format("x.fallback", "Say %s", "hi", "extra")
        ok(out == "Say hi", "a surplus ARGUMENT is harmless (string.format ignores it)")

        local n1 = #logged
        i18n.format("x.warnonce", "%s %s", "only-one")
        i18n.format("x.warnonce", "%s %s", "only-one")
        i18n.format("x.warnonce", "%s %s", "only-one")
        ok(#logged == n1 + 1, "a broken template warns ONCE per key, not per render")
        ok(logged[#logged]:find("x.warnonce", 1, true) ~= nil,
            "the warning names the offending key so it can be found in the catalog")

        -- An ESCAPED percent whose bytes look positional ("100%%1$ off") is NOT a positional
        -- template. A `find("%%%d+%$")` pre-check thought it was, sent a plain template down
        -- the positional path, and got it refused as "mixed" -- so only the scanner decides.
        ok(i18n.format("x.escape", "100%% off %s", "everything") == "100% off everything",
            "an escaped percent beside a plain slot formats normally")
        ok(i18n.format("x.escape2", "50%%2$ off %s", "x") == "50%2$ off x",
            "bytes that LOOK positional inside an escaped percent are not a slot")

        -- warn-once is keyed by the TEMPLATE, not just the key: several features declare the
        -- same key name (three ship "alert.axRequired"), and one broken template must not
        -- silence a different feature's broken one.
        i18n.resetTemplateWarnings()
        logged = {}
        i18n.format("alert.shared", "%s and %s", "only-one")           -- feature A's template
        i18n.format("alert.shared", "%s, %s and %s", "only-one")       -- feature B's, same key
        ok(#logged == 2, "two DIFFERENT broken templates under one key both warn")

        -- A broken ENGLISH source must fail over to the raw text, never format `nil` into it.
        local bad = i18n.format("x.badsource", "%3$s of %1$s", "a", "b")
        ok(not bad:find("nil", 1, true),
            "an out-of-range slot in the English source never renders the string 'nil'")

        -- "NEVER RAISES" has to mean never -- including a template that is not a STRING.
        -- A translator can typo a plural form as a JSON number ("other": 3) or a bool; that
        -- value used to reach the scanner and blow up on `#tpl`, OUTSIDE any pcall, from
        -- inside a firing rule. The lookup now type-checks (like i18n.t always did) and the
        -- formatter refuses to assume.
        ok(pcall(i18n.formatPlural, "x.numform", 2, { other = 5 }, nil, 2),
            "a NUMBER where a plural form belongs does not raise")
        ok(pcall(i18n.format, "x.boolsrc", true, "x"),
            "a non-string template does not raise")
        ok(i18n.formatPlural("x.mixedforms", 2, { one = "%d step", other = "%d steps" }, nil, 2)
            == "2 steps", "a well-formed plural still formats normally")

        -- The plural twin takes the same route (and the same guarantees).
        ok(i18n.formatPlural("x.missing", 3, { one = "%d step", other = "%d steps" }, nil, 3)
            == "3 steps", "i18n.formatPlural formats the chosen plural form")
        local okP = pcall(i18n.formatPlural, "x.badplural", 3,
            { one = "%d %s", other = "%d %s" }, nil, 3)   -- one arg short
        ok(okP, "i18n.formatPlural does not raise on a broken plural template")

        -- Back to the suite's source language -- AND drop the log sink. configure() keeps a
        -- sink across reconfigures on purpose (a locale switch must not go silent), so
        -- leaving this case's closure installed would have every later case writing warnings
        -- into a dead local that nothing asserts on.
        i18n.configure({ locale = "en", log = false })
        i18n.resetTemplateWarnings()
    end,
}
