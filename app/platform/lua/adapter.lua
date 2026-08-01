-- platform/adapter.lua
--
-- THE SEAM (Lua side). This is the only Lua file in the project allowed to
-- talk to the backend -- the `native` table the Swift host (Native.swift)
-- injects as a global. Every feature and every other platform module calls
-- `adapter.*` instead. NO hs.* anywhere: Hammerspoon was dropped as a backend
-- on 2026-06-10 -- Hammerdeck is a standalone native app from the start.
--
-- Handle contract: every method that creates a live binding (hotkey, timer,
-- watcher, chooser, dialog, banner) returns a plain table with `.stop()`.
-- Native bindings return integer resource ids; `native.stop(id)` cancels and
-- is idempotent on the Swift side. platform/ctx.lua layers scoped tracking on
-- top of these handles.

assert(type(native) == "table",
    "adapter: the `native` bridge is missing -- run inside the Hammerdeck host (swift run)")

local adapter = {}

local function handleFor(id)
    return { stop = function() native.stop(id) end }
end

-- ---------------------------------------------------------------------------
-- Triggers / bindings
-- ---------------------------------------------------------------------------

-- mods: table like {"cmd","alt"}; key: string like "h"; fn: function fired on
-- press. onRelease (optional): fired on the key-up edge -- the basis for
-- hold/auto-repeat (Carbon delivers no repeats while a key is held).
-- `shadow` (optional): when true, this binding SHADOWS any standalone hotkey on
-- the same combo for its lifetime (parked on bind, restored on stop) -- used by a
-- modal's "sticky" keys so the leader's modifiers held through a bare key win over
-- the global on that combo. See Native+Triggers.bindHotkey / ChordCenter.
function adapter.bindHotkey(mods, key, fn, onRelease, shadow)
    return handleFor(native.bind_hotkey(mods or {}, key, fn, onRelease, shadow))
end

-- A chord: mods+key is the PREFIX hotkey; `follows` is the ordered sequence of
-- bare keys pressed after it (e.g. {"b"} for cmd+shift+a then b, or {"b","c"}).
-- Permission-free: the prefix is a normal global hotkey, and the follow keys
-- are registered transiently only while the prefix has armed the chord mode.
-- `label` (optional): the action's human name, shown in the which-key hint that
-- appears after the prefix arms (so a chord menu is discoverable, not memorized).
-- `icon` (optional): its SF Symbol name, rendered as the hint row's leading glyph.
function adapter.bindChord(mods, key, follows, fn, label, icon)
    return handleFor(native.bind_chord(mods or {}, key, follows or {}, fn, label, icon))
end

function adapter.everySeconds(n, fn)
    return handleFor(native.timer_every(n, fn))
end

function adapter.afterSeconds(n, fn)
    return handleFor(native.timer_after(n, fn))
end

function adapter.dailyAt(timeStr, fn)
    return handleFor(native.timer_daily_at(timeStr, fn))
end

-- Subscribe to a system event. Edges (a human may or may not be present):
-- "sleep","wake","screenLock","screenUnlock","screenChanged", plus the
-- coarse re-read triggers behind the state signals:
-- "appearanceChanged","appsChanged","powerChanged".
function adapter.onSystemEvent(event, fn)
    return handleFor(native.on_system_event(event, fn))
end

-- State-signal reads (each paired with an onSystemEvent above; see signals.lua).
-- System appearance: "dark" | "light".
function adapter.appearance()
    return native.appearance()
end

-- { name, bundleId } of every running regular app (the runningApps signal's value
-- set), read so a "launches/quits X" rule matches on the stable bundle id, not the
-- locale-sensitive name (cf. frontmostAppInfo).
function adapter.runningAppsInfo()
    return native.running_apps_info()
end

-- Power source: "ac" (plugged in) | "battery".
function adapter.powerSource()
    return native.power_source()
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function adapter.getSetting(key, default)
    local v = native.get_setting(key)
    if v == nil then return default end
    return v
end

function adapter.setSetting(key, value)
    native.set_setting(key, value)
end

