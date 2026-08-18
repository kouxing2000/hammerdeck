-- platform/i18n.lua
--
-- Localization catalog for the platform + features.
--
-- ONE authority resolves the locale: the Swift LocaleResolver, surfaced as
-- adapter.locale(). The bootstrap injects that code here via i18n.configure, so
-- Swift and Lua localize against the same string (e.g. "zh-Hans").
--
-- ENGLISH IS THE SOURCE LANGUAGE and lives INLINE at every call site as the
-- `default` argument. Only non-English locales ship a JSON catalog, so:
--   * when the resolved locale is "en", every lookup returns its inline default
--     (no file is read at all), and
--   * MECHANICALLY, a feature with no catalog file still runs -- every lookup just
--     falls back to English.
--
-- That fallback is deliberate (a missing string must never surface a raw dotted key)
-- but it makes a MISSING translation invisible at runtime: the zh UI simply speaks
-- English and nothing fails. So the suite, not the engine, holds the line -- a SHIPPED
-- feature must carry a zh-Hans catalog covering every string it can render, and
-- test/cases/_integration/platform/i18n_parity.lua fails the build otherwise (the Swift
-- chrome's half is LocalizationTests.testEveryChromeStringIsTranslated). Ship a new
-- feature's zh-Hans.json with it; an untranslated string is a red suite, not a shrug.
--
-- Catalogs are flat JSON objects (dotted string keys -> string values; a value
-- may instead be a {one=,other=} object for a plural). Two scopes:
--   <appdir>/i18n/<locale>.json                 -- chrome + shared platform strings (GLOBAL keys)
--   <appdir>/features/<id>/i18n/<locale>.json    -- one feature's strings (SHORT, feature-relative keys)
--
-- Lookup order is: translation -> inline default -> the key itself (mirrors
-- NSLocalizedString). This module is a PLATFORM module: it reads files with `io`
-- (exactly like the registry reads feature.json) and never touches the seam.
-- Features reach it only through ctx.t / ctx.plural; the platform.windows leaf
-- localizes through the ctx handed to it.

local M = {}

local json                 -- platform.json, required lazily (cost only when used)
local locale       = "en"
local globalCat    = {}    -- resolved-locale chrome/platform catalog
local featureCats  = {}    -- id -> catalog table | false (false = checked, absent)
local featureRoots = {}    -- id -> feature dir OVERRIDE (user extensions live outside
                           -- <appdir>/features; the registry maps each one here at
                           -- register time -- see M.setFeatureRoot)
local appdir               -- resolved from loader, overridable for tests
local logger               -- optional sink for bad-template warnings, INJECTED at boot
                           -- (this module never touches the seam, so it cannot log itself)
local warnedTemplates = {} -- key -> true: a broken template warns ONCE, not per render

local function readCatalog(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()
    json = json or require("platform.json")
    local ok, doc = pcall(json.decode, raw)
    if not ok or type(doc) ~= "table" then return nil end
    return doc
end

--- (Re)load catalogs for a resolved locale. Called by the bootstrap with
--- adapter.locale(), and by tests. Clears the per-feature cache so a language
--- switch followed by registry.describe() yields the new language.
---@param opts table? `{ locale = "zh-Hans", appdir = "app" }` (both optional)
function M.configure(opts)
    opts        = opts or {}
    locale      = opts.locale or "en"
    appdir      = opts.appdir or require("loader").appdir
    globalCat   = {}
    featureCats = {}
    -- Cleared with the cache: configure is the canonical reset (freshWorld,
    -- reload). Both callers re-REGISTER features afterwards, and registration
    -- is what repopulates this map (registry.register -> setFeatureRoot), so an
    -- extension's catalog root is never stale and never leaks across resets.
    featureRoots = {}
    -- The log sink SURVIVES a reconfigure (a locale switch re-reads the catalogs but
    -- must not go silent); pass it once at boot.
    if opts.log ~= nil then logger = opts.log end
    if locale ~= "en" then
        globalCat = readCatalog(appdir .. "/i18n/" .. locale .. ".json") or {}
    end
end

--- The currently resolved locale code.
---@return string
function M.locale() return locale end

--- Override where one feature's i18n/ folder lives. Built-in features resolve
--- under <appdir>/features/<id>; a user EXTENSION lives in the user's own
--- folder, so the registry maps its id -> <extensionsDir>/<id> here at register
--- time (after every configure -- see the reset note in M.configure).
---@param id string feature id
---@param dir string the feature's own folder (holds i18n/<locale>.json)
function M.setFeatureRoot(id, dir)
    featureRoots[id] = dir
end

local function featureCatalog(id)
    if locale == "en" then return nil end
    if not appdir then appdir = require("loader").appdir end
    local c = featureCats[id]
    if c == nil then
        local root = featureRoots[id] or (appdir .. "/features/" .. id)
        c = readCatalog(root .. "/i18n/" .. locale .. ".json") or false
        featureCats[id] = c
    end
    return c or nil
end

--- Resolve a GLOBAL (chrome / shared-platform) key. `default` is the inline
--- English source; returned when there is no translation. Interpolation is the
--- caller's job (string.format over the returned template) so placeholders stay
--- identical across locales.
---@param key string
---@param default string?
---@return string
function M.t(key, default)
    if locale ~= "en" then
        local v = globalCat[key]
        if type(v) == "string" then return v end
    end
    if default ~= nil then return default end
    return key
end

--- Resolve a feature-scoped key against features/<id>/i18n/<locale>.json (a
--- SHORT, feature-relative key), then the GLOBAL catalog (so a feature can reuse
--- a shared platform string), then the inline default, then the key. Backs both
--- the registry's describe() metadata localization and ctx.t.
---@param id string feature id
---@param key string feature-relative key
---@param default string?
---@return string
function M.tFeature(id, key, default)
    if locale ~= "en" then
        local cat = featureCatalog(id)
        if cat and type(cat[key]) == "string" then return cat[key] end
        -- Shared platform strings live under DOTTED keys (window.*, trigger.*);
        -- a bare feature key (name/description/label) must NEVER pick up a same-
        -- named global key, so only dotted keys fall back to the global catalog.
        if key:find(".", 1, true) and type(globalCat[key]) == "string" then
            return globalCat[key]
        end
    end
    if default ~= nil then return default end
    return key
end

--- CLDR plural category for the current locale and `count`. English splits
--- one/other; the CJK locales we ship (zh-Hans) have a single category (other).
---@param count number
---@return string "one"|"other"
function M.category(count)
    if locale == "en" then
        return count == 1 and "one" or "other"
    end
    return "other"
end

--- Pick a plural TEMPLATE for `count`. `forms` is the inline English source as a
--- {one=,other=} table (or a plain string used for every count); a catalog entry
--- of the same shape overrides it. Returns the chosen template -- the caller
--- still does the string.format with the count (and any other args), so the
--- placeholder contract is uniform with M.t.
---@param key string lookup key
---@param count number
---@param forms table|string inline source: { one=, other= } or a string
---@param id string? feature id -> feature-scoped key; nil -> global key
---@return string
function M.plural(key, count, forms, id)
    local entry
    if locale ~= "en" then
        if id then
            local cat = featureCatalog(id)
            entry = cat and cat[key] or nil
            -- dotted keys only, mirroring tFeature's global-fallback guard
            if entry == nil and key:find(".", 1, true) then entry = globalCat[key] end
        else
            entry = globalCat[key]
        end
    end
    if entry == nil then entry = forms end
    if type(entry) == "string" then return entry end
    if type(entry) ~= "table" then return key end
    local c = M.category(count)
    local picked = entry[c] or entry.other or entry.one
    -- Type-check the catalog value, exactly as M.t/M.tFeature do. A translator can typo a
    -- form as a JSON number ("other": 3) or a bool, and handing that to a formatter that
    -- expects a string is a crash, not a translation bug. An untyped form falls back to the
    -- inline English `forms`, which is authored in-repo and trustworthy.
    if type(picked) ~= "string" then
        if type(forms) == "string" then return forms end
        if type(forms) == "table" then
            local en = forms[c] or forms.other or forms.one
            if type(en) == "string" then return en end
        end
        return key
    end
    return picked
end

-- ---------------------------------------------------------------------------
-- FORMATTING. Lua's string.format has NO positional specifiers: `%2$s` raises
-- "invalid conversion '%2$' to 'format'" (Sources/CLua/lstrlib.c checkformat --
-- flags, width, precision, then an ALPHA conversion char; '$' can never appear),
-- and it consumes arguments strictly in order. A 2009 patch to add the POSIX
-- extension was never accepted upstream, so every solution lives above format().
--
-- That limitation is a localization bug, because word order is not universal:
-- "Set wallpaper <color> on <display>" has to become "把 <display> 的壁纸设为
-- <color>" in some languages, and a translator handed only `%s %s` cannot say so.
-- Worse, `%1$s` is exactly what a translator WILL write -- Apple .strings, gettext,
-- and the Swift half of this very catalog (String(format:)) all support it -- and in
-- Lua it does not degrade, it THROWS, from inside a firing rule.
--
-- So this layer owns formatting:
--   * it accepts `%1$s` / `%2$s` and reorders the arguments before string.format;
--   * it NEVER throws -- a broken template (bad spec, too many slots, positional
--     mixed with plain) falls back to the ENGLISH source and warns once.
-- A malformed translation is then a cosmetic bug, never a crash.

--- Rewrite "%2$s ... %1$s" into "%s ... %s" plus the argument order it implies.
--- Returns (template, order) for a positional template, (template, nil) for a plain
--- one, or (nil, reason) when the two styles are MIXED -- which POSIX leaves
--- undefined and we refuse rather than guess.
---@param tpl string
---@return string|nil template  nil when the template is unusable
---@return integer[]|nil order  the argument order, when the template is positional
---@return string|nil reason    why the template is unusable
local function expandPositional(tpl)
    -- No cheap `find` pre-check: "100%%1$ off %s" contains the bytes of a positional
    -- specifier but they belong to an ESCAPED percent, and a naive pre-check would send a
    -- perfectly plain template down the positional path and get it refused as "mixed".
    -- The scanner below is the only thing that knows the difference.
    local out, order, plain = {}, {}, 0
    local i, n = 1, #tpl
    while i <= n do
        local c = tpl:sub(i, i)
        if c ~= "%" then
            out[#out + 1] = c
            i = i + 1
        elseif tpl:sub(i + 1, i + 1) == "%" then
            out[#out + 1] = "%%"                            -- an escaped percent
            i = i + 2
        else
            local num = tpl:match("^(%d+)%$", i + 1)
            if num then
                order[#order + 1] = tonumber(num)
                out[#out + 1] = "%"
                i = i + 1 + #num + 1                        -- skip "%", digits, "$"
            else
                plain = plain + 1                           -- a plain conversion
                out[#out + 1] = "%"
                i = i + 1
            end
        end
    end
    if #order == 0 then return tpl, nil, nil end        -- a plain template: hand it back as-is
    if plain > 0 then
        return nil, nil, "mixes positional (%1$s) and plain (%s) specifiers"
    end
    return table.concat(out), order, nil
end

--- Format `tpl`, honouring positional specifiers, and NEVER raise: on any failure
--- fall back to `fallback` (the English source), warn once under `key`, and if even
--- that fails, return the raw fallback text. Returns the formatted string.
local function safeFormat(key, tpl, fallback, ...)
    local args = table.pack(...)
    -- NEVER RAISE means never -- for the TEMPLATE (a mistyped catalog value that slipped past
    -- a lookup: `"other": 3`) and for the FALLBACK alike. Either one reaching the scanner as
    -- a non-string blows up on `#tpl`, and a crash from a bad translation inside a firing
    -- rule is the exact class this layer exists to make impossible.
    if type(tpl) ~= "string" then tpl = nil end
    if type(fallback) ~= "string" then fallback = tostring(fallback) end
    -- Key the once-per-template warning by the TEMPLATE too, not just the key: several
    -- features share a key name (three declare "alert.axRequired"), and a plural has two
    -- forms under one key -- keying by name alone would let the first broken one silence
    -- every other.
    local warnKey = tostring(key) .. "\0" .. tostring(tpl)
    local function warn(why)
        if not warnedTemplates[warnKey] then
            warnedTemplates[warnKey] = true
            if logger then
                logger("i18n: bad template for '" .. key .. "' (" .. why ..
                    ") -- falling back to English: " .. tostring(tpl))
            end
        end
    end

    local form, order, reason
    if tpl == nil then
        reason = "template is not a string"
    else
        form, order, reason = expandPositional(tpl)
    end
    local okFmt, res
    if form == nil then
        warn(tostring(reason))
    elseif order then
        local reordered, bad = {}, false
        for slot, argIndex in ipairs(order) do
            if argIndex < 1 or argIndex > args.n then bad = true break end
            reordered[slot] = args[argIndex]
        end
        if bad then
            warn("a positional slot has no matching argument")
        else
            okFmt, res = pcall(string.format, form, table.unpack(reordered, 1, #order))
            if not okFmt then warn(tostring(res)) end
        end
    else
        okFmt, res = pcall(string.format, form, table.unpack(args, 1, args.n))
        if not okFmt then warn(tostring(res)) end
    end
    if okFmt then return res end

    -- The English source is authored in-repo (not by a translator), so it is the
    -- trustworthy fallback -- but it is ALSO positional ("Move %1$s to %2$s" is the house
    -- style for any multi-slot template), so it needs the same expansion. Guard it too:
    -- the fallback path must never trade one throw for another.
    local enForm, enOrder = expandPositional(fallback)
    local okEn, en
    if enForm and enOrder then
        local reordered, bad = {}, false
        for slot, argIndex in ipairs(enOrder) do
            -- same bounds check as the primary path: without it a broken English source
            -- ("%3$s" with two args) formats `nil` into the string instead of failing over
            -- to the raw text.
            if argIndex < 1 or argIndex > args.n then bad = true break end
            reordered[slot] = args[argIndex]
        end
        if not bad then
            okEn, en = pcall(string.format, enForm, table.unpack(reordered, 1, #enOrder))
        end
    elseif enForm then
        okEn, en = pcall(string.format, enForm, table.unpack(args, 1, args.n))
    end
    return okEn and en or tostring(fallback)
end

--- Look up `key` and format it with `...`. `en` is the inline English source, used
--- both as the missing-key default and as the fallback if the translation's template
--- is broken. THE call for any string with a placeholder.
---@param key string
---@param en string English source template
---@return string
function M.format(key, en, ...)
    return safeFormat(key, M.t(key, en), en, ...)
end

--- The feature-scoped twin of M.format (resolves against features/<id>/i18n/<locale>.json,
--- then the global catalog). Backs ctx.t(key, default, ...) -- the ONLY formatting path a
--- feature should use, so a feature's translations get positional support and the
--- never-throws guarantee exactly like the platform's do.
---@param id string feature id
---@param key string
---@param en string English source template
---@return string
function M.formatFeature(id, key, en, ...)
    return safeFormat(key, M.tFeature(id, key, en), en, ...)
end

--- The plural twin: pick the template for `count` (catalog or inline `forms`), then
--- format it the same safe way. `forms` is { one=, other= } (or a string).
---@param key string
---@param count number
---@param forms table|string
---@param id string? feature id -> a feature-scoped key
---@return string
function M.formatPlural(key, count, forms, id, ...)
    local tpl = M.plural(key, count, forms, id)
    local en  = type(forms) == "table"
        and (forms[count == 1 and "one" or "other"] or forms.other or forms.one or key)
        or tostring(forms)
    return safeFormat(key, tpl, en, ...)
end

--- Test seam: forget which templates have already warned (they warn once per process).
function M.resetTemplateWarnings() warnedTemplates = {} end

return M
