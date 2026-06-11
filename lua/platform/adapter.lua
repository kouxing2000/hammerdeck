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

-- mods: table like {"cmd","alt"}; key: string like "h"; fn: function
function adapter.bindHotkey(mods, key, fn)
    return handleFor(native.bind_hotkey(mods or {}, key, fn))
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

-- ---------------------------------------------------------------------------
-- Windows / apps
-- ---------------------------------------------------------------------------

-- All standard windows, most-recently-focused first. Currently a stub on the
-- native backend (M2 Slice 2: AXUIElement + Accessibility permission).
function adapter.listWindows()
    return native.list_windows()
end

function adapter.focusWindow(id)
    return native.focus_window(id)
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

function adapter.setWallpaper(path)
    return native.set_wallpaper(path)
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
