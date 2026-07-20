-- features/bing_daily
--
-- Bing picture-of-the-day as wallpaper (ported from the BingDaily spoon).
-- Polls Bing's image API on a schedule, downloads new pictures into the app
-- cache (the donor saved them to ~/.Trash!), and sets the desktop image.
--
-- SERVICE (apply-on-enable + re-assert on display change) + ACTION
-- ("refresh now") whose DEFAULT trigger is a 3h schedule (rebindable in
-- Settings -- e.g. to a daily time): the first feature using the
-- service-plus-actions combo.

local json = require("platform.json")

-- The picture changes once a day; a 3h cadence catches it within hours and
-- re-asserts the wallpaper. This is the refresh action's DEFAULT schedule
-- trigger (rebindable in Settings), not a hidden timer. Most of these ticks
-- cost nothing: refresh() skips the network once it holds the day's picture
-- (see rolloverOf), so the poll is frequent enough to catch the flip promptly
-- without asking Bing the same question eight times a day.
local REFRESH_MINUTES = 3 * 60

local API_URL = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1"
local USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    .. "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

-- When the picture we HOLD stops being current, as "YYYYMMDDHHMM" in UTC --
-- built from Bing's OWN two fields rather than guessed: `enddate` is the day it
-- expires, and `fullstartdate`'s HHMM is the daily flip moment (07:00Z today).
-- Splicing the two needs no date arithmetic and no timezone conversion, so it
-- cannot drift with the host's clock or DST.
--
-- Both halves must be DIGITS, not merely the right length: freshness below is a
-- STRING comparison, and every non-digit byte sorts above "9" -- so a stamp like
-- "unknown!abcd" would read as forever-in-the-future and silence the feature for
-- the life of the install. nil for anything malformed (a non-string included --
-- Bing has no business sending one, but it must not throw in here), which simply
-- means "poll as usual".
local function rolloverOf(pic)
    local day = type(pic.enddate) == "string" and pic.enddate:match("^%d%d%d%d%d%d%d%d$")
    local hhmm = type(pic.fullstartdate) == "string"
        and pic.fullstartdate:match("^%d%d%d%d%d%d%d%d(%d%d%d%d)$")
    if day and hhmm then return day .. hhmm end
end

-- A UTC "YYYYMMDDHHMM" stamp for a time that came from ctx.now(): os.date is
-- FORMATTING here, never a clock read. Zero-padded, so lexicographic order IS
-- chronological order.
local function utcStamp(t) return os.date("!%Y%m%d%H%M", t) end

-- The picture changes daily, so a rollover further out than this is a bad value,
-- not a long day. Without the ceiling one corrupt stamp would wedge the feature
-- into never polling again -- silently, and for good.
local MAX_SKIP_SECONDS = 48 * 60 * 60

-- Do we still hold the current picture? Only if the stored stamp is well-formed
-- AND inside that horizon. A stamp in the past is the ordinary "time to poll".
local function stillCurrent(ctx, stamp)
    if type(stamp) ~= "string" or not stamp:match("^%d%d%d%d%d%d%d%d%d%d%d%d$") then
        return false
    end
    local now = ctx.now()
    return utcStamp(now) < stamp and stamp <= utcStamp(now + MAX_SKIP_SECONDS)
end

-- Set the wallpaper, logging a failure in ONE place. The log is the audit trail
-- for "did the desktop actually change", so an apply that no-ops (no target
-- display, a cache file macOS purged) must never read back as a success.
local function applyWallpaper(ctx, path, applyTo)
    if ctx.setWallpaper(path, applyTo) then return true end
    ctx.log("wallpaper apply failed (target " .. tostring(applyTo) .. "): " .. path)
    return false
end

