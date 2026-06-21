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
