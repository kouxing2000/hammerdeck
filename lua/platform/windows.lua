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
