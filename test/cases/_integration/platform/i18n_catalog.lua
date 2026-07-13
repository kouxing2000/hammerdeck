-- test/cases/_integration/platform/i18n_catalog.lua -- the locale-injected i18n module -- zh-Hans lookup/fallback/
-- interpolation/plural against the shipped catalog, the leaf-util localizes
-- via ctx.t, the P2 per-feature runtime-key sweep (no English leak in zh),
-- and the leaf-util ZERO-require layer invariant.
--
-- Migrated from run.lua T0b (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "i18n_catalog",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok = t.ok

        do
            local i18n    = require("platform.i18n")
            local windows = require("platform.windows")
            i18n.configure({ locale = "zh-Hans", appdir = "app" })

            ok(i18n.t("window.noFocused", "No focused window") == "没有聚焦的窗口",
                "i18n.t returns the zh-Hans translation for a global key")
            ok(i18n.t("missing.key", "fallback") == "fallback",
                "i18n.t falls back to the inline default for a missing key")
            ok(i18n.t("missing.key") == "missing.key",
                "i18n.t falls back to the key itself when no default is given")

            -- The template is localized and i18n.format interpolates -- NOT a raw
            -- string.format over i18n.t, which is precisely the bug this line used to be:
            -- a 2+-slot template is now positional ("%1$s ... %2$s", so a locale may
            -- reorder), and Lua's own string.format RAISES on "%1$s". The formatting layer
            -- is the only thing that may render a translated template.
            local msg = i18n.format("window.axRequired",
                "%1$s needs Accessibility -- grant %2$s", "Window Mode", "Hammerdeck")
            ok(msg:find("Window Mode", 1, true) and msg:find("Hammerdeck", 1, true)
                and msg:find("辅助功能", 1, true),
                "i18n.format interpolates caller args into the zh-Hans string")

            ok(i18n.category(1) == "other" and i18n.category(5) == "other",
                "zh-Hans plural category collapses to other")
            local forms = { one = "%d window", other = "%d windows" }
            ok(i18n.plural("x.count", 5, forms) == "%d windows",
                "i18n.plural picks the other form from inline forms (no catalog entry)")

            -- platform.windows is a leaf: it localizes through the ctx handed to it, with
            -- NO require of i18n. A shared key resolves via ctx.t's global fallback.
            local alerted
            local fakeCtx = {
                window    = { frame = function() return nil end },
                axTrusted = function() return false end,
                axPrompt  = function() end,
                alert     = function(s) alerted = s end,
                appName   = "Hammerdeck",
                -- mirrors the REAL ctx.t contract (platform/ctx.lua): a bare lookup returns
                -- the template; passing args formats it safely (positional-aware). A fake
                -- that drops the varargs would let a leaf's formatting go untested.
                t         = function(k, d, ...)
                    if select("#", ...) == 0 then return i18n.tFeature("window_modal", k, d) end
                    return i18n.formatFeature("window_modal", k, d, ...)
                end,
            }
            windows.focusedOrAlert(fakeCtx, "Window Mode")
            ok(alerted and alerted:find("辅助功能", 1, true) and alerted:find("Hammerdeck", 1, true),
                "platform.windows localizes its Accessibility alert via ctx.t")

            -- P2 localization sweep: every feature that emits runtime user-facing strings
            -- must carry the zh-Hans key the code requests, or ctx.t silently falls back to
            -- English in zh (the leak this pass closed). Assert a representative NEW key per
            -- touched feature resolves to a translation (NOT the English default) -- the
            -- exact missing-key failure the en-locale tests below cannot see.
            do
                local sweep = {
                    { "sleep_schedule",  "banner.countdown",    "System sleep in %s  --  Save your work!" },
                    { "break_reminder",  "action.lock",         "Lock Screen" },
                    { "window_modal",    "hud.footer",          "esc  exit" },
                    { "text_actions",    "action.calculate",    "Calculate" },
                    { "insert_datetime", "error.tableFormat",   "That format produces a table, not text (avoid *t)" },
                    { "window_grid",     "hud.caption",         "press a number to place the window" },
                    { "window_grid",     "hud.captionExtend",   "press a cell down-right to extend" },
                    { "window_grid",     "flash.span",          "%d×%d region" },
                    { "window_snap",     "option.presets.label", "Saved placements" },
                    { "window_deck",     "pick.windows",        "Deck which windows?" },
                }
                for _, e in ipairs(sweep) do
                    ok(i18n.tFeature(e[1], e[2], e[3]) ~= e[3],
                        e[1] .. " localizes runtime key '" .. e[2] .. "' in zh (no English leak)")
                end
            end

            -- Leaf-util invariant: the leaf utils (platform.windows/hotkeys/json/urls/
            -- cyclingChooser) must have ZERO `require` -- that require-freedom is exactly what lets a feature
            -- `require` them safely (the layer map's leaf tier). Nothing else guards this
            -- (no luacheck / CI grep), so assert it HERE: it runs in both `lua test/run.lua`
            -- and `scripts/test-lua.sh` (the exact embedded engine), failing loudly if a
            -- ported window algorithm or a careless edit drags a require into the pure layer.
            -- Code lines only -- a comment mentioning "require" (windows.lua's header does)
            -- is skipped so prose never trips the guard.
            do
                local appdir = require("loader").appdir
                for _, leaf in ipairs({ "windows", "hotkeys", "json", "urls", "cyclingChooser" }) do
                    local path = appdir .. "/platform/lua/" .. leaf .. ".lua"
                    local fh = assert(io.open(path, "r"), "leaf-guard: cannot open " .. path)
                    local offender
                    for line in fh:lines() do
                        if not line:match("^%s*%-%-") and line:match("require%s*[%(\"']") then
                            offender = line
                            break
                        end
                    end
                    fh:close()
                    ok(offender == nil,
                        "leaf util platform." .. leaf .. " stays require-free (layer invariant)"
                        .. (offender and (" -- found: " .. offender) or ""))
                end
            end

            -- (Mnemonics, action labels, option strings and the runtime ctx.t/ctx.plural
            -- keys are all guarded wholesale by i18n_parity.lua -- the localization GATE,
            -- which diffs describe() across locales instead of hand-listing keys. The
            -- sweep above stays as a fast, readable canary on specific strings.)

            -- RESET to the source language for the rest of the suite.
            i18n.configure({ locale = "en" })
            ok(i18n.t("window.noFocused", "No focused window") == "No focused window",
                "i18n.t returns the inline English source when locale is en")
            ok(i18n.plural("x.count", 1, forms) == "%d window",
                "en plural category splits one/other")
        end
    end,
}
