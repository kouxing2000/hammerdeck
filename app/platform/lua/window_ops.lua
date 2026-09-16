-- platform/window_ops.lua
--
-- Live FOCUSED-window operations that reach the adapter directly -- the stateful
-- core peer that ctx.window delegates to (NOT a leaf util; it `require`s the
-- adapter). Today it owns one policy: "Pointer Follows Moved Window".
--
-- "Pointer Follows Moved Window" (the pointer_follows_window feature): when its
-- toggle is on, repositioning the FOCUSED window carries the pointer along,
-- preserving its RELATIVE position inside the window (it was 30% from the left
-- edge -> still 30% from the left edge after the move). Implemented here, at the
-- single focused-window-move seam (ctx.window.setFrame), so every feature that
-- moves the FOCUSED window (window_snap, Window Mode, window_to_next_screen, ...)
-- gets it for free with no per-feature code.
--
-- SCOPE: the FOCUSED-window seam only. The rules engine moves windows BY ID via
-- adapter.setWindowFrame (effects.lua, layout / move-to-display) on a separate
-- path that intentionally bypasses pointer-follow -- carrying the pointer would be
-- wrong for a batch layout -- so those do NOT route through here.
--
-- The "is pointer-follow on?" predicate is INJECTED via configure() by the
-- composition root (registry), which owns enabled-state. This keeps window_ops
-- feature-agnostic and resolves the old ctx -> registry -> ctx require-cycle
-- workaround at the root: window_ops never names the pointer_follows_window
-- feature (no stringly-typed enabled-key read) -- the registry does.
--
-- It also owns the EXCLUSIVE WINDOW-MODE LEASE (below), for the same reason it
-- owns pointer-follow: a policy that spans features has to live where no feature
-- can require another. Features reach it only through ctx.window.requestExclusive.

local adapter = require("platform.adapter")
local history = require("platform.window_history")   -- CORE peer; records before-frames

local M = {}

-- Whether to carry the pointer with a focused-window move. The registry installs
-- the real predicate from configure() at ITS module-load -- which both the app
-- boot (hammerdeck.lua requires registry) and the test harness (test/run.lua
-- requires registry) trigger before any ctx is built, since a ctx is only ever
-- created via ctxlib.make, called only by the registry. So in practice this is
-- always wired first. The OFF default is the safety net for a hypothetical load
-- that builds a ctx WITHOUT requiring registry: it degrades to a plain setFrame
-- (no wrong pointer yank), never an error -- but pointer-follow would silently be
-- off, and the through-registry T24b test would not catch it. If you ever add
-- such a path, call window_ops.configure() explicitly there.
local pointerFollowEnabled = function() return false end

--- Composition-root wiring. Called once at boot by the registry.
---@param opts {pointerFollowEnabled: fun(): boolean} predicate for the live
---            pointer_follows_window enabled-state.
function M.configure(opts)
    if opts and opts.pointerFollowEnabled then
        pointerFollowEnabled = opts.pointerFollowEnabled
    end
end

--- Move the focused window to frame `f`. When pointer-follow is on AND the
--- pointer was inside the window being moved, carry it to the same relative spot.
---@param f {x:number,y:number,w:number,h:number}
---@return boolean ok
function M.setFrame(f)
    history.recordFocused()   -- snapshot the focused window's before-frame for undo
    if pointerFollowEnabled() ~= true then
        return adapter.setFocusedWindowFrame(f)
    end
    local old = adapter.focusedWindowFrame()
    local mp  = adapter.mousePosition()
    local ok  = adapter.setFocusedWindowFrame(f)
    -- Carry the pointer only when it was actually inside the window being moved
    -- (never yank a pointer parked elsewhere); guard degenerate / missing sizes.
    if ok and old and mp and old.w and old.h and old.w > 0 and old.h > 0
        and mp.x >= old.x and mp.x <= old.x + old.w
        and mp.y >= old.y and mp.y <= old.y + old.h then
        local rx = (mp.x - old.x) / old.w
        local ry = (mp.y - old.y) / old.h
        adapter.setMousePosition(f.x + rx * f.w, f.y + ry * f.h)
    end
    return ok
end

-- List windows, feeding the snapshot to window_history so a following setFrameFor
-- batch can resolve each moved window's before-frame WITHOUT a second list() (which
-- would invalidate the caller's ids). Rows returned unchanged.
---@return { id:integer, wid:integer?, x:number, y:number, w:number, h:number }[]
function M.list()
    local rows = adapter.listWindows()
    history.noteList(rows)
    return rows
end

--- Place a SPECIFIC listed window by id (batch layout). Records the before-frame
--- for undo, then writes WITHOUT pointer-follow -- a multi-window layout must never
--- yank the cursor to chase one of its members (same rule the rules engine follows).
---
--- `norecord` is for a window mode putting its members BACK: that restore is itself
--- an undo, and recording it creates a second one whose before-frames are the
--- arrangement. Rewind fired afterwards then re-applies the arrangement -- with the
--- mode already gone and its captured originals discarded, so the user's real
--- layout is unrecoverable. Entering a mode stays recorded, so undo still works
--- inside a live one; only the way out is exempt.
---@param id integer
---@param f {x:number,y:number,w:number,h:number}
---@param norecord boolean? true when this write is a mode restoring its own capture
---@return boolean ok
function M.setFrameFor(id, f, norecord)
    if not norecord then history.recordById(id) end
    return adapter.setWindowFrame(id, f)
