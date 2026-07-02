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
-- The deck stays ABOVE non-deck windows on the screen: it is raised on enter and
-- re-raised ONLY when a "peek" (focusing a non-deck window) may have left one on
-- top -- a plain hero swap keeps the deck on top on its own, so it does NOT
-- re-raise (raising activates some apps, a needless one-frame blink). Focusing a
-- NON-deck window is a temporary peek -- left alone, on top only while it holds
-- focus, then sunk behind the deck the moment you focus a deck window again.
-- raiseDeck uses ctx.window.raise (surgical AXRaise); a settle guard absorbs the
-- focus/activation echoes those raises emit so they never re-enter reconcile and
-- make the hero and a peek fight for front. Focus is the only "tell".
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

local W    = require("platform.windows")
local json = require("platform.json")

local HYPER = { "cmd", "alt", "ctrl" }

-- Distinct per-window border colors ("#RRGGBB"). Defaults are positional; the
-- picker previews each window's color as a dot the user can click to recolor
-- (cycling this palette), and the chosen color persists per APP (bundle id) so
-- decks look stable session to session.
local PALETTE = {
    "#4C8DFF", "#34C759", "#FF9F0A", "#AF52DE", "#FF375F",
    "#5AC8FA", "#FFD60A", "#FF6482", "#30D158",
}

-- Ring-flight duration (seconds): how long a border ring flies between a grid
-- slot and the hero rect. The real window's AX move is dispatched at flight
-- START and applies asynchronously underneath, so this doubles as the cover
-- time hiding that latency -- the window should be in place by ring landing.
-- (A hero swap plays TWO flights back to back -- home, then out -- so it
-- takes ~2x this.)
local FLIGHT = 0.15

