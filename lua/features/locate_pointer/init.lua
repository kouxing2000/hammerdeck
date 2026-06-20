-- features/locate_pointer
--
-- "Where is my pointer?": draws a crosshair around the mouse that follows it
-- for a few seconds, then fades (ported from the MouseCircle spoon). Unlike
-- the donor, the overlay never intercepts clicks -- they pass straight
-- through (the spoon swallowed the click and re-synthesized it).
--
-- The donor had no hotkey of its own (mouseUtils wrapped it); this feature
-- gets a default and is rebindable like everything else.

return {
    api         = 1,
    id          = "locate_pointer",
    name        = "Locate Pointer",
    description = "Draws a crosshair around the mouse pointer for a moment, "
        .. "following it as it moves.",
    version     = "1.0.0",
    category    = "productivity",

    options = {
        { key = "seconds", type = "int", default = 3,
          label = "Show for (seconds)", min = 1, max = 10 },
    },

    defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "m" },

    action = function(ctx)
        ctx.locateMouse(ctx.opt("seconds"))
    end,
}
