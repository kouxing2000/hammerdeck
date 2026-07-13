-- test/cases/_integration/platform/i18n_parity.lua -- the LOCALIZATION GATE: no
-- feature string may silently render English in a translated UI.
--
-- Why this exists. i18n.t / tFeature fall back to the inline English default when a key
-- is missing -- by design (a missing string must never show a raw dotted key). The cost
-- of that kindness is that a MISSING translation is INVISIBLE at runtime: it just quietly
-- speaks English at a Chinese user, and nothing fails. An audit in 2026-07 found 18 such
-- leaks in the Lua catalog alone -- half of window_deck's HUD, and every single-action
-- feature's menubar label -- none of which any test could see. (The Swift chrome had 69
-- more; LocalizationTests.testEveryChromeStringIsTranslated guards that half.)
--
-- Two stages, because two things can go wrong:
--
--  1. CATALOG (name/description/action/option strings). Rather than hand-list keys -- a
--     list only catches what someone remembered to add -- this drives the REAL path:
--     describe() once under `en`, once under `zh-Hans`, and diff. A string that comes
--     back BYTE-IDENTICAL in zh is a CANDIDATE leak (describe() fell back to English).
--     Discovery therefore cannot drift out of sync with the registry's key naming.
--  2. RUNTIME (HUD / alert / picker text). These never reach describe(), so each
--     ctx.t / ctx.plural key the source actually asks for is resolved directly.
--
-- Both stages confirm a suspect by KEY PRESENCE in the raw catalog, never by value:
-- "no translation" and "translated to the same bytes" are different things, and only the
-- first is a bug. "[Safari] %s" is correct Chinese; a plural entry is legitimately a
-- {one=,other=} TABLE (which tFeature, returning only strings, would report as missing).
-- Value alone would call both a leak -- and a gate that cries wolf gets deleted.
--
-- A ctx.t whose default is a concatenation or a variable is not matched by the pattern
-- and goes unchecked -- write the default as a plain literal to be covered.
--
-- Integration (platform core). Hermetic: freshWorld() gives a pristine catalog before the
-- case; registering the real features touches no handles (binding happens on enable).

-- The fields registry.lua localizes (see its "Localized feature metadata" header) and the
-- keys it looks them up under. If a new localizable field is added there, add it here or
-- it ships unguarded.
local FEATURE_FIELDS = { "name", "description" }
local ACTION_FIELDS  = { "label", "description", "mnemonic" }
local OPTION_FIELDS  = { "label", "hint", "section", "defaultLabel", "actionLabel" }

--- An English source a Chinese catalog would legitimately leave byte-identical: an acronym
--- or symbol carries no lowercase letter ("AI", "URL", "%s"). Translating it would be
--- wrong, not missing. Anything with a lowercase letter is prose and needs a translation --
--- or, if it must stay verbatim (a brand name), an explicit key holding that same value.
local function untranslatable(s)
    return not s:find("%l")
end

