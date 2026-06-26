-- platform/windows -- pure window-geometry helpers shared by the window
-- features (window_snap, window_modal). Stateless leaf util: no require of its
-- own, every native call goes through the ctx passed in. Only the genuinely
-- identical code lives here; the divergent throw / fullscreen-guard math stays
-- in each feature.

local M = {}

--- A screen-ratio rect: x/y offset and w/h size as fractions of the screen
--- visible frame (the donor's positionWindow).
---@param s {x:number,y:number,w:number,h:number} screen visible frame
---@param xR number x-offset ratio
---@param yR number y-offset ratio
---@param wR number width ratio
---@param hR number height ratio
---@return {x:number,y:number,w:number,h:number}
function M.rectFromRatios(s, xR, yR, wR, hR)
    return { x = s.x + s.w * xR, y = s.y + s.h * yR,
             w = s.w * wR, h = s.h * hR }
end

--- Rescale + reposition a frame from its source screen onto a target screen,
--- then clamp it inside the target. The shared geometry of "throw to another
--- screen" -- the two window features differ only in size policy (and the
--- divergent target-screen SELECTION, which stays in each caller):
---   * default (window_snap): least-distortion scale -- whichever axis ratio is
---     closer to 1 scales BOTH dims; a result wider/taller than the target is
---     filled to the target edge.
---   * keepSize (window_modal): size kept, only shrunk to fit; clamp just pulls
---     the frame back inside (no fill, since it already fits).
--- Position always scales per axis by the screen-size ratio, so a window keeps
--- its relative place on the new screen. Pure: no native calls.
---@param f {x:number,y:number,w:number,h:number} the window frame
---@param s {x:number,y:number,w:number,h:number} source screen visible frame
---@param t {x:number,y:number,w:number,h:number} target screen visible frame
---@param opts {keepSize:boolean}|nil
---@return {x:number,y:number,w:number,h:number}
function M.moveToScreen(f, s, t, opts)
    local keepSize = opts and opts.keepSize
    local sx, sy = t.w / s.w, t.h / s.h
    local nf = { x = t.x + (f.x - s.x) * sx, y = t.y + (f.y - s.y) * sy }
    if keepSize then
        nf.w, nf.h = math.min(f.w, t.w), math.min(f.h, t.h)
    else
        -- least distortion: the axis ratio nearer 1 drives both dimensions.
        local scale = math.abs(sy - 1) < math.abs(sx - 1) and sy or sx
        nf.w, nf.h = f.w * scale, f.h * scale
    end
    if nf.x + nf.w > t.x + t.w then
        nf.x = t.x + t.w - nf.w
        if not keepSize and nf.x < t.x then nf.x, nf.w = t.x, t.w end
    end
    if nf.y + nf.h > t.y + t.h then
        nf.y = t.y + t.h - nf.h
        if not keepSize and nf.y < t.y then nf.y, nf.h = t.y, t.h end
    end
    return nf
end

