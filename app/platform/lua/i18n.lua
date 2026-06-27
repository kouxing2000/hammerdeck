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
--   * an English-only feature needs no catalog file -- it just ships its folder.
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
local appdir               -- resolved from loader, overridable for tests

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
    if locale ~= "en" then
        globalCat = readCatalog(appdir .. "/i18n/" .. locale .. ".json") or {}
    end
end

--- The currently resolved locale code.
---@return string
function M.locale() return locale end

local function featureCatalog(id)
    if locale == "en" then return nil end
    if not appdir then appdir = require("loader").appdir end
    local c = featureCats[id]
    if c == nil then
        c = readCatalog(appdir .. "/features/" .. id .. "/i18n/" .. locale .. ".json") or false
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
    return entry[c] or entry.other or entry.one or key
end

return M
