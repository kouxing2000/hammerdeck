-- test/fake_adapter.lua
--
-- In-memory implementation of the full adapter surface, for headless tests.
-- Tests preempt the seam with:
--   package.loaded["platform.adapter"] = require("test.fake_adapter").adapter
-- then drive time/input via the fake.* helpers (fireTimer, pressHotkey,
-- systemEvent, dialogs, ...) and assert on the recorded effects.

local fake = {}
local adapter = {}
fake.adapter = adapter

-- Recorded state ------------------------------------------------------------
fake.settings      = {}
fake.notifications = {}
fake.alerts        = {}
fake.timers        = {}   -- {kind="every"|"after"|"daily", n, fn, stopped}
fake.hotkeys       = {}   -- {mods, key, fn, stopped}
fake.chords        = {}   -- {mods, key, follows, fn, stopped}
fake.watchers      = {}   -- {event, fn, stopped}
fake.choosers      = {}   -- see adapter.chooser
fake.dialogs       = {}   -- see adapter.askChoice
fake.banners       = {}   -- {text, stopped}
fake.huds          = {}   -- {spec, title, stopped}
fake.textPrompts   = {}   -- see adapter.askText
fake.progressBars  = {}   -- {fraction, stopped}
fake.windows       = {}   -- preset by the test for listWindows()
fake.focused       = {}   -- focusWindow(id) calls
fake.modifiers     = {}   -- e.g. { alt = true }
fake.idle          = 0
fake.clockOffset   = 0    -- added to os.time(); tests advance time with this
fake.actions       = { sleep = 0, lock = 0, screensaver = 0, displaySleep = 0 }
fake.liveHandles   = 0    -- allocated-and-not-yet-freed native resources

local function alloc()
    fake.liveHandles = fake.liveHandles + 1
end
local function freeOnce(obj)
    if not obj.stopped then
        obj.stopped = true
        fake.liveHandles = fake.liveHandles - 1
    end
end

-- Async ONE-SHOT calls (http, download, JXA tab reads, favicon scan), mirroring
-- the real seam's cancelable-one-shot contract (Native+Callbacks registerOneShot/
-- fireOneShot): the returned handle's stop() drops the pending callback, so a
-- completion landing AFTER the feature was torn down does nothing.
--
-- Delivery is SYNCHRONOUS by default -- what nearly every case wants, and what
-- the suite assumed before these grew handles. Set fake.deferAsync = true to
-- queue completions instead and release them with fake.deliverAsync(): that is
-- the only way to drive the disable-mid-flight path the real bridge guards, and
-- without it the fake would silently under-report the contract (the shape-only
-- parity gap CODE-13 is about).
fake.pendingAsync = {}   -- queued completions while fake.deferAsync is set