return {
    id = "i18n_parity",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok = t.ok
        local registry = require("platform.registry")
        local i18n     = require("platform.i18n")
        local json     = require("platform.json")
        local appdir   = require("loader").appdir

        local function readJSON(path)
            local fh = io.open(path, "r")
            if not fh then return nil end
            local s = fh:read("a"); fh:close()
            return json.decode(s)
        end
        local globalCat = readJSON(appdir .. "/i18n/zh-Hans.json") or {}
        local featCat = setmetatable({}, { __index = function(tbl, id)
            local c = readJSON(appdir .. "/features/" .. id .. "/i18n/zh-Hans.json") or {}
            rawset(tbl, id, c); return c
        end })

        --- Does the zh catalog carry this key, at a type the lookup will actually USE?
        --- Mirrors tFeature's order: the feature catalog, then -- for dotted keys only --
        --- the shared global one. `want` matters: tFeature returns only STRING entries, so
        --- a table parked where a string belongs would pass a bare presence check and
        --- still fall back to English at runtime. A plural entry is the opposite case:
        --- legitimately a { one=, other= } table (or a string, in a single-category locale).
        local function typeOK(v, want)
            if v == nil then return false end
            if want == "plural" then return type(v) == "string" or type(v) == "table" end
            return type(v) == "string"
        end
        local function hasKey(id, key, want)
            if featCat[id][key] ~= nil then return typeOK(featCat[id][key], want) end
            return key:find(".", 1, true) ~= nil and typeOK(globalCat[key], want)
        end

        -- Every feature on disk (same rule as autodiscovery: <id>/lua/init.lua).
        local ids = {}
        local pipe = assert(io.popen('ls -1 "' .. appdir .. '/features" 2>/dev/null'),
            "i18n-parity: cannot scan " .. appdir .. "/features")
        for id in pipe:lines() do
            local probe = io.open(appdir .. "/features/" .. id .. "/lua/init.lua", "r")
            if probe then probe:close(); ids[#ids + 1] = id end
        end
        pipe:close()
        ok(#ids > 0, "i18n-parity: discovered features on disk (" .. #ids .. ")")

        for _, id in ipairs(ids) do
            registry.register(require("features." .. id .. ".init"))
        end

        -- ------------------------------------------------------------------ catalog
        -- The same describe() the Settings UI, the menubar and the palette read.
        i18n.configure({ locale = "en", appdir = appdir })
        local en = registry.describe()
        i18n.configure({ locale = "zh-Hans", appdir = appdir })
        local zh = registry.describe()
        ok(#en == #zh and #en == #ids,
            "i18n-parity: describe() returns every feature in both locales")

        local leaks, checked = {}, 0
        --- `key` is how the registry looks this field up; a byte-identical zh value is
        --- only a leak when that key is absent (else it is a deliberate same-in-Chinese).
        local function cmp(id, key, e, z)
            if type(e) ~= "string" or e == "" or untranslatable(e) then return end
            checked = checked + 1
            if e == z and not hasKey(id, key) then
                leaks[#leaks + 1] = id .. " " .. key .. ": " .. e
            end
        end

        for i, f in ipairs(en) do
            local g = zh[i]
            for _, k in ipairs(FEATURE_FIELDS) do cmp(f.id, k, f[k], g[k]) end
            -- a feature-contributed native page (Homepage sidebar) titles itself too
            if f.page then cmp(f.id, "page.title", f.page.title, (g.page or {}).title) end
            for j, a in ipairs(f.actions or {}) do
                local b = (g.actions or {})[j] or {}
                for _, k in ipairs(ACTION_FIELDS) do
                    cmp(f.id, "action." .. a.id .. "." .. k, a[k], b[k])
                end
            end
            for j, o in ipairs(f.options or {}) do
                local q = (g.options or {})[j] or {}
                for _, k in ipairs(OPTION_FIELDS) do
                    cmp(f.id, "option." .. o.key .. "." .. k, o[k], q[k])
                end
                -- Enum labels are keyed by VALUE (registry.locOptionLabels), so a
                -- reordering of values cannot mis-key a translation. Mind the false:
                -- `v ~= nil and v or x` collapses a `false` value to the index, which
                -- would key a boolean enum differently than the registry does.
                for x, lbl in ipairs(o.labels or {}) do
                    local v = (o.values or {})[x]
                    local vk = (v ~= nil) and tostring(v) or tostring(x)
                    cmp(f.id, "option." .. o.key .. ".values." .. vk, lbl, (q.labels or {})[x])
                end
            end
        end
        ok(checked > 0, "i18n-parity: catalog strings checked (" .. checked .. ")")
        ok(#leaks == 0, "i18n-parity: every catalog string is translated in zh-Hans"
            .. (#leaks > 0 and (" -- UNTRANSLATED: " .. table.concat(leaks, " | ")) or ""))

        -- ------------------------------------------------------------------ runtime
        -- ctx.t("key", "English default") / ctx.plural("key", n, forms) -- the HUD, alert
        -- and picker strings, which never appear in describe(). Presence, not value: a
        -- plural entry is a table, and "[Safari] %s" is its own translation.
        local rleaks, rchecked, rfiles = {}, 0, 0
        for _, id in ipairs(ids) do
            -- EVERY Lua module the feature ships, not just init.lua: window_deck alone
            -- splits across focus/store/identity/colors, and its HUD strings live there.
            local list = io.popen('ls -1 "' .. appdir .. '/features/' .. id .. '/lua"/*.lua 2>/dev/null')
            for path in list:lines() do
                local fh = io.open(path, "r")
                if fh then
                    local src = fh:read("a"); fh:close()
                    rfiles = rfiles + 1
                    for key, source in src:gmatch('ctx%.t%(%s*"([%w%.%_]+)"%s*,%s*"([^"]*)"') do
                        if source ~= "" and not untranslatable(source) then
                            rchecked = rchecked + 1
                            if not hasKey(id, key, "string") then
                                rleaks[#rleaks + 1] = id .. " " .. key .. ": " .. source
                            end
                        end
                    end
                    for key in src:gmatch('ctx%.plural%(%s*"([%w%.%_]+)"') do
                        rchecked = rchecked + 1
                        if not hasKey(id, key, "plural") then
                            rleaks[#rleaks + 1] = id .. " " .. key .. " (plural)"
                        end
                    end
                end
            end
            list:close()
        end
        ok(rfiles >= #ids, "i18n-parity: scanned every feature's lua modules (" .. rfiles .. ")")
        ok(rchecked > 0, "i18n-parity: runtime strings checked (" .. rchecked .. ")")
        ok(#rleaks == 0, "i18n-parity: every runtime ctx.t/ctx.plural string is translated"
            .. (#rleaks > 0 and (" -- UNTRANSLATED: " .. table.concat(rleaks, " | ")) or ""))

        -- ------------------------------------------------------ dynamic host families
        -- RulesView renders the trigger's noun as Strings.t("rules.triggerField." .. field),
        -- where `field` is a SIGNAL's `provides` -- a key the Swift gate cannot resolve by
        -- scanning source (it is concatenated, not a literal). The real noun set lives
        -- here, in signals.lua, so the check belongs here: every provides value must have
        -- its global key, or the rules builder prints an English noun mid-sentence.
        do
            local signals = require("platform.signals")
            local provided, missing = 0, {}
            for _, name in ipairs(signals.list()) do        -- list() -> names; meta(name) -> its table
                local p = (signals.meta(name) or {}).provides
                if type(p) == "string" and p ~= "" then
                    provided = provided + 1
                    local key = "rules.triggerField." .. p
                    if not typeOK(globalCat[key], "string") then missing[#missing + 1] = key end
                end
            end
            ok(provided > 0, "i18n-parity: signals declaring `provides` found (" .. provided .. ")")
            ok(#missing == 0, "i18n-parity: every signal's `provides` noun is translated"
                .. (#missing > 0 and (" -- UNTRANSLATED: " .. table.concat(missing, " | ")) or ""))
        end

        -- RESET to the source language for the rest of the suite.
        i18n.configure({ locale = "en" })
    end,
}
