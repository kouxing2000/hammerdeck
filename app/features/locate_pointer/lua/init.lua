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
--
-- The two "Center pointer on ... screen" actions are the worthwhile half of the
-- old mouseUtils.lua (the rest -- a console coords printer and an HS-Lua region
-- picker -- were authoring aids with no place here). They live alongside the
-- window-center action because all three end in a locate ripple.

-- warp the pointer to the center of a frame {x,y,w,h}, then flash the locator
local function centerOn(ctx, f)
    ctx.setMousePosition(f.x + f.w / 2, f.y + f.h / 2)
    ctx.locateMouse(1)
end

-- the frame after the one currently under the pointer, wrapping around (so on a
-- single-monitor setup it just re-centers on the same screen)
local function nextScreenFrame(frames, pos)
    if #frames == 0 then return nil end
    local cur = 1
    for i, f in ipairs(frames) do
        if pos.x >= f.x and pos.x < f.x + f.w
            and pos.y >= f.y and pos.y < f.y + f.h then
            cur = i
            break
        end
    end
    return frames[(cur % #frames) + 1]
end

return {
    api         = 1,
    id          = "locate_pointer",

    options = {
        { key = "seconds", type = "int", default = 3,
          label = "Locate: show for (seconds)", min = 1, max = 10 },
    },

    actions = {
        { id = "main", label = "Locate pointer",
          description = "Flash a crosshair around the mouse pointer so you can "
              .. "find it on screen.",
          defaultTrigger = { type = "chord", mods = { "cmd", "alt", "ctrl" }, key = "m", follows = { "m" } },
          mnemonic = "M for Mouse (Hyper+M, then M)",
          run = function(ctx)
              ctx.locateMouse(ctx.opt("seconds"))
          end },
        { id = "center", label = "Center pointer on focused window",
          description = "Warp the mouse pointer to the center of the focused "
              .. "window, then flash the locator.",
          defaultTrigger = { type = "chord", mods = { "cmd", "alt", "ctrl" }, key = "m", follows = { "c" } },
          mnemonic = "C for Center (same Hyper+M prefix)",
          run = function(ctx)
              local f = ctx.focusedWindowFrame() or ctx.screenFrames()[1]
              if f then centerOn(ctx, f) end
          end },
        { id = "center_screen", label = "Center pointer on main screen",
          description = "Warp the mouse pointer to the center of the main screen, "
              .. "then flash the locator.",
          defaultTrigger = { type = "chord", mods = { "cmd", "alt", "ctrl" }, key = "m", follows = { "s" } },
          mnemonic = "S for Screen (same Hyper+M prefix)",
          run = function(ctx)
              local f = ctx.screenFrames()[1]
              if f then centerOn(ctx, f) end
          end },
        { id = "center_next_screen", label = "Center pointer on next screen",
          description = "Warp the mouse pointer to the center of the next display "
              .. "(wraps around), then flash the locator.",
          defaultTrigger = { type = "chord", mods = { "cmd", "alt", "ctrl" }, key = "m", follows = { "n" } },
          mnemonic = "N for Next screen (same Hyper+M prefix)",
          run = function(ctx)
              local f = nextScreenFrame(ctx.screenFrames(), ctx.mousePosition())
              if f then centerOn(ctx, f) end
          end },
    },
}
