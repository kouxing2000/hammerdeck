-- features/site_jump
--
-- Jump to a website: focus the browser tab whose URL contains a pattern, or
-- open it in a new tab when absent (ported from myHammerSpoon
-- modules/misc/miscBindings.lua "locate otter" -- generalized from the
-- hardcoded otter.ai to a configurable site, donor defaults kept).
--
-- The browser automation is a curated seam call (a fixed AppleScript template
-- in the Swift side); first use triggers the macOS Automation permission
-- prompt for controlling Chrome.
--
-- ONE option: the site URL. The tab-match pattern is its domain (minus any
-- leading www.), so the two can never drift apart. (The pre-2026-06-12 "site"
-- option key is retired; a stored value under it is simply ignored.)

local getDomain = require("platform.urls").getDomain

return {
    api         = 1,
    id          = "site_jump",
    name        = "Jump to Site",
    description = "Focus the browser tab for a site (or open it) with one "
        .. "shortcut.",
    version     = "1.1.0",
    category    = "productivity",

    options = {
        { key = "openURL", type = "string", default = "https://www.otter.ai/",
          label = "Site URL" },
    },

    defaultTrigger = { type = "hotkey", mods = { "ctrl", "cmd" }, key = "6" },

    action = function(ctx)
        local url = ctx.opt("openURL")
        local pattern = (getDomain(url) or url):gsub("^www%.", "")
        if pattern == "" then
            ctx.alert("Set the Site URL option first")
            return
        end
        local found = ctx.focusBrowserTab(pattern, url)
        ctx.log(found and ("focused " .. pattern) or ("opened " .. url))
    end,
}
