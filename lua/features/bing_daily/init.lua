-- features/bing_daily
--
-- Bing picture-of-the-day as wallpaper (ported from the BingDaily spoon).
-- Polls Bing's image API on a schedule, downloads new pictures into the app
-- cache (the donor saved them to ~/.Trash!), and sets the desktop image.
--
-- SERVICE (refresh timer) + ACTION ("refresh now", dormant by default --
-- bind a shortcut in Settings if you want one): the first feature using the
-- service-plus-actions combo.

local json = require("platform.json")

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

        if ctx.getState("lastPic") == id then
            ctx.setWallpaper(path)   -- same picture; make sure it's applied
            return
        end
        ctx.downloadFile(picUrl, path, function(ok)
            if not ok then
                ctx.log("bing: download failed for " .. id)
                return
            end
            ctx.setState("lastPic", id)
            ctx.setWallpaper(path)
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
    version     = "1.0.0",
    category    = "appearance",

    options = {
        { key = "refreshHours", type = "int", default = 3,
          label = "Refresh every (hours)", min = 1, max = 24 },
    },

    start = function(ctx)
        ctx.afterSeconds(5, function() refresh(ctx) end)   -- shortly after boot
        ctx.everySeconds(ctx.opt("refreshHours") * 3600, function() refresh(ctx) end)
        ctx.log("started (every " .. ctx.opt("refreshHours") .. "h)")
    end,

    actions = {
        { id = "refresh", label = "Refresh wallpaper now",
          -- Dormant: bind a shortcut in Settings to use it.
          run = function(ctx) refresh(ctx) end },
    },
}
