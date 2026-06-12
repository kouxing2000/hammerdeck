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

return {
    api         = 1,
    id          = "site_jump",
    name        = "Jump to Site",
    description = "Focus the browser tab for a site (or open it) with one "
        .. "shortcut.",
    version     = "1.0.0",
    category    = "productivity",

    options = {
        { key = "site", type = "string", default = "otter.ai",
          label = "URL contains" },
        { key = "openURL", type = "string", default = "https://www.otter.ai/",
          label = "Open when absent" },
    },

    defaultTrigger = { type = "hotkey", mods = { "ctrl", "cmd" }, key = "6" },

    action = function(ctx)
        local found = ctx.focusBrowserTab(ctx.opt("site"), ctx.opt("openURL"))
        ctx.log(found and ("focused " .. ctx.opt("site"))
                      or ("opened " .. ctx.opt("openURL")))
    end,
}
