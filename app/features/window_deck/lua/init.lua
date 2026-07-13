-- features/window_deck
--
-- "Window Deck": lay a screen's windows out as a uniform GRID (overview), then
-- focus any one and it lifts to a large centered HERO (detail) with the others
-- peeking behind in their grid slots. Focus another group window -> it swaps in
-- as a TWO-STEP BEAT with RING FLIGHTS (real windows can't tween, but the
-- border overlays are our own windows and animate smoothly): step 1, the old
-- hero steps home -- its ring flies back to its slot; step 2, once that lands,
-- the incoming window's colored ring flies from its slot to the hero rect. The
-- steps are SEQUENCED (demotion reads first, then promotion), and each window's
-- AX move is dispatched at its OWN flight's start, not landing: AX applies a
-- frame asynchronously (~50-200ms), so the flight is the cover that hides that
-- latency -- the window is in place when its ring lands, never a ring waiting
-- alone at the destination. ⌥Esc reverses it (ring and window travel home
-- together); ⌥Esc again (or the toggle hotkey) exits and restores the original
-- layout. Focus IS the promotion signal, so no bespoke keymap -- cmd+tab
-- (cross-app) and cmd+` (within-app) both promote, reaching even a
-- fully-covered 3x3 center tile.
--
-- Entering runs a PICK FLOW first (v1.1): on a multi-monitor setup, choose a
-- screen (ctx.askChoice), then a multi-select of that screen's windows
-- (ctx.askWindows -- all pre-checked, uncheck to leave one out), then commit to
-- the grid. Exiting stays instant (no picker on the way out).
--
-- A FRESH pick records its membership as the "last deck" (store.saveLastDeck --
-- {bundleID, title, wid} per window + the screen name). When one is available,
-- the multi-monitor screen-selector offers a "restore last deck" row LAST (a
-- deliberate pick -- Enter still defaults to a fresh deck on the current screen);
-- choosing it rebuilds the deck with no window multi-select. Restore is SMART
-- about availability: it re-matches the saved members against the live windows
-- (identity.matchMembers -- wid within a session, title across an app restart),
-- restores around any that are now closed (as long as >= 2 survive, labelled
-- "N of M available"), and does NOT rewrite the template, so it survives a lean
-- session intact. Single-monitor keeps its one-tap fast path (no selector step),
-- so restore rides the selector rather than forcing a chooser onto it.
--
-- The deck stays ABOVE non-deck windows on the screen: it is raised on enter,
-- and after a "peek" (focusing a non-deck window) the reclean that sinks the
-- peeked window runs DEFERRED, at the next beat (a promote or an ⌥Esc drop),
-- whose ring flights + window motion cover the raise churn. The bare return to
-- the hero raises NOTHING: the user's own click/cmd-tab already fronted the
-- hero, and any AXRaise to an app that activates-on-raise (VSCode, Chrome) can
-- front a member over the hero for a beat -- the "return blink". Until that
-- next beat the ex-peek may overlap the member margins -- the same visual
-- state as during the peek itself, just a little longer. When the reclean does
-- run, raiseDeck raises the non-hero members with ctx.window.raise (surgical
-- AXRaise) then lifts the HERO on top with ctx.window.focus (a real activation
-- -- a surgical raise can't beat an app that activated itself when raised),
-- gated on the hero actually holding focus; a settle guard absorbs the
-- raise/activation echoes so they never re-enter reconcile and make the hero
-- and a peek fight for front. Focus is the only "tell".
--
-- A SERVICE (start builds the idle controller; stop restores if the deck is live
-- on disable) with one rebindable action (the toggle). Reuses the pure tiling
-- math in platform.windows (gridDims / tileSlots / assignNearest / centeredRect
-- -- the "grid Phase 2" this feature drives) and rides the new focus observer
-- (ctx.window.onFocusChanged) + the existing app-activation watcher.
--
-- Needs Accessibility (window enumeration + by-id frame setting + the observer).
-- Window ROW ids churn on every list(), so the deck re-lists right before
-- every by-id placement batch; long-lived member identity rides the ladder in
-- keyOf: the OS-stable CGWindowID first (survives retitles), bundleID+title
-- as the fallback tier (healed by resolveIds' adoption when a title churns).

local W        = require("platform.windows")
local identity = require("features.window_deck.identity")
local colors   = require("features.window_deck.colors")
local store    = require("features.window_deck.store")
local focus    = require("features.window_deck.focus")

local HYPER = { "cmd", "alt", "ctrl" }

-- Window identity keys + frame-proximity geometry (widKey/titleKey/keyOf ladder,
-- onScreen/atFrame/frameFar) are a pure leaf in identity.lua; the border palette
-- + positional dealing are a pure leaf in colors.lua. Aliased here so the
-- controller body below reads unchanged.
local widKey, titleKey, keyOf = identity.widKey, identity.titleKey, identity.keyOf
local onScreen, atFrame, frameFar = identity.onScreen, identity.atFrame, identity.frameFar
local PALETTE = colors.PALETTE

-- Ring-flight duration (seconds): how long a border ring flies between a grid
-- slot and the hero rect. The real window's AX move is dispatched at flight
-- START and applies asynchronously underneath, so this doubles as the cover
-- time hiding that latency -- the window should be in place by ring landing.
-- (A hero swap plays TWO flights back to back -- home, then out -- so it
-- takes ~2x this.)
local FLIGHT = 0.15

-- One controller per enablement (ctx changes on re-enable). Holds the live deck
-- session; nil/inactive between decks.
local function controllerFor(ctx)
    local st = { active = false, picking = false, settling = false, peeked = false }

    -- The INDEX of the screen to deck by default: the focused window's, else the
    -- one under the cursor. (An index, not the screen table -- ctx.window.frame()
    -- .screen and ctx.screen.frames() rows are different objects, so identity
    -- comparison is wrong; screens are matched by their stable `index`.)
    local function activeScreenIndex()
        local f = ctx.window.frame()
        if f and f.screenIndex then return f.screenIndex end
        local m = ctx.mouse.position()
        local s = W.screenOfFrame(ctx.screen.frames(), { x = m.x, y = m.y, w = 0, h = 0 })
        return s and s.index or nil
    end

    -- The deckable windows on `screen`, MRU order: visible, sized, not
    -- fullscreen. Capped at `limit` (default 9 -- the deck size cap for the
    -- PICK path). Restore matching passes a bigger limit: the saved template is
    -- already <= 9, but its members may sit PAST the top-9 in MRU order among
    -- many open windows, and truncating the candidate set there would report an
    -- open member as "missing". A single list() call -- its ids stay valid for
    -- the immediately-following placement batch (no intervening list()).
    local function groupWindows(screen, limit)
        limit = limit or 9
        local out = {}
        for _, w in ipairs(ctx.window.list()) do
            local sized = w.w and w.h and w.w > 0 and w.h > 0
            if sized and not w.minimized and not w.fullscreen
                and onScreen(w, screen) then
                out[#out + 1] = w
                if #out >= limit then break end
            end
        end
        return out
    end

    local function memberByKey(key)
        for _, m in ipairs(st.group) do
            if m.key == key then return m end
        end
        return nil
    end

    local function heroFrame()
        return W.centeredRect(st.screen, ctx.opt("heroPercent") / 100)
    end

    -- key -> current id from a fresh list (row ids churn on every list()),
    -- with IDENTITY ADOPTION for the FALLBACK tier. Wid-keyed members (the
    -- common case) survive retitles by construction; but a member keyed by
    -- bundleID+title (wid unresolvable), or one whose wid resolution flips
    -- between lists, can vanish from the key space even though its window is
    -- still open -- historically that stranded the old hero at the hero rect
    -- and broke restore-on-exit. So each resolve re-binds a vanished member
    -- to its app's unclaimed window still sitting at the member's last-known
    -- frame (m.cur), carrying the border and all keyed state over to the new
    -- key. A truly closed window has no such twin and stays gone.
    local function resolveIds()
        local list = ctx.window.list()
        local ids = {}
        for _, w in ipairs(list) do ids[keyOf(w)] = w.id end
        if not st.group then return ids end
        local claimed = {}
        for _, m in ipairs(st.group) do claimed[m.key] = true end
        for _, m in ipairs(st.group) do
            if not ids[m.key] then
                local pick
                for _, w in ipairs(list) do
                    if (w.bundleID or "") == (m.bundleID or "")
                        and not claimed[keyOf(w)] and atFrame(w, m.cur) then
                        pick = w
                        break
                    end
                end
                if pick then
                    local old, new = m.key, keyOf(pick)
                    ctx.log("adopt retitle:", m.appName or "?", "->", pick.title or "?")
                    m.key, m.title = new, pick.title
                    claimed[new] = true
                    if st.borders and st.borders[old] then
                        st.borders[new], st.borders[old] = st.borders[old], nil
                    end
                    if st.heroKey == old then st.heroKey = new end
                    if st.pendingSnapKey == old then st.pendingSnapKey = new end
                    if st.echo and st.echo[old] then
                        st.echo[new], st.echo[old] = st.echo[old], nil
                    end
                    if st.stable and st.stable[old] then
                        st.stable[new], st.stable[old] = st.stable[old], nil
                    end
                end
            end
        end
        return ids
    end

    -- Echo guard for OUR OWN AX moves: the frame watcher (onMemberFrameEvent)
    -- hears them too and must not mistake them for the user dragging. Every
    -- move we dispatch arms a per-window timer; a frame event under an armed
    -- timer is treated as an echo ONLY if it reports (about) the frame we
    -- dispatched -- a diverging frame is the USER grabbing the window inside
    -- the guard window (promote-then-drag), which must still be detected.
    -- Generous duration -- an app applies + echoes the async move over a few
    -- hundred ms.
    local ECHO_SECS = 1.0
    local function markOurMove(key)
        if not st.echo then return end
        if st.echo[key] then st.echo[key].stop() end
        st.echo[key] = ctx.afterSeconds(ECHO_SECS, function()
            if st.echo and st.echo[key] then st.echo[key].stop(); st.echo[key] = nil end
        end)
    end

    -- Every window move WE initiate goes through here: records the expected
    -- frame (m.cur -- renderBorders rings the last-known truth, so a border
    -- never snaps back to a stale slot) and arms the echo guard, then
    -- dispatches the async AX move.
    local function moveWin(id, m, frame)
        m.cur = frame
        markOurMove(m.key)
        ctx.window.setFrameFor(id, frame)
    end

    -- Deck persistence (per-app colors, widget position, hero-mode) lives in
    -- store.lua as a ctx-scoped factory; alias its surface so the body below
    -- reads unchanged. Preview colors for the pick list come from the pure
    -- colors.assign (stored map passed in).
    local persist = store.new(ctx)
    local readColors, saveColors = persist.readColors, persist.saveColors
    local readWidgetPos, saveWidgetPos = persist.readWidgetPos, persist.saveWidgetPos
    local readHeroMode, saveHeroMode = persist.readHeroMode, persist.saveHeroMode
    local readLastDeck, saveLastDeck = persist.readLastDeck, persist.saveLastDeck

    -- The ONLY two mutators of the (mode, heroKey) pair -- the machine's core
    -- state. The invariant "heroKey == nil  <=>  mode == 'grid'" is enforced by
    -- routing every hero transition through here, each logged with its cause, so
    -- the whole mode life is greppable to two functions instead of ~5 inline
    -- assignments. (resolveIds' retitle ADOPTION re-keys the SAME hero in place,
    -- not a transition, so it stays a direct st.heroKey rewrite there.)
    local function setHero(key)
        st.mode, st.heroKey = "focus", key
        ctx.log("deck hero ->", key)
    end
    local function dropToGrid(reason)
        -- Log the DEPARTING key + cause (the audit rule wants the decision + the
        -- key identity), captured before the clear below.
        if st.heroKey then ctx.log("deck hero", st.heroKey, "-> grid (" .. (reason or "?") .. ")") end
        st.mode, st.heroKey = "grid", nil
    end

    -- The rects the container scrim punches holes for = every present member at
    -- its last-known frame (the hero at the hero frame). Same rects the rings
    -- bound, so the bright cutouts track the windows. Includes members hidden
    -- mid-drag (st.stable) at their last frame -- a hole is just a reveal, it
    -- has no ring to trail the drag.
    local function deckHoles()
        local holes = {}
        for _, m in ipairs(st.group or {}) do
            if not m.gone then
                local f = m.cur
                    or (m.key == st.heroKey and heroFrame() or m.slot)
                if f then holes[#holes + 1] = { x = f.x, y = f.y, w = f.w, h = f.h } end
            end
        end
        return holes
    end
    local function syncScrim()
        if st.scrim then st.scrim.setHoles(deckHoles()) end
    end

    -- The mini-map cell (1-based) currently the hero, or 0 in the flat grid.
    local function heroCellIndex()
        if not st.heroKey or not st.widgetOrder then return 0 end
        for i, key in ipairs(st.widgetOrder) do
            if key == st.heroKey then return i end
        end
        return 0
    end

    -- Is any deck window off its home frame (its slot, or the hero frame for the
    -- hero)? Drives the widget's Rearrange button -- enabled only when re-tiling
    -- would actually move something. m.cur is our last dispatched target for our
    -- own moves and the reported frame after a USER drag, so a drag makes it far
    -- (frameFar's >6px threshold lives in identity.lua).
    local function isDirty()
        for _, m in ipairs(st.group or {}) do
            if not m.gone and m.cur then
                local target = (m.key == st.heroKey) and heroFrame() or m.slot
                if frameFar(m.cur, target) then return true end
            end
        end
        return false
    end

    -- Promote the window in mini-map cell `i` (1-based) to hero -- or, if it is
    -- already the hero, drop back to the grid. Shared by the widget's mini-map
    -- clicks and the ⌥1-9 hotkeys. In Hero-off mode reconcile won't promote, so
    -- a focus here just brings the window forward (a plain focus launcher).
    local function switchToCell(i)
        if not st.active then return end
        local key = st.widgetOrder and st.widgetOrder[i]
        if not key then return end
        if key == st.heroKey then
            ctx.log("deck switch: cell", i, "(hero) -> drop to grid")
            st.dropHero()
        else
            local ids = resolveIds()
            if ids[key] then
                ctx.log("deck switch: cell", i, "-> focus", key)
                ctx.window.focus(ids[key])
            end
        end
    end

    -- The mini-map hint, worded for the current mode (in Hero-off mode a cell
    -- click just focuses, so "make it the hero" would mislead).
    local function switchHintFor()
        if st.heroMode then
            return ctx.t("deck.switchHint", "click or ⌥1-9 to set the hero")
        end
        return ctx.t("deck.switchHintGrid", "click or ⌥1-9 to focus")
    end

    local renderBorders   -- forward: defined below (swapCells re-renders after a swap)
    local focusedMember   -- forward: defined below (renderBorders bolds the focused member; raiseDeck gates on it)

    -- (Re)build the mini-map cell order from the current slot layout: cell i
    -- (row-major reading order) -> the window now in that slot, and its color.
    -- Run at enter and after a drag-swap so the mini-map stays spatially true.
    local function rebuildWidgetOrder(grp)
        grp = grp or st.group or {}
        local ordered = {}
        for _, m in ipairs(grp) do ordered[#ordered + 1] = m end
        table.sort(ordered, function(a, b)
            local ay, by = math.floor((a.slot.y or 0) / 10), math.floor((b.slot.y or 0) / 10)
            if ay ~= by then return ay < by end
            return (a.slot.x or 0) < (b.slot.x or 0)
        end)
        st.widgetOrder, st.widgetColors = {}, {}
        for i, m in ipairs(ordered) do
            st.widgetOrder[i], st.widgetColors[i] = m.key, m.color
        end
    end

    -- Drag one mini-map cell onto another (in the widget) to SWAP the two
    -- windows' slots. `from`/`to` are 1-based cell indices. Swaps the slot
    -- assignments and moves each window to its new slot -- EXCEPT a window that
    -- is the current hero (it stays centred; only its drop-back home slot
    -- changes, which the ghost then reflects). Re-colors the mini-map to match.
    local function swapCells(from, to)
        if not st.active or from == to then return end
        local kf = st.widgetOrder and st.widgetOrder[from]
        local kt = st.widgetOrder and st.widgetOrder[to]
        if not kf or not kt then return end
        local mf, mt = memberByKey(kf), memberByKey(kt)
        if not mf or not mt then return end
        mf.slot, mt.slot = mt.slot, mf.slot
        local ids = resolveIds()
        for _, m in ipairs({ mf, mt }) do
            if m.key ~= st.heroKey and ids[m.key] then moveWin(ids[m.key], m, m.slot) end
        end
        ctx.log("mini-map reorder: cell", from, "<-> cell", to)
        rebuildWidgetOrder()
        if st.widget then
            st.widget.setCells(st.widgetColors)
            st.widget.setHero(heroCellIndex())
        end
        renderBorders()
    end

    -- Border overlays (click-through). Every deck member gets a subtle "member"
    -- border at its current frame so you can see which windows are in the deck; the
    -- hero's border is re-styled "hero" (strong) and moved to the hero frame; and a
    -- faint dashed "ghost" marks the hero's home SLOT (where it drops back to).
    -- Persistent per member -- re-styled/moved on each transition, not recreated,
    -- so nothing flickers. renderBorders() syncs them to the current state.
    function renderBorders()   -- (forward-declared above)
        if not st.active then return end
        st.borders = st.borders or {}
        -- Rings are placed at each window's LAST-KNOWN frame (m.cur -- kept by
        -- moveWin for our moves and by the frame watcher for the user's), so a
        -- render never snaps a ring back onto a stale slot. Slot/heroFrame are
        -- the fallbacks for a member that has never moved.
        -- In FOCUS the hero's frame is a HOLE clipped out of every other
        -- border: the overlays float above all normal windows, so a member
        -- border whose region runs under the hero would otherwise draw its
        -- lines across the hero.
        local hero = st.heroKey and memberByKey(st.heroKey) or nil
        local hole = hero and (hero.cur or heroFrame()) or nil
        -- In HERO-OFF grid mode (a pure tiler, with no hero to signal the active
        -- window), the member holding focus gets a BOLDER ring so you can see which
        -- tiled window is focused as you cmd-tab / click around. In hero mode the
        -- hero already signals focus, so this stays off (and never fights it).
        local focusKey = nil
        if not st.heroMode then
            local _, fk = focusedMember()
            focusKey = fk
        end
        for _, m in ipairs(st.group) do
            if m.gone then
                if st.borders[m.key] then st.borders[m.key].stop(); st.borders[m.key] = nil end
            elseif st.stable and st.stable[m.key] then
                -- mid-motion (hide-until-stable, see onMemberFrameEvent): a
                -- setFrame here would re-show the hidden ring at a lagging
                -- frame -- leave it alone; the stable timer's own render
                -- re-places it once the window settles
            else
                local b = st.borders[m.key]
                if not b then b = ctx.outline("member", m.color); st.borders[m.key] = b end
                if m.key == st.heroKey then
                    b.setStyle("hero"); b.setHole(nil); b.setFrame(m.cur or heroFrame())
                elseif m.key == focusKey then
                    b.setStyle("focus"); b.setHole(hole); b.setFrame(m.cur or m.slot)
                else
                    b.setStyle("member"); b.setHole(hole); b.setFrame(m.cur or m.slot)
                end
            end
        end
        -- ghost at the hero's home slot (FOCUS only), in the hero's own color;
        -- clipped by the hero too (in a 3x3 the home slot sits under it)
        if hero then
            if not st.ghost then st.ghost = ctx.outline("ghost", hero.color) end
            st.ghost.setColor(hero.color)
            st.ghost.setHole(hole)
            st.ghost.setFrame(hero.slot)
        elseif st.ghost then
            st.ghost.stop(); st.ghost = nil
        end
        syncScrim()   -- keep the container holes on the same frames the rings bound
        if st.widget then
            st.widget.setHero(heroCellIndex())   -- light the hero's cell
            st.widget.setDirty(isDirty())        -- enable Rearrange only when off-grid
        end
    end

    -- Hide / show all deck chrome (rings + ghost + container scrim) as a unit.
    -- The chrome belongs to the deck's FRONT context: when a non-deck window is
    -- focused (a peek) it must not float over that window (rings sit above normal
    -- windows; the scrim would dim it), so hide it; returning to a deck window
    -- re-shows it. Showing is pure OVERLAY ordering -- it never raises an app
    -- window, so it cannot reintroduce the return blink (see recleanIfPeeked).
    local function hideChrome()
        for _, b in pairs(st.borders or {}) do b.hide() end
        if st.ghost then st.ghost.hide() end
        if st.scrim then st.scrim.hide() end
        if st.widget then st.widget.hide() end
    end
    local function showChrome()
        if st.scrim then st.scrim.show() end
        if st.widget then st.widget.show() end
        renderBorders()   -- re-places (re-shows) every ring + ghost, re-syncs holes
    end

    -- Cancel any in-flight beat. A promote flight dispatches its window toward
    -- the hero rect at flight START; if the beat is cancelled mid-air (a newer
    -- promotion, an exit), that window must not stay stranded at centre -- step
    -- it back to its slot NOW. (`pendingHome` holds that member. A drop flight
    -- needs no such fixup: its window is already travelling home, exactly where
    -- grid mode wants it.)
    local function settlePending()
        if st.pendingSnap then
            st.pendingSnap.stop()
            st.pendingSnap, st.pendingSnapKey = nil, nil
        end
        if st.pendingHome then
            local m = st.pendingHome
            st.pendingHome = nil
            local ids = resolveIds()
            if ids[m.key] then moveWin(ids[m.key], m, m.slot) end
        end
    end

    -- Tear down every border overlay (exit path).
    local function clearBorders()
        if st.borders then
            for _, b in pairs(st.borders) do b.stop() end
            st.borders = nil
        end
        if st.ghost then st.ghost.stop(); st.ghost = nil end
    end

    -- Keep the deck ABOVE non-deck windows: raise every present non-hero member
    -- with a surgical raise (doesn't drag same-app siblings, so no spurious
    -- promotion), THEN lift the HERO on top LAST. Non-deck windows sink behind;
    -- a deliberately-focused non-deck window (a "peek") is left alone and stays
    -- on top only while it holds focus. Called on enter and from beat landings
    -- (via recleanIfPeeked) -- NEVER from the bare return-to-hero, which must
    -- not raise (see recleanIfPeeked). Re-listed because ids churn every list().
    --
    -- The hero's final lift is a real FOCUS (ctx.window.focus -- SLPS
    -- activation), NOT another surgical raise. A surgical raise can't beat the
    -- currently-active window, and some apps (VSCode, Chrome) ACTIVATE the
    -- window they are asked to raise -- so a member's raise can front its app,
    -- and the hero's surgical reclaim would then be unable to get back on top:
    -- the hero sat stranded behind a member (an async activation race, so
    -- "sometimes"), and on a peek-return the members flashed in front before the
    -- hero clawed back (the blink). Focusing the hero beats any such member
    -- activation, so the hero deterministically ends on top; beginSettle() at
    -- the call sites absorbs the focus/activation echoes so they never re-enter
    -- reconcile and fight for front.
    --
    -- The focus is GATED on the hero actually holding focus as the pass starts
    -- (captured BEFORE the member raises -- an activating member may have
    -- stolen frontmost mid-pass, which is exactly the race being beaten). The
    -- one path where the hero is NOT focused here: the user peeked a non-deck
    -- window DURING a promote flight, so landHero's reclean runs with the peek
    -- holding focus -- a real focus would yank it away, breaking the "a peek
    -- stays on top while it holds focus" contract. There the hero falls back
    -- to the surgical raise (above the members; the active peek stays in
    -- front, sunk on the next return like any peek).
    local function raiseDeck()
        if not st.active then return end
        local ids = resolveIds()
        local f = focusedMember()   -- read BEFORE the raises below can front an app
        for _, m in ipairs(st.group) do
            if m.key ~= st.heroKey and not m.gone and ids[m.key] then
                ctx.window.raise(ids[m.key])
            end
        end
        if st.heroKey and ids[st.heroKey] then
            if f and f.key == st.heroKey then
                ctx.window.focus(ids[st.heroKey])
            else
                ctx.window.raise(ids[st.heroKey])
            end
        end
    end

    -- Our own window moves (raise/resize) emit focus/activation notifications a
    -- beat LATER; without a guard those echoes re-enter reconcile and the hero and
    -- a peek fight for front (a blink). beginSettle() makes reconcile ignore events
    -- for a short window after we mutate, so only REAL user focus changes (which
    -- arrive after it clears) drive the deck. The timer stops itself so it never
    -- lingers as a live handle.
    local function beginSettle()
        st.settling = true
        if st.settleTimer then st.settleTimer.stop() end
        st.settleTimer = ctx.afterSeconds(0.3, function()
            st.settling = false
            if st.settleTimer then st.settleTimer.stop(); st.settleTimer = nil end
        end)
    end

    -- Sink an ex-peek behind the deck -- called ONLY from beat landings
    -- (landHero / dropHero), where ring flights + window motion cover the raise
    -- churn. NEVER from the bare return-to-hero: an AXRaise to an app that
    -- activates-on-raise fronts that member over the hero for a beat (the
    -- "return blink"), and the return needs no raises anyway -- the user's own
    -- click/cmd-tab already fronted the hero. A no-peek beat keeps the deck on
    -- top on its own, so this stays a no-op then. beginSettle absorbs the echoes.
    local function recleanIfPeeked()
        if not st.peeked then return end
        st.peeked = false
        ctx.log("reclean deck (a peek left a non-deck window on top)")
        beginSettle()
        raiseDeck()
    end

    -- A member window moved or resized. Our own AX moves echo here too --
    -- markOurMove's guard filters those; what remains is the USER dragging or
    -- resizing a deck window. Live ring tracking would visibly trail the drag
    -- (AX events throttle), so instead: HIDE the ring while the window is in
    -- motion, remember each reported frame, and once events go quiet for
    -- STABLE_SECS re-show the ring at the REAL frame (renderBorders places
    -- from m.cur). The slot stays the window's HOME -- ⌥Esc, demotion and
    -- restore-on-exit still use slot/orig.
    local STABLE_SECS = 0.35
    local function onMemberFrameEvent(info)
        if not st.active then return end
        -- the same identity ladder as keyOf: wid first, then bundleID+title
        local m
        if info.wid and info.wid ~= 0 then
            m = memberByKey(widKey(info.bundleID, info.wid))
        end
        m = m or memberByKey(titleKey(info.bundleID, info.title))
        if not m or m.gone then return end
        local key = m.key
        -- Our own move settling? Guard armed AND the reported frame matches
        -- what we dispatched (fire() reads the CURRENT frame, so echoes see
        -- the applied target). A diverging frame under an armed guard is the
        -- user already dragging it -- fall through and track that.
        if st.echo and st.echo[key] and atFrame(info, m.cur) then return end
        if not (st.stable and st.stable[key]) then    -- motion episode starts
            ctx.log("member in motion (ring hidden)", key)
            local b = st.borders and st.borders[key]
            if b then b.hide() end
        end
        m.cur = { x = info.x, y = info.y, w = info.w, h = info.h }
        if not st.stable then return end
        if st.stable[key] then st.stable[key].stop() end
        st.stable[key] = ctx.afterSeconds(STABLE_SECS, function()
            if st.stable and st.stable[key] then st.stable[key].stop(); st.stable[key] = nil end
            if not st.active then return end
            ctx.log("member settled (ring re-shown)", key)
            renderBorders()
        end)
    end

    -- Resolve the "restore last deck" option for the entry screen-selector, or
    -- nil when nothing is restorable right now. Reads the saved membership,
    -- resolves its target screen (the saved screen if still connected, else the
    -- active/current one), and matches the saved members against that screen's
    -- live windows (identity.matchMembers -- wid within a session, title across a
    -- restart). Restorable only if >= 2 members are available NOW (a deck needs
    -- two), so a last deck whose windows are all closed is silently NOT offered.
    -- `total` (vs #matched) lets the label say "N of M available" -- the "some
    -- are missing, restore around them" case the design calls for.
    local function restoreOption(screens)
        local last = readLastDeck()
        if not last then return nil end
        local screen
        for _, s in ipairs(screens) do
            if s.name == last.screen then screen = s; break end
        end
        if not screen then
            local idx = activeScreenIndex()
            for _, s in ipairs(screens) do
                if s.index == idx then screen = s; break end
            end
            screen = screen or screens[1]
        end
        -- match against ALL on-screen windows (uncapped) so a member past the
        -- top-9 in MRU order isn't wrongly seen as closed (see groupWindows).
        local matched = identity.matchMembers(last.members, groupWindows(screen, math.huge))
        if #matched < 2 then return nil end
        return { screen = screen, matched = matched, total = #last.members }
    end

    -- Idle -> pick -> Grid. Per the "picker on every toggle" decision, entering
    -- always runs the pick flow first: choose a screen (multi-monitor only), then
    -- a multi-select of that screen's windows (all pre-checked, uncheck to leave
    -- out), then commit to the flat GRID (overview first, no hero). Exiting stays
    -- instant -- no picker on the way out. `picking` guards a re-trigger while a
    -- panel is open (the toggle hotkey stays live).
    --
    -- The screen-selector also carries a "restore last deck" BUTTON when one is
    -- available (multi-monitor -- that step exists only here; single-monitor
    -- keeps its one-tap fast path to the window picker, so restore rides the
    -- selector rather than forcing a chooser onto the single-screen flow).
    function st.enter()
        if st.active or st.picking then return end
        if not ctx.axTrusted() then
            ctx.axPrompt()
            ctx.alert(
                ctx.t("alert.axRequired",
                    "%s needs the Accessibility permission to arrange windows -- "
                    .. "grant it in System Settings, then try again.", ctx.appName))
            return
        end
        local screens = ctx.screen.frames()
        if not screens or #screens == 0 then return end
        st.picking = true
        if #screens < 2 then
            st.pickWindows(screens[1])
        else
            st.pickScreen(screens, restoreOption(screens))
        end
    end

    -- Multi-monitor: pick which screen to deck, off a spatial display map. The
    -- display the user is CURRENTLY on (their focused window's screen, else the
    -- cursor's) is the pre-selected DEFAULT, so a single Enter decks it without
    -- touching the mouse. (If we can't tell which is active -- no focused window
    -- and the cursor is off every screen -- the first display is the default:
    -- still a one-Enter pick.) Cancel / click-away backs all the way out.
    function st.pickScreen(screens, restore)
        local activeIdx = activeScreenIndex()
        -- The spatial display map (ctx.screen.pickDisplay): each display drawn at
        -- its real position, tagged with its deckable-window count. Indices map
        -- 1:1 to `screens`. The display the user is on is the DEFAULT selection
        -- (Enter decks it -- the one-tap fast path the old text list had via a
        -- pre-selected first row), and every display is freely clickable.
        -- Deckable-window count per screen in ONE list() pass -- the AX window
        -- listing is dear (see groupWindows), so bucket rather than call
        -- groupWindows per screen (window_snap's displaysWithCounts does the same).
        -- Same deckable predicate: sized, not minimized/fullscreen, on that screen.
        local counts = {}
        for i = 1, #screens do counts[i] = 0 end
        for _, w in ipairs(ctx.window.list()) do
            if w.w and w.h and w.w > 0 and w.h > 0
                and not w.minimized and not w.fullscreen then
                for i, s in ipairs(screens) do
                    if onScreen(w, s) then counts[i] = counts[i] + 1; break end
                end
            end
        end
        local displays, activeMapIdx = {}, nil
        for i, s in ipairs(screens) do
            displays[i] = { x = s.x, y = s.y, w = s.w, h = s.h, name = s.name,
                            windows = counts[i] }
            if s.index == activeIdx then activeMapIdx = i end
        end
        -- A restorable last deck rides the map as a secondary-action BUTTON (not a
        -- display), so it does NOT hijack the default (Enter still decks the
        -- current screen). Its label states availability, so a deck with some
        -- windows now closed reads "N of M available" and still restores around
        -- the missing ones (>= 2 survive -- restoreOption's gate).
        local restoreLabel
        if restore then
            if #restore.matched >= restore.total then
                restoreLabel =
                    ctx.t("pick.restoreAll", "Restore last deck (%d windows)", restore.total)
            else
                restoreLabel =
                    ctx.t("pick.restoreSome", "Restore last deck (%1$d of %2$d available)", #restore.matched, restore.total)
            end
        end
        local h
        h = ctx.screen.pickDisplay {
            displays    = displays,
            preselect   = { activeMapIdx or 1 },   -- current display (else the first) is the default
            selectCount = 1,
            title       = ctx.t("pick.screen", "Deck which screen?"),
            prompt      = ctx.t("pick.screenPrompt",
                "Pick the display to deck. Your current one is selected by default."),
            confirmVerb = ctx.t("pick.deckVerb", "Deck on"),
            extraLabel  = restoreLabel,   -- nil/absent -> no restore button
            onPick = function(indices)
                if h then h.stop() end   -- drop the one-shot from the scope
                local idx = indices and indices[1]
                if idx and screens[idx] then st.pickWindows(screens[idx]) else st.picking = false end
            end,
            onExtra = function()
                if h then h.stop() end
                st.restoreLast(restore)
            end,
        }
    end

    -- Commit the saved "last deck" directly (chosen from the screen-selector),
    -- skipping the window multi-select. Re-matches the saved members against a
    -- FRESH window list (the user spent time in the chooser; row ids churn and a
    -- window may have closed since restoreOption ran), colors them from the same
    -- per-app memory a fresh pick uses, and commits WITHOUT rewriting the saved
    -- template (isRestore -- so a partial restore doesn't erode it). If fewer
    -- than two survive by now, alert rather than enter a one-window "deck".
    function st.restoreLast(restore)
        st.picking = false
        local last = readLastDeck()
        if not last then return end
        local screen = restore.screen
        -- match against ALL on-screen windows (uncapped) so a member past the
        -- top-9 in MRU order isn't wrongly seen as closed (see groupWindows).
        local matched = identity.matchMembers(last.members, groupWindows(screen, math.huge))
        if #matched < 2 then
            ctx.alert(ctx.t("alert.restoreGone",
                "The last deck's windows are no longer open on this screen."))
            return
        end
        local cellColors = colors.assign(matched, readColors())
        local chosen = {}
        for i, w in ipairs(matched) do chosen[keyOf(w)] = cellColors[i] or true end
        ctx.log("restore last deck:", #matched, "of", #last.members,
            "on screen", tostring(screen.index))
        st.commit(screen, chosen, true)
    end

    -- Show the multi-select of a screen's deckable windows (all pre-checked;
    -- uncheck to exclude). Confirm needs >= 2 checked (the panel enforces it too).
    function st.pickWindows(screen)
        local wins = groupWindows(screen)
        if #wins < 2 then
            st.picking = false
            ctx.alert(ctx.t("alert.needTwo",
                "Window Deck needs at least two windows on this screen."))
            return
        end
        local items = {}
        local cellColors = colors.assign(wins, readColors())   -- previewed as clickable dots in the picker
        for i, w in ipairs(wins) do
            local title = (w.title and #w.title > 0) and w.title
                or (w.appName or ctx.t("pick.untitled", "Untitled window"))
            items[i] = {
                key = keyOf(w), text = title, subText = w.appName,
                image = w.icon or ctx.appIcon(w.bundleID),
                color = cellColors[i],
            }
        end
        local h
        h = ctx.askWindows {
            title   = ctx.t("pick.windows", "Deck which windows?"),
            min     = 2,
            items   = items,
            palette = PALETTE,
            screen  = screen,   -- center the picker on the PICKED display
            -- opt in to the picker's Hero switch (its initial state = persisted)
            heroLabel = ctx.t("pick.hero", "Enlarge focused window (hero)"),
            hero    = readHeroMode(),

            onChoose = function(kept, heroOn)
                if h then h.stop() end   -- drop the one-shot from the scope
                st.picking = false
                if not kept then return end          -- cancelled
                -- Persist the picker's Hero switch (on() below reads it back).
                if heroOn ~= nil then saveHeroMode(heroOn) end
                if #kept < 2 then
                    ctx.alert(ctx.t("alert.needTwo",
                        "Window Deck needs at least two windows on this screen."))
                    return
                end
                -- key -> chosen color (the hex doubles as set membership)
                local chosen = {}
                for _, it in ipairs(kept) do chosen[it.key] = it.color or true end
                st.commit(screen, chosen)
            end,
        }
    end

    -- Grid: re-list (ids churn between the pick and now), keep only the chosen
    -- keys still present on `screen`, tile with nearest-cell assignment, arm the
    -- focus watchers + ⌥Esc + banner. Stays flat (overview first, no hero).
    function st.commit(screen, chosenKeys, isRestore)
        if st.active then return end
        local wins = {}
        for _, w in ipairs(ctx.window.list()) do
            local sized = w.w and w.h and w.w > 0 and w.h > 0
            if sized and not w.minimized and not w.fullscreen
                and onScreen(w, screen) and chosenKeys[keyOf(w)] then
                wins[#wins + 1] = w
                if #wins >= 9 then break end
            end
        end
        if #wins < 2 then
            ctx.alert(ctx.t("alert.needTwo",
                "Window Deck needs at least two windows on this screen."))
            return
        end

        -- capture originals (color = the picker's choice, else positional)
        local group = {}
        for i, w in ipairs(wins) do
            local picked = chosenKeys[keyOf(w)]
            group[i] = {
                key = keyOf(w), id = w.id,
                appName = w.appName, title = w.title, bundleID = w.bundleID,
                orig = { x = w.x, y = w.y, w = w.w, h = w.h },
                gone = false,
                color = (type(picked) == "string") and picked
                    or PALETTE[((i - 1) % #PALETTE) + 1],
            }
        end

        -- persist each app's color (its first window wins) so the same apps get
        -- the same border colors next deck -- that's what makes recoloring stick.
        do
            local stored, seen = readColors(), {}
            for _, m in ipairs(group) do
                local bid = m.bundleID or ""
                if bid ~= "" and not seen[bid] then
                    stored[bid], seen[bid] = m.color, true
                end
            end
            saveColors(stored)
        end

        -- Remember this membership as the "last deck" for one-tap restore -- but
        -- ONLY on a fresh pick. A restore reuses the saved template as-is, so it
        -- must not overwrite it with the (possibly smaller) set that survived a
        -- session with some windows closed, else the curated deck erodes over
        -- time. Descriptors carry wid + title so restore re-matches either way.
        if not isRestore then
            local members = {}
            for i, w in ipairs(wins) do
                members[i] = { bundleID = w.bundleID, title = w.title, wid = w.wid }
            end
            saveLastDeck(screen.name, members)
        end

        -- uniform slots + minimise-travel assignment (keep windows near home)
        local slots = W.tileSlots(screen, #group, ctx.opt("gutter"))
        local winCenters, slotCenters = {}, {}
        for i, m in ipairs(group) do winCenters[i] = W.center(m.orig) end
        for i, s in ipairs(slots)  do slotCenters[i] = W.center(s) end
        local perm = W.assignNearest(winCenters, slotCenters)
        for i, m in ipairs(group) do m.slot = slots[perm[i]] end

        -- Mini-map cell order (cell i, row-major reading order, -> the window in
        -- that slot). A drag-swap re-runs rebuildWidgetOrder to keep it truthful.
        rebuildWidgetOrder(group)
        st.widgetCols = W.gridDims(#group).w

        -- place immediately: the ids from the re-list above are still valid.
        -- (moveWin records m.cur and arms the echo guard the frame watcher
        -- below relies on.)
        st.echo, st.stable = {}, {}
        for _, m in ipairs(group) do moveWin(m.id, m, m.slot) end

        st.screen  = screen
        st.group   = group
        dropToGrid("enter")   -- start flat: no hero (heroKey nil after any prior exit, so silent)
        st.active  = true

        -- focus is the promotion signal: app-activation (cross-app) + focused-
        -- window-changed (within-app) both reconcile. Idempotent, so double-fire
        -- on a cross-app switch is harmless.
        st.appWatcher   = ctx.onAppActivated(function() st.reconcile() end)
        st.focusWatcher = ctx.window.onFocusChanged(function() st.reconcile() end)
        st.escHotkey    = ctx.bindHotkey({ "alt" }, "escape", function() st.onEsc() end)
        -- ⌥1-9 switch the hero to that mini-map cell (⌥ matches ⌥Esc; bare
        -- numbers would hijack typing in a focused deck window). One per window.
        -- Append only real handles (no nil holes), so the ipairs teardown in
        -- exitDeck can't stop short and strand a hotkey still hijacking ⌥N.
        st.numHotkeys = {}
        for i = 1, math.min(#group, 9) do
            local hk = ctx.bindHotkey({ "alt" }, tostring(i), function() switchToCell(i) end)
            if hk then st.numHotkeys[#st.numHotkeys + 1] = hk end
        end
        -- The container scrim pins to the DECK's screen (a picked screen, not
        -- necessarily the key one). It (and the widget below) re-anchor on
        -- screenChanged, so they can't be orphaned onto another display the way
        -- the old fixed-rect banner was.
        st.scrim        = ctx.scrim(screen, ctx.opt("dim") / 100)
        -- The draggable indicator card floats above the scrim. Its position is
        -- persisted as an OFFSET from the deck screen's top-left (so it survives
        -- a screen move); the native drag is CLAMPED to the deck screen, so the
        -- reported (and saved) offset is always on-screen. onExit exits the deck.
        st.widgetDx, st.widgetDy = readWidgetPos()
        st.heroMode     = readHeroMode()
        st.widget       = ctx.deckWidget({
            title  = ctx.t("deck.title", "Window Deck"),
            hint   = ctx.t("deck.hint", "to exit"),
            name   = screen.name or "",
            switchHint     = switchHintFor(),
            heroLabel      = ctx.t("deck.hero", "Hero"),
            exitLabel      = ctx.t("deck.exit", "Exit"),
            rearrangeLabel = ctx.t("deck.rearrange", "Rearrange"),
            pos    = { x = screen.x + st.widgetDx, y = screen.y + st.widgetDy },
            screen = screen,
            hero   = st.heroMode,
            -- Flip the Hero toggle live: off drops any current hero back to the
            -- grid and stops zooming on focus; on re-enables it. Persisted.
            onToggleHero = function(on)
                if not st.active then return end
                st.heroMode = on
                saveHeroMode(on)
                ctx.log("hero mode", on and "on" or "off")
                -- Flipping ON: promote whatever deck window is focused RIGHT NOW
                -- into the hero (the widget is a non-activating panel, so the
                -- click didn't steal focus -- the real front window is still the
                -- one to zoom). reconcile classifies it as "promote" and plays
                -- the beat, matching what a fresh focus would have done. OFF:
                -- drop any current hero back to the grid.
                if not on and st.mode == "focus" then st.dropHero()
                elseif on then st.reconcile() end
                if st.widget then st.widget.setSwitchHint(switchHintFor()) end
            end,
            switcher = {
                cols   = st.widgetCols,
                colors = st.widgetColors,
                hero   = 0,   -- flat grid on enter; renderBorders lights the hero
                -- Click cell i: the current hero drops back to grid; any other
                -- window is FOCUSED, which fires the existing promote beat (no
                -- new promotion path). Same as a real click; shared with ⌥1-9.
                onSwitch = switchToCell,
                -- Drag cell `from` onto cell `to` in the widget: swap the two
                -- windows' slots (drag-and-drop rearrange, mini-map only).
                onReorder = swapCells,
            },
            onMove = function(x, y)
                if not st.active or not st.screen then return end
                st.widgetDx = x - st.screen.x
                st.widgetDy = y - st.screen.y
                saveWidgetPos(st.widgetDx, st.widgetDy)
                ctx.log("deck widget moved", math.floor(st.widgetDx), math.floor(st.widgetDy))
            end,
            onExit = function() if st.active then st.exitDeck() end end,
            onRearrange = function() if st.active then st.rearrange() end end,
        })
        -- Display reconfig (a screen powered off/on, resolution or arrangement
        -- change): if the deck's screen is gone, its whole world is gone -- exit
        -- cleanly instead of stranding the tiled windows + chrome on a surviving
        -- display. If the screen merely moved/resized, re-anchor the scrim.
        st.screenWatcher = ctx.onSystemEvent("screenChanged", function()
            st.onScreenChanged()
        end)
        -- hide-until-stable for USER moves: watch the member apps' move/resize
        -- events (our own AX moves are echo-guarded -- see onMemberFrameEvent)
        local bids, seenBid = {}, {}
        for _, m in ipairs(group) do
            local bid = m.bundleID or ""
            if bid ~= "" and not seenBid[bid] then
                bids[#bids + 1], seenBid[bid] = bid, true
            end
        end
        st.frameWatcher = ctx.window.onFramesChanged(bids, onMemberFrameEvent)

        ctx.log("on:", #group, "windows on screen", tostring(screen.index))
        -- Ring every member (subtle): each border starts at the window's
        -- ORIGINAL frame and flies to its slot alongside the window's own async
        -- AX move -- so the borders never sit at the slots while the windows
        -- are still travelling. Flat grid: no hero/ghost yet.
        st.borders = {}
        for _, m in ipairs(group) do
            local b = ctx.outline("member", m.color)
            b.setFrame(m.orig)
            b.animateFrame(m.slot, FLIGHT)
            st.borders[m.key] = b
        end
        syncScrim()     -- punch the container holes at the members' slots
        beginSettle()   -- absorb the echoes of the enter raise
        raiseDeck()     -- lift the deck above any non-deck windows on this screen
    end

    -- Which member is ACTUALLY focused right now, matched by the same identity
    -- ladder as keyOf: the stable wid key first (the bridge resolves the
    -- focused window's CGWindowID), then the bundleID+title key -- so lookups
    -- stay coherent even when one side's wid resolution fails. Read from the
    -- AX focused-window state; we must NOT use list()[1] (the CG z-order
    -- front): that z-order LAGS the activation/focus notification that
    -- triggers reconcile, so its first row is frequently the PREVIOUS front
    -- window -- which promoted the wrong window and left the one you just
    -- focused sitting in its slot. Returns member (nil = non-deck focus) plus
    -- the best key for logging. (Forward-declared above: raiseDeck gates the
    -- hero's focus-lift on it.)
    function focusedMember()
        local info = ctx.frontmostAppInfo() or {}
        local bid = info.bundleId or ""
        local wid = ctx.window.focusedWid()
        if wid and wid ~= 0 then
            local k = widKey(bid, wid)
            local m = memberByKey(k)
            if m then return m, k end
        end
        local k = titleKey(bid, ctx.window.title())
        return memberByKey(k), k
    end

    -- A focus change: promote whichever group window is now focused. Blur to a
    -- non-group window is ignored (stay); re-focusing the current hero is a no-op
    -- (guards the raise/activate feedback loop). Only the two windows that change
    -- role move -- never a re-tile.
    function st.reconcile()
        if not st.active then return end
        -- Ignore events while settling -- they are echoes of our own raises/moves,
        -- not a real user focus change (see beginSettle). Without this the hero and
        -- a peek fight for front (the blink). Logged so a runaway is visible.
        if st.settling then ctx.log("reconcile: suppressed settling echo"); return end

        -- presence bookkeeping (resolveIds also ADOPTS retitled members -- see
        -- its header): mark truly closed members gone; if the hero vanished,
        -- fall back to the flat grid.
        local ids = resolveIds()
        for _, m in ipairs(st.group) do m.gone = not ids[m.key] end
        if st.heroKey and not ids[st.heroKey] then
            dropToGrid("hero vanished")
            renderBorders()
        end

        -- Classify the focus event with the pure decision core (focus.lua), then
        -- apply the named outcome. reconcile stays the effectful SHELL: it
        -- resolves presence above and runs the side effects below; the DECISION
        -- (which of the 5 outcomes) is the testable pure part.
        local member, focusKey = focusedMember()
        local outcome = focus.classify({
            hasMember = member ~= nil,
            isHero    = member ~= nil and member.key == st.heroKey,
            listed    = member ~= nil and ids[member.key] ~= nil,
            heroMode  = st.heroMode,
        })

        if outcome == "peek" then                  -- blur = stay: a peek, leave the deck behind
            st.peeked = true                        -- a non-deck window took front; sunk at the next beat
            hideChrome()                            -- deck chrome must not float over the peeked window
            ctx.log("reconcile: peek (non-deck focus)", focusKey, "-- stay (chrome hidden)")
            return
        elseif outcome == "return" then
            -- Raise NOTHING here. The user's own click/cmd-tab already fronted
            -- the hero (system click-to-front), and any AXRaise to an
            -- activating app would flash a member over the hero -- the "return
            -- blink". st.peeked stays set: the ex-peek sinks at the next beat
            -- (landHero/dropHero), under motion cover. But DO re-show the chrome
            -- (a peek hid it): pure overlay ordering, no window raise, no blink.
            showChrome()
            ctx.log("reconcile: return to hero", member.key,
                st.peeked and "(reclean deferred to next beat)" or "")
            return
        elseif outcome == "ignore" then
            return                                  -- focused window not listed yet
        elseif outcome == "gridFocus" then
            -- Grid-only mode (Hero off): focusing a deck window does NOT zoom it
            -- into a hero. Just re-show the chrome (a peek may have hidden it)
            -- and stay flat -- the deck is a pure tiler here.
            showChrome()
            ctx.log("reconcile: focus", member.key, "-- grid-only (hero off), no promote")
            return
        end
        -- outcome == "promote": a non-hero deck member regained front in Hero
        -- mode -- fall through to the two-step beat below.

        -- A deck member (not the current hero) regained front: re-show the
        -- container chrome if a peek hid it, before the promote beat plays. The
        -- rings re-show themselves via renderBorders at the beat's landing.
        if st.scrim then st.scrim.show() end
        if st.widget then st.widget.show() end

        -- a cross-app switch double-fires (app-activated + focus-changed); if the
        -- beat is already playing toward this window, let it finish undisturbed
        if st.pendingSnap and st.pendingSnapKey == member.key then return end
        settlePending()

        ctx.log("reconcile: promote", member.key, "(was", tostring(st.heroKey) .. ")")

        -- Land the beat: flip to FOCUS and re-render the borders at their final
        -- frames (the real window's move was already dispatched at flight
        -- start). NOTE: do NOT read the frame back and re-centre here. AX
        -- setFrame is applied ASYNCHRONOUSLY by the target app, so an immediate
        -- ctx.window.frame() returns the PRE-resize (slot-sized) frame --
        -- re-centring to that shrank the hero back to a grid cell (~25% on a
        -- 2x2). Set it and trust it; a fixed-size app that refuses to grow just
        -- sits at the 78% origin (a rare, minor cosmetic case).
        -- Prefers whoever is focused NOW over the captured target, so a fast
        -- second switch during the beat (whose event a settle window swallowed)
        -- still lands on the right window -- re-slotting the one that flew.
        local function landHero()
            local ids2 = resolveIds()
            local m2 = member
            local mNow = focusedMember()
            if mNow and ids2[mNow.key] then m2 = mNow end
            if not ids2[m2.key] then
                -- the promoted window is truly gone (closed mid-beat; a mere
                -- retitle would have been adopted by resolveIds): nothing to
                -- land on -- stay in the grid, never a stranded hero
                m2.gone = true
                renderBorders()
                recleanIfPeeked()
                return
            end
            if m2 ~= member and ids2[member.key] then
                moveWin(ids2[member.key], member, member.slot)
            end
            moveWin(ids2[m2.key], m2, heroFrame())
            m2.gone = false
            setHero(m2.key)
            renderBorders()
            recleanIfPeeked()   -- a plain swap keeps the deck on top; only re-raise after a peek
        end

        -- The promotion plays as a TWO-STEP BEAT with RING FLIGHTS (real
        -- windows can't tween, but the border overlays are OUR windows and
        -- animate smoothly). Step 1 (swap only): the old hero steps home --
        -- its ring flies to its slot with its window's AX move dispatched
        -- under it. Step 2 (once step 1 lands; immediately when promoting
        -- from the flat grid): the incoming ring flies to the hero rect,
        -- again with its window's move dispatched at flight start. AX applies
        -- a frame asynchronously (~50-200ms), so dispatching under each
        -- flight hides that latency -- the window is in place as its ring
        -- lands -- while the two movements stay SEQUENCED: the demotion
        -- reads first, then the promotion.
        local dest = heroFrame()

        -- Step 2. Re-lists first: when it runs a flight after reconcile's
        -- list(), those ids are stale (ids churn on every list()).
        local function launchPromote()
            local ids2 = resolveIds()
            local fb = st.borders and st.borders[member.key]
            if fb then
                fb.setStyle("hero")
                fb.setHole(nil)
                fb.animateFrame(dest, FLIGHT)
            end
            if ids2[member.key] then moveWin(ids2[member.key], member, dest) end
            member.gone = false
            -- Carve the hero rect out of every OTHER border now, not at
            -- landing -- the real window is already growing into it -- and
            -- show the ghost at the incoming hero's home slot as its ring
            -- lifts off.
            for k, b in pairs(st.borders or {}) do
                if k ~= member.key then b.setHole(dest) end
            end
            if not st.ghost then st.ghost = ctx.outline("ghost", member.color) end
            st.ghost.setColor(member.color)
            st.ghost.setHole(dest)
            st.ghost.setFrame(member.slot)
            st.pendingHome = member   -- cancelled mid-flight? settlePending re-slots it
            st.pendingSnap = ctx.afterSeconds(FLIGHT, function()
                if st.pendingSnap then st.pendingSnap.stop() end
                st.pendingSnap, st.pendingSnapKey, st.pendingHome = nil, nil, nil
                if not st.active then return end
                landHero()
            end)
        end

        st.pendingSnapKey = member.key   -- guards the cross-app double-fire across the whole beat
        if st.heroKey then
            -- INVARIANT this branch's `ids` lookups lean on: a hero can only
            -- exist when no flight is mid-air (every beat nils heroKey until
            -- it lands), so pendingHome was nil and the settlePending() above
            -- did NOT re-list -- reconcile's `ids` are still the freshest
            -- listing here. If a future edit lets pendingHome coexist with a
            -- live heroKey, re-list before using `ids` below.
            local old = memberByKey(st.heroKey)
            dropToGrid("demote for promote")
            if old and ids[old.key] then
                -- Step 1: the old hero steps home; step 2 launches when its
                -- ring lands. (`pendingHome` stays nil during step 1: the
                -- incoming window hasn't moved yet, so cancelling here needs
                -- no fixup -- the old window is already headed where grid
                -- mode wants it.)
                moveWin(ids[old.key], old, old.slot)
                local ob = st.borders and st.borders[old.key]
                if ob then ob.setStyle("member"); ob.animateFrame(old.slot, FLIGHT) end
                st.pendingSnap = ctx.afterSeconds(FLIGHT, function()
                    if st.pendingSnap then st.pendingSnap.stop() end
                    st.pendingSnap = nil
                    if not st.active then return end
                    launchPromote()
                end)
                return
            end
        end
        launchPromote()
    end

    -- Focus -> Grid: drop the hero back into its slot (⌥Esc, first press). The
    -- reverse ring flight: the hero's ring flies home to its slot and the real
    -- window's move home is dispatched NOW, under the flight (same trick as the
    -- promote beat -- AX applies frames asynchronously, so the window is
    -- settling into its slot as the ring lands instead of popping in after it).
    function st.dropHero()
        if st.mode ~= "focus" then return end
        settlePending()
        local hero = memberByKey(st.heroKey)
        dropToGrid("drop")   -- reads heroKey above first, then clears + logs the transition
        if not hero then
            renderBorders()
            recleanIfPeeked()
            return
        end
        local ids = resolveIds()   -- adopts a retitled hero before the lookups below
        local b = st.borders and st.borders[hero.key]
        if b then b.setStyle("member"); b.animateFrame(hero.slot, FLIGHT) end
        if ids[hero.key] then moveWin(ids[hero.key], hero, hero.slot) end
        st.pendingSnap = ctx.afterSeconds(FLIGHT, function()
            if st.pendingSnap then st.pendingSnap.stop() end
            st.pendingSnap, st.pendingSnapKey = nil, nil
            if not st.active then return end
            renderBorders()
            recleanIfPeeked()   -- re-raise only if a peek left a non-deck window on top
        end)
    end

    -- Display reconfig handler (see the screenChanged watcher in on()). Match the
    -- deck's screen across the reconfig by name (localizedName is the stable-ish
    -- key; the index can shuffle). Gone -> exit the deck, and SKIP restore: the
    -- windows' original frames were on the vanished display, so re-applying them
    -- would fling the windows off-screen -- leave them where macOS relocated
    -- them. Merely moved/resized -> re-anchor the scrim and re-cover the rings.
    function st.onScreenChanged()
        if not st.active or not st.screen then return end
        local want = st.screen.name
        local cur
        for _, f in ipairs(ctx.screen.frames()) do
            if f.name == want then cur = f; break end
        end
        if not cur then
            ctx.log("screenChanged: deck screen gone", tostring(want), "-- exiting (no restore)")
            st.exitDeck(true)
            return
        end
        st.screen = cur
        if st.scrim then st.scrim.reanchor(cur) end
        if st.widget then
            st.widget.reanchor({ x = cur.x + st.widgetDx, y = cur.y + st.widgetDy }, cur)
        end
        -- Re-tile onto the new geometry. The slots were sized to the OLD screen
        -- frame at enter (W.tileSlots); a resolution/scale change -- same display,
        -- new w/h -- leaves every slot stale, so the tiled windows sit off-screen
        -- or wrong-sized (the "deck stops working after a resolution change" bug).
        -- Recompute the grid for `cur` and move each member to the slot in the SAME
        -- cell it already holds: sort members by their OLD slot and the new slots
        -- both in row-major reading order, then pair them up. That preserves each
        -- window's cell (no reshuffle, mini-map stays truthful). The hero re-centres
        -- on the new heroFrame; only its drop-back slot changes.
        if st.group and #st.group > 0 then
            settlePending()   -- resolve any in-flight promotion snap before re-tiling
            local newSlots = W.tileSlots(cur, #st.group, ctx.opt("gutter"))
            local function rowMajor(af, bf)
                local ay, by = math.floor((af.y or 0) / 10), math.floor((bf.y or 0) / 10)
                if ay ~= by then return ay < by end
                return (af.x or 0) < (bf.x or 0)
            end
            table.sort(newSlots, rowMajor)
            local ordered = {}
            for _, m in ipairs(st.group) do ordered[#ordered + 1] = m end
            table.sort(ordered, function(a, b) return rowMajor(a.slot, b.slot) end)
            local ids = resolveIds()
            for i, m in ipairs(ordered) do
                m.slot = newSlots[i] or m.slot
                if not m.gone and ids[m.key] then
                    -- Cancel any in-flight hide-until-stable (a user mid-drag when
                    -- the reconfig fired), so its pending timer can't later re-show
                    -- the ring at a stale frame -- same guard as st.rearrange.
                    if st.stable and st.stable[m.key] then
                        st.stable[m.key].stop(); st.stable[m.key] = nil
                    end
                    moveWin(ids[m.key], m, (m.key == st.heroKey) and heroFrame() or m.slot)
                end
            end
            rebuildWidgetOrder()
            ctx.log("screenChanged: re-tiled", #st.group, "windows on", tostring(cur.name))
        end
        renderBorders()   -- re-cover the rings + holes onto the (moved) screen
        ctx.log("screenChanged: re-anchored deck to", tostring(cur.name))
    end

    -- Grid -> Idle: restore original frames (a setting), drop watchers/hotkey/
    -- scrim. Also the disable path (via forceExit) and the toggle-off path.
    -- `skipRestore` forces the restore off (the deck's screen vanished -- see
    -- onScreenChanged -- so the original frames no longer make sense).
    function st.exitDeck(skipRestore)
        if not st.active then return end
        ctx.log("off")
        if st.settleTimer then st.settleTimer.stop(); st.settleTimer = nil end
        settlePending()
        st.settling = false
        st.peeked = false
        clearBorders()
        if st.frameWatcher then st.frameWatcher.stop(); st.frameWatcher = nil end
        if st.screenWatcher then st.screenWatcher.stop(); st.screenWatcher = nil end
        for _, t in pairs(st.echo or {}) do t.stop() end
        for _, t in pairs(st.stable or {}) do t.stop() end
        st.echo, st.stable = nil, nil
        if ctx.opt("restoreOnExit") and not skipRestore then
            -- resolveIds adopts retitled members, so a window that renamed
            -- itself mid-deck (a browser does on every tab switch) is still
            -- restored instead of being left wherever the deck put it.
            local ids = resolveIds()
            for _, m in ipairs(st.group) do
                if ids[m.key] then
                    ctx.window.setFrameFor(ids[m.key], m.orig)
                end
            end
        end
        if st.appWatcher   then st.appWatcher.stop() end
        if st.focusWatcher then st.focusWatcher.stop() end
        if st.escHotkey    then st.escHotkey.stop() end
        for _, hk in ipairs(st.numHotkeys or {}) do hk.stop() end
        st.numHotkeys = nil
        if st.scrim        then st.scrim.stop() end
        if st.widget       then st.widget.stop() end
        st.active = false
        st.group, st.screen, st.heroKey, st.mode = nil, nil, nil, nil
        st.appWatcher, st.focusWatcher, st.escHotkey = nil, nil, nil
        st.scrim, st.widget = nil, nil
    end

    -- Rearrange (widget button): snap every window back to its home -- its slot,
    -- or the hero frame for the hero -- after the user has dragged/resized some.
    -- Re-dispatches the moves under the echo guard and re-syncs the rings/holes;
    -- renderBorders then recomputes the dirty state (now clean).
    function st.rearrange()
        if not st.active then return end
        ctx.log("rearrange -> re-tile" .. (st.heroKey and " (hero re-centered)" or ""))
        settlePending()
        local ids = resolveIds()
        for _, m in ipairs(st.group) do
            if not m.gone and ids[m.key] then
                if st.stable and st.stable[m.key] then
                    st.stable[m.key].stop(); st.stable[m.key] = nil
                end
                local target = (m.key == st.heroKey) and heroFrame() or m.slot
                moveWin(ids[m.key], m, target)
            end
        end
        renderBorders()
    end

    -- Escalating Escape: first press drops the hero, second leaves the deck.
    function st.onEsc()
        if st.mode == "focus" then st.dropHero() else st.exitDeck() end
    end

    function st.toggle()
        if st.active then st.exitDeck() elseif not st.picking then st.enter() end
    end

    -- Called from stop(ctx) on disable: restore if a deck is still live.
    function st.forceExit()
        if st.active then st.exitDeck() end
    end

    return st
end

local function with(ctx)
    return ctx.perEnable(controllerFor)
end

return {
    api = 1,
    id  = "window_deck",

    options = {
        { key = "heroPercent", type = "int", default = 78, min = 50, max = 95,
          label = "Hero size (% of screen)" },
        { key = "gutter", type = "int", default = 8, min = 0, max = 40,
          label = "Grid gap (px)" },
        { key = "dim", type = "int", default = 50, min = 0, max = 85,
          label = "Container dim (% -- how much the rest of the screen darkens)" },
        { key = "restoreOnExit", type = "bool", default = true,
          label = "Restore original layout on exit" },
    },

    -- Service: start builds the idle controller; stop restores a live deck.
    start = function(ctx) with(ctx) end,
    stop  = function(ctx) with(ctx).forceExit() end,

    actions = {
        { id = "toggle", label = "Toggle Window Deck",
          description = "Pick which of this screen's windows to tile into a grid; "
              .. "focus one to make it the hero. ⌥Esc drops the hero, then exits.",
          defaultTrigger = { type = "hotkey", mods = HYPER, key = "k" },
          mnemonic = "Hyper+K — K for decK (Hyper+D is Insert Date/Time)",
          run = function(ctx) with(ctx).toggle() end },
    },
}
