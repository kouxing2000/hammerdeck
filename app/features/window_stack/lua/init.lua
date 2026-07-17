-- features/window_stack
--
-- "Auto Stack": a persistent WINDOW-SWITCHER MODE. One trigger gathers every
-- window on the FOCUSED screen into a BORDER-ANCHORED SLAB FAN
-- (platform.windows.fanSlots): each window is a large slab flush against its own
-- segment of the screen's edge, so EVERY window keeps a full, always-visible,
-- grabbable edge strip in its own slice of the screen border. You STAY in the
-- mode: every window wears a live colored border, and clicking any window
-- switches to it. Press the toggle again -- or "Restore layout" (the menubar
-- exit) -- to leave the mode and put every window back where it was (slab shapes
-- are a switcher-only cost; leaving restores the real layout).
--
-- WHY THE FAN. macOS won't let us reorder OTHER apps' windows (AXRaise is
-- top-only; some apps steal focus on raise), so we cannot "manage layers". The
-- fan sidesteps z-order entirely: each window's edge strip lives where NO other
-- window's RECTANGLE reaches, so it is visible under ANY stacking order -- no
-- reflow, no re-layer, and the user's own click (raise-to-top) never covers
-- another window's edge. (Proven in windows_geometry: strip-exclusivity.)
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
-- primitives -- but none of its widget/scrim/hero/pick machinery: Auto Stack has
-- ONE state (in the mode), so a switcher panel would be redundant.
--
-- A LIGHT STATEFUL MODE via ctx.perEnable (deck's pattern): entering CAPTURES
-- each window's original frame; leaving restores every window (matched by stable
-- wid across the re-list). stop() leaves a live mode on disable. Every placement
-- rides ctx.window.setFrameFor, so Window Rewind also undoes a stack.
--
-- Needs Accessibility (window enumeration, by-id frame setting, the observers).

local W = require("platform.windows")

local NAME = "Auto Stack"
local HYPER = { "cmd", "alt", "ctrl" }

-- Gutter between the ring and the screen edge (px), the deck's visual rhythm.
local PAD = 8

-- Window Deck's member-ring palette (a feature cannot require another feature's
-- module, so the values are mirrored; drift is cosmetic only).
local PALETTE = {
    "#4C8DFF", "#34C759", "#FF9F0A", "#AF52DE", "#FF375F",
    "#5AC8FA", "#FFD60A", "#FF6482", "#30D158",
}

-- The screen to stack: the focused window's, else the mouse's (so the action
-- still resolves when focus is on the desktop). Returns a ctx.screen.frames()
-- row, or nil when no screens are reported.
---@param ctx table the curated feature ctx
---@return table|nil screen a screen row { x,y,w,h,name?,index? }
local function focusedScreen(ctx)
    local screens = ctx.screen.frames()
    if #screens == 0 then return nil end
    local f = ctx.window.frame()
    if f and f.screenIndex and screens[f.screenIndex] then
        return screens[f.screenIndex]
    end
    local m = ctx.mouse.position()
    return W.screenOfFrame(screens, { x = m.x, y = m.y, w = 0, h = 0 })
        or screens[1]
end