local function refresh(ctx)
    local applyTo = ctx.opt("applyTo")

    -- The picture changes once a day. Once we hold the current one there is
    -- nothing for Bing to tell us until it rolls over, so skip the request
    -- entirely and just re-assert what we already downloaded -- the trigger
    -- stays local and free for the rest of the day.
    local have, validUntil = ctx.getState("lastPic"), ctx.getState("picRollover")
    if have and stillCurrent(ctx, validUntil) then
        -- Only a re-apply that LANDED earns the skip. If it did not (the cache
        -- file was purged, no display matched), fall through and re-fetch rather
        -- than sit out the rest of the day on a wallpaper we never set.
        if applyWallpaper(ctx, ctx.cacheDir() .. "/" .. have, applyTo) then
            ctx.log("picture current until " .. validUntil .. "Z; skipped the Bing check")
            return
        end
    end

    ctx.httpGet(API_URL, { ["User-Agent"] = USER_AGENT }, function(status, body)
        if status ~= 200 or not body then
            ctx.log("bing request failed (status " .. tostring(status) .. ")")
            return
        end
        local data, derr = json.decode(body)
        local pic = data and data.images and data.images[1]
        if not (pic and pic.url) then
            ctx.log("bing: unexpected response (" .. tostring(derr) .. ")")
            return
        end

        local picUrl = "https://www.bing.com" .. pic.url
        local id = picUrl:match("[?&]id=([^&]+)")
            or ("bing_" .. tostring(ctx.now()))
        local path = ctx.cacheDir() .. "/" .. id

        -- The rollover describes the picture we HOLD, so it is recorded only on
        -- the paths that actually leave us holding one -- NEVER merely because
        -- Bing answered. Recording it up here would mean a failed download left
        -- yesterday's picture paired with tomorrow's stamp, and the skip above
        -- would then sit out every tick until a rollover we never reached.
        local rollover = rolloverOf(pic) or ""

        if ctx.getState("lastPic") == id then
            ctx.setState("picRollover", rollover)   -- Bing can extend the current picture
            if applyWallpaper(ctx, path, applyTo) then
                ctx.log("picture unchanged (" .. id .. "); re-applied")
            end
            return
        end
        ctx.downloadFile(picUrl, path, function(ok)
            if not ok then
                ctx.log("bing: download failed for " .. id)
                return
            end
            ctx.setState("lastPic", id)
            ctx.setState("picRollover", rollover)
            if applyWallpaper(ctx, path, applyTo) then
                ctx.log("wallpaper updated: " .. id)
            end
        end)
    end)
end

return {
    api         = 1,
    id          = "bing_daily",

    options = {
        { key = "applyTo", type = "enum", default = "all",
          values = { "all", "primary" },
          labels = { "All displays", "Main display only" },
          label = "Apply wallpaper to" },
    },

    -- The recurring refresh is the `refresh` action's schedule trigger (visible
    -- + rebindable on its own). This descriptor surfaces the OTHER thing the
    -- service does on its own: re-asserting the wallpaper when a display is
    -- plugged in / rearranged -- an event the Timeline's events lane shows.
    schedule = function()
        return {
            { label = "Re-apply on display change", event = "screenChanged" },
        }
    end,

    -- A minimal service: apply once shortly after enable/boot so the wallpaper
    -- is current immediately (a schedule trigger only fires AFTER its first
    -- interval, never on bind). The recurring refresh is the action's declared
    -- schedule trigger below -- visible and rebindable, per the platform's
    -- "bind each to a schedule" model.
    start = function(ctx)
        ctx.afterSeconds(5, function() refresh(ctx) end)
        -- A display plugged in / rearranged: re-assert the already-downloaded
        -- picture onto all screens immediately (no network), so a new monitor
        -- gets the wallpaper at once instead of waiting for the next poll.
        ctx.onSystemEvent("screenChanged", function()
            local id = ctx.getState("lastPic")
            if id then ctx.setWallpaper(ctx.cacheDir() .. "/" .. id, ctx.opt("applyTo")) end
        end)
        ctx.log("started")
    end,

    actions = {
        { id = "refresh", label = "Refresh wallpaper now",
          -- Context-free (just fetches + sets the wallpaper), so it may run on
          -- an automated trigger -- and its default IS a schedule.
          automatable = true,
          defaultTrigger = { type = "schedule", everyMin = REFRESH_MINUTES },
          run = function(ctx) refresh(ctx) end },
    },
}
