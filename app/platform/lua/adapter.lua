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
function adapter.bindHotkey(mods, key, fn, onRelease)
    return handleFor(native.bind_hotkey(mods or {}, key, fn, onRelease))
end

-- A chord: mods+key is the PREFIX hotkey; `follows` is the ordered sequence of
-- bare keys pressed after it (e.g. {"b"} for cmd+shift+a then b, or {"b","c"}).
-- Permission-free: the prefix is a normal global hotkey, and the follow keys
-- are registered transiently only while the prefix has armed the chord mode.
-- `label` (optional): the action's human name, shown in the which-key hint that
-- appears after the prefix arms (so a chord menu is discoverable, not memorized).
function adapter.bindChord(mods, key, follows, fn, label)
    return handleFor(native.bind_chord(mods or {}, key, follows or {}, fn, label))
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
    function h.select(n)          native.chooser_select(id, n) end
    function h.setQuery(q)        native.chooser_set_query(id, q) end
    function h.stop()             native.stop(id) end
    return h
end

-- A one-shot "pick an action" dialog. opts:
--   title    = placeholder text
--   infos    = { "info line", ... }   -- non-selectable context rows
--   actions  = { "Action A", ... }    -- selectable rows; each entry is either a
--              plain label string OR a table { label = "...", icon = "<token>" }
--              where icon is an icon token ("symbol:moon.stars", "appicon:...",
--              "file:..."). onChoose still receives the LABEL string either way.
--   onChoose(actionText|nil)          -- nil = dismissed without choosing
-- The dialog frees itself after completion. dismiss() cancels (-> onChoose(nil)).
function adapter.askChoice(opts)
    local raw = opts.actions or {}
    local labels, items = {}, {}
    for i, a in ipairs(raw) do
        if type(a) == "table" then
            labels[i] = a.label or a.text or ""
            items[i] = { text = labels[i], image = a.icon }
        else
            labels[i] = a
            items[i] = { text = a }
        end
    end
    local id = native.ask_choice(
        opts.title or "",
        opts.infos or {},
        items,
        function(idx)
            if opts.onChoose then opts.onChoose(idx and labels[idx] or nil) end
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
-- plain table: { title, cells = {{col,row,keys,label?}, ...}, caption,
-- groups = {{label, keys}, ...}, footer }. Returns { stop() }.
function adapter.hud(spec)
    local id = native.hud_show(spec or {})
    return {
        stop = function() native.stop(id) end,
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
-- setCells(colors) [recolor the mini-map after a drag-swap], hide, show, stop }.
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
        setCells = function(colors) native.deck_widget_set_cells(id, colors or {}) end,
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

-- Set the SYSTEM appearance. `mode` is "dark" | "light" | "toggle". Drives the
-- dark_mode feature; uses System Events (first run prompts for Automation).
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

-- Async GET; cb(status, body|nil). One-shot, NOT a handle: it cannot be
-- cancelled, and the callback may arrive after the feature was disabled --
-- any stopped ctx handles it touches are safe no-ops.
function adapter.httpGet(url, headers, cb)
    native.http_get(url, headers or {}, cb)
end

-- Async request with an explicit method/body; cb(status, body|nil). Same
-- one-shot, non-cancellable contract as httpGet. `body` is a string (e.g. a
-- JSON payload); pass Content-Type / Authorization via the headers table.
function adapter.httpRequest(url, method, headers, body, cb)
    native.http_request(url, method or "GET", headers or {}, body, cb)
end

-- Convenience POST over adapter.httpRequest; cb(status, body|nil).
function adapter.httpPost(url, headers, body, cb)
    native.http_request(url, "POST", headers or {}, body, cb)
end

-- Async download straight to `path` (binary-safe); cb(ok).
function adapter.downloadFile(url, path, cb)
    native.download_file(url, path, cb)
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
function adapter.openSite(bundleId, profile, app, url)
    return native.open_site(bundleId, profile, app == true, url) == true
end

-- Is an app with this localized name currently running?
function adapter.isAppRunning(name)
    return native.app_running(name) == true
end

-- ---------------------------------------------------------------------------
-- Browser tabs (curated JXA templates; app must be "Google Chrome"/"Safari")
-- ---------------------------------------------------------------------------

local json -- platform.json, loaded lazily (avoids a cost when unused)

-- All tabs of a RUNNING browser; cb(tabs|nil) where tabs is a list of
-- { title, url, winId, tabIndex, visible }. Async (out-of-process script).
function adapter.browserListTabs(app, cb)
    native.browser_list_tabs(app, function(raw)
        if not raw then return cb(nil) end
        json = json or require("platform.json")
        local doc = json.decode(raw)
        cb(doc and doc.tabs or nil)
    end)
end

-- Raise the window and activate the tab (ids from browserListTabs);
-- cb(currentUrl|nil) -- nil means the tab moved/closed since listing.
function adapter.browserFocusTab(app, winId, tabIndex, cb)
    native.browser_focus_tab_at(app, winId, tabIndex, function(raw)
        if not raw then return cb(nil) end
        json = json or require("platform.json")
        local doc = json.decode(raw)
        cb(doc and doc.url or nil)
    end)
end

-- The URL the browser is showing right now (front window's active tab), or
-- nil. Sync + cheap -- the curated "browser context" read.
function adapter.browserActiveURL(app)
    return native.browser_active_url(app)
end

-- Pull real favicons for `domains` out of Chrome's local icon DB into
-- outDir/<domain>.png (largest PNG per domain; existing files kept).
-- Async; cb(savedDomains). Works offline -- the browser already has them.
function adapter.extractFavicons(outDir, domains, cb)
    native.extract_favicons(outDir, domains, cb)
end

-- Draw a crosshair around the pointer for `seconds` (fire-and-forget overlay;
-- clicks pass through). Re-invoking replaces the live one.
function adapter.locateMouse(seconds)
    native.locate_mouse(seconds or 3)
end

function adapter.idleSeconds()
    return native.idle_seconds()
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