end

--- Restore the most-recent window layout change (single-step). Returns the count
--- of windows moved back.
---@return integer restored
function M.undoLast() return history.undoLast() end

--- Turn window-layout history recording on/off (window_rewind toggles this).
---@param on boolean
function M.setHistoryEnabled(on) history.setEnabled(on) end

--- Forget the pending undo group. Called by a window mode once it has put its
--- members back, and it is the OTHER half of setFrameFor's `norecord`.
---
--- norecord alone stops the restore from becoming an undoable step, which is not
--- enough: history keeps only the most-recent group, so any move the mode made
--- WHILE it was up -- a retile on a resolution change, a reflow when a member
--- closed, a hero promotion, a Rearrange -- has already replaced the enter-group
--- with one whose before-frames are the mode's OWN arrangement. Rewind after the
--- mode exits then re-applies that arrangement, with the originals the mode has
--- just finished restoring and then discarded. Single-step undo means they are
--- gone for good.
---
--- Every group a live mode can leave behind describes the mode's own layout, so
--- once it has restored there is nothing left that is meaningful to undo.
function M.forgetPendingLayout() history.clear() end

-- ---------------------------------------------------------------------------
-- The exclusive window-mode lease
-- ---------------------------------------------------------------------------
--
-- A persistent window MODE (Window Deck, Window Fan) captures each member's
-- current frame as the frame to restore on exit. Two modes running at once means
-- the second captures the FIRST one's arrangement as the "original layout", and
-- exiting in the wrong order leaves the user in an arrangement they never chose
-- with the real layout unrecoverable (undoLast is single-step, not a snapshot).
-- So a screen carries at most ONE mode, and every window MOVER consults the slot
-- before it touches anything.
--
-- SCREEN-SCOPED, not global: a deck on display A and a fan on display B touch
-- disjoint window sets and cannot poison each other, so a global lease would
-- prompt in the one case where coexistence is harmless. Keyed by the screen's
-- stable `index` (the same identity ctx.screen.frames() rows carry -- never the
-- table, which differs between ctx.window.frame().screen and a frames() row).
--
-- THE SLOT IS EMPTY ACROSS AN EVICTION, AND THE ARBITRATION SLOT IS WHAT GUARDS
-- THAT GAP. Handing the screen over is three steps -- tear the incumbent down,
-- wait for its restore to reach the windows, then install the newcomer -- and it
-- has no holder in between. A request arriving there would find the slot free,
-- be granted with no prompt, and list frames the restore has not finished
-- writing: both failures at once. So `arbitrating()` is consulted by EVERY
-- request BEFORE it looks for a holder -- the uncontended fast path included,
-- since during the gap "no holder" is precisely the wrong answer -- and the slot
-- is held from before the confirm dialog opens until the newcomer is installed.
-- It also makes an auto-repeating hotkey (Window Snap's arrows) unable to stack
-- a second dialog over the first.
--
-- Release is TOKEN-checked, so the evicted mode's own handle.stop() -- which
-- fires during the teardown evictHolder just triggered, and again if it exits
-- later -- can never clear a slot that has since been given to someone else.

--- Sentinel screen for an operation whose reach is not one display -- window
--- rewind's undoLast restores whatever the last layout change touched, and Window
--- Snap's screen-swap moves windows on BOTH displays. Such an action is blocked by
--- a mode on ANY screen, and clearing the way means clearing ALL of them: evicting
--- whichever holder a `pairs()` scan happened to reach first would leave the guard
--- not holding in exactly the multi-display case it was added for.
M.ANY_SCREEN = "*"

---@alias ModeHolder { id: string, name: string, onEvict: fun(), token: table, screen: integer }
---@alias HeldScreen { key: integer, holder: ModeHolder }

--- Keyed by the lease's own TOKEN, not by the screen it holds -- the screen is a
--- FIELD, because it changes and the identity does not. A display reconfig
--- renumbers indices (both modes re-match their screen by name across one), so an
--- index is the one thing about a lease that cannot be its name: keyed by index,
--- following a mode onto a new display means moving a row between keys, and two
--- displays trading indices then makes the two moves collide. Keyed by token,
--- that same reconfig is a field assignment per lease and cannot collide at all.
---@type table<table, ModeHolder>
local holders = {}
-- Non-nil while an arbitration is in flight (its dialog is open, or an eviction is
-- settling). Holds the RELEASE closure rather than a bool so the handle handed to
-- the requester can free it -- see beginArbitration.
local arbitration = nil

--- The mode holding `screenIndex`, or nil. Exact key only; use `heldScreens` for
--- the ANY_SCREEN question, which has more than one possible answer.
---@param screenIndex integer
---@return ModeHolder|nil
function M.modeHolder(screenIndex)
    for _, h in pairs(holders) do
        if h.screen == screenIndex then return h end
    end
    return nil
end

--- Every screen currently held, as {key, holder} rows. The caller resolves the set
--- ONCE and evicts by the rows it was given, so the holders it asked the user about
--- are exactly the ones torn down -- a second independent scan can return a
--- different set, because the dialog is async and a mode may exit while it is open.
---@return HeldScreen[]
function M.heldScreens()
    local out = {}
    for _, holder in pairs(holders) do
        out[#out + 1] = { key = holder.screen, holder = holder }
    end
    -- Stable order, so the dialog lists them the same way twice running. Load-
    -- bearing here rather than incidental: `holders` is keyed by an opaque table,
    -- so pairs() order is not even consistent between two runs of the same build.
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

--- Install `id` as the mode holding `screenIndex`, replacing whoever held it.
--- Returns the release handle; stopping it frees the slot ONLY if this claim is
--- still the current one.
---@param screenIndex integer
---@param id string the claiming feature's id
---@param name string its localized display name (for the confirm dialog)
---@param onEvict fun() tears the mode down and restores its captured layout
---@return { stop: fun(), rekey: fun(newIndex: integer) }
function M.claimMode(screenIndex, id, name, onEvict)
    local token = {}
    holders[token] = { id = id, name = name, onEvict = onEvict,
                       token = token, screen = screenIndex }
    return {
        stop = function()
            holders[token] = nil
        end,
        -- Follow the mode onto a new screen index. A display reconfig SHUFFLES
        -- indices, so a lease that kept the index it was taken at would end up
        -- guarding a display the mode has left -- claiming a screen it does not
        -- hold, and leaving the one it does hold open to a second mode.
        --
        -- Two occupied displays trading indices is the ordinary shape of this, and
        -- each mode rekeys from its OWN screenChanged handler, so the two arrive
        -- one at a time. Between them the map briefly shows both leases on one
        -- index. That is invisible: the handlers run back-to-back inside a single
        -- screenChanged dispatch, and nothing between them reads a holder --
        -- arbitration only happens on a user action. The state that MATTERS, that
        -- every live mode holds exactly one lease and no mode is ever left without
        -- one, holds at every step, which is what the index-keyed version could
        -- not manage: there, the second mode's move found the first still recorded
        -- at the index it was leaving, and had nowhere to go.
        ---@param newIndex integer
        rekey = function(newIndex)
            local h = holders[token]
            if h then h.screen = newIndex end
        end,
    }
end

--- Tear down the holder of `screenIndex`, but only if it is still the one the
--- caller was given (token identity). Clearing the slot here rather than trusting
--- onEvict to do it is what makes a mode with a buggy or early-returning exit path
--- unable to leave a phantom holder behind.
---
--- The token check is what keeps an async confirm honest: between showing the
--- dialog and the user answering it, the named mode may have exited on its own and
--- a DIFFERENT one moved in. Evicting by key alone would then tear down a mode the
--- user was never asked about.
---@param screenIndex integer
---@param token table the `holder.token` read when the question was asked
---@return boolean evicted
function M.evictHolder(screenIndex, token)
    local h = holders[token]
    -- The screen is still checked, not just the token: the caller asked the user
    -- about a mode on a NAMED display, and a reconfig between the question and
    -- the answer can have carried that same lease onto a different one. Evicting
    -- it then tears down a mode the user was never asked about -- the same
    -- mistake as evicting by key alone, arriving from the other direction.
    if not h or h.screen ~= screenIndex then return false end
    holders[token] = nil
    h.onEvict()
    return true
end

--- Is an arbitration in flight? Checked by EVERY request, including the ones that
--- would otherwise take the uncontended fast path: across an eviction the slot is
--- already empty but its restore is still being written, so "no holder" is not yet
--- "free to take".
---@return boolean
function M.arbitrating() return arbitration ~= nil end

--- Take the single-flight arbitration slot, or nil if one is already running.
---
--- Returns a HANDLE rather than a boolean so the slot cannot outlive the caller.
--- Every path that clears it -- a dialog answered, a settle timer firing -- is a
--- scope-tracked handle belonging to the REQUESTING feature, and a panel cancelled
--- by teardown never invokes its callback. Disabling that feature (a Settings
--- toggle re-enables it, which is enough) would therefore latch the flag on
--- forever, and a latched flag silently turns every window mover in the catalog
--- into a no-op. Tracking this handle on the same scope makes teardown release it.
---@return { stop: fun() }|nil
function M.beginArbitration()
    if arbitration then return nil end
    local mine = {}
    arbitration = mine
    return { stop = function()
        if arbitration == mine then arbitration = nil end
    end }
end

--- Drop every lease. The registry calls this on reload so a mode torn down with
--- the whole Lua state behind it cannot leave a holder that outlives it.
function M.resetModes()
    holders = {}
    arbitration = nil
end

return M
