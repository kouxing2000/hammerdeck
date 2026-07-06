-- platform/window_history.lua
--
-- CORE / stateful. Records the BEFORE-frame of window LAYOUT writes and restores
-- the single most-recent change (single-step undo). This is the engine behind the
-- window_rewind feature ("Undo last window change"). Features NEVER `require` it --
-- it sits above the adapter, reached only through window_ops (which funnels every
-- window write) and the curated ctx.window.undoLast / enableHistory helpers.
--
-- GROUPING. Writes that land close together in time coalesce into ONE undo group:
-- a single half-snap is one group; a whole-display swap or a Window Deck retile
-- (many setFrameFor calls in a tight loop) is also one group. The boundary is a
-- time gap (adapter.now(), whole seconds -- see the note below), so undo reverts
-- "the last thing you did", not just the last individual window it happened to
-- touch. Single-step: only the most-recent group is retained.
--
-- THE ONE HARD RULE: never call listWindows() WHILE recording. Every list_windows()
-- rebuilds the host's AX window cache and re-mints the numeric ids a batch caller
-- is mid-loop over (Native+Windows.swift), so a stray list would strand those ids
-- and the caller's remaining moves would silently no-op. So the two record paths
-- take NO list: the by-id path reads before-frames from the caller's OWN list
-- (fed in via noteList, which window_ops.list routes here), and the focused path
-- self-captures from focusedWindowFrame()/Wid() (neither touches the AX cache).
-- undoLast() DOES list -- but only at undo time, when no batch is in flight.
--
-- Before-frames are keyed by the STABLE wid (CGWindowID), because a row's numeric
-- id is valid only until the next list(); undoLast re-resolves each wid to a live
-- id before restoring.

local adapter = require("platform.adapter")

local M = {}

-- Seconds gap that starts a new group. NOTE: adapter.now() is os.time() (whole
-- seconds), so in practice this means "writes within the same wall-clock second
-- coalesce; a new second starts a new group". A synchronous batch completes well
-- inside one second (-> one group); two deliberate user moves are almost always
-- >1s apart. The only casualty is a huge batch that straddles a second boundary
-- (it would split, and undo would revert only the later half) -- acceptable for v1.
local GAP = 0.4

local enabled     = false
local restoring   = false   -- re-entrancy guard: undo's own restores must not record
---@type { frames: table<integer, {x:number,y:number,w:number,h:number}>, order: integer[], mouse: {x:number,y:number}? }?
local group       = nil      -- the current (accumulating) undo group, or nil when idle
local lastWriteAt = 0        -- adapter.now() of the last recorded write
---@type { byId: table<integer, {wid:integer,x:number,y:number,w:number,h:number}> }?
local lastList    = nil      -- the caller's most recent list() snapshot (fed by noteList)

--- Turn recording on/off. window_rewind's start/stop toggles this so the extra
--- bookkeeping runs only while the feature is enabled. Disabling also clears any
--- pending group (a stale pre-disable snapshot must never be undoable later).
---@param on boolean
function M.setEnabled(on)
    enabled = (on == true)
    if not enabled then M.clear() end
end

--- Drop all recorded state (the pending group + the cached list).
function M.clear()
    group, lastList, lastWriteAt = nil, nil, 0
    restoring = false   -- also release the undo guard, so a disable/enable recovers
end

--- Cache the caller's OWN list() snapshot so recordById can resolve a moved
--- window's wid + before-frame without listing again mid-batch. Cheap no-op when
--- disabled or while restoring. Called by window_ops.list().
---@param rows { id:integer, wid:integer?, x:number, y:number, w:number, h:number }[]
function M.noteList(rows)
    if not enabled or restoring then return end
    local byId = {}
    for _, r in ipairs(rows) do
        if r.id then
            byId[r.id] = { wid = r.wid, x = r.x, y = r.y, w = r.w, h = r.h }
        end
    end
    lastList = { byId = byId }
end

