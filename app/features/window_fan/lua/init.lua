-- features/window_fan
--
-- "Window Fan": a persistent WINDOW-SWITCHER MODE. One trigger gathers every
-- window on the FOCUSED screen into a BORDER-ANCHORED SLAB FAN
-- (platform.windows.fanSlots): each window is a large slab flush against its own
-- segment of the screen's edge, so EVERY window keeps a full, always-visible,
-- grabbable edge strip in its own slice of the screen border. You STAY in the
-- mode: every window wears a live colored border, and clicking any window
-- switches to it. Press the toggle again -- or the widget's Exit -- to leave
-- the mode and put every window back where it was (slab shapes are a
-- switcher-only cost; leaving restores the real layout). The rearranging is
-- OPTIONAL -- see LABEL MODE below.
--
-- FOUR ACTIONS: the toggle, plus next / prev / confirm for keyboard use. There is
-- still deliberately no separate "restore" action -- the toggle already exits from
-- both the menubar and the hotkey, and a duplicate exit path was removed on
-- 2026-07-19. `confirm` is NOT that duplicate: it exits AND focuses the selection,
-- which the toggle cannot do (the toggle leaves focus where it was). next/prev
-- move a preview only -- see the note on st.cursor for why they must not focus.
--
-- WHY THE FAN. macOS won't let us reorder OTHER apps' windows (AXRaise is
-- top-only; some apps steal focus on raise), so we cannot "manage layers". The
-- fan sidesteps z-order entirely: each window's edge strip lives where NO other
-- window's RECTANGLE reaches, so it is visible under ANY stacking order -- no
-- reflow, no re-layer, and the user's own click (raise-to-top) never covers
-- another window's edge. (Proven in windows_geometry: strip-exclusivity.)
--
-- LABEL MODE (`arrange` = false) is the same mode with the ARRANGEMENT REMOVED:
-- borders, widget list, live tracking and the keyboard ring, with no window ever
-- moved. It exists because the arrangement is the expensive half and the
-- identification is the half that demonstrably works -- and dropping it drops every
-- constraint the arrangement imposes: no window limit (nothing has to fit a slab),
-- no minimum-size problem, no raise pass, and no restore. Label mode captures NO
-- originals at all, at entry or later, precisely so that leaving never yanks back a
-- window the user moved themselves while the labels were up. The option is latched
-- at enter() for the session, so a live mode is never half-slabbed. Everything
-- below about slabs, capacity and restore therefore applies to the ARRANGING mode;
-- `st.arranging` marks each place it forks.
--
-- AND WHY IT IS BOUNDED. That proof is sound but it ASSUMES each window occupies
-- the slab it is handed, and macOS windows have minimum sizes they will not go
-- below. Slabs shrink as ~1/N; minimums do not. Past the crossing point windows
-- overshoot their slots and bury their neighbours' strips -- replaying a real
-- 33-window fan measured median overshoot 3.8x (worst 5.3x) and 24 of 26 strips
-- covered, 22 of them completely. So the mode is CAPPED by W.fanCapacity: it
-- refuses to enter above the screen's honest capacity, and refuses to grow past
-- it while live, rather than silently delivering the exact layout it exists to
-- prevent. (Owner's call, 2026-07-25, over fanning a top-K subset: the mode keeps
-- its promise for every window on the screen, or it does not run.)
-- Analysis: notes/window-fan-usability.md.
--
-- THE FAN STAYS COMPLETE, WITH STABLE SLOTS. The mode's promise is "every window
-- on this screen has a grabbable edge" -- so a window that opens or is dragged in
-- is TAKEN into the fan, and one that closes or leaves frees its place. But re-
-- fanning must NOT shuffle the OTHER windows: each window holds a FIXED slot index
-- + color for the mode's life (fanSlots keys geometry off the index, so only the
-- ONE side whose count changes ever re-tiles). A window MOVED to another screen
-- RESERVES its slot, color, and captured original -- moving it back reclaims the
-- exact slab and color, and no other window budges. A newcomer takes the lowest
-- FREE slot + color (reserved ones are held, so it never collides with a live one).
-- Only a genuinely CLOSED window frees its slot + color back to the pool. Detection
-- is EVENT-driven: onFocusChanged (open/close in the frontmost app) + onAppActivated
-- (a NEW app's window, and a drag's START), with a LOOSE reconcile poll
-- (RECONCILE_SECONDS) as the sole backstop for a drag-IN completing -- the same
-- reconcile a real window manager keeps, since AX observers only see apps they
-- attached to.
--
-- OCCLUSION-CORRECT BORDERS. The borders are our own floating overlays, which
-- macOS can only paint ON TOP of every window -- so a naive full border draws
-- across whatever window is actually in front. The fix uses the fact that
-- ctx.window.list() is returned in true FRONT-TO-BACK z-order (CGWindowList):
-- each window's border is its full frame CLIPPED (W.rectMinus) to the part no
-- window IN FRONT of it covers, so the border hugs the window's real visible
-- region (which always includes its strip). The frontmost window shows a full
-- border; the focused one is bold; the rest carry a translucent fill. A click or
-- drag re-reads the z-order / frame and re-clips.
--
-- The borders are PERSISTENT and TRACKED, not a flash: they live for the mode's
-- whole lifetime. This is deck's service shape and its border/tracking
-- primitives -- but none of its scrim/hero/pick machinery: Window Fan has ONE
-- state (in the mode), plus its OWN switcher widget (the draggable card below).
--
-- A LIGHT STATEFUL MODE via ctx.perEnable (deck's pattern): when ARRANGING,
-- entering CAPTURES each window's original frame and leaving restores every window
-- (matched by stable wid across the re-list); label mode captures and restores
-- nothing. stop() leaves a live mode on disable. Every placement rides
-- ctx.window.setFrameFor, so Window Rewind also undoes a fan.
--
-- Needs Accessibility (window enumeration, by-id frame setting, the observers).

local W = require("platform.windows")

local NAME = "Window Fan"
local HYPER = { "cmd", "alt", "ctrl" }

-- Gutter between the ring and the screen edge (px), the deck's visual rhythm.
local PAD = 8

-- How often the LOOSE reconcile poll re-checks the member set (seconds). The
-- app-activation + focus events catch opens / closes / drag-starts instantly, so
-- this is only the backstop for a drag-IN completing -- an AX window-move on an
-- app we may not be observing, which fires no event we hear. Hence loose.
local RECONCILE_SECONDS = 2.0

-- The member-ring palette shared with Window Deck (platform.windows owns it,
-- so the two window modes never drift apart on their shared visual language).
local PALETTE = W.RING_PALETTE

-- The per-enable controller: holds the live mode state (borders, tracking
-- subscriptions, captured originals) and the enter/leave lifecycle. Built once
-- per enable via ctx.perEnable, so every action fire and stop() reach the SAME
-- state.
---@param ctx table
---@param ctx Ctx
local function controllerFor(ctx)
    -- The mode's live state. Three per-window maps, all keyed by stable wid, held
    -- for the mode's life so a window keeps its identity across re-fans (and across
    -- a move-out-and-back):
    --   slot:      wid -> slot INDEX (1-based) in the fan; fixed once assigned.
    --   color:     wid -> border color; fixed once assigned.
    --   originals: wid -> pre-fan frame, so leaving restores it.
    -- A window MOVED off-screen keeps all three (reserved); only a CLOSED window
    -- (gone from the whole window list) frees them back to the pool. borders holds
    -- only the ACTIVE (on-screen) windows' overlays. order: ALL on-screen wids front-
    -- to-back; frames: wid -> frame for every wid in `order`. screen: the bound
    -- screen. memberSig: signature of the arranged active set (change detection).
    -- active gates the toggle; refanning guards re-entry. Occlusion clips a border
    -- against EVERY window in front of it -- fanned or not -- so a window we didn't
    -- gather still clips it.
    -- bundle: wid -> owning app's bundleID (non-empty only). Recorded at place
    -- time so refan can tell "this window closed" from "this window's WHOLE APP
    -- missed the AX timeout" -- absence from a listing looks identical otherwise,
    -- and guessing wrong destroys the window's captured original (see refan).
    -- cursor: the KEYBOARD selection (a wid), or nil when the keyboard is not
    -- driving. It is deliberately separate from focusedWid: stepping through the
    -- ring must not focus each window on the way past, both because that is a
    -- burst of app activations per keypress and because raising windows one after
    -- another is the z-order churn the project's Z-order rule forbids. So next/prev
    -- move a PREVIEW, and only confirm commits.
    local st = { active = false, slot = {}, color = {}, side = {}, originals = {},
                 bundle = {},
                 borders = {}, order = {}, frames = {}, focusedWid = nil, screen = nil,
                 memberSig = nil, refanning = false, widget = nil, widgetOrder = {},
                 cursor = nil, recycled = false, arranging = true }

    -- What the bold border and the highlighted widget row point at: the keyboard
    -- selection when the keyboard is driving, else whatever is really focused.
    --
    -- The cursor is dropped the moment its window is no longer a fan member (closed,
    -- moved to another Space, its app went quiet). A cursor pointing outside
    -- st.borders would leave NO border bold and NO widget row highlighted -- the
    -- selection would simply vanish from view while still being what confirm() acts
    -- on, so confirm would exit having focused nothing.
    local function selectedWid()
        if st.cursor and not st.borders[st.cursor] then st.cursor = nil end
        return st.cursor or st.focusedWid
    end

    -- The fan's SIZE: the high-water slot index, which is what place() hands to
    -- fanSlots and therefore what actually determines how thin the slabs get.
    --
    -- This is NOT the member count, and the difference is the whole point. A slot
    -- held for a window that moved to another screen or whose app went quiet is
    -- RESERVED -- it still consumes geometry while its window is absent, and a
    -- freed slot below it leaves a hole. So counting members (or even counting
    -- st.slot entries) understates the fan, and a capacity gate built on either
    -- silently lets the slabs fall below what apps accept. Every capacity decision
    -- must ask this function, so all of them agree with place().
    local function fanSizeN()
        local n = 0
        for _, idx in pairs(st.slot) do if idx > n then n = idx end end
        return n
    end

    -- The fan's members in a STABLE ring order (by slot index), independent of the
    -- widget -- keyboard navigation must work with the widget option turned off,
    -- so this cannot live inside widgetRows.
    local function orderedWids()
        local wids = {}
        for wid in pairs(st.borders) do wids[#wids + 1] = wid end
        table.sort(wids, function(a, b) return (st.slot[a] or 0) < (st.slot[b] or 0) end)
        return wids
    end

    -- Re-draw every border for the current z-order + frames: each window's full
    -- border, CLIPPED to the part of it that nothing IN FRONT covers. The FOCUSED
    -- window's border is bold; a window that is ACTUALLY covered carries a
    -- translucent fill on its still-visible sliver (an identity aid). A window
    -- that nothing actually covers gets a full, UNFILLED border -- even if other
    -- windows sit in front of it in z-order without overlapping it (e.g. focus
    -- moved to another SCREEN): filling such a window would tint its whole frame,
    -- the "full transparent overlay" bug. So fill/clip keys on real coverage
    -- (visible area < frame area), not merely on "something is in front".
    local function drawOcclusion()
        for i, wid in ipairs(st.order) do
            local b = st.borders[wid]
            local f = st.frames[wid]
            if b and f then
                b.o.setFrame(f)
                b.o.setStyle(wid == selectedWid() and "focus" or "member")
                -- Every window in front of it that can actually cover any of it. The
                -- INTERSECTION filter is behaviour-identical (rectMinus returns a piece
                -- untouched when the subtrahend misses it) but it keeps rectMinus from
                -- fragmenting on rects that cannot contribute -- and fragmentation is
                -- what makes this pass quadratic. Measured on a worst-case full cascade:
                -- 8 windows 0.06ms, 24 1.1ms, 40 4.7ms, 80 33ms. Label mode has no
                -- window limit (the fan's capacity gate does not apply to it), so on a
                -- real desktop, where most windows do NOT overlap, this filter is what
                -- keeps the common case near the low end of that curve.
                local fronts = {}
                for j = 1, i - 1 do
                    local wf = st.frames[st.order[j]]
                    if wf and wf.x < f.x + f.w and f.x < wf.x + wf.w
                       and wf.y < f.y + f.h and f.y < wf.y + wf.h then
                        fronts[#fronts + 1] = wf
                    end
                end
                local vis = W.rectMinus(f, fronts)         -- the still-visible pieces
                local visArea = 0
                for _, r in ipairs(vis) do visArea = visArea + r.w * r.h end
                if visArea >= f.w * f.h - 0.5 then          -- nothing actually covers it
                    b.o.setFilled(false)
                    b.o.clearClip()
                else
                    b.o.setFilled(wid ~= selectedWid())
                    b.o.setClip(vis)                        -- draw only where still visible
                end
            end
        end
    end

    -- Rebuild order + frames from the live window list (front-to-back), covering
    -- ALL on-screen windows so occlusion tracks the real stacking (and any window
    -- we didn't gather that ends up in front) after the user clicks around. Also
    -- PRUNE: a bordered window that has left the list (closed, minimized, moved to
    -- another screen) loses its border here, so no ghost border lingers. A window
    -- that newly appears shows up in `order`/`frames` (so it clips the borders
    -- behind it like any other window in front) -- it is TAKEN into the fan
    -- separately, by refan(), once the member-set change is detected.
    local function refreshFromList()
        local order, frames, live = {}, {}, {}
        for _, w in ipairs(ctx.window.list()) do
            if w.wid and w.wid ~= 0 then
                order[#order + 1] = w.wid
                frames[w.wid] = { x = w.x, y = w.y, w = w.w, h = w.h }
                live[w.wid] = true
                -- RECYCLED WINDOW ID. macOS reuses a CGWindowID after a window
                -- closes, and originals are retained for the whole mode session now,
                -- so the reuse window is minutes rather than sub-second. A wid whose
                -- OWNING APP changed is a different window wearing a dead one's id.
                --
                -- It has to be caught HERE, on the raw listing. It does not look like
                -- a newcomer (st.slot[wid] is already set), and -- the part that makes
                -- it invisible everywhere else -- the member SIGNATURE is keyed by
                -- wid, so a recycle produces an IDENTICAL signature and refan is never
                -- even called. Left undetected it inherits the dead window's slot and
                -- captured original, and leave() "restores" it to a stranger's frame.
                local owner = st.bundle[w.wid]
                if owner and w.bundleID and w.bundleID ~= "" and owner ~= w.bundleID then
                    ctx.log("fan: wid " .. w.wid .. " changed owner ('" .. owner
                        .. "' -> '" .. w.bundleID .. "') -- recycled window id;"
                        .. " slot + original reset")
                    if st.borders[w.wid] then
                        st.borders[w.wid].o.stop(); st.borders[w.wid] = nil
                    end
                    st.slot[w.wid], st.color[w.wid], st.side[w.wid] = nil, nil, nil
                    st.originals[w.wid], st.bundle[w.wid] = nil, nil
                    st.recycled = true          -- the signature cannot see this; force a refan
                end
            end
        end
        for wid, b in pairs(st.borders) do
            if not live[wid] then                       -- window gone -> drop its border
                b.o.stop()
                st.borders[wid] = nil
                ctx.log("fan: window " .. wid .. " gone -- border dropped")
            end
        end
        -- The focused window is the one the user just brought FORWARD (a real click,
        -- or our raise on a widget switch), so it is frontmost -- HOIST it to the
        -- front of the occlusion order even if the CGWindow z-order read here still
        -- lags the raise. Without this, an async gap left the focused window listed
        -- behind a window it is actually above, and its (bold) border got clipped to
        -- the uncovered sliver instead of drawing full. (Its slot is exclusive, so a
        -- genuinely-behind case still shows its edge; hoisting only fixes the race.)
        if st.focusedWid then
            for i, wid in ipairs(order) do
                if wid == st.focusedWid then
                    table.remove(order, i); table.insert(order, 1, wid)
                    break
                end
            end
        end
        st.order, st.frames = order, frames
    end

    -- The fannable windows on `screen`, MRU order: W.arrangeable (the mode
    -- predicate shared with Window Deck) + membership by PURE GEOMETRY
    -- (W.onScreen: centre-in-rect) -- window frames and screen frames come from
    -- separate native calls whose tables are never the same object, so an
    -- identity compare would silently match nothing in the real host.
    local function fannable(screen)
        local out = {}
        for _, w in ipairs(ctx.window.list()) do
            if W.arrangeable(w) and W.onScreen(w, screen) then
                out[#out + 1] = w
            end
        end
        return out
    end

    -- A stable signature of a member set: the sorted wids. Detects add/remove
    -- regardless of order, so a plain click (same set, new z-order) never trips it.
    local function sigOf(wins)
        local ids = {}
        for _, w in ipairs(wins) do ids[#ids + 1] = w.wid end
        table.sort(ids)
        return table.concat(ids, ",")
    end

    -- The current fannable set on the mode's screen, as a signature.
    local function currentSig()
        return sigOf(fannable(st.screen))
    end

    -- The lowest slot INDEX not held by any known window (active or reserved). Fills
    -- a hole a closed window left before extending the fan, so indices stay dense and
    -- a returning reserved window's held index is never handed to someone else.
    local function lowestFreeIndex()
        local used = {}
        for _, idx in pairs(st.slot) do used[idx] = true end
        local i = 1
        while used[i] do i = i + 1 end
        return i
    end

    -- The lowest palette color not held by any known window. Reserved windows keep
    -- their color, so a newcomer never draws a live window's color (the conflict the
    -- old monotonic dealer hit once it wrapped). Wraps only past #PALETTE windows.
    local function lowestFreeColor()
        local used = {}
        for _, c in pairs(st.color) do used[c] = true end
        for _, c in ipairs(PALETTE) do
            if not used[c] then return c end
        end
        local n = 0
        for _ in pairs(st.color) do n = n + 1 end
        return PALETTE[n % #PALETTE + 1]
    end

    -- (Re)install the frame-drag observer for the CURRENT member apps, so a
    -- newcomer's app is watched too. Fires our own AX echoes; the handler only
    -- re-clips a bordered window's frame, which is idempotent.
    local function installFramesWatch(bundleIds)
        if st.framesWatch then st.framesWatch.stop(); st.framesWatch = nil end
        st.framesWatch = ctx.window.onFramesChanged(bundleIds, function(info)
            if not st.active then return end
            if info.wid and st.borders[info.wid] then
                st.frames[info.wid] = { x = info.x, y = info.y, w = info.w, h = info.h }
                drawOcclusion()
            end
        end)
    end

    -- Build the switcher-widget rows from the ACTIVE windows, ordered by slot index
    -- (a stable list). Each row carries the window's border color, the EDGE it
    -- exposes (T/B/L/R, for the spatial swatch), its title + bundle (icon), and the
    -- focused flag. Records st.widgetOrder so onSwitch(i) maps a row back to its wid.
    local function widgetRows()
        local meta = {}
        for _, w in ipairs(ctx.window.list()) do
            if w.wid then meta[w.wid] = { title = w.title or "", bundleID = w.bundleID or "" } end
        end
        local rows = {}
        st.widgetOrder = orderedWids()          -- the SAME ring the keyboard walks
        for _, wid in ipairs(st.widgetOrder) do
            local m = meta[wid] or { title = "", bundleID = "" }
            rows[#rows + 1] = {
                color = st.color[wid], side = st.side[wid] or "",
                title = m.title, bundleID = m.bundleID,
                focused = wid == selectedWid(),
            }
        end
        return rows
    end

    -- Push the current rows + count into the live widget (no-op if it is off).
    local function updateWidget()
        if not st.widget then return end
        local rows = widgetRows()
        st.widget.setRows(rows, ctx.plural("widget.count", #rows,
            { one = "%d window", other = "%d windows" }, #rows))
    end

    -- Place the ACTIVE `wins` onto their FIXED slot indices, keeping `focusWid`
    -- frontmost. Shared by enter and refan. Callers assign st.slot / st.color /
    -- st.originals FIRST (enter via assignNearest for a minimal first jump; refan
    -- by reserving survivors and dealing newcomers a free index) -- place just reads
    -- them. Fan size N is the HIGH-WATER slot index (active members + reserved
    -- holes), so a reserved window's held index keeps the geometry from re-tiling
    -- while it is gone. Records each slot frame + exposed side, runs the ordered
    -- raise pass + focus hand-back, re-arms observers, refreshes the widget.
    ---@param reason string a short trace label ("entered" | "refanned")
    local function place(wins, screen, focusWid, reason)
        local N = fanSizeN()
        if N < 1 then return end
        -- LABEL MODE (st.arranging == false) computes no slab geometry at all: it
        -- labels the windows WHERE THEY ARE. Slots are still assigned -- they carry
        -- identity and ring order, not position -- so membership, reservations and
        -- the keyboard ring all work unchanged; only the geometry is skipped.
        local slots = st.arranging
            and W.fanSlots(screen, N, ctx.opt("edge") or 40, PAD) or nil

        -- Place each active window on its slot, give any un-bordered one its
        -- PERSISTENT colored border, and record its slot frame. The IMPOSED z-order
        -- (built below) is what the raise pass establishes -- reliable now, before
        -- the async AX frames settle.
        local bundleSet = {}
        for _, w in ipairs(wins) do
            if not st.borders[w.wid] then
                local color = st.color[w.wid]
                st.borders[w.wid] = { o = ctx.outline("member", color), color = color }
            end
            if st.arranging then
                local s = slots[st.slot[w.wid]]
                st.frames[w.wid] = { x = s.x, y = s.y, w = s.w, h = s.h }
                st.side[w.wid] = s.side           -- the edge this window exposes (widget swatch)
                ctx.window.setFrameFor(w.id, st.frames[w.wid])
            else
                -- The window's OWN frame, untouched. "" side => the widget draws a
                -- plain colour chip instead of an edge glyph, because in label mode
                -- no edge is guaranteed exposed and pointing at one would be a lie.
                st.frames[w.wid] = { x = w.x, y = w.y, w = w.w, h = w.h }
                st.side[w.wid] = ""
            end
            if w.bundleID and w.bundleID ~= "" then
                bundleSet[w.bundleID] = true
                -- Only NON-EMPTY ids are recorded: "" is truthy in Lua, so storing
                -- it would make refan read every bundle-less process as an
                -- AX-timeout blind spot forever.
                st.bundle[w.wid] = w.bundleID
            end
        end

        -- One ordered raise pass, back-to-front (reversed MRU), so the pile's
        -- final z-order matches recency -- the window motion covers the churn.
        -- Then the focused window is lifted with a real focus (a surgical raise
        -- can't beat an app that activated itself when raised).
        --
        -- SKIPPED in label mode, and that is a headline benefit rather than an
        -- omission: this pass is the raise storm behind the z-order churn, the
        -- self-activating-app flashes, and (with the seam's per-activation costs) a
        -- large share of the stalls that started this whole investigation. Labelling
        -- windows in place needs no reordering, so the user's own stacking is left
        -- exactly as they arranged it.
        if st.arranging then
            for i = #wins, 1, -1 do ctx.window.raise(wins[i].id) end
            if focusWid and focusWid ~= 0 then
                for _, w in ipairs(wins) do
                    if w.wid == focusWid then ctx.window.focus(w.id); break end
                end
            end
        end

        -- The z-order we just imposed: focused window frontmost, then the rest in
        -- MRU order (st.frames already holds each slot). drawOcclusion clips each
        -- border against those in front. These are the INTENDED slot frames; the
        -- delayed refresh below swaps in the ACTUAL frames once AX has applied them.
        st.focusedWid = focusWid
        st.order = {}
        if focusWid and st.borders[focusWid] then st.order[1] = focusWid end
        for _, w in ipairs(wins) do
            if w.wid ~= focusWid then st.order[#st.order + 1] = w.wid end
        end
        drawOcclusion()

        local bundleIds = {}
        for id in pairs(bundleSet) do bundleIds[#bundleIds + 1] = id end
        installFramesWatch(bundleIds)

        -- AX applies setFrameFor ASYNCHRONOUSLY, and a window may not land exactly
        -- on its slot (min-size, clamping). Re-read the REAL frames + z-order once
        -- things settle so the borders sit on the windows, not on where we asked
        -- them to go. Logs any gap (the alignment diagnostic). Label mode asked
        -- nothing to move, so there is nothing to settle and nothing to realign --
        -- st.frames already holds each window's real frame.
        if st.settleTimer then st.settleTimer.stop(); st.settleTimer = nil end
        if st.arranging then
            -- Snapshot the INTENDED frames for the comparison below. Built inside the
            -- branch so label mode does not copy a table it will never read.
            local intended = {}
            for wid, f in pairs(st.frames) do intended[wid] = f end
            st.settleTimer = ctx.afterSeconds(0.3, function()
                if not st.active then return end
                refreshFromList()
                for wid in pairs(st.borders) do
                    local s, a = intended[wid], st.frames[wid]
                    if s and a and (math.abs(s.x - a.x) > 2 or math.abs(s.y - a.y) > 2
                        or math.abs(s.w - a.w) > 2 or math.abs(s.h - a.h) > 2) then
                        ctx.log(string.format(
                            "fan: wid %d slot=%.0f,%.0f,%.0fx%.0f actual=%.0f,%.0f,%.0fx%.0f (border realigned)",
                            wid, s.x, s.y, s.w, s.h, a.x, a.y, a.w, a.h))
                    end
                end
                drawOcclusion()
            end)
        else
            -- Arranging mode gets its first honest clip from the settle timer above.
            -- Label mode has no settle timer, so do the equivalent once, now: without
            -- it the first draw clips each border only against fan MEMBERS, and a
            -- non-member window in front (including this feature's own widget card)
            -- would not clip until the first focus event or the 2s poll. Label mode is
            -- precisely the case where windows genuinely overlap.
            refreshFromList()
            drawOcclusion()
        end

        st.screen = screen
        st.memberSig = sigOf(wins)

        -- Terse arrangement summary so a layout issue (a wasted edge, an off pile)
        -- is diagnosable from the log alone: the slots' bounding box vs the screen.
        -- Guarded on `slots` rather than st.arranging: the summary needs the slot
        -- geometry, and only one of those two facts is provable to the type checker.
        if slots then
            local bx1, by1, bx2, by2 = math.huge, math.huge, -math.huge, -math.huge
            for _, s in ipairs(slots) do
                bx1 = math.min(bx1, s.x); by1 = math.min(by1, s.y)
                bx2 = math.max(bx2, s.x + s.w); by2 = math.max(by2, s.y + s.h)
            end
            ctx.log(string.format(
                "fan: %s fan -- %d active / %d slots on '%s', edge=%d, margins L=%.0f R=%.0f T=%.0f B=%.0f",
                reason, #wins, N, screen.name or "?", ctx.opt("edge") or 40,
                bx1 - screen.x, (screen.x + screen.w) - bx2, by1 - screen.y, (screen.y + screen.h) - by2))
        else
            ctx.log(string.format(
                "fan: %s labels -- %d windows labelled in place on '%s' (nothing moved)",
                reason, #wins, screen.name or "?"))
        end

        updateWidget()   -- reflect the new membership / order / focus in the widget
    end

    -- The active set changed (a window opened / dragged in, or one closed / moved
    -- out): re-place, DISTURBING NO ONE ELSE. Survivors keep their slot + color +
    -- original; a MOVED-OUT window (still open, just off our screen) keeps all three
    -- reserved so a return reclaims its exact slab; a CLOSED window (gone from the
    -- whole list) frees its slot + color + original; a NEWCOMER is dealt the lowest
    -- free slot + color, its pre-fan frame captured before it moves. Guarded
    -- against re-entry (our own moves fire the observers but never change the SET, so
    -- the signature guard already absorbs those echoes -- refanning is belt-and-braces).
    local function refan()
        if st.refanning then return end
        local active = fannable(st.screen)
        local activeSet = {}
        for _, w in ipairs(active) do activeSet[w.wid] = true end
        -- The FULL window list (all screens) tells a moved-out window (still exists
        -- -> reserve) from a closed one (gone -> free).
        local exists = {}
        for _, w in ipairs(ctx.window.list()) do
            if w.wid and w.wid ~= 0 then exists[w.wid] = true end
        end
        -- A member missing from the listing is EITHER closed OR its app just missed
        -- the AX messaging timeout -- and absence ALONE cannot tell them apart.
        -- Treating a timeout as a close is DESTRUCTIVE: it frees st.originals, and
        -- when the app answers again the window returns as a newcomer whose
        -- "original" is captured from the SLAB it now sits in, so leaving the mode
        -- restores it to the slab and its real pre-fan geometry is gone for good.
        -- That was a live bug (found 2026-07-25), and it fired routinely: a fixed
        -- 0.3s AX ceiling was dropping nine apps' windows from every listing.
        --
        -- So ASK, don't guess -- the seam reports exactly which apps it failed to
        -- read (a heuristic on "did any of this app's windows appear?" was tried
        -- first and is WRONG: closing an app's LAST window is indistinguishable from
        -- that app going quiet, so it wasted a slot and re-tiled the fan on an
        -- ordinary close -- which the test suite caught).
        local dropped = {}
        for _, id in ipairs(ctx.window.droppedApps()) do dropped[id] = true end
        for wid in pairs(st.slot) do
            if not exists[wid] then
                local owner = st.bundle[wid]
                if owner and dropped[owner] then
                    -- Its app did not answer: keep slot + color + original reserved
                    -- so nothing re-tiles and the true geometry survives. Only the
                    -- border goes (there is no known frame to draw it on).
                    if st.borders[wid] then st.borders[wid].o.stop(); st.borders[wid] = nil end
                    ctx.log("fan: window " .. wid .. " missing -- app '" .. owner
                        .. "' did not answer AX, slot " .. (st.slot[wid] or "?")
                        .. " + original RESERVED (not treated as closed)")
                else
                    -- Free the slot + color (so the fan re-tiles densely and the
                    -- colour returns to the pool) but NEVER the captured original.
                    -- An absent window has SEVERAL possible causes and only some are
                    -- distinguishable: closed, app unanswered (handled above), or
                    -- moved to another Space -- CGWindowList is Space-scoped, so a
                    -- Space switch makes every window elsewhere "absent" while its
                    -- app still answers, which lands here. Discarding the original
                    -- is the one irreversible act available, so it is simply never
                    -- done while the mode is live: the entry costs a few bytes, and
                    -- leave() only ever restores wids that are still bordered, so a
                    -- genuinely-closed window's stale entry is inert.
                    st.slot[wid], st.color[wid], st.side[wid] = nil, nil, nil
                    st.bundle[wid] = nil
                    if st.borders[wid] then st.borders[wid].o.stop(); st.borders[wid] = nil end
                    ctx.log("fan: window " .. wid
                        .. " absent -- slot + color freed, original kept")
                end
            end
        end
        -- MOVED-OUT members (exist but off our screen): drop only the border; keep
        -- the slot / color / original reserved so moving back reclaims them.
        for wid, b in pairs(st.borders) do
            if not activeSet[wid] then
                b.o.stop(); st.borders[wid] = nil
                ctx.log("fan: window " .. wid .. " left screen -- slot " ..
                    (st.slot[wid] or "?") .. " reserved")
            end
        end
        st.recycled = false        -- consumed: refreshFromList already reset any recycled ids
        -- NEWCOMERS: lowest FREE slot + color (reserved holes are held, never reused
        -- here), original captured NOW before we move it.
        -- The entry gate would be theatre on its own: a screen reaches 30 windows by
        -- ACCUMULATING them, and every one of those opens lands here, not in enter().
        -- So the same ceiling applies to growth -- a newcomer beyond capacity is left
        -- where it is rather than shrinking every slab past what apps will accept.
        -- The members keep their exclusive strips relative to each other, and
        -- drawOcclusion already clips their borders against non-member windows, so
        -- the borders stay honest about what is actually visible.
        -- math.huge in label mode: the ceiling exists only because slabs shrink, and
        -- label mode has no slabs (see the gate in enter).
        local cap = st.arranging
            and W.fanCapacity(st.screen, ctx.opt("edge") or 40, PAD) or math.huge
        -- The high-water index, not a count: reserved slots and holes both mean the
        -- fan is already larger than the number of windows in it (see fanSizeN).
        local held = fanSizeN()
        for _, w in ipairs(active) do
            if not st.slot[w.wid] then
                if held >= cap then
                    ctx.log("fan: not taking in wid " .. w.wid .. " -- at capacity ("
                        .. cap .. " on '" .. (st.screen.name or "?") .. "'); left in place")
                else
                    st.slot[w.wid] = lowestFreeIndex()
                    st.color[w.wid] = lowestFreeColor()
                    -- Re-read rather than incrementing: lowestFreeIndex may FILL A
                    -- HOLE left by a closed window, which does not grow the fan at all.
                    held = fanSizeN()
                    -- NEVER overwrite a retained original. The branch above keeps one
                    -- alive across an AX blind spot; this guard is what makes that
                    -- retention count, and it also covers the bundle-less case that
                    -- branch cannot classify. Capturing here unconditionally is exactly
                    -- how the pre-fan frame got replaced by the slab.
                    --
                    -- But retention is keyed to the OWNING APP, because macOS RECYCLES
                    -- a CGWindowID after a window closes (listWindows says so itself).
                    -- Retention now spans the whole mode session rather than a
                    -- sub-second gap, so a recycled wid really can arrive here -- and
                    -- inheriting the dead window's frame would make leave() fling this
                    -- window to a stranger's geometry, which is worse than the bug the
                    -- retention fixes. A different owner means a different window.
                    -- Gated on st.arranging for the same reason enter() is: label mode
                    -- must NEVER hold an original, or a window that joins mid-session
                    -- and is then dragged by the user would be yanked back on leave.
                    -- This keeps the invariant absolute ("label mode captures nothing")
                    -- rather than true only for the windows present at entry.
                    local kept = st.originals[w.wid]
                    if st.arranging and (not kept or kept.bundleID ~= (w.bundleID or "")) then
                        st.originals[w.wid] = { x = w.x, y = w.y, w = w.w, h = w.h,
                                                bundleID = w.bundleID or "" }
                    end
                end
            end
        end
        -- Only SLOTTED windows may go to place() -- it indexes the slot table by
        -- st.slot[wid], so a refused newcomer would index it with nil.
        local placeable = {}
        for _, w in ipairs(active) do
            if st.slot[w.wid] then placeable[#placeable + 1] = w end
        end
        if #active == 0 then                            -- screen emptied: nothing to fan
            for _, b in pairs(st.borders) do b.o.stop() end
            st.borders, st.order, st.frames, st.memberSig = {}, {}, {}, ""
            updateWidget()
            ctx.log("fan: no windows left on screen -- fan cleared (mode still on)")
            return
        end
        if #placeable == 0 then                          -- everything refused
            ctx.log("fan: refan placed nothing -- all " .. #active
                .. " active windows are past capacity on '" .. (st.screen.name or "?") .. "'")
            st.memberSig = sigOf(active)
            updateWidget()
            return
        end
        -- Keep whoever is focused frontmost if they're a member; else the first one.
        local fwid = ctx.window.focusedWid()
        local isMember = false
        for _, w in ipairs(placeable) do if w.wid == fwid then isMember = true; break end end
        if not isMember then fwid = placeable[1].wid end
        st.refanning = true
        place(placeable, st.screen, fwid, "refanned")
        st.refanning = false
        -- place() records the signature of what it PLACED, but change detection
        -- compares against the full fannable set (currentSig). With a refused
        -- newcomer those differ permanently, and every poll would see a "changed"
        -- set and re-fan forever -- so the signature must describe what we LOOKED
        -- at, not what we moved.
        st.memberSig = sigOf(active)
    end

    -- Reconcile the highlight + occlusion with what is ACTUALLY focused and on top
    -- RIGHT NOW. Re-read who is focused (a 0 = UNRESOLVED keeps the last known -- a
    -- windowless / menubar app, or a not-yet-settled AX read; the "0 = don't trust
    -- it" rule place()/refan() also follow), refresh the z-order, and re-fan if the
    -- member set ALSO changed else just re-clip. This is the ONE self-heal path,
    -- shared by every focus signal AND the loose poll, so a stale focus read always
    -- converges (previously nothing re-read focus after an event, so a stale read
    -- stuck). Cross-app coverage is load-bearing: the native focused-window observer
    -- sees the frontmost app's OWN (within-app, cmd+`) switches only, so a CROSS-app
    -- switch -- to or from ANY other app, very much including Hammerdeck's OWN window
    -- -- reaches us ONLY as an app-activation; routing it here (not a membership-only
    -- check) is what keeps the highlight from STICKING on the last window when focus
    -- crosses apps.
    ---@param source string a short trace label
    local function resyncFocus(source)
        if not st.active or st.refanning then return end
        local w = ctx.window.focusedWid()
        if w ~= 0 then
            -- Focus moved by some OTHER means (a click on a window, a widget row,
            -- an app switch): the keyboard preview is stale and would now point
            -- somewhere the user is not, so hand the highlight back to real focus.
            if st.focusedWid and w ~= st.focusedWid then st.cursor = nil end
            st.focusedWid = w
        end
        refreshFromList()          -- the switch changed the stacking order
        -- st.recycled is checked alongside the signature because the signature CANNOT
        -- see a recycled window id: it is keyed by wid, and a recycle leaves the wid
        -- set identical. Without this the reset that refreshFromList just did would
        -- never be followed by the re-place that gives the new window a slot.
        if currentSig() ~= st.memberSig or st.recycled then
            ctx.log("fan: window set changed (" .. source .. ") -- refanning")
            refan()
        else
            drawOcclusion()
        end
        updateWidget()             -- move the widget's highlight to the new focus
    end

    -- A genuine focus signal (onFocusChanged / onAppActivated): reconcile NOW, then
    -- schedule ONE short deferred re-read. A cross-app activation can fire BEFORE the
    -- newly-active app's AX focused window resolves (focusedWid -> 0, or briefly the
    -- OLD app's window) AND/OR before CGWindowList reflects the raise -- leaving
    -- st.focusedWid stale. refreshFromList then HOISTS that stale window over the one
    -- the user actually clicked, so drawOcclusion clips + TINTS the real front with
    -- the translucent member fill (the reported "the focused window has a transparent
    -- color area, as if it isn't the focused one" bug). The deferred pass converges
    -- once AX + z-order settle -- the same async gap place() cures with its settle
    -- timer; a genuinely-unresolved focus (windowless app) just stays kept, and the
    -- 2s poll is the final backstop if even the deferred read fired too early.
    local function syncFocus(source)
        if not st.active or st.refanning then return end
        resyncFocus(source)
        if st.focusSettle then st.focusSettle.stop() end
        st.focusSettle = ctx.afterSeconds(0.12, function() resyncFocus(source .. "-settle") end)
    end

    -- Tear down every live-mode handle (widget + borders + observers + timers).
    -- Idempotent.
    local function teardown()
        if st.settleTimer then st.settleTimer.stop(); st.settleTimer = nil end
        if st.focusSettle then st.focusSettle.stop(); st.focusSettle = nil end
        if st.pollTimer then st.pollTimer.stop(); st.pollTimer = nil end
        if st.appWatch then st.appWatch.stop(); st.appWatch = nil end
        if st.screenWatcher then st.screenWatcher.stop(); st.screenWatcher = nil end
        if st.framesWatch then st.framesWatch.stop(); st.framesWatch = nil end
        if st.focusWatch then st.focusWatch.stop(); st.focusWatch = nil end
        if st.widget then st.widget.stop(); st.widget = nil end
        for _, b in pairs(st.borders) do b.o.stop() end
        st.borders, st.order, st.frames, st.widgetOrder = {}, {}, {}, {}
        st.memberSig, st.screen = nil, nil
    end

    function st.enter()
        if not ctx.axTrusted() then
            ctx.axPrompt()
            ctx.alert(ctx.t("fan.axRequired",
                "%1$s needs the Accessibility permission -- grant %2$s in System Settings, then try again",
                NAME, ctx.appName))
            return
        end
        local screen = W.focusedScreen(ctx)
        if not screen then return end

        -- Read focus BEFORE anything moves: a self-activating app fronting itself
        -- mid-pass must not change who we hand focus back to.
        local fwid = ctx.window.focusedWid()
        local wins = fannable(screen)
        if #wins == 0 then
            ctx.alert(ctx.t("fan.none", "No windows to fan on this screen"))
            return
        end

        -- The mode's SHAPE, latched for the session rather than read per pass: with
        -- `arrange` off this is LABEL MODE -- the borders, the widget, the tracking
        -- and the keyboard ring, with no window ever moved. Latched because flipping
        -- it under a live mode would leave half the windows slabbed and half not, and
        -- would make "restore on leave" mean two different things mid-session.
        st.arranging = ctx.opt("arrange") ~= false

        -- CAPACITY GATE. The fan's promise -- every window keeps an edge no other
        -- window can cover -- holds only while each window can actually TAKE the
        -- slab it is handed. Slabs shrink as ~1/N; app minimum sizes do not. Past
        -- the crossing point windows overshoot their slots (measured: median 3.8x,
        -- worst 5.3x) and bury their neighbours' strips, so the mode silently
        -- delivers the exact layout it exists to prevent -- 24 of 26 strips covered
        -- at 33 windows, 22 of them completely.
        --
        -- So REFUSE rather than degrade. Owner's call (2026-07-25) over fanning a
        -- top-K subset: the mode either keeps its promise for every window on the
        -- screen or does not run, and the alert names the real number so the limit
        -- is visible instead of mysterious.
        -- ... and it therefore does not apply to LABEL MODE at all: with no slab to
        -- refuse, there is no minimum size to violate and no strip to bury, so label
        -- mode has NO window limit. That is the whole reason it exists.
        local edge = ctx.opt("edge") or 40
        local cap = st.arranging and W.fanCapacity(screen, edge, PAD) or math.huge
        if #wins > cap then
            ctx.log(string.format(
                "fan: REFUSED -- %d windows on '%s' but edge=%d fits only %d "
                .. "(slabs below %dx%d are refused by real apps)",
                #wins, screen.name or "?", edge, cap, W.MIN_SLAB_W, W.MIN_SLAB_H))
            if cap == 0 then
                -- "it fits 0" is not a limit the user can act on -- the screen itself
                -- is too small for even one slab at this edge depth, and the only
                -- lever is the edge option (or a bigger display).
                ctx.alert(ctx.t("fan.screenTooSmall",
                    "This screen is too small to fan any window at an edge depth of %1$d",
                    edge))
            else
                ctx.alert(ctx.t("fan.tooMany",
                    "Too many windows to fan on this screen -- %1$d open, and it fits %2$d",
                    #wins, cap))
            end
            return
        end

        -- Fresh slot / color / original maps for this mode session. assignNearest
        -- gives each window the slot NEAREST its current position, so the first
        -- arrangement is the least jarring jump; colors are dealt lowest-free in
        -- window order. Refan keeps these fixed and only fills in newcomers.
        -- (Originals are captured by VALUE -- setFrameFor mutates the live rows.)
        st.slot, st.color, st.side, st.originals, st.bundle = {}, {}, {}, {}, {}
        -- assignNearest matches each window to the slot nearest its CURRENT position,
        -- which is meaningless without slots -- label mode takes MRU order instead, so
        -- the ring reads top-to-bottom in recency, and reserves nothing geometric.
        local perm
        if st.arranging then
            local slots = W.fanSlots(screen, #wins, ctx.opt("edge") or 40, PAD)
            local winCenters, slotCenters = {}, {}
            for i, w in ipairs(wins) do winCenters[i] = W.center(w) end
            for i, s in ipairs(slots) do slotCenters[i] = W.center(s) end
            perm = W.assignNearest(winCenters, slotCenters)
        else
            perm = {}
            for i = 1, #wins do perm[i] = i end
        end
        for i, w in ipairs(wins) do
            st.slot[w.wid] = perm[i]
            st.color[w.wid] = lowestFreeColor()
            -- Originals are captured ONLY when we are about to disturb the layout.
            -- Label mode must not capture them, and the reason is not thrift: it moves
            -- nothing, so the user stays free to drag their own windows while the
            -- labels are up -- and a "restore" on exit would then YANK every window
            -- back to where it happened to be when the mode started, silently undoing
            -- their own work. Nothing was taken, so nothing is given back.
            -- bundleID rides along so a RECYCLED CGWindowID can be told from the
            -- window that held it before (see the guard in refan).
            if st.arranging then
                st.originals[w.wid] = { x = w.x, y = w.y, w = w.w, h = w.h,
                                        bundleID = w.bundleID or "" }
            end
        end

        place(wins, screen, fwid, "entered")

        -- ACTIVE the moment the windows have MOVED, not at the end of enter --
        -- window_deck marks its own mode active on the same boundary (init.lua:920,
        -- before it binds anything). Every seam call below can RAISE (the seam
        -- errors rather than returning nil), and every exit path -- st.leave, the
        -- widget's Exit, forceExit on disable -- is gated on st.active. Setting it
        -- last meant a throw in the tail left the fan ENTERED BUT UNEXITABLE:
        -- windows fanned, no way out, and a re-press re-running enter() would
        -- overwrite st.originals with the FANNED frames, destroying the pre-fan
        -- layout for good. Nothing between here and the end reads st.active (the
        -- watchers that check it are registered below), so moving it up costs
        -- nothing and closes that hole.
        st.active = true

        -- The switcher widget (a draggable card listing the fan's windows). Opt-out
        -- via the "widget" option. Its position is persisted as an OFFSET from the
        -- mode's screen top-left, so it survives a screen move; a click on a row
        -- FOCUSES that window (the focus observer then moves the highlight), and Exit
        -- leaves the mode. Built AFTER place so st.side / st.color / st.borders are set.
        if ctx.opt("widget") ~= false then
            -- Offset from the mode screen's top-left, persisted (survives a screen
            -- move) and kept in st so onScreenChanged can re-anchor to the new frame.
            st.widgetDx = ctx.getState("widgetDx", math.max(0, math.floor(screen.w / 2 - 170)))
            st.widgetDy = ctx.getState("widgetDy", math.floor(screen.h * 0.26))
            st.widget = ctx.fanWidget({
                title = ctx.t("widget.title", NAME),
                count = ctx.plural("widget.count", #wins,
                    { one = "%d window", other = "%d windows" }, #wins),
                pos = { x = screen.x + st.widgetDx, y = screen.y + st.widgetDy },
                screen = { x = screen.x, y = screen.y, w = screen.w, h = screen.h },
                rows = widgetRows(),
                onMove = function(x, y)
                    st.widgetDx = x - (st.screen and st.screen.x or screen.x)
                    st.widgetDy = y - (st.screen and st.screen.y or screen.y)
                    ctx.setState("widgetDx", st.widgetDx)
                    ctx.setState("widgetDy", st.widgetDy)
                end,
                onExit = function() if st.active then st.leave() end end,
                onSwitch = function(i)
                    if not st.active then return end
                    local wid = st.widgetOrder[i]
                    if not wid then return end
                    for _, w in ipairs(ctx.window.list()) do
                        if w.wid == wid then
                            -- RAISE then focus, like a real click -- a bare focus can
                            -- leave the window behind its neighbour (border clipped).
                            -- One window forward is the sanctioned z-order move.
                            ctx.window.raise(w.id)
                            ctx.window.focus(w.id)
                            break
                        end
                    end
                end,
            })
        end

        -- Keep the borders honest AND the fan complete. Three triggers, all live
        -- for the mode's life (teardown() stops them):
        --   * onFocusChanged -- a WITHIN-app switch (cmd+`): re-reads the real z-order
        --     (the OS raised the focused window), moves the highlight, prunes gone
        --     windows; re-fans if the member set changed, else just re-clips.
        --   * onAppActivated -- a CROSS-app switch (clicking another app's window, incl.
        --     Hammerdeck's own), which the focused-window observer never sees: it drives
        --     the SAME focus sync (so the highlight follows focus across apps), and takes
        --     in a NEW app's window / a drag's start when that changed the set.
        --   * the loose poll -- the backstop that RE-READS focus + membership: it
        --     catches a silent drag-IN completing (the one change no event reports),
        --     AND heals a focus read stale during a racy activation if the deferred
        --     re-read was itself still too early.
        st.focusWatch = ctx.window.onFocusChanged(function() syncFocus("focus") end)
        st.appWatch = ctx.onAppActivated(function() syncFocus("app-activated") end)
        st.pollTimer = ctx.everySeconds(RECONCILE_SECONDS, function() resyncFocus("poll") end)
        -- Display reconfig (monitor plugged/unplugged, resolution or arrangement
        -- change): the fan's slots were sized to the OLD screen frame, so a resize
        -- leaves every slab stale, and a moved display leaves the widget adrift.
        st.screenWatcher = ctx.onSystemEvent("screenChanged", function() st.onScreenChanged() end)

    end

    -- Leave the mode: tear down borders + observers, then put every captured
    -- window back where it was. Re-list ONCE (ids churn) and match by stable wid;
    -- a window that has since closed is simply skipped. `skipRestore` leaves the
    -- windows where they are (onScreenChanged uses it when the fanned display
    -- vanished -- the captured originals were on the gone screen, so re-applying
    -- them would fling the windows off into nowhere).
    ---@param skipRestore boolean|nil
    function st.leave(skipRestore)
        if not st.active then return end   -- every caller guards; belt-and-braces
        -- Snapshot the ACTIVE members BEFORE teardown clears the borders: only
        -- windows currently in the fan are restored. A window MOVED off-screen
        -- (reserved) is left where the user put it -- restoring it would yank it back.
        local members = {}
        for wid in pairs(st.borders) do members[#members + 1] = wid end
        teardown()
        local restored, gone = 0, 0
        -- No `st.arranging` check here on purpose. Label mode holds NO originals at
        -- all -- neither at entry nor for a window that joins later -- so this loop
        -- naturally finds nothing to put back. Stating the rule once, as a property of
        -- the data, beats repeating it as a third branch that could drift out of step
        -- with the two capture sites.
        if not skipRestore then
            local byWid = {}
            for _, w in ipairs(ctx.window.list()) do
                if w.wid and w.wid ~= 0 then byWid[w.wid] = w.id end
            end
            for _, wid in ipairs(members) do
                local o, id = st.originals[wid], byWid[wid]
                if o and id then
                    ctx.window.setFrameFor(id, { x = o.x, y = o.y, w = o.w, h = o.h })
                    restored = restored + 1
                else
                    gone = gone + 1
                end
            end
        end
        st.active = false
        st.slot, st.color, st.side, st.originals, st.bundle = {}, {}, {}, {}, {}
        st.cursor = nil          -- the next entry starts on real focus, not a stale pick
        ctx.log("fan: left mode -- " .. ((not st.arranging)
            and (#members .. " labels cleared; nothing was moved, nothing restored")
            or skipRestore
            and (#members .. " windows left in place (screen gone)")
            or ("restored " .. restored .. " windows" ..
                (gone > 0 and (" (" .. gone .. " gone)") or ""))))
    end

    -- Display reconfig handler (the screenChanged watcher in enter). Match the
    -- mode's screen across the reconfig by NAME (the index can shuffle; name is the
    -- stable-ish key, same as Window Deck). GONE -> leave WITHOUT restore. Merely
    -- moved/resized -> re-anchor the widget and re-fan onto the new geometry (via
    -- refan, which also reconciles any window macOS relocated off this display).
    function st.onScreenChanged()
        if not st.active or not st.screen then return end
        local want = st.screen.name
        local cur
        for _, f in ipairs(ctx.screen.frames()) do
            if f.name == want then cur = f; break end
        end
        if not cur then
            ctx.log("fan: screenChanged -- screen '" .. tostring(want) ..
                "' gone, leaving (no restore)")
            st.leave(true)
            return
        end
        st.screen = cur
        if st.widget then
            st.widget.reanchor({ x = cur.x + st.widgetDx, y = cur.y + st.widgetDy }, cur)
        end
        -- Re-fan the KNOWN members onto the new geometry. Crucially do NOT re-derive
        -- membership by geometry (refan does, via fannable/onScreen): the members
        -- are still sitting in their OLD slabs, so on a SHRINK or an origin move their
        -- centres can fall OUTSIDE the new frame -- a geometry filter would then wrongly
        -- "reserve" them, stranding a window off the new screen with no border (the
        -- "stops working after a resolution change" bug that Deck's re-tile avoids).
        -- Re-list to resolve current ids; a member that CLOSED during the reconfig is
        -- pruned (its slot/color freed).
        local members, live = {}, {}
        for _, w in ipairs(ctx.window.list()) do
            if w.wid and st.borders[w.wid] then members[#members + 1] = w; live[w.wid] = true end
        end
        -- Absence is ambiguous here for the SAME reason it is in refan, and this path
        -- is the likelier one to hit it -- a display reconfig is exactly when apps
        -- reflow and their AX reads time out. So apply refan's rule in FULL, not half
        -- of it: ask the seam which apps went quiet, reserve everything for those, and
        -- for a genuine close recycle the slot but NEVER the captured original.
        local reconfigDropped = {}
        for _, id in ipairs(ctx.window.droppedApps()) do reconfigDropped[id] = true end
        for wid in pairs(st.borders) do
            if not live[wid] then
                st.borders[wid].o.stop(); st.borders[wid] = nil
                local owner = st.bundle[wid]
                if owner and reconfigDropped[owner] then
                    ctx.log("fan: screenChanged -- wid " .. wid .. " missing, app '" .. owner
                        .. "' did not answer AX; slot " .. (st.slot[wid] or "?")
                        .. " + original RESERVED (not treated as closed)")
                else
                    st.slot[wid], st.color[wid], st.side[wid] = nil, nil, nil
                    st.bundle[wid] = nil
                end
            end
        end
        if #members == 0 then
            st.order, st.frames, st.memberSig = {}, {}, ""
            updateWidget()
            ctx.log("fan: screenChanged -- no members left on '" .. tostring(cur.name) .. "'")
            return
        end
        -- CAPACITY, on the third path. A display that SHRANK may no longer hold the
        -- members honestly -- and this is the transition most likely to overflow,
        -- since nothing about it is under the user's control. Re-placing anyway would
        -- rebuild the exact buried-strip layout the entry gate exists to prevent, just
        -- reached by a different route. So apply the same answer: keep the promise for
        -- every member, or leave. Restore IS wanted here (unlike the screen-GONE case
        -- above, which skips it) -- the display still exists, so the captured
        -- originals are still meaningful frames on it.
        -- Gate on the FAN SIZE place() will actually use, not on the member count:
        -- reserved slots still consume geometry, so a fan with 3 visible members can
        -- still be laid out at N=6 and produce sub-minimum slabs. Comparing #members
        -- here let exactly that through.
        local shrunkCap = st.arranging
            and W.fanCapacity(cur, ctx.opt("edge") or 40, PAD) or math.huge
        local shrunkN = fanSizeN()
        if shrunkN > shrunkCap then
            ctx.log(string.format(
                "fan: screenChanged -- '%s' now fits only %d, but the fan is laid out"
                .. " at %d (%d members + reserved slots) -- leaving and restoring",
                tostring(cur.name), shrunkCap, shrunkN, #members))
            ctx.alert(ctx.t("fan.leftTooSmall",
                "Left Window Fan -- '%1$s' now fits only %2$d windows, and %3$d are fanned",
                tostring(cur.name), shrunkCap, shrunkN))
            st.leave()
            return
        end
        local fwid = ctx.window.focusedWid()
        local isMember = false
        for _, w in ipairs(members) do if w.wid == fwid then isMember = true; break end end
        if not isMember then fwid = members[1].wid end
        st.refanning = true
        place(members, cur, fwid, "screenChanged")   -- place logs the geometry
        st.refanning = false
    end

    function st.toggle()
        if st.active then st.leave() else st.enter() end
    end

    -- Move the keyboard selection `delta` places around the ring (wrapping), from
    -- wherever the highlight currently is. PREVIEW ONLY -- no raise, no focus (see
    -- the note on st.cursor); confirm is what commits. A no-op outside the mode:
    -- these are ordinary global hotkeys, so they fire whether or not the fan is up,
    -- and an alert on every stray press would be noise.
    ---@param delta integer
    function st.step(delta)
        if not st.active then return end
        local ring = orderedWids()
        if #ring == 0 then return end
        -- Where the highlight is NOW, if it is still in the ring at all. When it is
        -- not (the selected window closed, left the screen, or its app went quiet),
        -- step onto the ring's FIRST member rather than treating the miss as
        -- index 1 and stepping off it -- the latter silently skips ring[1].
        local cur, idx = selectedWid(), nil
        for i, wid in ipairs(ring) do
            if wid == cur then idx = i; break end
        end
        if idx then
            st.cursor = ring[((idx - 1 + delta) % #ring) + 1]
        else
            st.cursor = ring[1]
        end
        drawOcclusion()
        updateWidget()
        -- "position", not "slot": in label mode the index is a pure ring ordinal with
        -- no slab behind it, and the log is read as the record of what the mode decided.
        ctx.log("fan: cursor -> wid " .. st.cursor .. " (position "
            .. (st.slot[st.cursor] or "?") .. " of " .. #ring .. ")")
    end

    -- Commit the selection: leave the mode (restoring every window to its real
    -- geometry), THEN focus the picked one -- in that order, so the user lands on
    -- their window at its true size rather than on a slab. This is the switcher's
    -- payoff, and the one thing the toggle alone cannot do: the toggle exits
    -- leaving focus wherever it was.
    function st.confirm()
        if not st.active then return end
        local wid = selectedWid()
        ctx.log("fan: confirm -> wid " .. tostring(wid))
        st.leave()
        if not wid then return end
        for _, w in ipairs(ctx.window.list()) do
            if w.wid == wid then
                -- One window forward, after the layout is already restored: the
                -- sanctioned single-window z-order move.
                ctx.window.raise(w.id)
                ctx.window.focus(w.id)
                break
            end
        end
    end

    -- Called from stop(ctx) on disable: leave a live mode so disabling never
    -- strands the user's windows in the pile (and never leaks a border/observer).
    function st.forceExit()
        if st.active then st.leave() end
    end

    return st
end

---@param ctx Ctx
local function with(ctx) return ctx.perEnable(controllerFor) end

return {
    api = 1,
    id  = "window_fan",

    options = {
        -- The mode's SHAPE. Off = LABEL MODE: the borders, the widget list, the live
        -- tracking and the keyboard ring, with no window ever moved. It exists because
        -- the fan's arrangement is the expensive half and the identification is the
        -- half that demonstrably works -- and turning it off drops every constraint
        -- the arrangement imposes: no window limit (nothing has to fit a slab), no
        -- minimum-size problem, no restore, and no raise pass. Listed FIRST because
        -- it changes what the other options mean (`edge` is arrangement-only).
        { key = "arrange", type = "bool", default = true,
          label = "Rearrange windows into the fan",
          hint = "On: windows are moved into the edge-anchored fan, each keeping a guaranteed visible edge (limited by how many the screen can fit). Off: nothing is moved -- windows just get their live colored border and the switcher list, with no limit on how many. Applies the next time you enter the mode, not to a session already running." },
        { key = "edge", type = "int", default = 40, min = 24, max = 80,
          label = "Edge thickness",
          hint = "How deep each window's always-visible edge strip is, in points -- no other window can cover it, whatever is on top. Only applies when 'Rearrange windows into the fan' is on." },
        { key = "widget", type = "bool", default = true,
          label = "Show switcher widget",
          hint = "A small draggable card listing the windows -- click a row to switch, or Exit to leave the mode." },
    },

    -- Service: start builds the idle controller; stop leaves a live mode.
    ---@param ctx Ctx
    start = function(ctx) with(ctx) end,
    stop  = function(ctx) with(ctx).forceExit() end,

    actions = {
        {
            id = "arrange",
            -- "Toggle", like Window Deck's sole action: this row is also the
            -- menubar EXIT while the mode is live, so the label must not read
            -- as a one-way enter. (id stays "arrange" -- a stored trigger
            -- override is keyed by it.)
            label = "Toggle Window Fan",
            description = "Enter Window Fan mode: fan the focused screen's windows against the screen edges, each keeping a live colored border and a full always-visible edge no other window can cover. Windows that open or are dragged onto the screen are taken into the fan automatically. Press again to leave and restore the original layout.",
            defaultTrigger = { type = "hotkey", mods = HYPER, key = "f" },
            mnemonic = "Hyper+F -- F for Fan",
            ---@param ctx Ctx
            run = function(ctx) with(ctx).toggle() end,
        },
        -- KEYBOARD NAVIGATION -- MODE-SCOPED and UNBOUND BY DEFAULT.
        --
        -- Two deliberate absences, and they answer two different failures.
        --
        -- No `defaultTrigger`: nobody asked for these keys. Shipping them on
        -- Hyper+N / B / J spent three prime caps, around the clock, on a ring most
        -- users will never reach for -- and the mode is fully usable without them
        -- (the switcher widget lists every window; a click switches). An action
        -- with no default is dormant until the user binds one in Settings, which is
        -- exactly the right default for a capability rather than a headline.
        -- (`swap_screens` in window_snap is the same shape and says so too.)
        --
        -- `modeScoped`: these no-op outside a live fan, so the menubar and the
        -- command palette -- both "run this now" surfaces -- must not offer them.
        -- Three rows that silently do nothing is what the fan's submenu WAS, and it
        -- read as broken next to Window Deck's single row. modeScoped hides them
        -- there while keeping them in Settings, where binding them is the whole
        -- point. It is a property of the ACTION, not of its binding state: bound or
        -- not, clicking one from a menu can never work.
        --
        -- None is automatable -- they act on the live selection, which means
        -- nothing unattended.
        {
            id = "next",
            label = "Select next window in the fan",
            description = "Move the fan's selection one window forward (wrapping). Only the highlight moves -- the window is not focused until you confirm. Bind a shortcut to use it; the fan works without one.",
            modeScoped = true,
            ---@param ctx Ctx
            run = function(ctx) with(ctx).step(1) end,
        },
        {
            id = "prev",
            label = "Select previous window in the fan",
            description = "Move the fan's selection one window back (wrapping). Only the highlight moves -- the window is not focused until you confirm. Bind a shortcut to use it; the fan works without one.",
            modeScoped = true,
            ---@param ctx Ctx
            run = function(ctx) with(ctx).step(-1) end,
        },
        {
            id = "confirm",
            label = "Jump to the selected window",
            description = "Leave Window Fan, restore every window to its original position, and focus the selected one. This is the keyboard ring's payoff -- the plain toggle exits without changing focus.",
            modeScoped = true,
            ---@param ctx Ctx
            run = function(ctx) with(ctx).confirm() end,
        },
    },
}