-- ---------------------------------------------------------------------------
-- Secrets (login Keychain; never plaintext UserDefaults)
-- ---------------------------------------------------------------------------
-- `key` is the full account string -- features reach these only via ctx.secret,
-- which namespaces it as hammerdeck.opt.<id>.<key> (same namespace the Settings
-- UI writes through SettingsStore's KeychainStore).

function adapter.secretGet(key)
    return native.keychain_get(key)
end

function adapter.secretSet(key, value)
    return native.keychain_set(key, value)
end

function adapter.secretDelete(key)
    return native.keychain_delete(key)
end

-- The user's currently-enabled macOS system shortcuts, as hotkey-shaped specs
-- { mods = {...}, key = "...", name = "..." }. READ-ONLY: macOS owns these
-- (com.apple.symbolichotkeys); the config UI uses them only to warn before a
-- binding collides with Spotlight, input-source switching, etc. Returns {} on a
-- backend (test fake / older host) that does not expose the call.
function adapter.systemHotkeys()
    if type(native.system_hotkeys) ~= "function" then return {} end
    return native.system_hotkeys() or {}
end

-- ---------------------------------------------------------------------------
-- Clipboard (general pasteboard; no permission required)
-- ---------------------------------------------------------------------------

-- Returns the clipboard's plain-text contents, or nil if empty/non-text.
function adapter.pasteboardRead()
    return native.pasteboard_read()
end

function adapter.pasteboardWrite(text)
    native.pasteboard_write(text)
end

-- { change = <changeCount>, concealed = bool } -- change detection without
-- reading contents; concealed marks password-manager/transient entries that
-- a clipboard history must not record.
function adapter.pasteboardInfo()
    return native.pasteboard_info()
end

-- ---------------------------------------------------------------------------
-- Output / notifications
-- ---------------------------------------------------------------------------

function adapter.notify(title, text)
    native.notify(title, text)
end

-- Post to the macOS Notification Center (vs adapter.notify's in-app banner).
-- Returns whether it was delivered -- false when there is no app bundle (dev
-- `swift run`), so the caller can fall back to the in-app banner.
function adapter.systemNotify(title, text)
    return native.system_notify(title, text)
end

function adapter.alert(text)
    native.alert(text)
end

-- A brief single-slot "flash" chip (SF Symbol glyph + one line, top-center,
-- ~1.4s, replaces any prior flash) -- the QUIET confirmation that a manual
-- shortcut fired and WHICH action it ran. Distinct from notify's stacking
-- top-right card: this is at-keyboard feedback, meant to fire-and-fade.
function adapter.flash(symbol, text)
    native.flash(symbol, text)
end

function adapter.log(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    native.log(table.concat(parts, " "))
end

-- ---------------------------------------------------------------------------
-- UI: chooser (searchable picker), choice dialog, banner overlay
-- ---------------------------------------------------------------------------

-- A raw searchable picker. opts:
--   onSelect(choice|nil)  -- choice is the table from setChoices
--   onHide()              -- optional
--   searchSubText = bool  -- optional
-- Choice tables: { text=, subText=, image=<icon token>, id=, valid= }
-- The bridge passes row INDICES; the choices table stays on the Lua side.
function adapter.chooser(opts)
    local choicesCache = {}
    local id = native.chooser_new(
        opts.searchSubText == true,
        function(idx)
            if opts.onSelect then opts.onSelect(idx and choicesCache[idx] or nil) end
        end,
        function()
            if opts.onHide then opts.onHide() end
        end)
    local h = {}
    function h.setPlaceholder(t)  native.chooser_set_placeholder(id, t) end
    -- title plus optional leading SF Symbol + right-flush badge (e.g. a count)
    function h.setTitle(t, symbol, badge) native.chooser_set_title(id, t, symbol, badge) end
    function h.setChoices(list)   choicesCache = list; native.chooser_set_choices(id, list) end
    function h.show()             native.chooser_show(id) end
    function h.hide()             native.chooser_hide(id) end
    function h.isVisible()        return native.chooser_visible(id) end
    function h.getSelectedRow()   return native.chooser_selected_row(id) end
    function h.setSelectedRow(n)  native.chooser_set_selected_row(id, n) end
    -- Step the selection by delta over the VISIBLE (filtered) rows: wraps at
    -- either end and skips non-selectable info rows -- the same move the
    -- panel's own tab / option-arrow keys make. Prefer this over hand-rolled
    -- setSelectedRow wrap math, which cannot see the filtered row count.
    function h.step(delta)        native.chooser_step(id, delta) end
    function h.select(n)          native.chooser_select(id, n) end
    function h.setQuery(q)        native.chooser_set_query(id, q) end
    function h.getQuery()         return native.chooser_query(id) end
    function h.stop()             native.stop(id) end
    return h
end

-- A one-shot "pick an action" dialog. opts:
--   title    = placeholder text
--   infos    = { "info line", ... }   -- non-selectable context rows
--   actions  = { "Action A", ... }    -- selectable rows; each entry is either a
--              plain label string OR a table { id = "...", label = "...",
--              icon = "<token>" } where icon is an icon token
--              ("symbol:moon.stars", "appicon:...", "file:...").
--   onChoose(choiceId|nil, label)     -- nil = dismissed without choosing
--
-- WHAT onChoose RECEIVES, and why it is NOT the label (CODE-12). `choiceId` is
-- the entry's `id` when it declares one, else its 1-based INDEX -- never the
-- display text. Callers dispatch on a value they control, which cannot change
-- when a string is translated, retitled, or interpolated.
--
-- The bridge has always handed back the index; this used to map it into the
-- label right here, which pushed every caller into comparing translated strings
-- (`if choice == snoozeLabel`) or keeping a private label->entry map. That is
-- silent when it breaks: two rows whose translations collide dispatch to
-- whichever the map saw last, and a label that gains a formatted value stops
-- matching itself. Passing the id makes the whole class unrepresentable, and the
-- label rides along second for logs and display.
function adapter.askChoice(opts)
    local raw = opts.actions or {}
    local labels, ids, items = {}, {}, {}
    for i, a in ipairs(raw) do
        if type(a) == "table" then
            labels[i] = a.label or a.text or ""
            -- No `id` declared -> the index. Never the label: falling back to it
            -- would quietly reinstate exactly what this change removes.
            ids[i] = a.id ~= nil and a.id or i
            items[i] = { text = labels[i], image = a.icon }
        else
            labels[i] = a
            ids[i] = i
            items[i] = { text = a }
        end
    end
    local id = native.ask_choice(
        opts.title or "",
        opts.infos or {},
        items,
        function(idx)
            if opts.onChoose then
                if idx then opts.onChoose(ids[idx], labels[idx]) else opts.onChoose(nil) end
            end
        end)
    return {
        dismiss = function() native.ask_choice_dismiss(id) end,
        stop    = function() native.stop(id) end,
    }
end

-- A one-shot MULTI-SELECT picker: a titled, checkboxed list, every row
-- pre-checked; the user unchecks the ones to leave out, then confirms. opts:
--   title   = header text
--   items   = { { text=, subText=, image=<icon token>, color=<"#RRGGBB">,
--                 <caller payload...> }, ... } -- color (optional) previews the
--               window's border color as a trailing dot the user can CLICK to
--               recolor (cycles `palette`)
--   min     = minimum rows that must stay checked to confirm (default 1)
--   palette = { "#RRGGBB", ... } cycle order for recoloring (empty/nil = no dots)
--   onChoose(kept|nil)  -- kept = array of the CHECKED item tables (the caller's
--                          payload intact, `color` updated to the user's pick);
--                          nil = cancelled / clicked away
-- The bridge passes CHECKED row INDICES + per-row colors; the items table stays
-- Lua-side (same split as adapter.chooser). The dialog frees itself after
-- completion.
function adapter.askWindows(opts)
    local items = opts.items or {}
    local display = {}
    for i, it in ipairs(items) do
        display[i] = { text = it.text or "", subText = it.subText,
                       image = it.image, color = it.color }
    end
    local function onPick(indices, colors, heroOn)
        if not opts.onChoose then return end
        if not indices then return opts.onChoose(nil, heroOn) end
        local kept = {}
        for _, idx in ipairs(indices) do
            local it = items[idx]
            if colors and colors[idx] and colors[idx] ~= "" then it.color = colors[idx] end
            kept[#kept + 1] = it
        end
        opts.onChoose(kept, heroOn)
    end
    -- `opts.heroLabel` (a non-empty string) OPTS IN to a switch row (Window
    -- Deck's Hero mode); omit it for a plain picker. `opts.hero` (default true)
    -- is that switch's initial state; the bridge returns its final state as the
    -- 3rd onPick arg. `opts.screen` ({x,y,w,h} top-left global, e.g. a
    -- ctx.screen.frames() row) centers the picker on THAT display -- the caller
    -- may be acting on a screen that doesn't hold key focus (the deck's target).
    local id
    local heroLabel = opts.heroLabel or ""
    local hero = opts.hero ~= false
    if opts.screen then
        id = native.ask_windows(opts.title or "", display, opts.min or 1,
            opts.palette or {}, onPick, heroLabel, hero,
            opts.screen.x, opts.screen.y, opts.screen.w, opts.screen.h)
    else
        id = native.ask_windows(opts.title or "", display, opts.min or 1,
            opts.palette or {}, onPick, heroLabel, hero)
    end
    return {
        stop = function() native.stop(id) end,
    }
end

-- One-shot SPATIAL display picker (DisplayPickerPanel): draws every display at
-- its real relative position (name + resolution + window count) and returns the
-- displays the user selects. Reusable across features (Window Snap's swap picks
-- 2; a "which display?" pick like Window Deck's target picks 1). opts:
--   displays    = { {x,y,w,h,name,windows}, ... } -- e.g. ctx.screen.frames()
--                 rows, each optionally tagged with a `windows` count to show
--   preselect   = { idx, ... } 1-based defaults; pass the "sticky" one LAST (it
--                 survives when the user clicks a new pick -- e.g. the active
--                 display for a swap)
--   selectCount = how many displays must be picked to confirm (default 1)
--   title       = header text
--   prompt      = one/two-line explanation under the title
--   confirmVerb = the confirm button's verb, e.g. "Swap" / "Deck on"
--   extraLabel  = optional secondary-action button label (nil/"" = none), e.g.
--                 "Restore last deck (3 windows)"
--   onPick(indices|nil) -- the chosen displays' 1-based indices (array), or nil
--   onExtra()   -- the secondary action button was pressed
-- Returns a handle with .stop() (a one-shot: it frees itself on pick/cancel).
function adapter.pickDisplays(opts)
    return handleFor(native.display_picker(
        opts.displays or {},
        opts.preselect or {},
        opts.selectCount or 1,
        opts.title or "",
        opts.prompt or "",
        opts.confirmVerb or "Select",
        opts.extraLabel or "",
        function(indices, extra)
            if extra then
                if opts.onExtra then opts.onExtra() end
            elseif opts.onPick then
                opts.onPick(indices)
            end
        end))
end

-- Full-width banner overlay along a screen's top edge. `screenFrame`
-- (optional, a {x,y,w,h} top-left-global rect -- e.g. a ctx.screen.frames()
-- row) pins the banner to THAT screen; without it the banner falls to the
-- key window's screen, which is wrong whenever the caller acts on a screen
-- that doesn't hold key focus (Window Deck's picked target screen).
-- Returns { setText(t), stop() }.
function adapter.banner(text, screenFrame)
    local id
    if screenFrame then
        id = native.banner_show(text or "", screenFrame.x, screenFrame.y,
                                screenFrame.w, screenFrame.h)
    else
        id = native.banner_show(text or "")
    end
    return {
        setText = function(t) native.banner_set_text(id, t) end,
        stop    = function() native.stop(id) end,
    }
end

-- Structured HUD card (a spatial cheat-sheet, e.g. Window Mode). `spec` is a
-- plain table: { title, cells = {{col,row,keys,label?,state?}, ...}, caption,
-- groups = {{label, keys}, ...}, footer }. Returns { stop(), update(newSpec) }.
-- update() re-renders the SAME card in place (e.g. window_grid highlighting the
-- picked corner + dimming the invalid cells after the first press).
function adapter.hud(spec)
    local id = native.hud_show(spec or {})
    return {
        stop   = function() native.stop(id) end,
        update = function(newSpec) native.hud_update(id, newSpec or {}) end,
    }
end

-- One-shot text prompt: Enter submits the string, Escape cancels (nil). opts:
--   title, placeholder, default, onSubmit(text|nil)
function adapter.askText(opts)
    local id = native.ask_text(
        opts.title or "", opts.placeholder or "", opts.default or "",
        function(text)
            if opts.onSubmit then opts.onSubmit(text) end
        end)
    return {
        dismiss = function() native.ask_text_dismiss(id) end,
        stop    = function() native.stop(id) end,
    }
end

-- A click-through accent BORDER drawn around a window region (Window Deck's
-- member/hero/ghost markers). `kind` styles it: "member" (subtle), "hero"
-- (strong), "ghost" (faint dashed). `f` is a top-left-origin global-points rect
-- (same coordinate system as setWindowFrame). Returns { setFrame(f),
-- setStyle(kind), stop() } -- setStyle re-styles in place (member -> hero on
-- promote) without recreating the panel.
function adapter.outline(kind, color)
    local id = native.outline_show(kind or "member", color or "")
    return {
        setFrame = function(f) native.outline_set_frame(id, f.x, f.y, f.w, f.h) end,
        -- Fly the border smoothly to `f` over `dur` seconds (the ring flight);
        -- real windows can't tween, but this overlay is our own window.
        animateFrame = function(f, dur)
            native.outline_animate_frame(id, f.x, f.y, f.w, f.h, dur or 0.15)
        end,
        setStyle = function(k) native.outline_set_style(id, k) end,
        setColor = function(c) native.outline_set_color(id, c) end,
        -- Fill the interior translucently (Window Fan's tab) or clear it.
        setFilled = function(on) native.outline_set_filled(id, on and true or false) end,
        -- Occlusion: draw only inside these visible rects (top-left global), or
        -- clearClip() for a full unclipped border. Window Fan passes a window's
        -- frame minus everything in front of it.
        setClip   = function(rects) native.outline_set_clip(id, rects or {}) end,
        clearClip = function() native.outline_clear_clip(id) end,
        -- Hide without destroying; the next setFrame/animateFrame re-shows.
        -- (Window Deck hides a ring while the user drags its window -- live
        -- tracking would trail the drag -- and re-shows it once stable.)
        hide     = function() native.outline_hide(id) end,
        -- Clip the stroke out of rect `f` (nil clears): the overlays float above
        -- every normal window, so without this a border whose region runs under
        -- the hero would draw its lines ACROSS the hero.
        setHole  = function(f)
            if f then native.outline_set_hole(id, f.x, f.y, f.w, f.h)
            else native.outline_set_hole(id) end
        end,
        stop     = function() native.stop(id) end,
    }
end

-- The Window Deck "container" surface: a full-screen DIM scrim on `screenFrame`
-- (a {x,y,w,h} top-left-global rect, e.g. a ctx.screen.frames() row) with a HOLE
-- punched for each deck window. The deck windows show through their holes; every
-- other window is dimmed behind it. `dim` is 0..1 (scrim alpha). `holes` is an
-- array of {x,y,w,h} top-left-global rects. The deck's title/exit affordance is
-- a SEPARATE draggable card (adapter.deckWidget). Replaces adapter.banner for
-- the deck; both re-anchor on display change so neither can be orphaned to
-- another screen. Returns { setHoles, setDim, reanchor, hide, show, stop }.
function adapter.scrim(screenFrame, dim)
    local id
    if screenFrame then
        id = native.scrim_show(screenFrame.x, screenFrame.y,
                               screenFrame.w, screenFrame.h, dim or 0.5)
    else
        id = native.scrim_show(nil, nil, nil, nil, dim or 0.5)
    end
    return {
        setHoles  = function(rects) native.scrim_set_holes(id, rects or {}) end,
        setDim    = function(d) native.scrim_set_dim(id, d) end,
        reanchor  = function(f) native.scrim_reanchor(id, f.x, f.y, f.w, f.h) end,
        hide      = function() native.scrim_hide(id) end,
        show      = function() native.scrim_show_again(id) end,
        stop      = function() native.stop(id) end,
    }
end

-- The Window Deck control card: a small DRAGGABLE floating card (grid glyph +
-- `title` + optional `· name` + a Hero toggle + a "⌥esc Exit" button + a mini-map
-- switcher row + a "Rearrange" button) floating above the scrim. `opts`:
-- { title, hint, name, switchHint, heroLabel, exitLabel, rearrangeLabel (button
-- text -- i18n), pos = {x,y} top-left-global corner, screen = {x,y,w,h} deck
-- screen (drag clamp), switcher = { cols, colors = {"#..",...} row-major, hero =
-- 1-based lit cell or 0, onSwitch(i) }, hero = initial Hero toggle (true
-- default), onToggleHero(bool), onRearrange(), onMove(x,y), onExit() }.
-- Returns { reanchor(pos, screen), setHero(i), setDirty(bool), setSwitchHint(t),
-- setCells(colors, dead, cols), hide, show, stop }.
-- setCells recolors the mini-map (after a drag-swap); `dead` is a parallel array
-- of booleans marking cells whose window has closed (drawn hollow + dashed, and
-- inert -- no click, no drag); `cols` is OPTIONAL and only needed when the cell
-- COUNT changes (a reflow after a close) -- passing it rebuilds the mini-map at
-- the new geometry, omitting it leaves the current grid alone.
-- Passed as ONE table (deck_widget_show is field-read Swift-side, not ~20
-- positional args).
function adapter.deckWidget(opts)
    opts = opts or {}
    local pos, scr = opts.pos or {}, opts.screen or {}
    local swi = opts.switcher or {}
    local id = native.deck_widget_show({
        title = opts.title or "", hint = opts.hint or "", name = opts.name or "",
        switchHint = opts.switchHint or "",
        heroLabel = opts.heroLabel or "Hero", exitLabel = opts.exitLabel or "Exit",
        rearrangeLabel = opts.rearrangeLabel or "Rearrange",
        x = pos.x or 20, y = pos.y or 20,
        sx = scr.x or 0, sy = scr.y or 0, sw = scr.w or 1440, sh = scr.h or 900,
        gridCols = swi.cols or 2, heroIndex = swi.hero or 0, colors = swi.colors or {},
        heroOn = opts.hero ~= false,
        onMove = opts.onMove or function() end,
        onExit = opts.onExit or function() end,
        onSwitch = swi.onSwitch or function() end,
        onToggleHero = opts.onToggleHero or function() end,
        onRearrange = opts.onRearrange or function() end,
        onReorder = swi.onReorder or function() end,
    })
    return {
        reanchor = function(p, s)
            native.deck_widget_reanchor(id, p.x, p.y, s.x, s.y, s.w, s.h)
        end,
        setHero = function(i) native.deck_widget_set_hero(id, i or 0) end,
        setDirty = function(d) native.deck_widget_set_dirty(id, d and true or false) end,
        setSwitchHint = function(t) native.deck_widget_set_switch_hint(id, t or "") end,
        setCells = function(colors, dead, cols)
            native.deck_widget_set_cells(id, colors or {}, dead or {}, cols)
        end,
        hide = function() native.deck_widget_hide(id) end,
        show = function() native.deck_widget_show_again(id) end,
        stop = function() native.stop(id) end,
    }
end

-- Thin progress strip along the bottom of the main screen.
-- Returns { setProgress(fraction 0..1), stop() }.
function adapter.progressBar()
    local id = native.progress_show()
    return {
        setProgress = function(f) native.progress_set(id, f) end,
        stop        = function() native.stop(id) end,
    }
end

-- Desktop-pinned usage stats card (bottom-left, above wallpaper, below all
-- windows, click-through). screenIndex: 1 = primary (default), 2 = secondary
-- when present. Returns { setData(data), stop() }; data is the typed table
-- usage_stats computes (total/updated/avg/apps/week/weekTotal).
function adapter.usageWidget(screenIndex)
    local id = native.usage_widget_show(screenIndex or 1)
    return {
        setData = function(d) native.usage_widget_set(id, d) end,
        stop    = function() native.stop(id) end,
    }
end

-- Window Fan's DRAGGABLE switcher card: a floating list of the fan's windows, each
-- row an edge-swatch (color + exposed side) + app icon + title, the focused one lit.
-- opts = { title, count (strings); pos = {x,y} top-left global; screen = {x,y,w,h};
-- rows = { {color, side, title, bundleID, focused}, ... };
-- onMove(x,y), onExit(), onSwitch(i) }. Returns { setRows(rows, count),
-- reanchor(pos, screen), stop() }.
function adapter.fanWidget(opts)
    opts = opts or {}
    local pos, scr = opts.pos or {}, opts.screen or {}
    local id = native.fan_widget_show({
        title = opts.title or "", count = opts.count or "",
        x = pos.x or 40, y = pos.y or 60,
        sx = scr.x or 0, sy = scr.y or 0, sw = scr.w or 1440, sh = scr.h or 900,
        rows = opts.rows or {},
        onMove = opts.onMove or function() end,
        onExit = opts.onExit or function() end,
        onSwitch = opts.onSwitch or function() end,
    })
    return {
        setRows = function(rows, count) native.fan_widget_set(id, rows or {}, count or "") end,
        reanchor = function(p, s)
            native.fan_widget_reanchor(id, p.x, p.y, s.x, s.y, s.w, s.h)
        end,
        stop = function() native.stop(id) end,
    }
end

-- ---------------------------------------------------------------------------
-- Windows / apps
-- ---------------------------------------------------------------------------

-- All standard windows, most-recently-focused first: { id, wid, title,
-- appName, bundleID, x, y, w, h, minimized, fullscreen, screenName? } rows
-- (frame in top-left-origin global points -- the layout engine snapshots it).
-- `id` is valid only until the next list; `wid` is the OS-stable CGWindowID
-- (0 = unresolved), the key for long-lived identity (it survives retitles).
-- Minimized/fullscreen windows ARE listed (with their normal frames) --
-- layout features filter them out. Returns {} when the Accessibility
-- permission is missing -- check axTrusted()/axPrompt() to onboard.
function adapter.listWindows()
    return native.list_windows()
end

--- Bundle ids whose windows are MISSING from the most recent listWindows()
--- because their app did not answer AX in time (empty on a clean listing).
---
--- Absence from a listing is ambiguous -- closed and unanswered look the same --
--- so a caller tracking windows ACROSS listings must consult this before
--- concluding a window is gone.
---@return string[]
function adapter.windowsDroppedApps()
    return native.windows_dropped_apps()
end

-- Focus a window by an id from the MOST RECENT listWindows() call.
function adapter.focusWindow(id)
    return native.focus_window(id)
end

-- Raise a listed window above others WITHOUT activating its app -- a pure window-
-- level AXRaise. Verified surgical (z-order probe): no same-app-sibling drag
-- (same- or cross-screen), no app activation (so it never trips the focus
-- observer), and it can't beat the currently-active window (so a focused hero
-- stays on top). Window Deck keeps the deck above non-deck windows with this.
-- Id from the MOST RECENT listWindows(). Returns true on success.
function adapter.raiseWindow(id)
    return native.raise_window(id) == true
end

-- Is this process trusted for Accessibility (window listing/focus)?
function adapter.axTrusted()
    return native.ax_trusted() == true
end

-- ---------------------------------------------------------------------------
-- Focused-window frame surface (Accessibility). ONE coordinate system:
-- top-left-origin global points; screen rects are VISIBLE frames.
-- ---------------------------------------------------------------------------

-- nil when there is no focused window (or no permission); else
-- { x,y,w,h, fullscreen, screenIndex, screen = {x,y,w,h} }.
function adapter.focusedWindowFrame()
    return native.focused_window_frame()
end

-- Title of the focused window, or nil (no window / no permission).
function adapter.focusedWindowTitle()
    return native.focused_window_title()
end

function adapter.setFocusedWindowFrame(f)
    return native.set_focused_window_frame(f.x, f.y, f.w, f.h) == true
end

-- Move ANY window by an id from the MOST RECENT listWindows() call (the layout
-- engine lists, matches, then places each match). Same coordinate system as
-- setFocusedWindowFrame. Returns true on success.
function adapter.setWindowFrame(id, f)
    return native.set_window_frame(id, f.x, f.y, f.w, f.h) == true
end

function adapter.setFocusedWindowFullscreen(on)
    return native.set_focused_window_fullscreen(on == true) == true
end

-- App-target window actions (by localizedName). The rules minimizeApp / hideApp /
-- quitApp effects drive these. Each returns true on success.
function adapter.minimizeApp(name)
    return native.minimize_app(name) == true
end

function adapter.hideApp(name)
    return native.hide_app(name) == true
end

function adapter.quitApp(name)
    return native.quit_app(name) == true
end

-- Set the SYSTEM appearance. `mode` is "dark" | "light" | "toggle". Backs the
-- `setAppearance` rules effect; uses System Events (first run prompts for Automation).
function adapter.setAppearance(mode)
    return native.set_appearance(mode) == true
end

-- Visible frame of every screen (primary first): { x,y,w,h, name, index, builtin }
-- rows; screenIndex indexes this. `name` is the display's localizedName -- the
-- layout engine targets a display by it; `builtin` is true for the laptop's own
-- panel (capture skips it to keep only external displays).
function adapter.screenFrames()
    return native.screen_frames()
end

function adapter.mousePosition()
    return native.mouse_position()
end

function adapter.setMousePosition(x, y)
    native.set_mouse_position(x, y)
end

-- Show the system Accessibility prompt if untrusted; returns trusted state.
function adapter.axPrompt()
    return native.ax_prompt() == true
end

-- Open System Settings directly to Privacy & Security > Accessibility. The system
-- prompt only appears once per app, so this guarantees the "Grant" click always
-- lands the user on the right pane.
function adapter.axOpenSettings()
    native.ax_open_settings()
end

-- Opaque icon token usable as `image` in chooser choices.
function adapter.appIcon(bundleID)
    return native.app_icon(bundleID)
end

-- Bare names of feature modules found in `dir` (the registry prefixes
-- "features." and loads them). Platform-only -- not exposed through ctx.
function adapter.discoverFeatures(dir)
    return native.discover_features(dir)
end

-- Name of the frontmost application, or nil.
function adapter.frontmostApp()
    return native.frontmost_app()
end

-- { name, bundleId } of the frontmost app (each "" if none) -- the frontmostApp
-- signal reads this to match on the stable bundle id, not the locale-sensitive name.
function adapter.frontmostAppInfo()
    return native.frontmost_app_info()
end

-- The user-visible app display name (e.g. "Hammerdeck"). Single source of truth
-- shared with Swift -- features compose "<app> needs Accessibility" off ctx.appName.
function adapter.appName()
    return native.app_name()
end

-- The resolved UI locale code (e.g. "en", "zh-Hans"). The Swift LocaleResolver
-- is the single authority (in-app override -> macOS preferred languages matched
-- against the shipped catalogs -> "en"); the bootstrap feeds this into the Lua
-- i18n module so both languages localize against the same code.
function adapter.locale()
    return native.locale()
end

-- Subscribe to app activations: fn(appName) fires whenever an application
-- becomes frontmost. No permission required (NSWorkspace notification).
function adapter.onAppActivated(fn)
    return handleFor(native.on_app_activated(fn))
end

-- The { name, bundleId } twin of onAppActivated -- fn({name, bundleId}) on each
-- activation. Used by the frontmostApp signal so it matches on the bundle id.
function adapter.onAppActivatedInfo(fn)
    return handleFor(native.on_app_activated_info(fn))
end

-- Subscribe to focused-WINDOW changes: fn() fires (a bare pulse, no payload)
-- whenever the frontmost app's focused window changes -- the within-app switch
-- (cmd+`) that onAppActivated (app-level) can't see. The native observer swaps
-- to the newly-frontmost app on each activation, so subscribing to BOTH covers
-- every focus move. Needs Accessibility (AXObserver). Window Deck is the caller.
function adapter.onFocusedWindowChanged(fn)
    return handleFor(native.on_focused_window_changed(fn))
end

-- Subscribe to window move/resize for the given apps: fn(info) fires with
-- { bundleID, title, wid, x, y, w, h } (top-left global points; wid = the
-- stable CGWindowID, 0 when unresolvable) each time a window of one of
-- `bundleIds` moves or resizes. Fires for the caller's OWN AX moves too --
-- callers guard their own echoes. Needs Accessibility (AXObserver).
-- Window Deck uses it to hide a ring while the user drags/resizes the window.
function adapter.onWindowFramesChanged(bundleIds, fn)
    return handleFor(native.on_window_frames_changed(bundleIds or {}, fn))
end

-- The FOCUSED window's stable CGWindowID (0 = unresolvable). Matches the
-- `wid` field on listWindows rows, so a caller can key identity on it
-- without touching the retitle-prone window title. Needs Accessibility.
function adapter.focusedWindowWid()
    return native.focused_window_wid()
end

-- ---------------------------------------------------------------------------
-- Data files (durable feature-owned storage; cacheDir may be purged by the OS)
-- ---------------------------------------------------------------------------

function adapter.dataDir()
    return native.data_dir()
end

-- The user's home directory -- a feature resolves a user-visible storage path
-- (e.g. ~/.computer-usage) off this without touching the OS itself.
function adapter.homeDir()
    return native.home_dir()
end

function adapter.mkdir(path)
    return native.mkdir(path)
end

-- Delete `base/rel` -- the retention sweep's curated tool; there is
-- deliberately no general delete. `base` must resolve inside the user's home
-- tree (a path outside it is refused), `rel` is relative with no traversal.
-- Pass dataDir() for app-internal data, or a feature's configured durable dir.
function adapter.removeSubdir(base, rel)
    return native.remove_subdir(base, rel) == true
end

-- Plain text file helpers. Implemented with Lua's io here IN THE ADAPTER (the
-- seam may touch the OS); features go through ctx so headless tests can fake
-- the filesystem entirely.

function adapter.fileRead(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- Atomic full-file write: write to a sibling temp file, then rename it over the
-- target. rename(2) is atomic on the same filesystem, so a crash or error
-- mid-write can never truncate or blank an existing file -- a reader always sees
-- either the old contents or the complete new ones, never a half-written file.
-- The temp lives beside the target to guarantee the same volume. This is the
-- durability net for every full-rewrite caller (usage_stats' per-flush apps CSV,
-- tab_switcher's MRU, clipboard history) -- no git/snapshot dependency needed.
function adapter.fileWrite(path, text)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false end
    local okWrite = f:write(text)
    local okClose = f:close()
    if not (okWrite and okClose) then
        os.remove(tmp)
        return false
    end
    if not os.rename(tmp, path) then
        os.remove(tmp)
        return false
    end
    return true
end

-- Appends line + "\n".
function adapter.fileAppend(path, line)
    local f = io.open(path, "a")
    if not f then return false end
    f:write(line .. "\n")
    f:close()
    return true
end

function adapter.fileExists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

-- ---------------------------------------------------------------------------
-- Network / files / wallpaper
-- ---------------------------------------------------------------------------

-- Async GET; cb(status, body|nil). Returns a HANDLE: stop() cancels the transfer
-- and drops the callback, so a feature torn down mid-flight never hears back.
-- ctx tracks it in the feature's scope, which is what makes "disabled" mean
-- disabled (bing_daily chains httpGet -> downloadFile -> setWallpaper; before
-- this, disabling it mid-chain still changed the wallpaper).
---@return { stop: fun() }
function adapter.httpGet(url, headers, cb)
    return handleFor(native.http_get(url, headers or {}, cb))
end

-- Async request with an explicit method/body; cb(status, body|nil). Same
-- cancelable-handle contract as httpGet. `body` is a string (e.g. a JSON
-- payload); pass Content-Type / Authorization via the headers table.
---@return { stop: fun() }
function adapter.httpRequest(url, method, headers, body, cb)
    return handleFor(native.http_request(url, method or "GET", headers or {}, body, cb))
end

-- Convenience POST over adapter.httpRequest; cb(status, body|nil).
---@return { stop: fun() }
function adapter.httpPost(url, headers, body, cb)
    return handleFor(native.http_request(url, "POST", headers or {}, body, cb))
end

-- Async download straight to `path` (binary-safe); cb(ok).
---@return { stop: fun() }
function adapter.downloadFile(url, path, cb)
    return handleFor(native.download_file(url, path, cb))
end

-- mode: "primary" sets only the main display; nil/"all" sets every screen.
function adapter.setWallpaper(path, mode)
    return native.set_wallpaper(path, mode)
end

-- Paint a SOLID color across the chosen displays. `hex` is "#RRGGBB"; `target`
-- is "external" (non-built-in monitors only -- what a display-connect rule
-- wants), "primary" (main display), or "all"/nil (every screen).
function adapter.setWallpaperColor(hex, target)
    return native.set_wallpaper_color(hex, target)
end

-- App-owned writable cache directory (created on demand).
function adapter.cacheDir()
    return native.cache_dir()
end

-- ---------------------------------------------------------------------------
-- Input / system state / system actions
-- ---------------------------------------------------------------------------

-- Current epoch seconds. Lua's os.time is fine here -- the adapter owns the
-- decision; features must still go through ctx.now() so tests control time.
function adapter.now()
    return os.time()
end

function adapter.isModifierHeld(mod)
    return native.is_modifier_held(mod)
end

-- The modifier tokens the seam accepts (canonical + long aliases), sorted.
-- KeyModifier.swift is the one authority; triggers.validate reads this
-- instead of hardcoding a list (the fake adapter mirrors it, pinned by an
-- integration contract test).
---@return string[]
function adapter.validModifiers()
    return native.valid_modifiers()
end

-- Cryptographically secure uniform integer in [min, max] (CSPRNG in the host).
-- The seam's one secure-randomness source: features only have Lua's non-crypto
-- math.random, so anything sensitive (e.g. password_generator) uses this.
function adapter.randomInt(min, max)
    return native.random_int(min, max)
end

-- Input synthesis (delivered to the frontmost app; needs Accessibility).
-- keyStroke: one modified press, e.g. ({"cmd"}, "c"). typeText: type a
-- unicode string as keystrokes.
function adapter.keyStroke(mods, key)
    native.key_stroke(mods or {}, key)
end

function adapter.typeText(text)
    native.type_text(text)
end

-- Open a URL in the default handler (browser etc.).
function adapter.openURL(url)
    return native.open_url(url) == true
end

-- Bring a RUNNING app (by localized name) frontmost; false if not running.
function adapter.activateApp(name)
    return native.activate_app(name) == true
end

-- Focus an app by BUNDLE ID, launching it first if it is not running. False
-- only when no installed app has that bundle id. (Unlike activateApp, this
-- launches -- the basis for "open my dictionary app and search".)
function adapter.launchOrFocusApp(bundleId)
    return native.launch_or_focus_app(bundleId) == true
end

-- Focus the first browser tab whose URL contains `pattern`; open fallbackURL
-- in a new tab when absent. Returns whether an existing tab was found.
-- (Curated browser automation -- the AppleScript template lives in the seam.)
function adapter.focusBrowserTab(pattern, fallbackURL)
    return native.focus_browser_tab(pattern, fallbackURL) == true
end

-- Safari counterpart of focusBrowserTab (focus the first Safari tab whose URL
-- contains `pattern`, else open fallbackURL). Returns whether a tab was found.
function adapter.focusSafariTab(pattern, fallbackURL)
    return native.focus_safari_tab(pattern, fallbackURL) == true
end

-- The bundle id of the browser macOS would use for an https URL right now (the
-- user's default browser), or nil. Lets a feature offer browser-specific
-- behavior only when that browser is the one in charge.
function adapter.defaultBrowser()
    return native.default_browser_bundle_id()
end

-- Focus the first Chrome tab/app-window whose URL contains `pattern`; when none
-- exists, open the site as a chromeless Chrome APP WINDOW (`chrome --app`).
-- Returns whether an existing window was found. Chrome-only (curated automation).
function adapter.openSiteApp(pattern, url)
    return native.open_site_app(pattern, url) == true
end

-- Open `url` in a SPECIFIC browser (bundle id), routing to a Chrome `profile`
-- and/or opening it as a chromeless `app` window when that browser is Chromium.
-- Non-Chromium browsers (Safari, Firefox) open a plain tab; profile/app are
-- ignored. An empty profile means the browser's default/current profile.
--
-- `incognito` asks for a PRIVATE window. It is honored only by a Chromium browser
-- (`--incognito`); anything else REFUSES and returns false rather than opening a
-- normal window that a caller would go on to describe as private. It also wins
-- over `app` -- see the seam's own note for both rules.
function adapter.openSite(bundleId, profile, app, url, incognito)
    return native.open_site(bundleId, profile, app == true, url, incognito == true) == true
end

-- Is an app with this localized name currently running?
function adapter.isAppRunning(name)
    return native.app_running(name) == true
end

-- ---------------------------------------------------------------------------
-- Browser tabs (curated JXA templates; app must be "Google Chrome"/"Safari")
-- ---------------------------------------------------------------------------

local json -- platform.json, loaded lazily (avoids a cost when unused)

---@class BrowserTab
---@field title string
---@field url string
---@field winId integer      window id (stable for the window's life)
---@field tabIndex integer   1-based slot -- fragile; do NOT key focus on it
---@field id integer         stable tab id (Chrome); 0 for Safari (no tab id)
---@field visible boolean

-- All tabs of a RUNNING browser; cb(tabs|nil) where tabs is a list of BrowserTab.
-- Async (out-of-process script).
---@param app string             "Google Chrome" | "Safari"
---@param cb fun(tabs: BrowserTab[]|nil)
---@return { stop: fun() } handle -- stop() drops the callback if the feature
---        is torn down while osascript is still running
function adapter.browserListTabs(app, cb)
    return handleFor(native.browser_list_tabs(app, function(raw)
        if not raw then return cb(nil) end
        json = json or require("platform.json")
        local doc = json.decode(raw)
        cb(doc and doc.tabs or nil)
    end))
end

-- Raise the window and activate a tab, RE-RESOLVING it by stable identity across
-- all windows: by `tabId` when non-zero (Chrome), else by `url` preferring the
-- `winId` hint and, among equal-url matches there, the listed `tabIndex` (Safari /
-- no id). Position is never PRIMARY identity (a reorder / close-before / cross-
-- window move still lands via id/url) -- but on a total url miss the tab AT the
-- listed (winId, tabIndex) is the last-resort tertiary: same host = an in-place
-- navigation, an honest success with its CURRENT url; different host = activated
-- best-effort but reported as a miss. cb(currentUrl|nil, via) -- nil means the
-- tab is genuinely gone since listing.
---@param app string             "Google Chrome" | "Safari"
---@param tabId integer          stable Chrome tab id, or 0 for "resolve by url"
---@param winId integer          window-id hint for the url fallback (tie-break)
---@param url string             the listed url (the url-fallback key)
---@param tabIndex integer       listed 1-based position (0 = unknown) -- the
---                              last-resort tertiary for an in-place navigation
---@param cb fun(currentUrl: string|nil, via: string|nil) via: "id"|"url"|"pos"
---@return { stop: fun() }
function adapter.browserFocusTab(app, tabId, winId, url, tabIndex, cb)
    return handleFor(native.browser_focus_tab(app, tabId, winId, url, tabIndex, function(raw)
        if not raw then return cb(nil) end
        json = json or require("platform.json")
        local doc = json.decode(raw)
        if doc and doc.url then cb(doc.url, doc.via) else cb(nil) end
    end))
end

-- The URL the browser is showing right now (front window's active tab); cb(url|nil).
-- The curated "browser context" read.
--
-- ASYNC (out-of-process), and that is load-bearing, not incidental: the old
-- synchronous form measured ~1s per call and up to 6.7s, blocking the main
-- thread on every app activation (see the seam comment in Native+Browser for the
-- numbers). A departed browser, an incognito window, or no window all give nil.
---@param app string   "Google Chrome" | "Safari"
---@param cb fun(url: string|nil)
---@return { stop: fun() } handle -- stop() drops the callback if the feature is
---        torn down while osascript is still running
function adapter.browserActiveURL(app, cb)
    return handleFor(native.browser_active_url(app, function(raw)
        -- The script answers "" for incognito / no window; normalize to nil so
        -- callers never have to know the difference.
        if raw and raw ~= "" then cb(raw) else cb(nil) end
    end))
end

-- Pull real favicons for `domains` out of Chrome's local icon DB into
-- outDir/<domain>.png (largest PNG per domain; existing files kept).
-- Async; cb(savedDomains). Works offline -- the browser already has them.
-- The scan itself cannot be aborted, but stop() drops the callback so results
-- never land in a feature that has since been disabled.
---@return { stop: fun() }
function adapter.extractFavicons(outDir, domains, cb)
    return handleFor(native.extract_favicons(outDir, domains, cb))
end

-- Draw a crosshair around the pointer for `seconds` (fire-and-forget overlay;
-- clicks pass through). Re-invoking replaces the live one.
function adapter.locateMouse(seconds)
    native.locate_mouse(seconds or 3)
end

function adapter.idleSeconds()
    return native.idle_seconds()
end

-- Who, if anyone, is holding the display awake. Returns the holding process's
-- name while SOME app holds a macOS display-wake power assertion (video
-- playback, a video call, a presentation, screen sharing), nil otherwise.
-- The companion to idleSeconds: idle time alone cannot tell "away from the
-- desk" from "watching a film", and this is the signal macOS's own
-- idle-display-sleep consults to tell them apart.
---@return string|nil holder process name, or nil when nothing holds one
function adapter.displaySleepPrevented()
    return native.display_sleep_prevented()
end

function adapter.systemSleep()
    native.system_sleep()
end

function adapter.lockScreen()
    native.lock_screen()
end

function adapter.displaySleep()
    native.display_sleep()
end

function adapter.startScreensaver()
    native.start_screensaver()
end

-- Run a macOS Shortcut by name (fire-and-forget). The automation escape hatch:
-- a user Shortcut reaches Focus/DND, volume, HomeKit, etc. -- see effects.lua.
function adapter.runShortcut(name)
    native.run_shortcut(name)
end

-- Speak a line aloud through the system speech synthesizer (fire-and-forget).
function adapter.say(text)
    native.say(text)
end

-- Add `delta` (may be negative) to the system output volume, clamped to 0-100;
-- returns the new level (-1 on error). The seam reads-modifies-writes in one
-- script -- serialized against other Lua callers.
function adapter.adjustVolume(delta)
    return native.adjust_volume(delta)
end

-- Flip the system output mute; returns the new muted state.
function adapter.toggleMute()
    return native.toggle_mute()
end

-- Empty the user's home Trash (no Finder prompt); returns the count removed.
function adapter.emptyTrash()
    return native.empty_trash()
end

-- Eject every ejectable external volume; returns the count ejected.
function adapter.eject()
    return native.eject()
end

-- Post a media/transport key ("playpause" | "next" | "previous") -- whatever app
-- is playing picks it up (fire-and-forget).
function adapter.mediaKey(name)
    native.media_key(name)
end

return adapter
