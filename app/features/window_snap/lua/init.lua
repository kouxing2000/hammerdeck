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
        ctx.window.setFullscreen(false)
        ctx.afterSeconds(RETRY_SECONDS, retry)
    end

    -- Snap to a screen-ratio rect: x/y position, w/h size (donor's
    -- positionWindow).
    function a.snap(xR, yR, wR, hR)
        local f = focused()
        if not f then return end
        ctx.window.setFrame(W.rectFromRatios(f.screen, xR, yR, wR, hR))
    end

    -- Snap to a cell of a `cols` x `rows` grid: cell {cx,cy} 0-based offset,
    -- {cw,ch} span (the ported grid algorithm -- windows.gridCellToFrame). Thirds
    -- ride a 3x1 grid; flush (no gutter), matching the halves.
    function a.snapGrid(cols, rows, cx, cy, cw, ch)
        local f = focused()
        if not f then return end
        ctx.window.setFrame(W.gridCellToFrame(f.screen,
            { w = cols, h = rows }, { x = cx, y = cy, w = cw, h = ch }))
    end

    -- Maximized (full width or height) -> centered 75%; else maximize.
    function a.toggleMax()
        local f = focused()
        if not f then return end
        if f.fullscreen then return unfullscreenThen(a.toggleMax) end
        local s = f.screen
        if f.w == s.w or f.h == s.h then
            local m = (1 - TOGGLE_SCALE) / 2
            ctx.window.setFrame(
                W.rectFromRatios(s, m, m, TOGGLE_SCALE, TOGGLE_SCALE))
        else
            ctx.window.setFrame(W.rectFromRatios(s, 0, 0, 1, 1))
        end
    end

    -- Move to the adjacent screen (by index), rescaling the frame with the
    -- shared least-distortion geometry (windows.moveToScreen). The pointer is
    -- carried over at the same relative spot and flashed.
    function a.moveScreen(dir)
        local f = focused()
        if not f then return end
        if f.fullscreen then
            return unfullscreenThen(function() a.moveScreen(dir) end)
        end
        local screens = ctx.screen.frames()
        if #screens < 2 then
            ctx.alert(ctx.t("alert.oneScreen", "Only one screen"))
            return
        end
        local i = f.screenIndex
        local j = (dir == "next") and (i % #screens) + 1 or ((i - 2) % #screens) + 1
        local s, t = f.screen, screens[j]

        -- least-distortion rescale + clamp (shared geometry; see windows.lua).
        ctx.window.setFrame(W.moveToScreen(f, s, t))

        -- Carry the pointer at the same offset on the new screen, clamped.
        local m = ctx.mouse.position()
        ctx.mouse.setPosition(
            t.x + math.min(math.max(m.x - s.x, 0), t.w),
            t.y + math.min(math.max(m.y - s.y, 0), t.h))
        ctx.mouse.locate(2)
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

    options = {},

    actions = {
        { id = "left", label = "Left half",
          description = "Move the focused window to the left half of the screen.",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "left" },
          mnemonic = "Hyper+← — the arrow points to the edge",
          run = function(ctx) with(ctx).snap(0, 0, 0.5, 1) end },
        { id = "right", label = "Right half",
          description = "Move the focused window to the right half of the screen.",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "right" },
          mnemonic = "Hyper+→ — the arrow points to the edge",
          run = function(ctx) with(ctx).snap(0.5, 0, 0.5, 1) end },
        { id = "top", label = "Top half",
          description = "Move the focused window to the top half of the screen.",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "up" },
          mnemonic = "Hyper+↑ — the arrow points to the edge",
          run = function(ctx) with(ctx).snap(0, 0, 1, 0.5) end },
        { id = "bottom", label = "Bottom half",
          description = "Move the focused window to the bottom half of the screen.",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "down" },
          mnemonic = "Hyper+↓ — the arrow points to the edge",
          run = function(ctx) with(ctx).snap(0, 0.5, 1, 0.5) end },

        -- Thirds (a 3-wide grid). No default trigger -- there is no natural
        -- arrow for a third, and grabbing five more global hotkeys uninvited is
        -- worse than leaving them dormant: each is fireable from the menubar and
        -- bindable to any key/chord in Settings. The columns-of-three idiom
        -- (Rectangle/Magnet) is the most-requested snap the halves don't cover.
        { id = "left_third", label = "Left third",
          description = "Move the focused window to the left third of the screen.",
          run = function(ctx) with(ctx).snapGrid(3, 1, 0, 0, 1, 1) end },
        { id = "center_third", label = "Center third",
          description = "Move the focused window to the center third of the screen.",
          run = function(ctx) with(ctx).snapGrid(3, 1, 1, 0, 1, 1) end },
        { id = "right_third", label = "Right third",
          description = "Move the focused window to the right third of the screen.",
          run = function(ctx) with(ctx).snapGrid(3, 1, 2, 0, 1, 1) end },
        { id = "left_two_thirds", label = "Left two-thirds",
          description = "Move the focused window to the left two-thirds of the screen.",
          run = function(ctx) with(ctx).snapGrid(3, 1, 0, 0, 2, 1) end },
        { id = "right_two_thirds", label = "Right two-thirds",
          description = "Move the focused window to the right two-thirds of the screen.",
          run = function(ctx) with(ctx).snapGrid(3, 1, 1, 0, 2, 1) end },

        { id = "toggle_max", label = "Maximize / 75%",
          description = "Toggle the focused window between maximized and 75% centered.",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "return" },
          mnemonic = "Hyper+Return — Return = fill the screen",
          run = function(ctx) with(ctx).toggleMax() end },
        { id = "screen_next", label = "To next screen",
          description = "Throw the focused window to the next screen, rescaling it "
              .. "proportionally and carrying the pointer along.",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "]" },
          mnemonic = "Hyper+] — ] pushes forward to the next screen",
          run = function(ctx) with(ctx).moveScreen("next") end },
        { id = "screen_prev", label = "To previous screen",
          description = "Throw the focused window to the previous screen, rescaling "
              .. "it proportionally and carrying the pointer along.",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "[" },
          mnemonic = "Hyper+[ — [ pushes back to the previous screen",
          run = function(ctx) with(ctx).moveScreen("previous") end },
    },
}