-- Start a fresh group when idle or when the gap since the last write is large
-- enough to count as a new user action. Captures the mouse at group start so undo
-- can restore the pointer (a focused move carries it via pointer-follow).
---@param now number
local function beginGroupIfNeeded(now)
    if group == nil or (now - lastWriteAt) > GAP then
        local mp = adapter.mousePosition()
        group = { frames = {}, order = {}, mouse = mp and { x = mp.x, y = mp.y } or nil }
    end
end

-- Record wid's before-frame into the current group (first-touch wins, so an
-- interactive re-place within one group keeps the pre-change frame).
---@param wid integer?
---@param f {x:number,y:number,w:number,h:number}?
local function stash(wid, f)
    if wid and wid ~= 0 and f and not group.frames[wid] then
        group.frames[wid] = { x = f.x, y = f.y, w = f.w, h = f.h }
        group.order[#group.order + 1] = wid
    end
end

--- Record the focused window's before-frame. Called by window_ops.setFrame BEFORE
--- the write. Self-captures (no list()), so it never invalidates a batch's ids.
function M.recordFocused()
    if not enabled or restoring then return end
    local now = adapter.now()
    beginGroupIfNeeded(now)
    stash(adapter.focusedWindowWid(), adapter.focusedWindowFrame())
    lastWriteAt = now
end

--- Record a by-id window's before-frame. Called by window_ops.setFrameFor BEFORE
--- the write. Resolves the before-frame from the caller's cached list (noteList),
--- so it takes no list() of its own.
---@param id integer
function M.recordById(id)
    if not enabled or restoring then return end
    local now = adapter.now()
    beginGroupIfNeeded(now)
    local ent = lastList and lastList.byId[id]
    if ent then stash(ent.wid, ent) end   -- ent already carries x/y/w/h
    lastWriteAt = now
end

-- Is this frame's center on any currently-connected screen? A window whose
-- original display was unplugged since the move can't be sensibly restored
-- (mirrors Window Deck's skipRestore for a vanished screen).
---@param f {x:number,y:number,w:number,h:number}
---@param screens {x:number,y:number,w:number,h:number}[]
---@return boolean
local function onScreen(f, screens)
    local cx, cy = f.x + f.w / 2, f.y + f.h / 2
    for _, s in ipairs(screens) do
        if cx >= s.x and cx <= s.x + s.w and cy >= s.y and cy <= s.y + s.h then
            return true
        end
    end
    return false
end

--- Restore the most-recent group: move every window it touched back to its
--- before-frame and return the pointer to where it was at the group's start.
--- Single-step -- the group is consumed, so a second call is a no-op until a new
--- change is recorded. Windows that have since closed, or whose original screen is
--- gone, are skipped.
---@return integer restored  how many windows were moved back
function M.undoLast()
    if not group or #group.order == 0 then return 0 end
    restoring = true
    local g = group
    group, lastWriteAt = nil, 0          -- consume up-front (single-step)
    -- pcall the whole restore so a mid-flight adapter error can NEVER leave
    -- `restoring` stuck true -- that would silently, permanently stop all
    -- recording (every record path early-returns on `restoring`), and clear()
    -- is the only reset, so without this an app restart would be the only cure.
    local ok, restored = pcall(function()
        -- Safe to list here: undo runs at rest, no batch caller mid-loop over ids.
        local rows = adapter.listWindows()
        local widToId = {}
        for _, r in ipairs(rows) do
            if r.wid then widToId[r.wid] = r.id end
        end
        local screens = adapter.screenFrames()
        local n = 0
        for _, wid in ipairs(g.order) do
            local id, before = widToId[wid], g.frames[wid]
            if id and before and onScreen(before, screens) then
                if adapter.setWindowFrame(id, before) then n = n + 1 end
            end
        end
        -- Only rewind the pointer if we actually moved something back (no spurious
        -- jump when every target had vanished).
        if n > 0 and g.mouse then adapter.setMousePosition(g.mouse.x, g.mouse.y) end
        return n
    end)
    restoring = false                    -- released on both success and error
    if not ok then error(restored, 0) end   -- re-surface so the registry logs it
    return restored
end

return M