-- Stable identity for a window across list() calls (row ids are rebuilt each
-- list). The IDENTITY LADDER: primary = the OS-stable CGWindowID the bridge
-- resolves (`wid` -- survives retitles, unique for the window's lifetime);
-- fallback = bundleID+title for the rare window whose wid is unresolvable
-- (see resolveIds' adoption for how that tier self-heals on retitles). The
-- two key spaces carry distinct prefixes so they can never collide. Two
-- untitled same-app windows still collide in the fallback tier -- a
-- documented limitation, now reachable only when wid resolution fails.
local function widKey(bundleID, wid)
    return (bundleID or "") .. "\0wid:" .. string.format("%d", wid)
end
local function titleKey(bundleID, title)
    return (bundleID or "") .. "\0t:" .. (title or "")
end
local function keyOf(w)
    if w.wid and w.wid ~= 0 then return widKey(w.bundleID, w.wid) end
    return titleKey(w.bundleID, w.title)
end

-- Is window `w`'s centre inside screen rect `s`? Pure geometry -- robust across
-- the separate native calls that produce window frames vs screen frames (their
-- screen tables are not the same object, so identity comparison would be wrong).
local function onScreen(w, s)
    local mx, my = w.x + w.w / 2, w.y + w.h / 2
    return mx >= s.x and mx < s.x + s.w
       and my >= s.y and my < s.y + s.h
end

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

    -- The deckable windows on `screen`, MRU order, capped at 9: visible, sized,
    -- not fullscreen. A single list() call -- its ids stay valid for the
    -- immediately-following placement batch (no intervening list()).
    local function groupWindows(screen)
        local out = {}
        for _, w in ipairs(ctx.window.list()) do
            local sized = w.w and w.h and w.w > 0 and w.h > 0
            if sized and not w.minimized and not w.fullscreen
                and onScreen(w, screen) then
                out[#out + 1] = w
                if #out >= 9 then break end
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

    -- Frame proximity for the identity adoption below: the window still sits
    -- where the member was last known to be (position ~32px, size ~64px --
    -- generous enough for apps that clamp or snap the frames we dispatch,
    -- e.g. terminals snapping to their character grid).
    local function atFrame(w, f)
        return f ~= nil and math.abs(w.x - f.x) <= 32 and math.abs(w.y - f.y) <= 32
            and math.abs(w.w - f.w) <= 64 and math.abs(w.h - f.h) <= 64
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

    -- Persisted per-app border colors (bundleID -> "#RRGGBB"), JSON in feature
    -- state. Object-tagged on encode so an empty map round-trips as {} not [].
    local function readColors()
        local raw = ctx.getState("colors")
        if type(raw) ~= "string" or raw == "" then return {} end
        return json.decode(raw) or {}
    end
    local function saveColors(map)
        ctx.setState("colors", json.encode(json.asObject(map)))
    end

    -- Preview colors for the pick list: an app the user has recolored keeps its
    -- stored color (its first window), everyone else takes the next free palette
    -- color positionally, skipping colors already in use.
    local function colorsFor(wins)
        local stored, used, out, seenApp = readColors(), {}, {}, {}
        for i, w in ipairs(wins) do
            local bid = w.bundleID or ""
            if bid ~= "" and stored[bid] and not seenApp[bid] then
                out[i], used[stored[bid]], seenApp[bid] = stored[bid], true, true
            end
        end
        local pi = 1
        for i in ipairs(wins) do
            if not out[i] then
                while pi < #PALETTE and used[PALETTE[((pi - 1) % #PALETTE) + 1]] do
                    pi = pi + 1
                end
                local c = PALETTE[((pi - 1) % #PALETTE) + 1]
                out[i], used[c] = c, true
                pi = pi + 1
            end
        end
        return out
    end

    -- Border overlays (click-through). Every deck member gets a subtle "member"
    -- border at its current frame so you can see which windows are in the deck; the
    -- hero's border is re-styled "hero" (strong) and moved to the hero frame; and a
    -- faint dashed "ghost" marks the hero's home SLOT (where it drops back to).
    -- Persistent per member -- re-styled/moved on each transition, not recreated,
    -- so nothing flickers. renderBorders() syncs them to the current state.
    local function renderBorders()
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

    -- Keep the deck ABOVE non-deck windows: raise every present member with a
    -- SURGICAL raise (verified -- doesn't activate the app or drag same-app
    -- siblings, so no spurious promotion, and it can't beat the currently-active
    -- window, so a focused hero stays on top of the group on its own). Non-deck
    -- windows sink behind; a deliberately-focused non-deck window (a "peek") is
    -- left alone and stays on top only while it holds focus. Called on enter and
    -- whenever focus returns to a deck window, so the deck self-heals after a
    -- peek. Re-listed because ids churn every list().
    local function raiseDeck()
        if not st.active then return end
        local ids = resolveIds()
        -- Raise the peeks first, then the HERO last: some apps ACTIVATE the window
        -- they are asked to raise, so raising the hero last leaves focus ON the
        -- hero, not on a peek. beginSettle() at the call sites then absorbs the
        -- focus/activation echoes these raises emit, so they don't re-enter
        -- reconcile and fight for front (the blink).
        for _, m in ipairs(st.group) do
            if m.key ~= st.heroKey and not m.gone and ids[m.key] then
                ctx.window.raise(ids[m.key])
            end
        end
        if st.heroKey and ids[st.heroKey] then ctx.window.raise(ids[st.heroKey]) end
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

    -- Re-lift the deck ONLY if a peek (a non-deck window taking focus) may have put
    -- a non-deck window on top since we last cleaned. A plain hero swap keeps the
    -- deck on top on its own, so it must NOT re-raise -- raising activates some apps,
    -- which flashes a one-frame blink for nothing. beginSettle absorbs the echoes.
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

    -- Idle -> pick -> Grid. Per the "picker on every toggle" decision, entering
    -- always runs the pick flow first: choose a screen (multi-monitor only), then
    -- a multi-select of that screen's windows (all pre-checked, uncheck to leave
    -- out), then commit to the flat GRID (overview first, no hero). Exiting stays
    -- instant -- no picker on the way out. `picking` guards a re-trigger while a
    -- panel is open (the toggle hotkey stays live).
    function st.enter()
        if st.active or st.picking then return end
        if not ctx.axTrusted() then
            ctx.axPrompt()
            ctx.alert(string.format(
                ctx.t("alert.axRequired",
                    "%s needs the Accessibility permission to arrange windows -- "
                    .. "grant it in System Settings, then try again."),
                ctx.appName))
            return
        end
        local screens = ctx.screen.frames()
        if not screens or #screens == 0 then return end
        st.picking = true
        if #screens < 2 then
            st.pickWindows(screens[1])
        else
            st.pickScreen(screens)
        end
    end

    -- Multi-monitor: pick which screen to deck. The display the user is CURRENTLY
    -- on (their focused window's screen, else the cursor's) is offered FIRST and
    -- marked "(current)" -- askChoice pre-selects row 1, so a single Enter takes
    -- it without reading the list. (If we can't tell which is active -- no focused
    -- window and the cursor is off every screen -- the first-listed / primary is
    -- the default: still a one-Enter pick, just unmarked.) Cancel backs all the
    -- way out.
    function st.pickScreen(screens)
        local activeIdx = activeScreenIndex()
        local ordered, labels = {}, {}
        for _, s in ipairs(screens) do
            if s.index == activeIdx then
                table.insert(ordered, 1, s)   -- current display first (Enter takes it)
            else
                ordered[#ordered + 1] = s
            end
        end
        for _, s in ipairs(ordered) do
            local name = s.name
                or string.format(ctx.t("pick.screenN", "Display %d"), s.index or 0)
            if s.index == activeIdx then
                name = name .. " " .. ctx.t("pick.current", "(current)")
            end
            labels[#labels + 1] = name
        end
        local h
        h = ctx.askChoice {
            title   = ctx.t("pick.screen", "Deck which screen?"),
            actions = labels,
            onChoose = function(label)
                if h then h.stop() end   -- drop the one-shot from the scope
                if not label then st.picking = false; return end
                -- Map the chosen label back to its screen (first match; duplicate
                -- display names are rare and only cost a wrong-of-two pick).
                local chosen
                for i, l in ipairs(labels) do
                    if l == label then chosen = ordered[i]; break end
                end
                if chosen then st.pickWindows(chosen) else st.picking = false end
            end,
        }
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
        local colors = colorsFor(wins)   -- previewed as clickable dots in the picker
        for i, w in ipairs(wins) do
            local title = (w.title and #w.title > 0) and w.title
                or (w.appName or ctx.t("pick.untitled", "Untitled window"))
            items[i] = {
                key = keyOf(w), text = title, subText = w.appName,
                image = w.icon or ctx.appIcon(w.bundleID),
                color = colors[i],
            }
        end
        local h
        h = ctx.askWindows {
            title   = ctx.t("pick.windows", "Deck which windows?"),
            min     = 2,
            items   = items,
            palette = PALETTE,
            onChoose = function(kept)
                if h then h.stop() end   -- drop the one-shot from the scope
                st.picking = false
                if not kept then return end          -- cancelled
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
    function st.commit(screen, chosenKeys)
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

        -- uniform slots + minimise-travel assignment (keep windows near home)
        local slots = W.tileSlots(screen, #group, ctx.opt("gutter"))
        local winCenters, slotCenters = {}, {}
        for i, m in ipairs(group) do winCenters[i] = W.center(m.orig) end
        for i, s in ipairs(slots)  do slotCenters[i] = W.center(s) end
        local perm = W.assignNearest(winCenters, slotCenters)
        for i, m in ipairs(group) do m.slot = slots[perm[i]] end

        -- place immediately: the ids from the re-list above are still valid.
        -- (moveWin records m.cur and arms the echo guard the frame watcher
        -- below relies on.)
        st.echo, st.stable = {}, {}
        for _, m in ipairs(group) do moveWin(m.id, m, m.slot) end

        st.screen  = screen
        st.group   = group
        st.mode    = "grid"
        st.heroKey = nil
        st.active  = true

        -- focus is the promotion signal: app-activation (cross-app) + focused-
        -- window-changed (within-app) both reconcile. Idempotent, so double-fire
        -- on a cross-app switch is harmless.
        st.appWatcher   = ctx.onAppActivated(function() st.reconcile() end)
        st.focusWatcher = ctx.window.onFocusChanged(function() st.reconcile() end)
        st.escHotkey    = ctx.bindHotkey({ "alt" }, "escape", function() st.onEsc() end)
        -- the banner pins to the DECK's screen -- NSScreen.main (the key
        -- window's screen) is wrong here: the target screen is picked, and by
        -- commit time key focus may sit on any display
        st.banner       = ctx.banner(
            ctx.t("banner.active", "Window Deck  --  ⌥Esc to exit"), screen)
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
    -- the best key for logging.
    local function focusedMember()
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
            st.mode, st.heroKey = "grid", nil
            renderBorders()
        end

        local member, focusKey = focusedMember()
        if not member then                     -- blur = stay: a peek, leave the deck behind
            st.peeked = true                   -- a non-deck window took front; re-clean on return
            ctx.log("reconcile: peek (non-deck focus)", focusKey, "-- stay")
            return
        end
        if member.key == st.heroKey then
            ctx.log("reconcile: return to hero", member.key)
            recleanIfPeeked()                  -- re-raise only if a peek left non-deck on top
            return
        end
        if not ids[member.key] then return end -- focused window not listed yet

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
            st.mode, st.heroKey = "focus", m2.key
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
            local old = memberByKey(st.heroKey)
            st.mode, st.heroKey = "grid", nil
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
        ctx.log("drop hero", tostring(st.heroKey), "-> grid")
        settlePending()
        local hero = memberByKey(st.heroKey)
        st.mode, st.heroKey = "grid", nil
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

    -- Grid -> Idle: restore original frames (a setting), drop watchers/hotkey/
    -- banner. Also the disable path (via forceExit) and the toggle-off path.
    function st.exitDeck()
        if not st.active then return end
        ctx.log("off")
        if st.settleTimer then st.settleTimer.stop(); st.settleTimer = nil end
        settlePending()
        st.settling = false
        st.peeked = false
        clearBorders()
        if st.frameWatcher then st.frameWatcher.stop(); st.frameWatcher = nil end
        for _, t in pairs(st.echo or {}) do t.stop() end
        for _, t in pairs(st.stable or {}) do t.stop() end
        st.echo, st.stable = nil, nil
        if ctx.opt("restoreOnExit") then
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
        if st.banner       then st.banner.stop() end
        st.active = false
        st.group, st.screen, st.heroKey, st.mode = nil, nil, nil, nil
        st.appWatcher, st.focusWatcher, st.escHotkey, st.banner = nil, nil, nil, nil
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