local function oneShot(deliver)
    local h = { stopped = false }
    alloc()
    local function fire()
        if h.stopped then return end   -- torn down while in flight: drop it
        freeOnce(h)                    -- consume before delivering (matches fireOneShot)
        deliver()
    end
    if fake.deferAsync then
        fake.pendingAsync[#fake.pendingAsync + 1] = fire
    else
        fire()
    end
    return { stop = function() freeOnce(h) end }
end

-- Canonical short name for a modifier token ("Command" -> "cmd"), mirroring
-- KeyModifier.canonical -- alias specs must match exactly as the real
-- bridge's bitmask comparison does (command+k and cmd+k are one combo).
local CANON_MOD = { command = "cmd", option = "alt", control = "ctrl" }
local function canonMod(m)
    m = tostring(m):lower()
    return CANON_MOD[m] or m
end

-- Order-independent canonical key for a modifier list ({"option","Cmd"} ->
-- "alt,cmd") -- the fake twin of Carbon's bitmask equality.
local function modsKey(mods)
    local c = {}
    for _, m in ipairs(mods or {}) do c[#c + 1] = canonMod(m) end
    table.sort(c)
    return table.concat(c, ",")
end

-- Order-independent modifier-set equality (matches HotkeyCenter.park's combo
-- comparison, which is a bitmask and so order-independent).
local function sameMods(a, b)
    return modsKey(a) == modsKey(b)
end

-- Triggers / bindings ---------------------------------------------------------

local function makeTimer(kind, n, fn)
    local t = { kind = kind, n = n, fn = fn, stopped = false }
    fake.timers[#fake.timers + 1] = t
    alloc()
    return t, { stop = function() freeOnce(t) end }
end

-- Mirror the real seam's modifier whitelist (KeyModifier.swift): the native
-- bridge REJECTS unknown modifier names loudly, so the fake must too -- or the
-- headless suite green-lights token typos the real app would error on.
local VALID_MODS = {
    cmd = true, command = true, alt = true, option = true,
    ctrl = true, control = true, shift = true,
}

local function assertMods(mods, what)
    for _, m in ipairs(mods or {}) do
        assert(type(m) == "string" and VALID_MODS[m:lower()],
            what .. ": unknown modifier '" .. tostring(m) .. "'")
    end
end

-- Same surface as the real seam's native.valid_modifiers(). An integration
-- contract test compares this list against KeyModifier's, so the fake's
-- whitelist above cannot silently drift from the real bridge.
function adapter.validModifiers()
    local out = {}
    for k in pairs(VALID_MODS) do out[#out + 1] = k end
    table.sort(out)
    return out
end

function adapter.bindHotkey(mods, key, fn, onRelease, shadow)
    assertMods(mods, "bind_hotkey")
    local h = { mods = mods, key = key, fn = fn, onRelease = onRelease,
                stopped = false, parked = false }
    -- Model HotkeyCenter.park: when `shadow`, temporarily deactivate every LIVE
    -- hotkey on this exact combo for this binding's lifetime (restored on stop).
    -- `parked` is distinct from `stopped` (unbound) -- the incumbent's handle
    -- stays alive, only its dispatch is suppressed, exactly like the real park.
    local shadowed = {}
    if shadow then
        for _, o in ipairs(fake.hotkeys) do
            if not o.stopped and not o.parked and o.key == key and sameMods(o.mods, mods) then
                o.parked = true
                shadowed[#shadowed + 1] = o
            end
        end
    end
    fake.hotkeys[#fake.hotkeys + 1] = h
    alloc()
    return { stop = function()
        freeOnce(h)
        for _, o in ipairs(shadowed) do
            if not o.stopped then o.parked = false end   -- skip any unbound while parked
        end
    end }
end

function adapter.bindChord(mods, key, follows, fn, label, icon)
    assertMods(mods, "bind_chord")
    -- Capture label + icon like the real seam does (they feed the which-key
    -- hint's row text + leading glyph), so a test can assert on them.
    local c = { mods = mods, key = key, follows = follows, fn = fn,
                label = label, icon = icon, stopped = false }
    fake.chords[#fake.chords + 1] = c
    alloc()
    return { stop = function() freeOnce(c) end }
end

function adapter.everySeconds(n, fn)
    local _, handle = makeTimer("every", n, fn)
    return handle
end

function adapter.afterSeconds(n, fn)
    local _, handle = makeTimer("after", n, fn)
    return handle
end

function adapter.dailyAt(timeStr, fn)
    local _, handle = makeTimer("daily", timeStr, fn)
    return handle
end

function adapter.onSystemEvent(event, fn)
    local w = { event = event, fn = fn, stopped = false }
    fake.watchers[#fake.watchers + 1] = w
    alloc()
    return { stop = function() freeOnce(w) end }
end

-- Persistence -----------------------------------------------------------------

function adapter.getSetting(key, default)
    local v = fake.settings[key]
    if v == nil then return default end
    return v
end

function adapter.setSetting(key, value)
    fake.settings[key] = value
end

-- System shortcuts the editor warns against; tests can populate fake.systemHotkeys.
function adapter.systemHotkeys()
    return fake.systemHotkeys or {}
end

-- Secrets (separate store from fake.settings, so tests can prove a secret never
-- leaks into UserDefaults). Keyed by the full account string ctx.secret builds.
fake.secrets = {}

function adapter.secretGet(key)        return fake.secrets[key] end
function adapter.secretSet(key, value) fake.secrets[key] = value; return true end
function adapter.secretDelete(key)     fake.secrets[key] = nil;   return true end

-- Output ------------------------------------------------------------------------

function adapter.notify(title, text)
    fake.notifications[#fake.notifications + 1] = { title = title, text = text }
end

fake.flashes = {}      -- recorded flash (manual-trigger confirmation) calls
function adapter.flash(symbol, text)
    fake.flashes[#fake.flashes + 1] = { symbol = symbol, text = text }
end

fake.systemNotifications = {}      -- recorded systemNotify (Notification Center) calls
fake.systemNotifyDelivers = true   -- tests flip to false to exercise the toast fallback
function adapter.systemNotify(title, text)
    fake.systemNotifications[#fake.systemNotifications + 1] = { title = title, text = text }
    return fake.systemNotifyDelivers
end

function adapter.alert(text)
    fake.alerts[#fake.alerts + 1] = text
end

fake.logs = {}                  -- captured adapter.log lines (for diagnostics assertions)
function adapter.log(...)        -- silent in tests, but recorded so tests can assert traces
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    fake.logs[#fake.logs + 1] = table.concat(parts, " ")
end

-- UI ------------------------------------------------------------------------------

function adapter.chooser(opts)
    local c = {
        opts = opts, visible = false, choices = {}, selectedRow = 0,
        placeholder = nil, query = nil, stopped = false,
        setChoicesCalls = 0,   -- how many times setChoices ran (native applyFilter =
                               -- selection reset; a background relist must NOT re-set
                               -- the live list, so this must not tick for it)
    }
    fake.choosers[#fake.choosers + 1] = c
    alloc()
    -- Visible = query-filtered choices, mirroring the native panel: every row
    -- number the handle speaks is an index into THIS list, not the full set.
    -- The match mirrors applyFilter exactly -- an order-preserving,
    -- case-insensitive substring filter over text, plus subText when
    -- searchSubText is on (the real panel does no ranking either).
    local function visible()
        if not c.query or c.query == "" then return c.choices end
        local out, q = {}, c.query:lower()
        for _, choice in ipairs(c.choices) do
            local hay = tostring(choice.text or ""):lower()
            if opts.searchSubText and choice.subText then
                hay = hay .. "\n" .. tostring(choice.subText):lower()
            end
            if hay:find(q, 1, true) then out[#out + 1] = choice end
        end
        return out
    end
    local function selectFirstValid()
        for i, choice in ipairs(visible()) do
            if choice.valid ~= false then c.selectedRow = i; return end
        end
        c.selectedRow = 0
    end
    local h = {}
    function h.setPlaceholder(t)  c.placeholder = t end
    function h.setTitle(t, symbol, badge)
        c.title = t; c.titleSymbol = symbol; c.titleBadge = badge
    end
    function h.setChoices(list)
        -- Mirror the native chooser: setChoices re-filters and reselects the
        -- first valid visible row (setChoices -> applyFilter -> selectFirstValid).
        c.choices = list; c.setChoicesCalls = c.setChoicesCalls + 1
        selectFirstValid()
    end
    function h.show()             c.visible = true end
    function h.hide()
        c.visible = false
        if opts.onHide then opts.onHide() end
    end
    function h.isVisible()        return c.visible end
    function h.getSelectedRow()   return c.selectedRow end
    function h.setSelectedRow(n)
        -- Mirror the native chooser: rows beyond the VISIBLE list are rejected.
        if n >= 1 and n <= #visible() then c.selectedRow = n end
    end
    function h.step(delta)
        -- Mirror the native panel's moveSelection: step over the visible rows,
        -- wrapping at either end and skipping non-selectable (valid == false)
        -- rows; an empty list is a no-op.
        local v = visible()
        local row = c.selectedRow >= 1 and c.selectedRow or (1 - delta)
        for _ = 1, #v do
            row = row + delta
            if row < 1 then row = #v end
            if row > #v then row = 1 end
            if v[row].valid ~= false then c.selectedRow = row; return end
        end
    end
    function h.select(n)
        -- Mirror the native chooser: selecting fires onSelect then onHide; the
        -- row indexes the VISIBLE list, delivering that filtered row's choice
        -- (out-of-range n delivers nil, as the panel's finish(nil) does).
        local v = visible()
        c.visible = false
        if opts.onSelect then opts.onSelect(v[n]) end
        if opts.onHide then opts.onHide() end
    end
    function h.setQuery(q)
        -- Mirror the native panel: a query change re-filters and reselects the
        -- first valid visible row (applyFilter -> selectFirstValid).
        c.query = q
        selectFirstValid()
    end
    function h.getQuery()         return c.query or "" end
    -- Mirror the native chooser: close() orders the panel out, so a stopped
    -- chooser is never "visible".
    function h.stop()             c.visible = false; freeOnce(c) end
    -- test-side driver: pick row n as the user would
    function c.userSelect(n)      h.select(n) end
    -- test-side driver: type a query as the user would (real typing lands in
    -- the same applyFilter -> reselect path setQuery takes)
    function c.userType(q)        h.setQuery(q) end
    -- test-side driver: step the selection as the panel's own keys would
    -- (tab / shift+tab / option+arrows all land in the same moveSelection)
    function c.userStep(delta)    h.step(delta) end
    return h
end

function adapter.askChoice(opts)
    -- Mirror the real adapter: each action entry is a plain label STRING or a
    -- { id, label, icon } table (icon = an icon token like "symbol:zzz").
    -- onChoose receives (choiceId, label) -- the entry's `id` if it declares one,
    -- else its 1-based INDEX, never the display text (CODE-12). Expose `actions`
    -- as the label strings (what tests read and pass to choose) and `items` as
    -- the normalized { text, image } rows, so a test can assert on the icons.
    local raw = opts.actions or {}
    local labels, ids, items = {}, {}, {}
    for i, a in ipairs(raw) do
        if type(a) == "table" then
            labels[i] = a.label or a.text or ""
            ids[i] = a.id ~= nil and a.id or i
            items[i] = { text = labels[i], image = a.icon }
        else
            labels[i] = a
            ids[i] = i
            items[i] = { text = a }
        end
    end
    local d = {
        title = opts.title, infos = opts.infos or {}, actions = labels, items = items,
        ids = ids, onChoose = opts.onChoose, open = true, stopped = false,
    }
    fake.dialogs[#fake.dialogs + 1] = d
    alloc()
    local function finish(idx)
        if not d.open then return end
        d.open = false
        freeOnce(d)
        if not d.onChoose then return end
        if idx then d.onChoose(ids[idx], labels[idx]) else d.onChoose(nil) end
    end
    -- Test-side driver: pick a row the way a USER does -- by the text they see,
    -- or by position. Deliberately NOT by id: a test that drove by id could not
    -- catch a row whose id and label got out of step, and "the user clicked the
    -- row reading X" is what the test is actually asserting. The callback still
    -- receives the id, so the feature's dispatch is exercised for real.
    ---@param which string|number|nil label text, 1-based index, or nil to dismiss
    function d.choose(which)
        if which == nil then return finish(nil) end
        if type(which) == "number" then return finish(which) end
        for i, l in ipairs(labels) do
            if l == which then return finish(i) end
        end
        error("fake askChoice: no action labelled '" .. tostring(which)
            .. "' (have: " .. table.concat(labels, ", ") .. ")")
    end
    return {
        dismiss = function() finish(nil) end,
        stop    = function() d.open = false; freeOnce(d) end,
    }
end

fake.windowPickers = {}   -- see adapter.askWindows
fake.displayPickers = {}  -- see adapter.pickDisplays

-- One-shot multi-select picker (Window Deck's entry). Records the items + min +
-- palette, and exposes drivers: confirm(indices|nil) keeps those 1-based rows
-- (nil = all, the pre-checked default), refusing below `min` like the real
-- panel's Enter guard; cancel() dismisses (onChoose(nil)); recolor(i, hex)
-- recolors row i as a dot-click would (kept items carry the updated color).
function adapter.askWindows(opts)
    local d = {
        title = opts.title, items = opts.items or {}, min = opts.min or 1,
        palette = opts.palette or {},
        screenFrame = opts.screen,   -- the display the picker centers on (nil = key screen)
        heroLabel = opts.heroLabel or "",   -- non-empty opts in to the Hero switch
        hero = opts.hero ~= false,   -- the picker's Hero switch initial (default on)
        onChoose = opts.onChoose, open = true, stopped = false,
    }
    fake.windowPickers[#fake.windowPickers + 1] = d
    alloc()
    local function finish(kept)
        if not d.open then return end
        d.open = false
        freeOnce(d)
        if d.onChoose then d.onChoose(kept, d.hero) end
    end
    function d.setHero(on) d.hero = on end   -- drive the Hero switch from a test
    function d.confirm(indices)
        if indices == nil then
            indices = {}
            for i = 1, #d.items do indices[i] = i end
        end
        if #indices < d.min then return false end   -- panel refuses below min
        local kept = {}
        for _, i in ipairs(indices) do kept[#kept + 1] = d.items[i] end
        finish(kept)
        return true
    end
    function d.cancel() finish(nil) end
    -- recolor row i as a dot-click would (the real panel returns colors on
    -- confirm; the fake mutates the item, which the adapter would do anyway)
    function d.recolor(i, hex)
        if d.items[i] then d.items[i].color = hex end
    end
    return {
        stop = function() d.open = false; freeOnce(d) end,
    }
end

-- Spatial display picker (see adapter.pickDisplays). One-shot: frees itself on
-- confirm/cancel/extra, mirroring the real DisplayPickerPanel. Test drivers:
-- userConfirm(indices) confirms the given 1-based selection, userExtra() presses
-- the secondary-action button, cancel() dismisses.
function adapter.pickDisplays(opts)
    local d = {
        displays = opts.displays or {}, preselect = opts.preselect or {},
        selectCount = opts.selectCount or 1, extraLabel = opts.extraLabel or "",
        title = opts.title, prompt = opts.prompt, confirmVerb = opts.confirmVerb,
        onPick = opts.onPick, onExtra = opts.onExtra, open = true, stopped = false,
    }
    fake.displayPickers[#fake.displayPickers + 1] = d
    alloc()
    local function finish(fn, arg)
        if not d.open then return end
        d.open = false
        freeOnce(d)
        if fn then fn(arg) end
    end
    function d.userConfirm(indices) finish(d.onPick, indices) end
    function d.userExtra() finish(d.onExtra) end
    function d.cancel() finish(d.onPick, nil) end
    return {
        stop = function() d.open = false; freeOnce(d) end,
    }
end

function adapter.banner(text, screenFrame)
    local b = { text = text, screenFrame = screenFrame, stopped = false }
    fake.banners[#fake.banners + 1] = b
    alloc()
    return {
        setText = function(t) b.text = t end,
        stop    = function() freeOnce(b) end,
    }
end

fake.outlines = {}   -- {frame, kind, color, hidden, stopped} for adapter.outline
function adapter.outline(kind, color)
    local o = { frame = nil, kind = kind or "member", color = color or "",
                hidden = false, stopped = false }
    fake.outlines[#fake.outlines + 1] = o
    alloc()
    return {
        setFrame = function(f) o.frame = f; o.hidden = false end,
        -- ring flight: lands at f; `flights` counts them for assertions
        animateFrame = function(f, dur)
            o.frame = f
            o.hidden = false
            o.flights = (o.flights or 0) + 1
        end,
        setStyle = function(k) o.kind = k end,
        setColor = function(c) o.color = c end,
        setFilled = function(on) o.filled = on and true or false end,
        setClip  = function(rects) o.clip = rects; o.clipped = true end,
        clearClip = function() o.clip = nil; o.clipped = false end,
        setHole  = function(f) o.hole = f end,
        -- hide without destroying; setFrame/animateFrame re-show (matches the
        -- real panel: orderOut vs the next place/animate's orderFront)
        hide     = function() o.hidden = true end,
        stop     = function() freeOnce(o) end,
    }
end

-- All live outlines (optionally filtered by kind).
function fake.liveOutlines(kind)
    local out = {}
    for _, o in ipairs(fake.outlines) do
        if not o.stopped and (kind == nil or o.kind == kind) then out[#out + 1] = o end
    end
    return out
end

-- The most-recent live outline of a kind (hero/ghost are singletons).
function fake.liveOutline(kind)
    for i = #fake.outlines, 1, -1 do
        local o = fake.outlines[i]
        if not o.stopped and (kind == nil or o.kind == kind) then return o end
    end
    return nil
end

fake.scrims = {}   -- {screenFrame, dim, holes, hidden, stopped}
function adapter.scrim(screenFrame, dim)
    local s = { screenFrame = screenFrame, dim = dim,
                holes = {}, hidden = false, stopped = false }
    fake.scrims[#fake.scrims + 1] = s
    alloc()
    return {
        setHoles  = function(rects) s.holes = rects or {} end,
        setDim    = function(d) s.dim = d end,
        reanchor  = function(f) s.screenFrame = f end,
        hide      = function() s.hidden = true end,
        show      = function() s.hidden = false end,
        stop      = function() freeOnce(s) end,
    }
end

-- The most-recent live (non-stopped) scrim, nil if none.
function fake.liveScrim()
    for i = #fake.scrims, 1, -1 do
        if not fake.scrims[i].stopped then return fake.scrims[i] end
    end
    return nil
end

fake.deckWidgets = {}   -- {title, name, switcher, hero, onMove, onExit, hidden, stopped}
function adapter.deckWidget(opts)
    opts = opts or {}
    local sw = opts.switcher or {}
    local w = { title = opts.title, hint = opts.hint, name = opts.name,
                switchHint = opts.switchHint, pos = opts.pos, screen = opts.screen,
                cols = sw.cols, colors = sw.colors, hero = sw.hero or 0,
                onSwitch = sw.onSwitch, onReorder = sw.onReorder,
                heroMode = opts.hero ~= false, onToggleHero = opts.onToggleHero,
                onRearrange = opts.onRearrange, dirty = false,
                onMove = opts.onMove, onExit = opts.onExit,
                hidden = false, stopped = false }
    fake.deckWidgets[#fake.deckWidgets + 1] = w
    alloc()
    return {
        -- drive w.onMove/onExit/onSwitch/onToggleHero/onRearrange from a test
        reanchor = function(p, s) w.pos, w.screen = p, s end,
        setHero = function(i) w.hero = i or 0 end,
        setDirty = function(d) w.dirty = d and true or false end,
        setSwitchHint = function(t) w.switchHint = t end,
        -- `dead` marks cells whose window closed; `cols` is only passed when the
        -- cell COUNT changed (a reflow), so mirror the real widget: omitting it
        -- leaves the recorded grid width alone.
        setCells = function(c, dead, cols)
            w.colors, w.dead = c, dead or {}
            if cols then w.cols = cols end
        end,
        hide = function() w.hidden = true end,
        show = function() w.hidden = false end,
        stop = function() freeOnce(w) end,
    }
end

-- The most-recent live (non-stopped) deck widget, nil if none.
function fake.liveWidget()
    for i = #fake.deckWidgets, 1, -1 do
        if not fake.deckWidgets[i].stopped then return fake.deckWidgets[i] end
    end
    return nil
end

function adapter.hud(spec)
    local h = { spec = spec, title = spec and spec.title, stopped = false }
    fake.huds[#fake.huds + 1] = h
    alloc()
    return {
        stop   = function() freeOnce(h) end,
        -- Re-render in place: mutate the live record so fake.liveHud().spec
        -- reflects the update (e.g. window_grid's corner highlight / dimming).
        update = function(newSpec) h.spec = newSpec; h.title = newSpec and newSpec.title end,
    }
end

function adapter.askText(opts)
    local d = {
        title = opts.title, placeholder = opts.placeholder,
        default = opts.default, onSubmit = opts.onSubmit,
        open = true, stopped = false,
    }
    fake.textPrompts[#fake.textPrompts + 1] = d
    alloc()
    local function finish(text)
        if not d.open then return end
        d.open = false
        freeOnce(d)
        if d.onSubmit then d.onSubmit(text) end
    end
    -- test-side driver: type text and hit Enter (nil = Escape)
    function d.submit(text) finish(text) end
    return {
        dismiss = function() finish(nil) end,
        stop    = function() d.open = false; freeOnce(d) end,
    }
end

function adapter.progressBar()
    local p = { fraction = 0, stopped = false }
    fake.progressBars[#fake.progressBars + 1] = p
    alloc()
    return {
        setProgress = function(f) p.fraction = f end,
        stop        = function() freeOnce(p) end,
    }
end

fake.usageWidgets = {}   -- {data, screen, stopped}
function adapter.usageWidget(screenIndex)
    local w = { data = nil, screen = screenIndex or 1, stopped = false }
    fake.usageWidgets[#fake.usageWidgets + 1] = w
    alloc()
    return {
        setData = function(d) w.data = d end,
        stop    = function() freeOnce(w) end,
    }
end

fake.fanWidgets = {}   -- {title, count, rows, pos, screen, onSwitch, onExit, onMove, stopped}
function adapter.fanWidget(opts)
    opts = opts or {}
    local w = { title = opts.title, count = opts.count, rows = opts.rows or {},
                pos = opts.pos, screen = opts.screen,
                onSwitch = opts.onSwitch, onExit = opts.onExit, onMove = opts.onMove,
                stopped = false }
    fake.fanWidgets[#fake.fanWidgets + 1] = w
    alloc()
    return {
        -- drive w.onSwitch(i)/w.onExit()/w.onMove(x,y) from a test.
        setRows  = function(rows, count) w.rows = rows or {}; w.count = count end,
        reanchor = function(p, s) w.pos, w.screen = p, s end,
        stop     = function() freeOnce(w) end,
    }
end

-- The most-recent live (non-stopped) Window Fan widget, nil if none.
function fake.liveFanWidget()
    for i = #fake.fanWidgets, 1, -1 do
        if not fake.fanWidgets[i].stopped then return fake.fanWidgets[i] end
    end
    return nil
end

function fake.liveUsageWidget()
    for i = #fake.usageWidgets, 1, -1 do
        if not fake.usageWidgets[i].stopped then return fake.usageWidgets[i] end
    end
    return nil
end

-- Windows / apps ---------------------------------------------------------------

function adapter.listWindows()
    return fake.windows
end

-- Apps the last listing could not read. Tests set fake.droppedApps to simulate an
-- app going quiet under AX (its windows removed from fake.windows AND its bundle
-- id listed here) -- the case a feature must not mistake for "those windows
-- closed". Default empty = every listing is clean.
fake.droppedApps = {}

function adapter.windowsDroppedApps()
    return fake.droppedApps
end

function adapter.focusWindow(id)
    fake.focused[#fake.focused + 1] = id
    -- Real focus ALWAYS activates the target app (SLPS front-process), but the
    -- echo below fires only under raiseActivates -- a deliberate scoping, not a
    -- model of reality: only the echo-hostile suites opt in, and there the
    -- deck's settle-guard is exercised against the hero-reclaim FOCUS too
    -- (raiseDeck lifts the hero with focus, not a surgical raise, precisely to
    -- beat such an activation). Default-mode tests see focus with no echo.
    if fake.raiseActivates then
        for _, w in ipairs(fake.windows) do
            if w.id == id then
                fake.windowTitle = w.title
                fake.activateApp(w.appName, w.bundleID)
                break
            end
        end
    end
    return true
end

fake.raises = {}   -- recorded raiseWindow(id) calls, in order (Window Deck's deck-on-top)
-- Some real apps ACTIVATE the window they're asked to raise (unlike Finder/TextEdit).
-- With this true, a raise fires an activation echo -- exactly the feedback that made
-- the hero and a peek fight for front. The deck's settle-guard must absorb it.
fake.raiseActivates = false
function adapter.raiseWindow(id)
    fake.raises[#fake.raises + 1] = id
    if fake.raiseActivates then
        for _, w in ipairs(fake.windows) do
            if w.id == id then
                fake.windowTitle = w.title
                fake.activateApp(w.appName, w.bundleID)   -- fires the watchers -> reconcile echo
                break
            end
        end
    end
    return true
end

-- set of ids raised so far -- lets a test assert the whole deck was raised
function fake.raisedSet()
    local s = {}
    for _, id in ipairs(fake.raises) do s[id] = true end
    return s
end

function adapter.appIcon(bundleID)
    return bundleID and ("icon:" .. bundleID) or nil
end

fake.axTrusted = true   -- the fake "machine" has Accessibility by default
fake.axPrompts = 0      -- recorded onboarding prompts

function adapter.axTrusted() return fake.axTrusted end
function adapter.axPrompt()
    fake.axPrompts = fake.axPrompts + 1
    return fake.axTrusted
end
fake.axSettingsOpens = 0   -- recorded "open Accessibility settings pane" calls
function adapter.axOpenSettings()
    fake.axSettingsOpens = fake.axSettingsOpens + 1
end

-- Focused-window frame surface (window_snap) -----------------------------------

fake.screenList     = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1, builtin = true } }
fake.focusedWindow  = nil   -- {x,y,w,h, fullscreen?, screenIndex?} preset by tests
fake.windowFrames   = {}    -- recorded setFocusedWindowFrame calls
fake.windowFrameSets = {}   -- recorded setWindowFrame(id, f) calls: {id, x, y, w, h}
fake.fullscreenSets = {}    -- recorded setFocusedWindowFullscreen calls
fake.mousePos       = { x = 0, y = 0 }

-- Return a FRESH copy (new array, new row tables) on every call, exactly as the
-- real host does (native.screen_frames() builds new tables each time). Returning
-- the one stored table would let a caller that identity-compares screen rows
-- (rawequal against another frames() call, or against ctx.window.frame().screen)
-- pass in tests yet silently match NOTHING in production -- a masked bug this
-- harness must not hide. Callers only read row fields, so the copy is transparent.
function adapter.screenFrames()
    local out = {}
    for i, s in ipairs(fake.screenList) do
        local row = {}
        for k, v in pairs(s) do row[k] = v end
        out[i] = row
    end
    return out
end

function adapter.focusedWindowFrame()
    local w = fake.focusedWindow
    if not w then return nil end
    local idx = w.screenIndex or 1
    return {
        x = w.x, y = w.y, w = w.w, h = w.h,
        fullscreen = w.fullscreen == true,
        screenIndex = idx,
        screen = fake.screenList[idx],
    }
end

function adapter.setFocusedWindowFrame(f)
    fake.windowFrames[#fake.windowFrames + 1] = f
    local w = fake.focusedWindow
    if w then w.x, w.y, w.w, w.h = f.x, f.y, f.w, f.h end
    return true
end

-- Move a listed window by id (the layout engine). Records the call and, if a
-- fake.windows row has that id, updates its frame so a capture-after-apply
-- round-trip reflects the move.
-- fake.failWindowFrameIds[id] = true makes a move on that window FAIL (returns
-- false, records nothing) -- lets a test exercise the matched-but-move-failed path
-- (the real AX setFrame can refuse on a fullscreen/just-closed window).
fake.failWindowFrameIds = {}
function adapter.setWindowFrame(id, f)
    if fake.failWindowFrameIds[id] then return false end
    fake.windowFrameSets[#fake.windowFrameSets + 1] =
        { id = id, x = f.x, y = f.y, w = f.w, h = f.h }
    for _, w in ipairs(fake.windows) do
        if w.id == id then w.x, w.y, w.w, w.h = f.x, f.y, f.w, f.h end
    end
    return true
end

-- Recorded app-target actions; fake.minimizeOk controls minimize's return.
fake.minimized = {}
fake.minimizeOk = true
fake.hidden = {}
fake.quit = {}
fake.appearanceSet = {}   -- recorded setAppearance modes
function adapter.minimizeApp(name)
    fake.minimized[#fake.minimized + 1] = name
    return fake.minimizeOk
end

function adapter.hideApp(name)
    fake.hidden[#fake.hidden + 1] = name
    return true
end

function adapter.quitApp(name)
    fake.quit[#fake.quit + 1] = name
    return true
end

function adapter.setAppearance(mode)
    -- Mirror set_appearance's whitelist: unknown mode used to silently toggle.
    mode = mode or "toggle"
    assert(mode == "dark" or mode == "light" or mode == "toggle",
        "set_appearance: unknown mode '" .. tostring(mode) .. "' (dark|light|toggle)")
    fake.appearanceSet[#fake.appearanceSet + 1] = mode
    return true
end

function adapter.setFocusedWindowFullscreen(on)
    fake.fullscreenSets[#fake.fullscreenSets + 1] = on
    if fake.focusedWindow then fake.focusedWindow.fullscreen = on end
    return true
end

fake.windowTitle = nil   -- preset by tests for focusedWindowTitle()
function adapter.focusedWindowTitle() return fake.windowTitle end

function adapter.mousePosition()
    return { x = fake.mousePos.x, y = fake.mousePos.y }
end

function adapter.setMousePosition(x, y)
    fake.mousePos = { x = x, y = y }
end

fake.featureNames = {}   -- bare names the fake "filesystem" exposes to discovery
function adapter.discoverFeatures(dir) return fake.featureNames end

fake.frontmost = nil     -- preset by the test for frontmostApp() (the name)
fake.frontmostId = ""    -- bundle id of the frontmost app (for frontmostAppInfo)
function adapter.frontmostApp() return fake.frontmost end
function adapter.frontmostAppInfo()
    return { name = fake.frontmost or "", bundleId = fake.frontmostId or "" }
end

fake.appName = "Hammerdeck"   -- the simulated app display name
function adapter.appName() return fake.appName end

fake.locale = "en"            -- the simulated resolved UI locale code
function adapter.locale() return fake.locale end

-- State-signal reads (drive via the fake.* fields + fake.systemEvent("...Changed")).
fake.appearance     = "light"   -- "dark" | "light"
fake.runningAppInfoList = {}     -- list of { name, bundleId } (runningAppsInfo signal)
fake.power          = "ac"       -- "ac" | "battery"
function adapter.appearance()  return fake.appearance end
function adapter.runningAppsInfo()  return fake.runningAppInfoList end
function adapter.powerSource()  return fake.power end

fake.appWatchers = {}    -- {fn, stopped} for onAppActivated (name)
fake.appInfoWatchers = {}  -- {fn, stopped} for onAppActivatedInfo ({name, bundleId})
function adapter.onAppActivated(fn)
    local w = { fn = fn, stopped = false }
    fake.appWatchers[#fake.appWatchers + 1] = w
    alloc()
    return { stop = function() freeOnce(w) end }
end
function adapter.onAppActivatedInfo(fn)
    local w = { fn = fn, stopped = false }
    fake.appInfoWatchers[#fake.appInfoWatchers + 1] = w
    alloc()
    return { stop = function() freeOnce(w) end }
end

-- test-side driver: the user switches to app `name` (optional `bundleId` for the
-- frontmostApp signal's bundle-id match). Fires both watcher flavors.
function fake.activateApp(name, bundleId)
    fake.frontmost = name
    fake.frontmostId = bundleId or ""
    for _, w in ipairs(fake.appWatchers) do
        if not w.stopped then w.fn(name) end
    end
    for _, w in ipairs(fake.appInfoWatchers) do
        if not w.stopped then w.fn({ name = name, bundleId = bundleId or "" }) end
    end
end

fake.windowFocusWatchers = {}   -- {fn, stopped} for onFocusedWindowChanged
-- Subscribe to focused-WINDOW changes (Window Deck's within-app promotion). The
-- real binding fires a bare pulse; the fake mirrors that (no payload).
function adapter.onFocusedWindowChanged(fn)
    local w = { fn = fn, stopped = false }
    fake.windowFocusWatchers[#fake.windowFocusWatchers + 1] = w
    alloc()
    return { stop = function() freeOnce(w) end }
end

-- test-side driver: the focused window changed WITHIN the frontmost app (cmd+`),
-- which onAppActivated cannot see. Reorder fake.windows first so row 1 is the
-- newly-focused window, then call this to pulse the window-focus watchers.
function fake.focusWindowChanged()
    for _, w in ipairs(fake.windowFocusWatchers) do
        if not w.stopped then w.fn() end
    end
end

fake.frameWatchers = {}   -- {bundleIds, fn, stopped} for onWindowFramesChanged
-- Subscribe to window move/resize for the given apps (Window Deck's
-- hide-while-dragging). The real binding fires {bundleID,title,x,y,w,h}.
function adapter.onWindowFramesChanged(bundleIds, fn)
    local w = { bundleIds = bundleIds, fn = fn, stopped = false }
    fake.frameWatchers[#fake.frameWatchers + 1] = w
    alloc()
    return { stop = function() freeOnce(w) end }
end

-- test-side driver: a window moved/resized (as the AX observer would report).
-- `info` = { bundleID, title, wid?, x, y, w, h } in top-left global points.
function fake.fireFrameEvent(info)
    for _, w in ipairs(fake.frameWatchers) do
        if not w.stopped then w.fn(info) end
    end
end

fake.focusedWid = nil   -- the focused window's stable CGWindowID (nil/0 = unresolved)
function adapter.focusedWindowWid()
    return fake.focusedWid or 0
end

-- Data files (in-memory filesystem) ----------------------------------------------

fake.files  = {}   -- path -> content string
fake.mkdirs = {}   -- recorded mkdir calls

function adapter.dataDir() return "/fake/data" end
function adapter.homeDir() return "/fake/home" end

function adapter.mkdir(path)
    fake.mkdirs[#fake.mkdirs + 1] = path
    return true
end

fake.removedSubdirs = {}   -- recorded removeSubdir calls

function adapter.removeSubdir(base, rel)
    fake.removedSubdirs[#fake.removedSubdirs + 1] = { base = base, rel = rel }
    local prefix = base .. "/" .. rel
    local removed = false
    for path in pairs(fake.files) do
        if path == prefix or path:sub(1, #prefix + 1) == prefix .. "/" then
            fake.files[path] = nil
            removed = true
        end
    end
    return removed
end

function adapter.fileRead(path)        return fake.files[path] end
function adapter.fileWrite(path, text) fake.files[path] = text; return true end
function adapter.fileAppend(path, line)
    fake.files[path] = (fake.files[path] or "") .. line .. "\n"
    return true
end
function adapter.fileExists(path)      return fake.files[path] ~= nil end

-- Clipboard ---------------------------------------------------------------------

fake.pasteboard          = nil     -- current general-pasteboard plain-text contents
fake.pasteboardChange    = 0       -- mirrors NSPasteboard.changeCount
fake.pasteboardConcealed = false   -- current clip marked concealed/transient

function adapter.pasteboardRead()       return fake.pasteboard end
function adapter.pasteboardWrite(text)
    fake.pasteboard = text
    fake.pasteboardChange = fake.pasteboardChange + 1
    fake.pasteboardConcealed = false
end

function adapter.pasteboardInfo()
    return { change = fake.pasteboardChange, concealed = fake.pasteboardConcealed }
end

-- test-side driver: the user copies `text` (concealed = a password manager)
function fake.copyText(text, concealed)
    fake.pasteboard = text
    fake.pasteboardConcealed = concealed == true
    fake.pasteboardChange = fake.pasteboardChange + 1
end

-- Input / system ------------------------------------------------------------------

function adapter.now()
    return os.time() + fake.clockOffset
end

function fake.now()
    return adapter.now()
end

function adapter.isModifierHeld(mod)
    assertMods({ mod }, "is_modifier_held")
    -- canonical lookup: probing "option" reads the same key a test presets as
    -- fake.modifiers.alt, exactly as the real bridge probes the option key.
    return fake.modifiers[canonMod(mod)] == true
end

-- In tests the host CSPRNG is absent; math.random gives the same uniform [min,max]
-- contract, which is all the feature logic depends on.
function adapter.randomInt(min, max)
    return math.random(min, max)
end

fake.keyEvents  = {}   -- recorded keyStroke calls: {mods, key}
fake.typedTexts = {}   -- recorded typeText strings
fake.openedUrls = {}   -- recorded openURL calls
fake.runningApps   = {}   -- set: name -> true (preset by tests)
fake.activatedApps = {}   -- recorded successful activateApp names

function adapter.keyStroke(mods, key)
    assertMods(mods, "key_stroke")
    fake.keyEvents[#fake.keyEvents + 1] = { mods = mods or {}, key = key }
end

function adapter.typeText(text)
    fake.typedTexts[#fake.typedTexts + 1] = text
end

function adapter.openURL(url)
    fake.openedUrls[#fake.openedUrls + 1] = url
    return true
end

fake.shortcutsRun = {}   -- recorded runShortcut names
function adapter.runShortcut(name)
    fake.shortcutsRun[#fake.shortcutsRun + 1] = name
end

fake.spokenTexts = {}    -- recorded say() lines
function adapter.say(text)
    fake.spokenTexts[#fake.spokenTexts + 1] = text
end

fake.volume = 50         -- system output volume 0-100
fake.muted = false       -- system output mute state
fake.volumeReturn = nil  -- override adjustVolume's return (nil = real clamp; -1 = AppleScript error)
function adapter.adjustVolume(delta)
    fake.volume = math.max(0, math.min(100, fake.volume + (delta or 0)))
    if fake.volumeReturn ~= nil then return fake.volumeReturn end
    return fake.volume
end
function adapter.toggleMute()
    fake.muted = not fake.muted
    return fake.muted
end

fake.trashEmptied = 0    -- count of empty_trash calls
fake.trashReturn = 3     -- what empty_trash returns (count, or -1 for a TCC denial)
function adapter.emptyTrash()
    fake.trashEmptied = fake.trashEmptied + 1
    return fake.trashReturn
end
fake.ejected = 0         -- count of eject calls
fake.ejectReturn = 1     -- what eject returns (count, or -1 for all-busy)
function adapter.eject()
    fake.ejected = fake.ejected + 1
    return fake.ejectReturn
end

fake.mediaKeys = {}      -- recorded media_key names ("playpause"/"next"/"previous")
function adapter.mediaKey(name)
    fake.mediaKeys[#fake.mediaKeys + 1] = name
end

function adapter.activateApp(name)
    if fake.runningApps[name] then
        fake.activatedApps[#fake.activatedApps + 1] = name
        return true
    end
    return false
end

fake.launchedApps = {}   -- recorded launchOrFocusApp bundle ids
-- Launch-or-focus by bundle id: records and succeeds unless the test marks the
-- id as not-installed via fake.uninstalledApps[bundleId] = true.
function adapter.launchOrFocusApp(bundleId)
    if fake.uninstalledApps and fake.uninstalledApps[bundleId] then return false end
    fake.launchedApps[#fake.launchedApps + 1] = bundleId
    return true
end

fake.browserTabs   = {}   -- url strings (the fake browser's open tabs)
fake.focusedTabs   = {}   -- recorded focused tab urls
fake.openedNewTabs = {}   -- recorded fallback opens

function adapter.focusBrowserTab(pattern, fallbackURL)
    for _, url in ipairs(fake.browserTabs) do
        if url:find(pattern, 1, true) then
            fake.focusedTabs[#fake.focusedTabs + 1] = url
            return true
        end
    end
    fake.openedNewTabs[#fake.openedNewTabs + 1] = fallbackURL
    return false
end

fake.defaultBrowserBundle = "com.google.Chrome"   -- the simulated default browser
fake.appWindows = {}   -- recorded openSiteApp app-window opens (url strings)

function adapter.defaultBrowser()
    return fake.defaultBrowserBundle
end

-- Mirrors focusBrowserTab, but a miss is recorded as an app-window open
-- (rather than a new tab) -- the "site as a standalone app" path.
function adapter.openSiteApp(pattern, url)
    for _, tab in ipairs(fake.browserTabs) do
        if tab:find(pattern, 1, true) then
            fake.focusedTabs[#fake.focusedTabs + 1] = tab
            return true
        end
    end
    fake.appWindows[#fake.appWindows + 1] = url
    return false
end

fake.siteOpens = {}   -- recorded openSite calls {bundleId, profile, app, url, incognito}
-- Make the next openSite REFUSE, the way the real seam does when a private window
-- is asked of a browser that has no such switch (Safari, Firefox). A flag rather
-- than a browser-matrix model on purpose: which bundle ids can go private is the
-- seam's business (BrowserCatalog), and duplicating that list here would just be a
-- second copy to drift. This lets a test drive the CALLER's refusal handling.
fake.refuseSiteOpen = false

function adapter.openSite(bundleId, profile, app, url, incognito)
    fake.siteOpens[#fake.siteOpens + 1] =
        { bundleId = bundleId, profile = profile, app = app, url = url,
          incognito = incognito == true }
    return not fake.refuseSiteOpen
end

-- Safari focus-or-open mirrors focusBrowserTab (same recorders) -- the routing
-- test distinguishes it from openSite by asserting siteOpens stays empty.
function adapter.focusSafariTab(pattern, fallbackURL)
    for _, url in ipairs(fake.browserTabs) do
        if url:find(pattern, 1, true) then
            fake.focusedTabs[#fake.focusedTabs + 1] = url
            return true
        end
    end
    fake.openedNewTabs[#fake.openedNewTabs + 1] = fallbackURL
    return false
end

function adapter.isAppRunning(name)
    return fake.runningApps[name] == true
end

-- Browser tab enumeration / jumping (tab_switcher) -----------------------------

fake.browserTabsByApp = {}   -- app -> list of {title,url,winId,tabIndex,id,visible}
fake.tabJumps  = {}          -- recorded {app, tabId, winId, url, resolved}
fake.jumpUrlOverride = nil   -- string = force the LANDED url (in-place navigation
                             -- drift); false = force "gone"; nil = the resolved url

function adapter.browserListTabs(app, cb)
    return oneShot(function() cb(fake.browserTabsByApp[app]) end)
end

-- Mirror the real JXA (Native+Browser.swift browserFocusTab): re-resolve the tab
-- by STABLE IDENTITY across ALL of the app's windows -- id first (Chrome), else the
-- url preferring the hinted winId and, among equal-url matches there, the LISTED
-- tabIndex (Safari / no id). Position is never primary identity (a reorder /
-- close-before / cross-window move must still land on the same tab) -- but on a
-- total url miss, the tab AT the listed (winId, tabIndex) is the last-resort
-- tertiary: same host as the listed url = an in-place navigation, an honest
-- success with its CURRENT url; different host = landed best-effort but reported
-- as a miss (`missLanding` records that landing). nil = genuinely gone. `resolved`
-- records WHICH record we landed on so tests can assert end to end; cb(url, via)
-- with via = "id" | "url" | "pos".
local function hostOf(u)
    local h = (u or ""):match("://([^/?#]*)") or ""
    h = h:gsub("^[^@]*@", ""):gsub(":.*$", "")
    return h:lower()
end

function adapter.browserFocusTab(app, tabId, winId, url, tabIndex, cb)
    -- Cancelable one-shot like the real JXA call: resolve AND delivery both run
    -- inside oneShot, so a handle stopped in flight drops the callback -- and,
    -- under fake.deferAsync, records no tabJump either (the real osascript has
    -- not run yet at that point).
    return oneShot(function()
        local rec = { app = app, tabId = tabId, winId = winId, url = url,
                      tabIndex = tabIndex }
        fake.tabJumps[#fake.tabJumps + 1] = rec
        if fake.jumpUrlOverride == false then return cb(nil) end   -- forced "gone"
        local tabs = fake.browserTabsByApp[app] or {}
        local match, via
        if tabId and tabId ~= 0 then
            for _, t in ipairs(tabs) do
                if t.id == tabId then match = t; via = "id"; break end
            end
        else
            local hinted, anywhere, pos
            for _, t in ipairs(tabs) do
                local atListed = t.winId == winId and t.tabIndex == tabIndex
                if atListed then pos = pos or t end
                if t.url == url then
                    if atListed then match = t; break end   -- url AND position: the listed tab itself
                    if t.winId == winId then hinted = hinted or t
                    else anywhere = anywhere or t end
                end
            end
            match = match or hinted or anywhere
            if match then via = "url" end
            if not match and pos then
                -- positional tertiary (see the JXA comment for the same-host rationale)
                local ph = hostOf(pos.url)
                if ph ~= "" and ph == hostOf(url) then
                    match = pos; via = "pos"
                else
                    rec.missLanding = pos   -- landed near where the tab was; still a miss
                    return cb(nil)
                end
            end
        end
        if not match then return cb(nil) end
        rec.resolved = match
        cb(fake.jumpUrlOverride or match.url, via)   -- string override = in-place drift
    end)
end

fake.activeUrls = {}   -- app -> the url its front tab is showing

-- Async at the seam (the real one is an out-of-process read), so it goes through
-- `oneShot` like every other async fake: that makes it visible to
-- fake.liveHandles, gives stop() real drop-on-teardown semantics, and -- the
-- reason it matters here -- lets a test set fake.deferAsync to hold the answer
-- and drive the ORDERING of concurrent reads, which is exactly what the callers'
-- serialization guards exist to control.
--
-- "" is normalized to nil, matching the real adapter (the script answers "" for
-- an incognito or window-less browser); a fake that skipped this would let a
-- caller pass here and fail against the real seam.
-- The url is snapshotted at ISSUE time, not delivery time -- the real read runs a
-- subprocess against the browser as it is when the call is made. This is what lets
-- a test stage two DIFFERENT answers and then deliver them out of order (reverse
-- fake.pendingAsync) to exercise a caller's ordering guard.
function adapter.browserActiveURL(app, cb)
    local u = fake.activeUrls[app]
    if u == "" then u = nil end
    return oneShot(function() cb(u) end)
end

fake.chromeFavicons   = {}   -- set: domain -> true ("Chrome knows this icon")
fake.extractedBatches = {}   -- recorded extractFavicons calls {outDir, domains}

function adapter.extractFavicons(outDir, domains, cb)
    fake.extractedBatches[#fake.extractedBatches + 1] =
        { outDir = outDir, domains = domains }
    local saved = {}
    for _, d in ipairs(domains) do
        if fake.chromeFavicons[d] then
            fake.files[outDir .. "/" .. d .. ".png"] = "\137PNG\r\n\26\nfake"
            saved[#saved + 1] = d
        end
    end
    return oneShot(function() cb(saved) end)
end

function adapter.idleSeconds()
    return fake.idle
end

-- Set to a process name to simulate an app holding the display awake (video
-- playback, a call, a presentation); nil = nothing holds one.
fake.displayHeldBy = nil
function adapter.displaySleepPrevented()
    return fake.displayHeldBy
end

fake.mouseLocates = {}   -- recorded locateMouse(seconds) calls
function adapter.locateMouse(seconds)
    fake.mouseLocates[#fake.mouseLocates + 1] = seconds
end

-- Network / files / wallpaper ----------------------------------------------------

fake.httpResponses = {}   -- url -> { status=, body= }; missing url -> (0, nil)
fake.httpRequests  = {}   -- recorded { url, headers }
fake.downloads     = {}   -- recorded { url, path }
fake.downloadOk    = true
fake.wallpapers    = {}   -- recorded setWallpaper paths
fake.wallpaperModes = {}  -- recorded setWallpaper modes (parallel to wallpapers)
fake.wallpaperOk   = true -- setWallpaper's return: false = no target display / missing file
fake.wallpaperColors = {} -- recorded setWallpaperColor { hex=, target= }

function adapter.httpGet(url, headers, cb)
    fake.httpRequests[#fake.httpRequests + 1] = { url = url, headers = headers }
    local r = fake.httpResponses[url]
    return oneShot(function()
        if r then cb(r.status, r.body) else cb(0, nil) end
    end)
end

function adapter.httpRequest(url, method, headers, body, cb)
    fake.httpRequests[#fake.httpRequests + 1] =
        { url = url, method = method, headers = headers, body = body }
    local r = fake.httpResponses[url]
    return oneShot(function()
        if r then cb(r.status, r.body) else cb(0, nil) end
    end)
end

function adapter.httpPost(url, headers, body, cb)
    return adapter.httpRequest(url, "POST", headers, body, cb)
end

function adapter.downloadFile(url, path, cb)
    fake.downloads[#fake.downloads + 1] = { url = url, path = path }
    local ok = fake.downloadOk
    return oneShot(function() cb(ok) end)
end

function adapter.setWallpaper(path, mode)
    fake.wallpapers[#fake.wallpapers + 1] = path
    fake.wallpaperModes[#fake.wallpaperModes + 1] = mode
    return fake.wallpaperOk
end

function adapter.setWallpaperColor(hex, target)
    fake.wallpaperColors[#fake.wallpaperColors + 1] = { hex = hex, target = target }
    return true
end

function adapter.cacheDir()
    return "/tmp/hammerdeck-fake-cache"
end

function adapter.systemSleep()      fake.actions.sleep = fake.actions.sleep + 1 end
function adapter.lockScreen()       fake.actions.lock = fake.actions.lock + 1 end
function adapter.displaySleep()     fake.actions.displaySleep = fake.actions.displaySleep + 1 end
function adapter.startScreensaver() fake.actions.screensaver = fake.actions.screensaver + 1 end

-- Test drivers ------------------------------------------------------------------

-- Release every completion queued while fake.deferAsync was set (see oneShot).
-- Returns how many fired. A completion whose handle was stopped in the meantime
-- (feature disabled mid-flight) is dropped, exactly as the real bridge drops it.
function fake.deliverAsync()
    local queued = fake.pendingAsync
    fake.pendingAsync = {}
    for _, fire in ipairs(queued) do fire() end
    return #queued
end

-- Fire all live timers matching kind (and optionally n).
function fake.fireTimers(kind, n)
    local fired = 0
    -- snapshot: firing may create new timers
    local snapshot = {}
    for _, t in ipairs(fake.timers) do snapshot[#snapshot + 1] = t end
    for _, t in ipairs(snapshot) do
        if not t.stopped and t.kind == kind and (n == nil or t.n == n) then
            fired = fired + 1
            if kind == "after" then freeOnce(t) end   -- one-shot consumes itself
            t.fn()
        end
    end
    return fired
end

-- Fire hotkeys bound to `key`. With `mods` given, only exact (order-free)
-- modifier matches fire -- needed when the same key is bound under different
-- modifier sets (e.g. cmd+alt+ctrl+left vs ctrl+alt+left).
function fake.pressHotkey(key, mods)
    -- canonical (alias-folding) match, like Carbon's bitmask: a hotkey bound
    -- with {"command"} fires on a press described as {"cmd"}.
    local want = mods and modsKey(mods) or nil
    -- Snapshot before firing: real Carbon dispatches a key event only to the
    -- hotkeys registered AT event time, never to ones a handler registers mid-
    -- dispatch (e.g. entering a modal binds its keys -- including a "sticky" twin
    -- on the entry combo -- which must NOT be triggered by the same press).
    local live = {}
    for _, h in ipairs(fake.hotkeys) do live[#live + 1] = h end
    for _, h in ipairs(live) do
        if not h.stopped and not h.parked and h.key == key then
            if not want or modsKey(h.mods) == want then h.fn() end
        end
    end
end

-- Fire the key-UP edge: invokes the onRelease handler of matching hotkeys (for
-- testing hold / auto-repeat). Same matching rules as fake.pressHotkey.
function fake.releaseHotkey(key, mods)
    local want = mods and modsKey(mods) or nil
    local live = {}
    for _, h in ipairs(fake.hotkeys) do live[#live + 1] = h end
    for _, h in ipairs(live) do
        if not h.stopped and not h.parked and h.key == key and h.onRelease then
            if not want or modsKey(h.mods) == want then h.onRelease() end
        end
    end
end

local function sortedCopy(t)
    local c = {}
    for _, v in ipairs(t or {}) do c[#c + 1] = v end
    table.sort(c)
    return c
end

local function sameList(a, b, sortFirst)
    if sortFirst then a, b = sortedCopy(a), sortedCopy(b) end
    a, b = a or {}, b or {}
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- Simulate pressing the chord prefix (mods+key) then the follow-key sequence
-- `seq` (an array). Fires every live chord whose prefix combo matches (mods
-- order-independent) and whose follow sequence equals `seq` (order matters).
-- Returns how many fired.
function fake.fireChord(mods, key, seq)
    local fired = 0
    for _, c in ipairs(fake.chords) do
        if not c.stopped and c.key == key
            and sameList(c.mods, mods, true)
            and sameList(c.follows, seq, false) then
            fired = fired + 1
            c.fn()
        end
    end
    return fired
end

function fake.systemEvent(event)
    local snapshot = {}
    for _, w in ipairs(fake.watchers) do snapshot[#snapshot + 1] = w end
    for _, w in ipairs(snapshot) do
        if not w.stopped and w.event == event then w.fn() end
    end
end

function fake.openDialog()
    for i = #fake.dialogs, 1, -1 do
        if fake.dialogs[i].open then return fake.dialogs[i] end
    end
    return nil
end

function fake.openWindowPicker()
    for i = #fake.windowPickers, 1, -1 do
        if fake.windowPickers[i].open then return fake.windowPickers[i] end
    end
    return nil
end

function fake.openDisplayPicker()
    for i = #fake.displayPickers, 1, -1 do
        if fake.displayPickers[i].open then return fake.displayPickers[i] end
    end
    return nil
end

function fake.visibleChooser()
    for i = #fake.choosers, 1, -1 do
        if fake.choosers[i].visible then return fake.choosers[i] end
    end
    return nil
end

function fake.liveBanner()
    for i = #fake.banners, 1, -1 do
        if not fake.banners[i].stopped then return fake.banners[i] end
    end
    return nil
end

function fake.liveHud()
    for i = #fake.huds, 1, -1 do
        if not fake.huds[i].stopped then return fake.huds[i] end
    end
    return nil
end

function fake.openTextPrompt()
    for i = #fake.textPrompts, 1, -1 do
        if fake.textPrompts[i].open then return fake.textPrompts[i] end
    end
    return nil
end

function fake.liveProgressBar()
    for i = #fake.progressBars, 1, -1 do
        if not fake.progressBars[i].stopped then return fake.progressBars[i] end
    end
    return nil
end

-- Reset the EPHEMERAL scenario state so a preset one section leaves behind can't
-- silently corrupt the next. Call it at the TOP of a test section (see run.lua's
-- T20 / T24r) for a clean input slate. Clears the inputs a test sets up (windows,
-- frontmost app, idle, mouse, browser tabs, appearance, ...), the observation
-- queues it reads back (alerts, notifications, key events, recorded frames, ...),
-- and any `hammerdeck.opt.*` option overrides.
--
-- DELIBERATELY PRESERVED (these carry real state, not scratch, and resetting them
-- would break correctness or intentional continuity):
--   * fake.adapter -- the seam itself.
--   * the live-binding registries (timers / hotkeys / chords / watchers / choosers
--     / banners / huds / widgets / outlines / scrims / *Watchers ...) and
--     fake.liveHandles -- they MIRROR the actually-enabled platform, so clearing
--     them would orphan a still-enabled feature and desync the handle accounting.
--   * fake.files and the non-opt settings (hammerdeck.enabled.* / .state.*) --
--     sections carry these forward on purpose (e.g. T20 writes usage CSVs that T32
--     later reads; enabled-state persists across a disable/re-enable test).
--   * fake.clockOffset -- tests advance time deliberately; a reset-to-zero would
--     jump the clock backward mid-suite.
--   * fake.secrets -- the simulated login keychain.
function fake.reset()
    -- scenario inputs a test presets
    fake.idle          = 0
    fake.mousePos      = { x = 0, y = 0 }
    fake.modifiers     = {}
    fake.windows       = {}
    fake.focused       = {}
    fake.focusedWindow = nil
    fake.focusedWid    = nil
    fake.windowTitle   = nil
    fake.screenList    = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1, builtin = true } }
    fake.frontmost     = nil
    fake.frontmostId   = ""
    fake.runningApps        = {}
    fake.runningAppInfoList = {}
    fake.appearance    = "light"
    fake.power         = "ac"
    fake.axTrusted     = true
    fake.activeUrls    = {}
    fake.browserTabs   = {}
    fake.browserTabsByApp = {}
    fake.pasteboard          = nil
    fake.pasteboardConcealed = false
    fake.httpResponses = {}
    fake.chromeFavicons = {}
    fake.jumpUrlOverride = nil
    fake.failWindowFrameIds = {}
    fake.minimizeOk    = true
    fake.downloadOk    = true
    fake.wallpaperOk   = true
    fake.volumeReturn  = nil
    fake.systemNotifyDelivers = true

    -- observation queues (recorded outputs an assertion reads back)
    fake.notifications = {}
    fake.alerts        = {}
    fake.flashes       = {}
    fake.systemNotifications = {}
    fake.logs          = {}
    fake.keyEvents     = {}
    fake.typedTexts    = {}
    fake.openedUrls    = {}
    fake.windowFrames  = {}
    fake.windowFrameSets = {}
    fake.fullscreenSets  = {}
    fake.raises        = {}
    fake.axPrompts     = 0
    fake.axSettingsOpens = 0
    fake.activatedApps = {}
    fake.launchedApps  = {}
    fake.focusedTabs   = {}
    fake.openedNewTabs = {}
    fake.tabJumps      = {}
    fake.appWindows    = {}
    fake.siteOpens     = {}
    fake.refuseSiteOpen = false
    fake.minimized     = {}
    fake.hidden        = {}
    fake.quit          = {}
    fake.appearanceSet = {}
    fake.shortcutsRun  = {}
    fake.spokenTexts   = {}
    fake.mouseLocates  = {}
    fake.extractedBatches = {}
    fake.httpRequests  = {}
    fake.downloads     = {}
    fake.wallpapers    = {}
    fake.wallpaperModes = {}
    fake.wallpaperColors = {}
    fake.mediaKeys     = {}

    fake.resetOpts()   -- option overrides (below)
end

-- Clear ONLY the `hammerdeck.opt.*` option overrides, keeping enabled-state
-- (.enabled.*) and feature state (.state.*) -- and every other fixture (windows,
-- frontmost, files, ...) -- untouched. This is the LIGHT per-section isolator: an
-- option a section sets can't leak into the next, WITHOUT forcing that next
-- section to re-establish shared fixtures. Sections that own all their inputs use
-- the deep fake.reset() instead (see T20 / T24r).
function fake.resetOpts()
    for k in pairs(fake.settings) do
        if k:match("^hammerdeck%.opt%.") then fake.settings[k] = nil end
    end
end

-- DEEP reset for the hermetic case runner (RUN_LUA_SPLIT_SPEC R5): restore the
-- fake to its pristine load-time state -- everything fake.reset() clears PLUS the
-- state it deliberately preserves (the live-binding registries, fake.liveHandles,
-- fake.files, the full fake.settings incl. enabled/state, fake.secrets, the clock,
-- fake.featureNames). Called BETWEEN cases; the shallow fake.reset() / resetOpts()
-- above stay for intra-case continuity.
--
-- Implemented as snapshot-restore, NOT a hand-maintained field list: the fake's
-- ~100 state fields are declared inline across this whole file, so any explicit
-- clear-list would silently miss a newly-added field and leak it into the next
-- case. Snapshotting the module's load-time state (captured here, after every
-- top-level `fake.X = ...` has run) covers every field automatically and restores
-- non-empty defaults (screenList, volume, ...) for free.
local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = deepcopy(val) end
    return out
end
local pristine = {}
for k, v in pairs(fake) do
    if type(v) ~= "function" and k ~= "adapter" then pristine[k] = deepcopy(v) end
end
function fake.resetWorld()
    -- drop every captured (data) field, then restore the pristine snapshot; a
    -- field created lazily mid-case (never present at load) is dropped -> absent,
    -- exactly as on a fresh boot.
    for k, v in pairs(fake) do
        if type(v) ~= "function" and k ~= "adapter" then fake[k] = nil end
    end
    for k, v in pairs(pristine) do fake[k] = deepcopy(v) end
    -- canonicalize the ephemeral inputs/queues uniformly (mousePos and a few
    -- others are established only by reset(), not at top-level declaration).
    fake.reset()
end

return fake
