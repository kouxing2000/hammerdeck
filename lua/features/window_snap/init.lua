-- features/window_snap
--
-- Arrange the focused window (ported from myHammerSpoon
-- modules/window/windowManagement.lua): snap to screen halves, toggle
-- maximize <-> centered 75%, and throw to the next/previous screen with
-- proportional rescaling + the mouse pointer carried along.
--
-- MULTI-ACTION feature: each arrangement is its own independently rebindable
-- action (the donor's seven hotkeys). Fullscreen windows are taken out of
-- fullscreen first, then the arrangement retries (donor behavior).
--
-- Needs the Accessibility permission (focused-window frame surface); without
-- it every action alerts the onboarding message.

local W = require("platform.windows")

local RETRY_SECONDS = 0.5   -- fullscreen exit settle time before retrying
local TOGGLE_SCALE  = 0.75  -- the "smaller" size of the maximize toggle

-- Build the helpers around a ctx once per enablement.
local function arranger(ctx)
    local a = {}

    -- The focused window, or nil after alerting (the per-action guard).
    local function focused()
        return W.focusedOrAlert(ctx, "Window Arrange")
    end

    -- Exit fullscreen and re-run `retry` after a beat (donor behavior).
    local function unfullscreenThen(retry)
        ctx.setFocusedWindowFullscreen(false)
        ctx.afterSeconds(RETRY_SECONDS, retry)
    end

    -- Snap to a screen-ratio rect: x/y position, w/h size (donor's
    -- positionWindow).
    function a.snap(xR, yR, wR, hR)
        local f = focused()
        if not f then return end
        ctx.setFocusedWindowFrame(W.rectFromRatios(f.screen, xR, yR, wR, hR))
    end

    -- Maximized (full width or height) -> centered 75%; else maximize.
    function a.toggleMax()
        local f = focused()
        if not f then return end
        if f.fullscreen then return unfullscreenThen(a.toggleMax) end
        local s = f.screen
        if f.w == s.w or f.h == s.h then
            local m = (1 - TOGGLE_SCALE) / 2
            ctx.setFocusedWindowFrame(
                W.rectFromRatios(s, m, m, TOGGLE_SCALE, TOGGLE_SCALE))
        else
            ctx.setFocusedWindowFrame(W.rectFromRatios(s, 0, 0, 1, 1))
        end
    end

    -- Move to the adjacent screen, scaling the frame proportionally (the
    -- donor's least-distortion scale: whichever axis ratio is closer to 1
    -- scales BOTH dimensions; positions scale per axis; clamp into the
    -- target). The pointer is carried over and flashed.
    function a.moveScreen(dir)
        local f = focused()
        if not f then return end
        if f.fullscreen then
            return unfullscreenThen(function() a.moveScreen(dir) end)
        end
        local screens = ctx.screenFrames()
        if #screens < 2 then
            ctx.alert("Only one screen")
            return
        end
        local i = f.screenIndex
        local j = (dir == "next") and (i % #screens) + 1 or ((i - 2) % #screens) + 1
        local s, t = f.screen, screens[j]

        local scale1, scale2 = t.w / s.w, t.h / s.h
        local scale = math.abs(scale2 - 1) < math.abs(scale1 - 1) and scale2 or scale1
        local nf = {
            w = f.w * scale, h = f.h * scale,
            x = t.x + (f.x - s.x) * scale1,
            y = t.y + (f.y - s.y) * scale2,
        }
        if nf.x + nf.w > t.x + t.w then
            nf.x = t.x + t.w - nf.w
            if nf.x < t.x then nf.x, nf.w = t.x, t.w end
        end
        if nf.y + nf.h > t.y + t.h then
            nf.y = t.y + t.h - nf.h
            if nf.y < t.y then nf.y, nf.h = t.y, t.h end
        end
        ctx.setFocusedWindowFrame(nf)

        -- Carry the pointer at the same offset on the new screen, clamped.
        local m = ctx.mousePosition()
        ctx.setMousePosition(
            t.x + math.min(math.max(m.x - s.x, 0), t.w),
            t.y + math.min(math.max(m.y - s.y, 0), t.h))
        ctx.locateMouse(2)
    end

    return a
end

-- One arranger per enablement (ctx changes on re-enable).
local cached = nil
local function with(ctx)
    if not cached or cached.ctx ~= ctx then
        cached = { ctx = ctx, a = arranger(ctx) }
    end
    return cached.a
end

local MODS = { "cmd", "alt", "ctrl" }

return {
    api         = 1,
    id          = "window_snap",
    name        = "Window Snap",
    description = "Direct hotkeys for the common arrangements -- snap to a "
        .. "half, toggle maximize/75%, throw to the next screen (pointer "
        .. "follows). Best for one-key snaps. Pairs with Window Mode.",
    version     = "1.0.0",
    category    = "productivity",

    options = {},

    actions = {
        { id = "left", label = "Left half",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "left" },
          run = function(ctx) with(ctx).snap(0, 0, 0.5, 1) end },
        { id = "right", label = "Right half",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "right" },
          run = function(ctx) with(ctx).snap(0.5, 0, 0.5, 1) end },
        { id = "top", label = "Top half",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "up" },
          run = function(ctx) with(ctx).snap(0, 0, 1, 0.5) end },
        { id = "bottom", label = "Bottom half",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "down" },
          run = function(ctx) with(ctx).snap(0, 0.5, 1, 0.5) end },
        { id = "toggle_max", label = "Maximize / 75%",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "return" },
          run = function(ctx) with(ctx).toggleMax() end },
        { id = "screen_next", label = "To next screen",
          defaultTrigger = { type = "hotkey", mods = { "ctrl", "alt" }, key = "right" },
          run = function(ctx) with(ctx).moveScreen("next") end },
        { id = "screen_prev", label = "To previous screen",
          defaultTrigger = { type = "hotkey", mods = { "ctrl", "alt" }, key = "left" },
          run = function(ctx) with(ctx).moveScreen("previous") end },
    },
}
