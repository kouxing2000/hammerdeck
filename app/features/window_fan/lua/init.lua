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
-- switcher-only cost; leaving restores the real layout). Deliberately ONE
-- action, like Window Deck: the toggle already exits from the menubar and the
-- hotkey, so a separate "restore" action only added a Settings editor and a
-- menubar row for a duplicate exit path (removed 2026-07-19).
--
-- WHY THE FAN. macOS won't let us reorder OTHER apps' windows (AXRaise is
-- top-only; some apps steal focus on raise), so we cannot "manage layers". The
-- fan sidesteps z-order entirely: each window's edge strip lives where NO other
-- window's RECTANGLE reaches, so it is visible under ANY stacking order -- no
-- reflow, no re-layer, and the user's own click (raise-to-top) never covers
-- another window's edge. (Proven in windows_geometry: strip-exclusivity.)
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
-- A LIGHT STATEFUL MODE via ctx.perEnable (deck's pattern): entering CAPTURES
-- each window's original frame; leaving restores every window (matched by stable
-- wid across the re-list). stop() leaves a live mode on disable. Every placement
-- rides ctx.window.setFrameFor, so Window Rewind also undoes a fan.
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
    local st = { active = false, slot = {}, color = {}, side = {}, originals = {},
                 borders = {}, order = {}, frames = {}, focusedWid = nil, screen = nil,
                 memberSig = nil, refanning = false, widget = nil, widgetOrder = {} }

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
                b.o.setStyle(wid == st.focusedWid and "focus" or "member")
                local fronts = {}                          -- EVERY window in front of it
                for j = 1, i - 1 do
                    local wf = st.frames[st.order[j]]
                    if wf then fronts[#fronts + 1] = wf end
                end
                local vis = W.rectMinus(f, fronts)         -- the still-visible pieces
                local visArea = 0
                for _, r in ipairs(vis) do visArea = visArea + r.w * r.h end
                if visArea >= f.w * f.h - 0.5 then          -- nothing actually covers it
                    b.o.setFilled(false)
                    b.o.clearClip()
                else
                    b.o.setFilled(wid ~= st.focusedWid)
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
        local wids = {}
        for wid in pairs(st.borders) do wids[#wids + 1] = wid end
        table.sort(wids, function(a, b) return (st.slot[a] or 0) < (st.slot[b] or 0) end)
        local rows = {}
        st.widgetOrder = {}
        for _, wid in ipairs(wids) do
            local m = meta[wid] or { title = "", bundleID = "" }
            st.widgetOrder[#st.widgetOrder + 1] = wid
            rows[#rows + 1] = {
                color = st.color[wid], side = st.side[wid] or "T",
                title = m.title, bundleID = m.bundleID,
                focused = wid == st.focusedWid,
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
        local N = 0
        for _, idx in pairs(st.slot) do if idx > N then N = idx end end
        if N < 1 then return end
        local slots = W.fanSlots(screen, N, ctx.opt("edge") or 40, PAD)

        -- Place each active window on its slot, give any un-bordered one its
        -- PERSISTENT colored border, and record its slot frame. The IMPOSED z-order
        -- (built below) is what the raise pass establishes -- reliable now, before
        -- the async AX frames settle.
        local bundleSet = {}
        for _, w in ipairs(wins) do
            local s = slots[st.slot[w.wid]]
            local frame = { x = s.x, y = s.y, w = s.w, h = s.h }
            if not st.borders[w.wid] then
                local color = st.color[w.wid]
                st.borders[w.wid] = { o = ctx.outline("member", color), color = color }
            end
            st.frames[w.wid] = frame
            st.side[w.wid] = s.side              -- the edge this window exposes (widget swatch)
            ctx.window.setFrameFor(w.id, frame)
            if w.bundleID and w.bundleID ~= "" then bundleSet[w.bundleID] = true end
        end

        -- One ordered raise pass, back-to-front (reversed MRU), so the pile's
        -- final z-order matches recency -- the window motion covers the churn.
        -- Then the focused window is lifted with a real focus (a surgical raise
        -- can't beat an app that activated itself when raised).
        for i = #wins, 1, -1 do ctx.window.raise(wins[i].id) end
        if focusWid and focusWid ~= 0 then
            for _, w in ipairs(wins) do
                if w.wid == focusWid then ctx.window.focus(w.id); break end
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
        -- them to go. Logs any gap (the alignment diagnostic).
        if st.settleTimer then st.settleTimer.stop() end
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

        st.screen = screen
        st.memberSig = sigOf(wins)

        -- Terse arrangement summary so a layout issue (a wasted edge, an off pile)
        -- is diagnosable from the log alone: the slots' bounding box vs the screen.
        local bx1, by1, bx2, by2 = math.huge, math.huge, -math.huge, -math.huge
        for _, s in ipairs(slots) do
            bx1 = math.min(bx1, s.x); by1 = math.min(by1, s.y)
            bx2 = math.max(bx2, s.x + s.w); by2 = math.max(by2, s.y + s.h)
        end
        ctx.log(string.format(
            "fan: %s fan -- %d active / %d slots on '%s', edge=%d, margins L=%.0f R=%.0f T=%.0f B=%.0f",
            reason, #wins, N, screen.name or "?", ctx.opt("edge") or 40,
            bx1 - screen.x, (screen.x + screen.w) - bx2, by1 - screen.y, (screen.y + screen.h) - by2))

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
        -- CLOSED members: free slot / color / side / original / border to the pool.
        for wid in pairs(st.slot) do
            if not exists[wid] then
                st.slot[wid], st.color[wid], st.side[wid], st.originals[wid] = nil, nil, nil, nil
                if st.borders[wid] then st.borders[wid].o.stop(); st.borders[wid] = nil end
                ctx.log("fan: window " .. wid .. " closed -- slot + color freed")
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
        -- NEWCOMERS: lowest FREE slot + color (reserved holes are held, never reused
        -- here), original captured NOW before we move it.
        for _, w in ipairs(active) do
            if not st.slot[w.wid] then
                st.slot[w.wid] = lowestFreeIndex()
                st.color[w.wid] = lowestFreeColor()
                st.originals[w.wid] = { x = w.x, y = w.y, w = w.w, h = w.h }
            end
        end
        if #active == 0 then                            -- screen emptied: nothing to fan
            for _, b in pairs(st.borders) do b.o.stop() end
            st.borders, st.order, st.frames, st.memberSig = {}, {}, {}, ""
            updateWidget()
            ctx.log("fan: no windows left on screen -- fan cleared (mode still on)")
            return
        end
        -- Keep whoever is focused frontmost if they're active; else the first active.
        local fwid = ctx.window.focusedWid()
        local isMember = false
        for _, w in ipairs(active) do if w.wid == fwid then isMember = true; break end end
        if not isMember then fwid = active[1].wid end
        st.refanning = true
        place(active, st.screen, fwid, "refanned")
        st.refanning = false
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
        if w ~= 0 then st.focusedWid = w end
        refreshFromList()          -- the switch changed the stacking order
        if currentSig() ~= st.memberSig then
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

        -- Fresh slot / color / original maps for this mode session. assignNearest
        -- gives each window the slot NEAREST its current position, so the first
        -- arrangement is the least jarring jump; colors are dealt lowest-free in
        -- window order. Refan keeps these fixed and only fills in newcomers.
        -- (Originals are captured by VALUE -- setFrameFor mutates the live rows.)
        st.slot, st.color, st.side, st.originals = {}, {}, {}, {}
        local slots = W.fanSlots(screen, #wins, ctx.opt("edge") or 40, PAD)
        local winCenters, slotCenters = {}, {}
        for i, w in ipairs(wins) do winCenters[i] = W.center(w) end
        for i, s in ipairs(slots) do slotCenters[i] = W.center(s) end
        local perm = W.assignNearest(winCenters, slotCenters)
        for i, w in ipairs(wins) do
            st.slot[w.wid] = perm[i]
            st.color[w.wid] = lowestFreeColor()
            st.originals[w.wid] = { x = w.x, y = w.y, w = w.w, h = w.h }
        end

        place(wins, screen, fwid, "entered")

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

        st.active = true
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
        st.slot, st.color, st.side, st.originals = {}, {}, {}, {}
        ctx.log("fan: left mode -- " .. (skipRestore
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
        for wid in pairs(st.borders) do
            if not live[wid] then
                st.borders[wid].o.stop(); st.borders[wid] = nil
                st.slot[wid], st.color[wid], st.side[wid], st.originals[wid] = nil, nil, nil, nil
            end
        end
        if #members == 0 then
            st.order, st.frames, st.memberSig = {}, {}, ""
            updateWidget()
            ctx.log("fan: screenChanged -- no members left on '" .. tostring(cur.name) .. "'")
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
        { key = "edge", type = "int", default = 40, min = 24, max = 80,
          label = "Edge thickness",
          hint = "How deep each window's always-visible edge strip is, in points -- no other window can cover it, whatever is on top." },
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
    },
}