-- The per-enable controller: holds the live mode state (borders, tracking
-- subscriptions, captured originals) and the enter/leave lifecycle. Built once
-- per enable via ctx.perEnable, so every action fire and stop() reach the SAME
-- state.
---@param ctx table
local function controllerFor(ctx)
    -- borders: wid -> { o, color } (the stacked windows only). order: ALL on-screen
    -- wids front-to-back. frames: wid -> frame for every wid in `order`. active
    -- gates the toggle. Occlusion clips a border against EVERY window in front of
    -- it -- stacked or not -- so a window we didn't gather still clips it.
    local st = { active = false, originals = {}, borders = {},
                 order = {}, frames = {}, focusedWid = nil }

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
    -- another screen) loses its border here, so no ghost border lingers. New
    -- windows that appear are NOT auto-added to the stack -- they just float, and
    -- their frame clips the borders behind them like any other window in front.
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
                ctx.log("stack: window " .. wid .. " gone -- border dropped")
            end
        end
        st.order, st.frames = order, frames
    end

    -- Tear down every live-mode handle (borders + the two observers). Idempotent.
    local function teardown()
        if st.settleTimer then st.settleTimer.stop(); st.settleTimer = nil end
        if st.framesWatch then st.framesWatch.stop(); st.framesWatch = nil end
        if st.focusWatch then st.focusWatch.stop(); st.focusWatch = nil end
        for _, b in pairs(st.borders) do b.o.stop() end
        st.borders, st.order, st.frames = {}, {}, {}
    end

    -- The stackable windows on `screen`, MRU order (window_deck's predicate):
    -- sized, not minimized, not fullscreen. Membership is PURE GEOMETRY
    -- (W.onScreen: centre-in-rect) -- window frames and screen frames come from
    -- separate native calls whose tables are never the same object, so an
    -- identity compare would silently match nothing in the real host.
    local function stackable(screen)
        local out = {}
        for _, w in ipairs(ctx.window.list()) do
            local sized = w.w and w.h and w.w > 0 and w.h > 0
            if sized and not w.minimized and not w.fullscreen
                and W.onScreen(w, screen) then
                out[#out + 1] = w
            end
        end
        return out
    end

    function st.enter()
        if not ctx.axTrusted() then
            ctx.axPrompt()
            ctx.alert(ctx.t("stack.axRequired",
                "%1$s needs the Accessibility permission -- grant %2$s in System Settings, then try again",
                NAME, ctx.appName))
            return
        end
        local screen = focusedScreen(ctx)
        if not screen then return end

        -- Read focus BEFORE anything moves: a self-activating app fronting itself
        -- mid-pass must not change who we hand focus back to.
        local fwid = ctx.window.focusedWid()
        local wins = stackable(screen)
        if #wins == 0 then
            ctx.alert(ctx.t("stack.none", "No windows to stack on this screen"))
            return
        end

        -- Capture originals by VALUE (setFrameFor mutates the live rows), keyed
        -- by stable wid so leaving can re-find each window after a re-list.
        st.originals = {}
        for _, w in ipairs(wins) do
            st.originals[#st.originals + 1] =
                { wid = w.wid, x = w.x, y = w.y, w = w.w, h = w.h }
        end

        local slots = W.fanSlots(screen, #wins, ctx.opt("edge") or 40, PAD)
        local winCenters, slotCenters = {}, {}
        for i, w in ipairs(wins) do winCenters[i] = W.center(w) end
        for i, s in ipairs(slots) do slotCenters[i] = W.center(s) end
        local perm = W.assignNearest(winCenters, slotCenters)

        -- Place each window, give it a PERSISTENT colored border, and record its
        -- slot frame. The IMPOSED z-order (built below) is what the raise pass
        -- establishes -- reliable now, before the async AX frames settle enough to
        -- re-list.
        local bundleSet = {}
        for i, w in ipairs(wins) do
            local s = slots[perm[i]]
            local frame = { x = s.x, y = s.y, w = s.w, h = s.h }
            local color = PALETTE[(i - 1) % #PALETTE + 1]
            st.borders[w.wid] = { o = ctx.outline("member", color), color = color }
            st.frames[w.wid] = frame
            ctx.window.setFrameFor(w.id, frame)
            if w.bundleID and w.bundleID ~= "" then bundleSet[w.bundleID] = true end
        end

        -- One ordered raise pass, back-to-front (reversed MRU), so the pile's
        -- final z-order matches recency -- the window motion covers the churn.
        -- Then the focused window is lifted with a real focus (a surgical raise
        -- can't beat an app that activated itself when raised).
        for i = #wins, 1, -1 do ctx.window.raise(wins[i].id) end
        if fwid and fwid ~= 0 then
            for _, w in ipairs(wins) do
                if w.wid == fwid then ctx.window.focus(w.id); break end
            end
        end

        -- The z-order we just imposed: focused window frontmost, then the rest in
        -- MRU order (st.frames already holds each slot). drawOcclusion clips each
        -- border against those in front. These are the INTENDED slot frames; the
        -- delayed refresh below swaps in the ACTUAL frames once AX has applied them.
        st.focusedWid = fwid
        st.order = {}
        if st.borders[fwid] then st.order[1] = fwid end
        for _, w in ipairs(wins) do
            if w.wid ~= fwid then st.order[#st.order + 1] = w.wid end
        end
        drawOcclusion()

        -- AX applies setFrameFor ASYNCHRONOUSLY, and a window may not land exactly
        -- on its slot (min-size, clamping). Re-read the REAL frames + z-order once
        -- things settle so the borders sit on the windows, not on where we asked
        -- them to go. Logs any gap (the alignment diagnostic).
        st.settleTimer = ctx.afterSeconds(0.3, function()
            if not st.active then return end
            local intended = st.frames
            refreshFromList()
            for wid in pairs(st.borders) do
                local s, a = intended[wid], st.frames[wid]
                if s and a and (math.abs(s.x - a.x) > 2 or math.abs(s.y - a.y) > 2
                    or math.abs(s.w - a.w) > 2 or math.abs(s.h - a.h) > 2) then
                    ctx.log(string.format(
                        "stack: wid %d slot=%.0f,%.0f,%.0fx%.0f actual=%.0f,%.0f,%.0fx%.0f (border realigned)",
                        wid, s.x, s.y, s.w, s.h, a.x, a.y, a.w, a.h))
                end
            end
            drawOcclusion()
        end)

        -- Keep the borders honest: a focus/click change re-reads the real z-order
        -- (the OS raised the clicked window) and prunes gone windows; a drag/resize
        -- updates that window's frame. Both re-run occlusion. They fire for the
        -- mode's life; teardown() stops them.
        local bundleIds = {}
        for id in pairs(bundleSet) do bundleIds[#bundleIds + 1] = id end
        st.framesWatch = ctx.window.onFramesChanged(bundleIds, function(info)
            if not st.active then return end
            if info.wid and st.borders[info.wid] then
                st.frames[info.wid] = { x = info.x, y = info.y, w = info.w, h = info.h }
                drawOcclusion()
            end
        end)
        st.focusWatch = ctx.window.onFocusChanged(function()
            if not st.active then return end
            st.focusedWid = ctx.window.focusedWid()
            refreshFromList()          -- the click changed the stacking order
            drawOcclusion()
        end)

        st.active = true
        -- Terse arrangement summary so a layout issue (a wasted edge, an off pile)
        -- is diagnosable from the log alone: the slots' bounding box vs the screen.
        local bx1, by1, bx2, by2 = math.huge, math.huge, -math.huge, -math.huge
        for _, s in ipairs(slots) do
            bx1 = math.min(bx1, s.x); by1 = math.min(by1, s.y)
            bx2 = math.max(bx2, s.x + s.w); by2 = math.max(by2, s.y + s.h)
        end
        ctx.log(string.format(
            "stack: entered fan -- %d windows on '%s', edge=%d, margins L=%.0f R=%.0f T=%.0f B=%.0f",
            #wins, screen.name or "?", ctx.opt("edge") or 40,
            bx1 - screen.x, (screen.x + screen.w) - bx2, by1 - screen.y, (screen.y + screen.h) - by2))
    end

    -- Leave the mode: tear down borders + observers, then put every captured
    -- window back where it was. Re-list ONCE (ids churn) and match by stable wid;
    -- a window that has since closed is simply skipped.
    function st.leave()
        if not st.active then
            ctx.alert(ctx.t("stack.nothing", "No stack to restore"))
            return
        end
        teardown()
        local byWid = {}
        for _, w in ipairs(ctx.window.list()) do
            if w.wid and w.wid ~= 0 then byWid[w.wid] = w.id end
        end
        local restored, gone = 0, 0
        for _, o in ipairs(st.originals) do
            local id = o.wid and byWid[o.wid]
            if id then
                ctx.window.setFrameFor(id, { x = o.x, y = o.y, w = o.w, h = o.h })
                restored = restored + 1
            else
                gone = gone + 1
            end
        end
        st.active = false
        st.originals = {}
        ctx.log("stack: left mode -- restored " .. restored .. " windows" ..
            (gone > 0 and (" (" .. gone .. " gone)") or ""))
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

local function with(ctx) return ctx.perEnable(controllerFor) end

return {
    api = 1,
    id  = "window_stack",

    options = {
        { key = "edge", type = "int", default = 40, min = 24, max = 80,
          label = "Edge thickness",
          hint = "How deep each window's always-visible edge strip is, in points -- no other window can cover it, whatever is on top." },
    },

    -- Service: start builds the idle controller; stop leaves a live mode.
    start = function(ctx) with(ctx) end,
    stop  = function(ctx) with(ctx).forceExit() end,

    actions = {
        {
            id = "arrange",
            label = "Stack arrange",
            description = "Enter Auto Stack mode: fan the focused screen's windows against the screen edges, each keeping a live colored border and a full always-visible edge no other window can cover. Press again to leave and restore the original layout.",
            defaultTrigger = { type = "hotkey", mods = HYPER, key = "s" },
            mnemonic = "Hyper+S -- S for Stack",
            run = function(ctx) with(ctx).toggle() end,
        },
        {
            id = "restore",
            label = "Restore layout",
            description = "Leave Auto Stack mode and put every window back where it was.",
            run = function(ctx) with(ctx).leave() end,
        },
    },
}
