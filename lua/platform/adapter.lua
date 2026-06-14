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
function adapter.bindChord(mods, key, follows, fn)
    return handleFor(native.bind_chord(mods or {}, key, follows or {}, fn))
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

-- Subscribe to a system event: "sleep","wake","screenLock","screenUnlock".
function adapter.onSystemEvent(event, fn)
    return handleFor(native.on_system_event(event, fn))
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
--   actions  = { "Action A", ... }    -- selectable rows
--   onChoose(actionText|nil)          -- nil = dismissed without choosing
-- The dialog frees itself after completion. dismiss() cancels (-> onChoose(nil)).
function adapter.askChoice(opts)
    local actions = opts.actions or {}
    local id = native.ask_choice(
        opts.title or "",
        opts.infos or {},
        actions,
        function(idx)
            if opts.onChoose then opts.onChoose(idx and actions[idx] or nil) end
        end)
    return {
        dismiss = function() native.ask_choice_dismiss(id) end,
        stop    = function() native.stop(id) end,
    }
end

-- Full-width banner overlay at the top of the main screen.
-- Returns { setText(t), stop() }.
function adapter.banner(text)
    local id = native.banner_show(text or "")
    return {
        setText = function(t) native.banner_set_text(id, t) end,
        stop    = function() native.stop(id) end,
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

-- All standard windows, most-recently-focused first: { id, title, appName,
-- bundleID } rows. Returns {} when the Accessibility permission is missing --
-- check axTrusted()/axPrompt() to onboard.
function adapter.listWindows()
    return native.list_windows()
end

-- Focus a window by an id from the MOST RECENT listWindows() call.
function adapter.focusWindow(id)
    return native.focus_window(id)
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

function adapter.setFocusedWindowFullscreen(on)
    return native.set_focused_window_fullscreen(on == true) == true
end

-- Visible frame of every screen (primary first); screenIndex indexes this.
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

-- Subscribe to app activations: fn(appName) fires whenever an application
-- becomes frontmost. No permission required (NSWorkspace notification).
function adapter.onAppActivated(fn)
    return handleFor(native.on_app_activated(fn))
end

-- ---------------------------------------------------------------------------
-- Data files (durable feature-owned storage; cacheDir may be purged by the OS)
-- ---------------------------------------------------------------------------

function adapter.dataDir()
    return native.data_dir()
end

function adapter.mkdir(path)
    return native.mkdir(path)
end

-- Delete a file/dir UNDER dataDir (relative path, no traversal) -- the
-- retention sweep's curated tool; there is deliberately no general delete.
function adapter.removeDataPath(rel)
    return native.remove_data_path(rel) == true
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

function adapter.fileWrite(path, text)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(text)
    f:close()
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

-- Async download straight to `path` (binary-safe); cb(ok).
function adapter.downloadFile(url, path, cb)
    native.download_file(url, path, cb)
end

-- mode: "primary" sets only the main display; nil/"all" sets every screen.
function adapter.setWallpaper(path, mode)
    return native.set_wallpaper(path, mode)
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

-- Focus the first browser tab whose URL contains `pattern`; open fallbackURL
-- in a new tab when absent. Returns whether an existing tab was found.
-- (Curated browser automation -- the AppleScript template lives in the seam.)
function adapter.focusBrowserTab(pattern, fallbackURL)
    return native.focus_browser_tab(pattern, fallbackURL) == true
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

return adapter
