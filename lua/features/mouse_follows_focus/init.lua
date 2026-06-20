-- features/mouse_follows_focus
--
-- Warp the pointer to the center of the focused window when the active app
-- changes (ported from the MouseFollowsFocus spoon). Pure Lua over ctx -- no
-- native. SERVICE feature: start() registers an app-activation watcher; the
-- scoped teardown removes it on disable.
--
-- Caveat (documented v1 limit): ctx.onAppActivated fires on APP switch, not on
-- a window switch WITHIN the same app -- so moving focus between two windows of
-- the same app does not warp the pointer. Acceptable for v1; a window-focus
-- event watcher would be a later native addition.
--
-- To stay unobtrusive the pointer is left alone when it is already inside the
-- newly focused window (no pointless jump), and the feature stays silent when
-- there is no focused-window frame (e.g. Accessibility not yet granted) rather
-- than nagging on every app switch.

local function center(f)
    return f.x + f.w / 2, f.y + f.h / 2
end

local function insideFrame(p, f)
    return p.x >= f.x and p.x <= f.x + f.w
        and p.y >= f.y and p.y <= f.y + f.h
end

return {
    api         = 1,
    id          = "mouse_follows_focus",
    name        = "Mouse Follows Focus",
    description = "Move the pointer to the focused window when you switch apps.",
    version     = "1.0.0",
    category    = "productivity",

    options = {
        { key = "locateAfter",     type = "bool", default = true,  label = "Flash the pointer after moving" },
        { key = "onlyMultiScreen", type = "bool", default = false, label = "Only when multiple displays are connected" },
    },

    start = function(ctx)
        ctx.onAppActivated(function()
            local f = ctx.focusedWindowFrame()
            if not f then return end   -- no AX grant / no window: stay silent
            if ctx.opt("onlyMultiScreen") and #ctx.screenFrames() < 2 then return end
            if insideFrame(ctx.mousePosition(), f) then return end   -- already there
            ctx.setMousePosition(center(f))
            if ctx.opt("locateAfter") then ctx.locateMouse(1) end
        end)
    end,
}
