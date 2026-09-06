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

-- No `onScreen` here -- membership belongs to `platform.windows`, and init.lua
-- asks it there. A copy in this file has to re-decide which of a screen row's two
-- rects to test: the VISIBLE one excludes the menu-bar and Dock strips, so a
-- window parked over the Dock reads as being on no display at all.

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

-- Match a SAVED deck's member descriptors against the currently-open windows --
-- the "restore last deck" rebuild. Identity is the SAME wid-first ladder as
-- keyOf, run in TWO passes so wid always wins over title:
--   PASS 1 -- by (app + wid): a CGWindowID is unique per live window and stable
--     for the window's whole life WITHIN a WindowServer session, so this survives
--     a RETITLE and disambiguates two same-app same-title windows in one session.
--   PASS 2 -- by (app + title): only for saved members PASS 1 couldn't place
--     (their app was restarted, reissuing wids). Survives the restart as long as
--     the window kept its title.
-- KNOWN LIMITATION (bounded, accepted): a persisted wid is only reliably the
-- SAME window within one login session. WindowServer reissues low ids after a
-- logout/reboot, so a saved wid CAN coincidentally equal a different same-app
-- window's new id and PASS 1 then binds to the wrong window -- always the right
-- APP, transient (exit restores frames), and only cross-reboot. Gating PASS 1 on
-- a boot/session token would fix it but needs native boot-time surface (the
-- seam); deferred as not worth that for the harm. In-session restore (the common
-- case) is exact. A single greedy (wid OR title) pass would let a title match
-- steal a window a different member's wid should have claimed -- hence the
-- two-pass split (wid wins globally before title runs). A member with
-- neither a real wid nor a title is unidentifiable and matches nothing; each
-- live window is claimed at most once (by table identity), so N same-app windows
-- never collapse onto one saved member. Returns the matched live windows in
-- SAVED order: #matched is how many of the saved deck are available NOW, and
-- (#saved - #matched) are missing -- the caller may still restore around the
-- gaps (a partial deck) as long as >= 2 survive.
---@param saved table[]|nil saved member descriptors ({bundleID, title, wid})
---@param live table[]|nil current window rows ({bundleID, title, wid})
---@return table[] matched live windows, in saved order
function M.matchMembers(saved, live)
    saved, live = saved or {}, live or {}
    local claimed, pick = {}, {}   -- pick[mem] = the live window bound to it
    -- first unclaimed same-app live window satisfying pred
    local function take(mem, pred)
        for _, w in ipairs(live) do
            if not claimed[w] and (w.bundleID or "") == (mem.bundleID or "")
                and pred(w) then return w end
        end
    end
    for _, mem in ipairs(saved) do            -- PASS 1: wid (exact)
        if mem.wid and mem.wid ~= 0 then
            local w = take(mem, function(w) return w.wid == mem.wid end)
            if w then claimed[w] = true; pick[mem] = w end
        end
    end
    for _, mem in ipairs(saved) do            -- PASS 2: title (survives a restart)
        if not pick[mem] and mem.title and mem.title ~= "" then
            local w = take(mem, function(w) return w.title == mem.title end)
            if w then claimed[w] = true; pick[mem] = w end
        end
    end
    local matched = {}                         -- emit in SAVED order
    for _, mem in ipairs(saved) do
        if pick[mem] then matched[#matched + 1] = pick[mem] end
    end
    return matched
end

-- Which deck members are HIDDEN behind a FOREIGN (non-member) window? Given the
-- front-to-back window list (ctx.window.list() order == the CG z-order) and each
-- present member's current rect keyed by keyOf, a member is OCCLUDED iff some
-- NON-member window sits IN FRONT of it (earlier in `list`) and covers the
-- member's CENTRE. Pure -- the render shell passes the freshly-listed windows
-- plus the members' own frames, so "is this deck window actually the visible one
-- at its slot, or is a foreign window over it?" is decided (and unit-tested)
-- without a live screen. This is what lets a ring hide itself instead of drawing
-- over a peeked window, WITHOUT re-ordering any window (which would blink).
--
-- CENTRE-coverage, not any-overlap: a foreign window merely grazing a member's
-- edge leaves it substantially visible, so its ring still means something; only a
-- window over the member's middle really hides it. The caller (init.lua) trusts
-- AX -- not this -- for who is FRONTMOST (the CG list lags the focus event), so it
-- drops the just-focused key from the result; this only decides the stable
-- foreign-over-the-others relationship, which the list reports reliably.
---@param list table[] front-to-back window rows (.wid/.bundleID/.title/.x/.y/.w/.h)
---@param rects table<string, table> present member key -> its rect {x,y,w,h}
---@return table<string, boolean> member keys occluded by a foreign window in front
function M.occludedMembers(list, rects)
    local rank = {}                            -- member key -> its own front-rank
    for i, w in ipairs(list) do
        local k = M.keyOf(w)
        if rects[k] and not rank[k] then rank[k] = i end
    end
    local occluded = {}
    for i, w in ipairs(list) do
        if not rects[M.keyOf(w)] then          -- a FOREIGN window at front-rank i
            for k, r in pairs(rects) do
                if not occluded[k] and rank[k] and i < rank[k] then
                    local cx, cy = r.x + r.w / 2, r.y + r.h / 2
                    if w.x <= cx and cx <= w.x + w.w
                        and w.y <= cy and cy <= w.y + w.h then
                        occluded[k] = true     -- foreign window in front covers its centre
                    end
                end
            end
        end
    end
    return occluded
end

return M