-- ---------------------------------------------------------------------------
-- Window-layout helpers (the rules engine's `layout` effect). All pure: given
-- a window list + screen list (from the adapter), decide what goes where.
-- ---------------------------------------------------------------------------

--- The named snap-grid positions a layout placement can target, each a
--- screen-ratio rect {xR,yR,wR,hR}. The Settings layout editor offers these by
--- key; `pos` may also be an explicit {x,y,w,h} ratio table (what "Capture
--- current layout" records -- exact, not snapped to the grid).
M.POSITIONS = {
    full        = { 0,   0,   1,   1   },
    left        = { 0,   0,   0.5, 1   },
    right       = { 0.5, 0,   0.5, 1   },
    top         = { 0,   0,   1,   0.5 },
    bottom      = { 0,   0.5, 1,   0.5 },
    topLeft     = { 0,   0,   0.5, 0.5 },
    topRight    = { 0.5, 0,   0.5, 0.5 },
    bottomLeft  = { 0,   0.5, 0.5, 0.5 },
    bottomRight = { 0.5, 0.5, 0.5, 0.5 },
}

-- Stable display order for the editor's position picker (POSITIONS is a map).
M.POSITION_ORDER = {
    "full", "left", "right", "top", "bottom",
    "topLeft", "topRight", "bottomLeft", "bottomRight",
}

-- Human labels for the position picker (single source for any UI surface).
M.POSITION_LABELS = {
    full        = "Full screen",
    left        = "Left half",       right       = "Right half",
    top         = "Top half",        bottom      = "Bottom half",
    topLeft     = "Top-left",        topRight    = "Top-right",
    bottomLeft  = "Bottom-left",     bottomRight = "Bottom-right",
}

--- Resolve a placement `pos` to a ratio rect {x,y,w,h} (fractions of a screen).
--- A string keys POSITIONS; a table is taken as explicit ratios (the capture
--- path). Returns nil for an unknown string -- the caller treats that as invalid.
---@param pos string|table
---@return {x:number,y:number,w:number,h:number}|nil
function M.ratiosFor(pos)
    if type(pos) == "table" then
        return { x = pos.x or 0, y = pos.y or 0, w = pos.w or 1, h = pos.h or 1 }
    end
    local g = M.POSITIONS[pos]
    if not g then return nil end
    return { x = g[1], y = g[2], w = g[3], h = g[4] }
end

--- Does a window row (from adapter.listWindows) match a placement's selector?
--- Matches by exact app name; an optional `titlePattern` is a plain (non-Lua-
--- pattern) substring of the title. A placement with neither matches nothing.
---@param w table a window row { appName, title, ... }
---@param p table a placement { app, titlePattern? }
---@return boolean
function M.windowMatches(w, p)
    if type(p.app) ~= "string" or #p.app == 0 then return false end
    if w.appName ~= p.app then return false end
    if type(p.titlePattern) == "string" and #p.titlePattern > 0 then
        if type(w.title) ~= "string" or not w.title:find(p.titlePattern, 1, true) then
            return false
        end
    end
    return true
end

--- Find the screen (from adapter.screenFrames) whose display name == `name`, or
--- nil if that display is not currently present -- which makes a layout
--- placement SELF-GATING: a "place on DELL U2720Q" entry is simply skipped when
--- that monitor is unplugged.
---@param screens table[] screen rows { x,y,w,h,name }
---@param name string
---@return table|nil
function M.resolveScreen(screens, name)
    for _, s in ipairs(screens or {}) do
        if (s.name or "") == name then return s end
    end
    return nil
end

--- The screen a frame sits on: the one whose visible frame contains the frame's
--- midpoint, else the first (used by "Capture current layout" to tag each window
--- with its display + ratios). Pure -- no reliance on listWindows' screenName.
---@param screens table[] screen rows { x,y,w,h,name }
---@param f table a frame { x,y,w,h }
---@return table|nil
function M.screenOfFrame(screens, f)
    local mx, my = f.x + f.w / 2, f.y + f.h / 2
    for _, s in ipairs(screens or {}) do
        if mx >= s.x and mx < s.x + s.w and my >= s.y and my < s.y + s.h then
            return s
        end
    end
    return screens and screens[1] or nil
end

--- The focused window's frame, or nil after alerting the user (the per-action
--- guard): if Accessibility is missing, prompt + onboard; otherwise alert that
--- nothing is focused.
---@param ctx table the curated feature ctx
---@param featureName string shown in the Accessibility onboarding message
---@return table|nil frame `{x,y,w,h,fullscreen,screenIndex,screen={x,y,w,h}}`
function M.focusedOrAlert(ctx, featureName)
    local f = ctx.focusedWindowFrame()
    if f then return f end
    if not ctx.axTrusted() then
        ctx.axPrompt()
        ctx.alert(featureName .. " needs the Accessibility permission -- "
            .. "grant Hammerdeck in System Settings, then try again")
    else
        ctx.alert("No focused window")
    end
    return nil
end

return M
