-- features/window_deck/identity.lua
--
-- PURE LEAF: a deck member's stable IDENTITY keys plus the frame-proximity
-- geometry the controller uses to match windows across list() calls. No state,
-- no require -- side-effect-free functions of their arguments, so they unit-test
-- in isolation and the stateful controller (init.lua) just calls them.
--
-- The IDENTITY LADDER (keyOf): primary = the OS-stable CGWindowID the bridge
-- resolves (`wid` -- survives retitles, unique for the window's lifetime);
-- fallback = bundleID+title for the rare window whose wid is unresolvable (see
-- resolveIds' adoption in init.lua for how that tier self-heals on retitles).
-- The two key spaces carry distinct prefixes so they can never collide. Two
-- untitled same-app windows still collide in the fallback tier -- a documented
-- limitation, now reachable only when wid resolution fails.

local M = {}

---@param bundleID string|nil
---@param wid integer
---@return string
function M.widKey(bundleID, wid)
    return (bundleID or "") .. "\0wid:" .. string.format("%d", wid)
end

---@param bundleID string|nil
---@param title string|nil
---@return string
function M.titleKey(bundleID, title)
    return (bundleID or "") .. "\0t:" .. (title or "")
end

---@param w table window row (needs .wid / .bundleID / .title)
---@return string
function M.keyOf(w)
    if w.wid and w.wid ~= 0 then return M.widKey(w.bundleID, w.wid) end
    return M.titleKey(w.bundleID, w.title)
end

-- Is window `w`'s centre inside screen rect `s`? Pure geometry -- robust across
-- the separate native calls that produce window frames vs screen frames (their
-- screen tables are not the same object, so identity comparison would be wrong).
---@param w table window rect (.x/.y/.w/.h)
---@param s table screen rect (.x/.y/.w/.h)
---@return boolean
function M.onScreen(w, s)
    local mx, my = w.x + w.w / 2, w.y + w.h / 2
    return mx >= s.x and mx < s.x + s.w
       and my >= s.y and my < s.y + s.h
end

-- Frame proximity for the identity adoption in resolveIds: the window still sits
-- where the member was last known to be (position ~32px, size ~64px -- generous
-- enough for apps that clamp or snap the frames we dispatch, e.g. terminals
-- snapping to their character grid).
---@param w table reported frame
---@param f table|nil expected frame (m.cur)
---@return boolean
function M.atFrame(w, f)
    return f ~= nil and math.abs(w.x - f.x) <= 32 and math.abs(w.y - f.y) <= 32
        and math.abs(w.w - f.w) <= 64 and math.abs(w.h - f.h) <= 64
end

-- Is frame `a` meaningfully off frame `b` (>6px on any axis)? Drives the
-- widget's Rearrange button (dirty only when re-tiling would move something).
---@param a table|nil
---@param b table|nil
---@return boolean
function M.frameFar(a, b)
    if not a or not b then return false end
    return math.abs((a.x or 0) - (b.x or 0)) > 6
        or math.abs((a.y or 0) - (b.y or 0)) > 6
        or math.abs((a.w or 0) - (b.w or 0)) > 6
        or math.abs((a.h or 0) - (b.h or 0)) > 6
end

return M
