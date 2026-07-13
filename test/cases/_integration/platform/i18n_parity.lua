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

--- The conversion specifiers in a template, in order -- "Set %s on %2$d" -> {"s","d"},
--- with `positional` set when any slot names its argument. `%%` is an escape, not a slot.
---@param tpl string
---@return string[] specs
---@return boolean positional
local function placeholders(tpl)
    local specs, positional, plain = {}, false, 0
    local i, n = 1, #tpl
    while i <= n do
        if tpl:sub(i, i) ~= "%" then
            i = i + 1
        elseif tpl:sub(i + 1, i + 1) == "%" then
            i = i + 2                                        -- escaped percent
        else
            local j = i + 1
            local num = tpl:match("^(%d+)%$", j)
            if num then positional = true; j = j + #num + 1 else plain = plain + 1 end
            j = j + #(tpl:match("^[-+ #0]*", j) or "")       -- flags
            j = j + #(tpl:match("^%d*%.?%d*", j) or "")      -- width.precision
            local conv = tpl:sub(j, j)
            if conv:match("%a") then specs[#specs + 1] = conv end
            i = j + 1
        end
    end
    return specs, positional, plain
end

--- HOUSE RULE: a template with 2+ slots must NUMBER them (%1$s / %2$s).
---
--- With one slot there is nothing to reorder and a number is noise. With two or more,
--- plain %s makes ARGUMENT ORDER load-bearing -- and no author can know which language
--- will need a different order. Chinese wants the target first ("把 <display> 的壁纸设为
--- <color>"), so the translator's only options were to contort the sentence or to reorder
--- and silently feed the arguments to the wrong slots. Numbering the SOURCE removes the
--- trap: a translator can always rearrange, and i18n.format reorders the arguments to
--- match. (This is what Apple .strings and gettext have always told you to do.)
---@return string|nil reason  nil when the template is fine
local function unnumbered(tpl)
    local specs, positional, plain = placeholders(tpl)
    -- MIXED is worse than unnumbered: Lua's i18n.format REFUSES it (degrades to English),
    -- and Swift's String(format:) is UNDEFINED with a format string that mixes positional
    -- and non-positional specifiers -- it can read the wrong vararg or crash. The gate is
    -- the only thing standing between a translator and that, so it must not accept what the
    -- engines cannot execute.
    if positional and plain > 0 then
        return "MIXES positional (%1$s) and plain (%s) specifiers -- number ALL of them"
    end
    if #specs >= 2 and not positional then
        return "has " .. #specs .. " slots but no positional markers -- write %1$s / %2$s "
            .. "so a locale can reorder them"
    end
    return nil
end

--- Does a translation's placeholder set still fit the arguments the CALLER passes?
--- Two ways to break it, both of which reach the user as a wrong string (or, before
--- i18n.format, as a crash):
---   * a different MULTISET -- a slot dropped or invented; string.format then runs out of
---     arguments or silently ignores one.
---   * a different ORDER without positional markers -- "%s %d" reworded as "%d %s" feeds
---     the arguments to the wrong slots, because plain Lua format is strictly sequential.
---     Reordering is legal ONLY when the translation says so with %1$s / %2$s.
---@return string|nil reason  nil when the translation is safe
local function placeholderMismatch(en, zh)
    local se = placeholders(en)
    local sz, positional = placeholders(zh)
    if #se ~= #sz then
        return "placeholder count " .. #se .. " -> " .. #sz
    end
    if positional then                                       -- order is explicit; multiset must match
        local a, b = { table.unpack(se) }, { table.unpack(sz) }
        table.sort(a); table.sort(b)
        for i = 1, #a do
            if a[i] ~= b[i] then
                return "positional template changes the placeholder TYPES ("
                    .. table.concat(a, ",") .. " -> " .. table.concat(b, ",") .. ")"
            end
        end
        return nil
    end
    for i = 1, #se do                                        -- no markers: order is load-bearing
        if se[i] ~= sz[i] then
            return "reorders %" .. se[i] .. " and %" .. sz[i]
                .. " without positional markers (use %1$s / %2$s to reorder)"
        end
    end
    return nil
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
        local unNo = {}   -- 2+-slot templates that forgot to number their slots
        local badFeatSlots = {}   -- feature translations whose slots don't fit the args
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
                            -- the house rule, on the SOURCE (an unnumbered source is what
                            -- makes argument order load-bearing for every translator)
                            local why = unnumbered(source)
                            if why then unNo[#unNo + 1] = id .. " " .. key .. ": " .. why end
                            -- ...and on the TRANSLATION, which must stay reorderable too,
                            -- AND its slots must still fit the arguments the feature passes:
                            -- a dropped/invented slot renders wrong (i18n.format degrades it
                            -- to English rather than crashing -- which is exactly why only a
                            -- build-time check can see it).
                            local zh = featCat[id][key] or globalCat[key]
                            if type(zh) == "string" then
                                local why2 = unnumbered(zh)
                                if why2 then unNo[#unNo + 1] = id .. " " .. key .. " (zh): " .. why2 end
                                local why3 = placeholderMismatch(source, zh)
                                if why3 then
                                    badFeatSlots[#badFeatSlots + 1] = id .. " " .. key .. ": " .. why3
                                end
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
        ok(#badFeatSlots == 0,
            "i18n-parity: every feature translation's placeholders match its source"
            .. (#badFeatSlots > 0 and (" -- BROKEN: " .. table.concat(badFeatSlots, " | ")) or ""))
        ok(#unNo == 0, "i18n-parity: every 2+-slot template numbers its slots (%1$s / %2$s)"
            .. (#unNo > 0 and (" -- " .. table.concat(unNo, " | ")) or ""))
        ok(rfiles >= #ids, "i18n-parity: scanned every feature's lua modules (" .. rfiles .. ")")
        ok(rchecked > 0, "i18n-parity: runtime strings checked (" .. rchecked .. ")")
        ok(#rleaks == 0, "i18n-parity: every runtime ctx.t/ctx.plural string is translated"
            .. (#rleaks > 0 and (" -- UNTRANSLATED: " .. table.concat(rleaks, " | ")) or ""))

        -- ---------------------------------------------------------- the rules engine
        -- The rules UI's VOCABULARY and GRAMMAR live in Lua (signals' nouns and verbs,
        -- effects' labels and clauses, the sentence templates) and cross to the host as
        -- DATA -- never through Strings.t. So the Swift gate is structurally blind to
        -- them, and until 2026-07 every one of them was English in a Chinese build.
        -- Same trick as above: run the real export under both locales and diff.
        do
            local rules   = require("platform.rules")
            local effects = require("platform.effects")
            local signals = require("platform.signals")

            local rleaks2, rchecked2 = {}, 0
            local function cmp2(what, e, z)
                if type(e) ~= "string" or e == "" or untranslatable(e) then return end
                rchecked2 = rchecked2 + 1
                if e == z then rleaks2[#rleaks2 + 1] = what .. ": " .. e end
            end

            -- RECORD every key this surface looks up, instead of diffing its output.
            -- A value-diff alone is fooled by PARTIAL English: delete rules.sentence.when
            -- and the grammar falls back to "When %s, %s." while the vocabulary inside it
            -- stays Chinese -- the sentence still differs from the English one, so a diff
            -- sees nothing wrong. Recording the keys the code ASKS FOR and demanding each
            -- one exists closes that hole, and needs no key list to go stale.
            local asked, source = {}, {}     -- key -> "string"|"plural";  key -> English source
            local realT, realPlural = i18n.t, i18n.plural
            local function record(fn)
                i18n.t = function(key, default)
                    asked[key] = "string"
                    if type(default) == "string" then source[key] = default end
                    return realT(key, default)
                end
                i18n.plural = function(key, n, forms, id)
                    asked[key] = "plural"
                    if type(forms) == "table" then
                        source[key] = forms.other or forms.one
                    elseif type(forms) == "string" then
                        source[key] = forms
                    end
                    return realPlural(key, n, forms, id)
                end
                local okRun, err = pcall(fn)
                i18n.t, i18n.plural = realT, realPlural       -- always restore
                assert(okRun, err)
            end

            -- formOptions() is what the Add-rule form populates its dropdowns from.
            i18n.configure({ locale = "en", appdir = appdir })
            local fo_en = rules.formOptions()
            i18n.configure({ locale = "zh-Hans", appdir = appdir })
            local fo_zh = rules.formOptions()

            for name, m in pairs(fo_en.signalMeta or {}) do
                local z = (fo_zh.signalMeta or {})[name] or {}
                for _, f in ipairs({ "label", "valueLabel", "enterVerb", "leaveVerb" }) do
                    cmp2("signal." .. name .. "." .. f, m[f], z[f])
                end
            end
            for i, e in ipairs(fo_en.effects or {}) do
                cmp2("effect[" .. i .. "].label", e.label, ((fo_zh.effects or {})[i] or {}).label)
            end
            for i, p in ipairs(fo_en.layoutPositions or {}) do
                cmp2("position." .. tostring(p.id), p.label,
                    ((fo_zh.layoutPositions or {})[i] or {}).label)
            end

            -- Every effect KIND's read-back clause. A fixture per kind, and the coverage
            -- assertion below means a NEW kind cannot be added without one -- otherwise
            -- this list would rot into "the kinds someone remembered", the exact failure
            -- the describe()-diff design exists to avoid.
            local FIXTURES = {
                notify        = { kind = "notify", title = "T" },
                layout        = { kind = "layout", placements = { { app = "A", screen = "S", pos = "left" } } },
                runShortcut   = { kind = "runShortcut", name = "S" },
                openURL       = { kind = "openURL", url = "https://x.dev" },
                lockScreen    = { kind = "lockScreen" },
                startScreensaver = { kind = "startScreensaver" },
                speak         = { kind = "speak", text = "hi" },
                emptyTrash    = { kind = "emptyTrash" },
                eject         = { kind = "eject" },
                setAppearance = { kind = "setAppearance", mode = "dark" },
                volume        = { kind = "volume", op = "up" },
                mediaKey      = { kind = "mediaKey", key = "next" },
                solidWallpaper = { kind = "solidWallpaper", color = "#FFFFFF", display = "all" },
                setWallpaperImage = { kind = "setWallpaperImage", image = "/p/a.jpg", display = "primary" },
                moveAppToDisplay = { kind = "moveAppToDisplay", app = "A", display = "primary" },
                launchApp     = { kind = "launchApp", app = "A" },
                minimizeApp   = { kind = "minimizeApp", app = "@trigger:app" },
                hideApp       = { kind = "hideApp", app = "@trigger:app" },
                quitApp       = { kind = "quitApp", app = "@trigger:app" },
                chain         = { kind = "chain", effects = { { kind = "lockScreen" }, { kind = "emptyTrash" } } },
            }
            -- Branch fixtures: a kind whose describe() switches on a value renders a
            -- DIFFERENT key per branch, so one fixture per kind leaves the rest unguarded.
            local BRANCHES = {
                { kind = "setAppearance", mode = "light" },
                { kind = "setAppearance", mode = "toggle" },
                { kind = "volume", op = "down" },
                { kind = "volume", op = "mute" },
                { kind = "mediaKey", key = "previous" },
                { kind = "mediaKey", key = "playpause" },
                { kind = "chain", effects = {} },                              -- chain.empty
                { kind = "solidWallpaper", color = "#F2F2F2", display = "external" },
                { kind = "solidWallpaper", color = "#808080", display = "primary" },
                { kind = "solidWallpaper", color = "#000000", display = "@trigger:display" },
                { kind = "moveAppToDisplay", app = "@trigger:app", display = "all" },
            }
            for i, node in ipairs(BRANCHES) do
                i18n.configure({ locale = "en", appdir = appdir })
                local d_en = effects.describe(node, nil)
                i18n.configure({ locale = "zh-Hans", appdir = appdir })
                record(function()
                    cmp2("effectDesc.branch[" .. i .. "]." .. node.kind, d_en, effects.describe(node, nil))
                end)
            end

            -- ...and every EVENT phrase + the daily-at schedule, which rules.sentence keys
            -- per value (only `wake` and `everyMin` were ever exercised).
            local MORE_SPECS = {
                { on = { type = "event", event = "sleep" }, effect = { kind = "lockScreen" } },
                { on = { type = "event", event = "screenLock" }, effect = { kind = "lockScreen" } },
                { on = { type = "event", event = "screenUnlock" }, effect = { kind = "lockScreen" } },
                { on = { type = "event", event = "screenChanged" }, effect = { kind = "lockScreen" } },
                { on = { type = "schedule", at = "07:30" }, effect = { kind = "emptyTrash" } },
                { on = { type = "schedule", everyMin = 1 }, effect = { kind = "eject" } },  -- the `one` plural form
                { on = { type = "state", signal = "powerSource", leaves = "battery" },
                  effect = { kind = "startScreensaver" } },                    -- leaveVerb path
            }
            for i, spec in ipairs(MORE_SPECS) do
                i18n.configure({ locale = "en", appdir = appdir })
                local s_en = rules.sentence(spec)
                i18n.configure({ locale = "zh-Hans", appdir = appdir })
                record(function()
                    local s_zh = rules.sentence(spec)
                    ok(s_en ~= "" and s_zh ~= "", "i18n-parity: sentence renders for spec #" .. i)
                    cmp2("sentence.more[" .. i .. "]", s_en, s_zh)
                end)
            end

            local uncovered = {}
            for _, e in ipairs(fo_en.effects or {}) do
                -- the command entries are per-action, not a kind; the kinds are the atoms
                if e.kind ~= "command" and not FIXTURES[e.kind] then
                    uncovered[#uncovered + 1] = e.kind
                end
            end
            ok(#uncovered == 0, "i18n-parity: every effect kind has a read-back fixture"
                .. (#uncovered > 0 and (" -- MISSING: " .. table.concat(uncovered, ", ")) or ""))

            -- BOTH pronoun modes. They take different branches and reach different strings:
            -- the sentence read-back says "minimize it" (pronoun), while the rules LIST and
            -- the FIRE LOG say "minimize the triggering app" and "2 steps: A -> B" -- so a
            -- pronoun-only sweep would leave the list/log half of the vocabulary unguarded,
            -- which is exactly where chain's plural and "the triggering %s" live.
            for kind, node in pairs(FIXTURES) do
                for _, pronoun in ipairs({ true, false }) do
                    local opts = pronoun and { pronoun = true } or nil
                    i18n.configure({ locale = "en", appdir = appdir })
                    local d_en = effects.describe(node, opts)
                    i18n.configure({ locale = "zh-Hans", appdir = appdir })
                    record(function()
                        cmp2("effectDesc." .. kind .. (pronoun and " (pronoun)" or " (list)"),
                            d_en, effects.describe(node, opts))
                    end)
                end
            end

            -- And the SENTENCE itself: its grammar (article, word order, joiners) used to
            -- be hardcoded English around the vocabulary. One spec per trigger type.
            local SPECS = {
                state = { on = { type = "state", signal = "appearance", becomes = "dark" },
                          effect = { kind = "lockScreen" } },
                entity = { on = { type = "state", signal = "frontmostApp", leaves = "Slack" },
                           effect = { kind = "minimizeApp", app = "@trigger:app" } },
                event = { on = { type = "event", event = "wake" }, effect = { kind = "emptyTrash" } },
                schedule = { on = { type = "schedule", everyMin = 30 },
                             effect = { kind = "notify", title = "T" } },
            }
            for what, spec in pairs(SPECS) do
                i18n.configure({ locale = "en", appdir = appdir })
                local s_en = rules.sentence(spec)
                i18n.configure({ locale = "zh-Hans", appdir = appdir })
                record(function()
                    local s_zh = rules.sentence(spec)
                    ok(s_en ~= "" and s_zh ~= "",
                        "i18n-parity: rules.sentence builds a " .. what .. " sentence")
                    cmp2("sentence." .. what, s_en, s_zh)
                end)
            end

            -- Re-run the dropdown export under the recorder too, so its vocabulary keys
            -- (signal nouns/verbs, effect labels, snap positions) are presence-checked and
            -- not merely diffed.
            record(function() rules.formOptions() end)

            -- Every key the rules engine ASKED FOR must exist in the shipped catalog.
            local askedMissing, askedCount = {}, 0
            for key, want in pairs(asked) do
                askedCount = askedCount + 1
                if not typeOK(globalCat[key], want) then
                    askedMissing[#askedMissing + 1] = key .. " (" .. want .. ")"
                end
            end
            ok(askedCount > 0, "i18n-parity: rules-engine keys recorded (" .. askedCount .. ")")
            ok(#askedMissing == 0,
                "i18n-parity: every key the rules engine looks up exists in zh-Hans"
                .. (#askedMissing > 0
                    and (" -- MISSING: " .. table.concat(askedMissing, " | ")) or ""))

            -- PLACEHOLDER PARITY. A translation whose slots don't match its English source
            -- is a bug the runtime cannot fix: i18n.format now refuses to crash on it, but
            -- it silently renders English instead -- so the build must catch it. A plain
            -- translation must keep the ORDER too (Lua format is sequential); reordering is
            -- allowed only with explicit %1$s / %2$s markers.
            local badSlots = {}
            for key, en in pairs(source) do
                local zh = globalCat[key]
                if type(zh) == "string" then
                    local why = placeholderMismatch(en, zh)
                    if why then badSlots[#badSlots + 1] = key .. ": " .. why end
                elseif type(zh) == "table" then                  -- a plural: check each form
                    for form, tpl in pairs(zh) do
                        if type(tpl) == "string" then
                            local why = placeholderMismatch(en, tpl)
                            if why then
                                badSlots[#badSlots + 1] = key .. "." .. tostring(form) .. ": " .. why
                            end
                        end
                    end
                end
            end
            ok(#badSlots == 0, "i18n-parity: every rules template's placeholders match its source"
                .. (#badSlots > 0 and (" -- BROKEN: " .. table.concat(badSlots, " | ")) or ""))

            -- The house rule on the rules engine's own templates (source AND translation).
            local unNo2 = {}
            for key, en in pairs(source) do
                local why = unnumbered(en)
                if why then unNo2[#unNo2 + 1] = key .. " (source): " .. why end
                local zh = globalCat[key]
                if type(zh) == "string" then
                    local why2 = unnumbered(zh)
                    if why2 then unNo2[#unNo2 + 1] = key .. " (zh): " .. why2 end
                elseif type(zh) == "table" then
                    for form, tpl in pairs(zh) do
                        if type(tpl) == "string" then
                            local why3 = unnumbered(tpl)
                            if why3 then unNo2[#unNo2 + 1] = key .. "." .. tostring(form) .. " (zh): " .. why3 end
                        end
                    end
                end
            end
            ok(#unNo2 == 0, "i18n-parity: every 2+-slot rules template numbers its slots"
                .. (#unNo2 > 0 and (" -- " .. table.concat(unNo2, " | ")) or ""))

            -- The read-back must never state the OPPOSITE of what the rule does. A signal
            -- that declares only ONE verb (a shape no shipped signal has yet, and therefore
            -- the shape a future one will) must still get the right one: an `enter` condition
            -- takes enterVerb, else the neutral fallback -- NEVER leaveVerb. The obvious
            -- `(enter and m.enterVerb or m.leaveVerb) or fallback` chain gets this wrong.
            do
                local realMeta = signals.meta
                signals.meta = function(name)                       -- a one-verb signal
                    if name == "frontmostApp" then
                        return { label = "Frontmost app", provides = "app",
                                 leaveVerb = "loses focus" }        -- NO enterVerb
                    end
                    return realMeta(name)
                end
                i18n.configure({ locale = "en", appdir = appdir })
                local s = rules.sentence({
                    on = { type = "state", signal = "frontmostApp", becomes = "Slack" },
                    effect = { kind = "lockScreen" } })
                signals.meta = realMeta
                ok(s:find("becomes", 1, true) ~= nil and s:find("loses focus", 1, true) == nil,
                    "an ENTER condition on a leaveVerb-only signal reads 'becomes', never "
                    .. "'loses focus' -- got: " .. s)
            end

            -- The trigger-field nouns (rules.triggerField.<provides>) are keyed by a
            -- SIGNAL's `provides` and reached from Swift by CONCATENATION, so the Swift
            -- scanner cannot resolve them -- the real noun set lives here.
            local provided, missingNoun = 0, {}
            for _, name in ipairs(signals.list()) do        -- list() -> names; meta(name) -> its table
                local p = (signals.meta(name) or {}).provides
                if type(p) == "string" and p ~= "" then
                    provided = provided + 1
                    local key = "rules.triggerField." .. p
                    if not typeOK(globalCat[key], "string") then missingNoun[#missingNoun + 1] = key end
                end
            end
            ok(provided > 0, "i18n-parity: signals declaring `provides` found (" .. provided .. ")")
            ok(#missingNoun == 0, "i18n-parity: every signal's `provides` noun is translated"
                .. (#missingNoun > 0 and (" -- UNTRANSLATED: " .. table.concat(missingNoun, " | ")) or ""))

            ok(rchecked2 > 0, "i18n-parity: rules-engine strings checked (" .. rchecked2 .. ")")
            ok(#rleaks2 == 0, "i18n-parity: the rules engine's vocabulary + grammar are translated"
                .. (#rleaks2 > 0 and (" -- UNTRANSLATED: " .. table.concat(rleaks2, " | ")) or ""))
        end

        -- RESET to the source language for the rest of the suite.
        i18n.configure({ locale = "en" })
    end,
}
