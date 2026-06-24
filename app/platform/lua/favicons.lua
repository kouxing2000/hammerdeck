-- platform/favicons -- shared favicon cache for chooser features (tab_switcher,
-- site_switcher / Quick Sites). A pure factory module (requires only the leaf
-- platform.urls); all state lives in the object `new(ctx)` returns, scoped to
-- the ctx passed in. Reads from / writes to the ONE shared
-- <cacheDir>/favicons/<domain>.png dir, so an icon either feature pulls shows
-- for both. Operates entirely through the feature's own ctx -- it never reaches
-- the seam.

local getDomain = require("platform.urls").getDomain

local FAVICON_URL = "https://%s/favicon.ico"

-- Image magic bytes (PNG / ICO / GIF / JPEG / BMP / RIFF-WEBP): a cached favicon
-- must start like an image or it is ignored (some sites answer /favicon.ico with
-- an HTML page and status 200).
local function looksLikeImage(bytes)
    if not bytes or #bytes < 4 then return false end
    local b4 = bytes:sub(1, 4)
    return b4 == "\137PNG" or b4 == "\0\0\1\0" or b4:sub(1, 3) == "GIF8"
        or bytes:byte(1) == 255 and bytes:byte(2) == 216   -- JPEG
        or b4:sub(1, 2) == "BM" or b4 == "RIFF"
end

local favicons = {}

-- Create a favicon cache bound to `ctx`. Returns:
--   iconFor(url, fallback?) -> a "file:<path>" icon token when a valid cached
--       icon exists for the URL's domain, else `fallback` (e.g. an app-icon
--       token) or nil.
--   prefetch(urls)          -> fetch any missing icons in the background (shown
--       on the next open): Chrome's local icon DB first, then the site's own
--       /favicon.ico for whatever Chrome doesn't know.
function favicons.new(ctx)
    local dir = ctx.cacheDir() .. "/favicons"
    local fetching = {}   -- domain -> true (download in flight)
    local valid = {}      -- domain -> bool (file checked once; nil = unchecked)

    local function pathFor(domain) return dir .. "/" .. domain .. ".png" end

    local function iconFor(url, fallback)
        local domain = getDomain(url)
        if domain then
            if valid[domain] == nil then
                local p = pathFor(domain)
                valid[domain] = ctx.fileExists(p) and looksLikeImage(ctx.fileRead(p)) or false
            end
            if valid[domain] then return "file:" .. pathFor(domain) end
        end
        return fallback
    end

    local function prefetch(urls)
        ctx.mkdir(dir)
        local missing, seen = {}, {}
        for _, url in ipairs(urls) do
            local domain = getDomain(url)
            if domain and not seen[domain] and not fetching[domain]
                and not ctx.fileExists(pathFor(domain)) then
                seen[domain] = true
                fetching[domain] = true
                missing[#missing + 1] = domain
            end
        end
        if #missing == 0 then return end
        ctx.extractFavicons(dir, missing, function(saved)
            local got = {}
            for _, d in ipairs(saved or {}) do
                got[d] = true
                valid[d] = nil          -- re-validate on next open
                fetching[d] = nil
            end
            for _, d in ipairs(missing) do
                if not got[d] then
                    ctx.downloadFile(FAVICON_URL:format(d), pathFor(d), function()
                        fetching[d] = nil
                        valid[d] = nil
                    end)
                end
            end
        end)
    end

    return { iconFor = iconFor, prefetch = prefetch }
end

return favicons
