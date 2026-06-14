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
-- trigger (rebindable in Settings), not a hidden timer.
local REFRESH_MINUTES = 3 * 60

local API_URL = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1"
local USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    .. "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

local function refresh(ctx)
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

        local applyTo = ctx.opt("applyTo")
        if ctx.getState("lastPic") == id then
            ctx.setWallpaper(path, applyTo)   -- same picture; make sure it's applied
            return
        end
        ctx.downloadFile(picUrl, path, function(ok)
            if not ok then
                ctx.log("bing: download failed for " .. id)
                return
            end
            ctx.setState("lastPic", id)
            ctx.setWallpaper(path, applyTo)
            ctx.log("wallpaper updated: " .. id)
        end)
    end)
end

return {
    api         = 1,
    id          = "bing_daily",
    name        = "Bing Daily Wallpaper",
    description = "Sets Bing's picture of the day as your wallpaper, "
        .. "refreshed on a schedule.",
    version     = "1.1.0",
    category    = "appearance",

    options = {
        { key = "applyTo", type = "enum", default = "all",
          values = { "all", "primary" },
          labels = { "All displays", "Main display only" },
          label = "Apply wallpaper to" },
    },

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
          defaultTrigger = { type = "schedule", everyMin = REFRESH_MINUTES },
          run = function(ctx) refresh(ctx) end },
    },
}
