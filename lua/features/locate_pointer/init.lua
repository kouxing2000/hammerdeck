-- features/locate_pointer
--
-- "Pointer": on-demand pointer utilities. Two independently-bindable actions:
--
--   Locate pointer  -- draws a crosshair around the mouse that follows it for a
--     few seconds, then fades (ported from the MouseCircle spoon). Unlike the
--     donor, the overlay never intercepts clicks -- they pass straight through
--     (the spoon swallowed the click and re-synthesized it).
--   Center pointer on focused window -- warps the pointer to the center of the
--     focused window (screen-center fallback when nothing is focused), then
--     flashes the locator. Was Window Mode's orphan alt+G; it lives here with
--     the other on-demand pointer action (both end in a locate ripple).
--
-- The donor had no hotkey of its own (mouseUtils wrapped it); these actions get
-- defaults and are rebindable like everything else. The locate action keeps id
-- "main" (the single-action sugar's id) so an existing custom hotkey survives.

return {
    api         = 1,
    id          = "locate_pointer",
    name        = "Pointer",
    description = "On-demand pointer helpers -- flash a crosshair to find the "
        .. "mouse, or center it on the focused window.",
    version     = "1.0.0",
    category    = "productivity",

    options = {
        { key = "seconds", type = "int", default = 3,
          label = "Locate: show for (seconds)", min = 1, max = 10 },
    },

    actions = {
        { id = "main", label = "Locate pointer",
          description = "Flash a crosshair around the mouse pointer so you can "
              .. "find it on screen.",
          defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "m" },
          run = function(ctx)
              ctx.locateMouse(ctx.opt("seconds"))
          end },
        { id = "center", label = "Center pointer on focused window",
          description = "Warp the mouse pointer to the center of the focused "
              .. "window, then flash the locator.",
          defaultTrigger = { type = "hotkey", mods = { "alt" }, key = "g" },
          run = function(ctx)
              local f = ctx.focusedWindowFrame()
              if f then
                  ctx.setMousePosition(f.x + f.w / 2, f.y + f.h / 2)
              else
                  local s = ctx.screenFrames()[1]
                  if s then ctx.setMousePosition(s.x + s.w / 2, s.y + s.h / 2) end
              end
              ctx.locateMouse(1)
          end },
    },
}
