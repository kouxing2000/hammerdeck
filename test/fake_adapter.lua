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

-- Triggers / bindings ---------------------------------------------------------

local function makeTimer(kind, n, fn)
    local t = { kind = kind, n = n, fn = fn, stopped = false }
    fake.timers[#fake.timers + 1] = t
    alloc()
    return t, { stop = function() freeOnce(t) end }
end

function adapter.bindHotkey(mods, key, fn)
    local h = { mods = mods, key = key, fn = fn, stopped = false }
    fake.hotkeys[#fake.hotkeys + 1] = h
    alloc()
    return { stop = function() freeOnce(h) end }
end

function adapter.bindChord(mods, key, follows, fn)
    local c = { mods = mods, key = key, follows = follows, fn = fn, stopped = false }
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

-- Output ------------------------------------------------------------------------

function adapter.notify(title, text)
    fake.notifications[#fake.notifications + 1] = { title = title, text = text }
end

function adapter.alert(text)
    fake.alerts[#fake.alerts + 1] = text
end

function adapter.log(...) end   -- silent in tests; flip to print(...) to debug

-- UI ------------------------------------------------------------------------------

function adapter.chooser(opts)
    local c = {
        opts = opts, visible = false, choices = {}, selectedRow = 0,
        placeholder = nil, query = nil, stopped = false,
    }
    fake.choosers[#fake.choosers + 1] = c
    alloc()
    local h = {}
    function h.setPlaceholder(t)  c.placeholder = t end
    function h.setChoices(list)   c.choices = list end
    function h.show()             c.visible = true end
    function h.hide()
        c.visible = false
        if opts.onHide then opts.onHide() end
    end
    function h.isVisible()        return c.visible end
    function h.getSelectedRow()   return c.selectedRow end
    function h.setSelectedRow(n)
        -- Mirror the native chooser: out-of-range rows are rejected.
        if n >= 1 and n <= #c.choices then c.selectedRow = n end
    end
    function h.select(n)
        -- Mirror the native chooser: selecting fires onSelect then onHide.
        c.visible = false
        if opts.onSelect then opts.onSelect(c.choices[n]) end
        if opts.onHide then opts.onHide() end
    end
    function h.setQuery(q)        c.query = q end
    -- Mirror the native chooser: close() orders the panel out, so a stopped
    -- chooser is never "visible".
    function h.stop()             c.visible = false; freeOnce(c) end
    -- test-side driver: pick row n as the user would
    function c.userSelect(n)      h.select(n) end
    return h
end

function adapter.askChoice(opts)
    local d = {
        title = opts.title, infos = opts.infos or {}, actions = opts.actions or {},
        onChoose = opts.onChoose, open = true, stopped = false,
    }
    fake.dialogs[#fake.dialogs + 1] = d
    alloc()
    local function finish(choiceText)
        if not d.open then return end
        d.open = false
        freeOnce(d)
        if d.onChoose then d.onChoose(choiceText) end
    end
    -- test-side driver
    function d.choose(text) finish(text) end
    return {
        dismiss = function() finish(nil) end,
        stop    = function() d.open = false; freeOnce(d) end,
    }
end

function adapter.banner(text)
    local b = { text = text, stopped = false }
    fake.banners[#fake.banners + 1] = b
    alloc()
    return {
        setText = function(t) b.text = t end,
        stop    = function() freeOnce(b) end,
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

fake.usageWidgets = {}   -- {data, stopped}
function adapter.usageWidget()
    local w = { data = nil, stopped = false }
    fake.usageWidgets[#fake.usageWidgets + 1] = w
    alloc()
    return {
        setData = function(d) w.data = d end,
        stop    = function() freeOnce(w) end,
    }
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

function adapter.focusWindow(id)
    fake.focused[#fake.focused + 1] = id
    return true
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

-- Focused-window frame surface (window_arrange) -----------------------------------

fake.screenList     = { { x = 0, y = 0, w = 1440, h = 900 } }  -- visible frames
fake.focusedWindow  = nil   -- {x,y,w,h, fullscreen?, screenIndex?} preset by tests
fake.windowFrames   = {}    -- recorded setFocusedWindowFrame calls
fake.fullscreenSets = {}    -- recorded setFocusedWindowFullscreen calls
fake.mousePos       = { x = 0, y = 0 }

function adapter.screenFrames() return fake.screenList end

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

function adapter.setFocusedWindowFullscreen(on)
    fake.fullscreenSets[#fake.fullscreenSets + 1] = on
    if fake.focusedWindow then fake.focusedWindow.fullscreen = on end
    return true
end

function adapter.mousePosition()
    return { x = fake.mousePos.x, y = fake.mousePos.y }
end

function adapter.setMousePosition(x, y)
    fake.mousePos = { x = x, y = y }
end

fake.featureNames = {}   -- bare names the fake "filesystem" exposes to discovery
function adapter.discoverFeatures(dir) return fake.featureNames end

fake.frontmost = nil     -- preset by the test for frontmostApp()
function adapter.frontmostApp() return fake.frontmost end

fake.appWatchers = {}    -- {fn, stopped}
function adapter.onAppActivated(fn)
    local w = { fn = fn, stopped = false }
    fake.appWatchers[#fake.appWatchers + 1] = w
    alloc()
    return { stop = function() freeOnce(w) end }
end

-- test-side driver: the user switches to app `name`
function fake.activateApp(name)
    fake.frontmost = name
    for _, w in ipairs(fake.appWatchers) do
        if not w.stopped then w.fn(name) end
    end
end

-- Data files (in-memory filesystem) ----------------------------------------------

fake.files  = {}   -- path -> content string
fake.mkdirs = {}   -- recorded mkdir calls

function adapter.dataDir() return "/fake/data" end

function adapter.mkdir(path)
    fake.mkdirs[#fake.mkdirs + 1] = path
    return true
end

function adapter.fileRead(path)        return fake.files[path] end
function adapter.fileWrite(path, text) fake.files[path] = text; return true end
function adapter.fileAppend(path, line)
    fake.files[path] = (fake.files[path] or "") .. line .. "\n"
    return true
end
function adapter.fileExists(path)      return fake.files[path] ~= nil end

-- Clipboard ---------------------------------------------------------------------

fake.pasteboard = nil   -- current general-pasteboard plain-text contents

function adapter.pasteboardRead()       return fake.pasteboard end
function adapter.pasteboardWrite(text)  fake.pasteboard = text end

-- Input / system ------------------------------------------------------------------

function adapter.now()
    return os.time() + fake.clockOffset
end

function fake.now()
    return adapter.now()
end

function adapter.isModifierHeld(mod)
    return fake.modifiers[mod] == true
end

fake.keyEvents  = {}   -- recorded keyStroke calls: {mods, key}
fake.typedTexts = {}   -- recorded typeText strings
fake.openedUrls = {}   -- recorded openURL calls
fake.runningApps   = {}   -- set: name -> true (preset by tests)
fake.activatedApps = {}   -- recorded successful activateApp names

function adapter.keyStroke(mods, key)
    fake.keyEvents[#fake.keyEvents + 1] = { mods = mods or {}, key = key }
end

function adapter.typeText(text)
    fake.typedTexts[#fake.typedTexts + 1] = text
end

function adapter.openURL(url)
    fake.openedUrls[#fake.openedUrls + 1] = url
    return true
end

function adapter.activateApp(name)
    if fake.runningApps[name] then
        fake.activatedApps[#fake.activatedApps + 1] = name
        return true
    end
    return false
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

function adapter.isAppRunning(name)
    return fake.runningApps[name] == true
end

-- Browser tab enumeration / jumping (tabs_jumper) -----------------------------

fake.browserTabsByApp = {}   -- app -> list of {title,url,winId,tabIndex,visible}
fake.tabJumps  = {}          -- recorded {app, winId, tabIndex}
fake.jumpUrlOverride = nil   -- set to simulate drift; false = tab gone (nil cb)

function adapter.browserListTabs(app, cb)
    cb(fake.browserTabsByApp[app])
end

function adapter.browserFocusTab(app, winId, tabIndex, cb)
    fake.tabJumps[#fake.tabJumps + 1] = { app = app, winId = winId, tabIndex = tabIndex }
    if fake.jumpUrlOverride ~= nil then
        if fake.jumpUrlOverride == false then return cb(nil) end
        return cb(fake.jumpUrlOverride)
    end
    for _, t in ipairs(fake.browserTabsByApp[app] or {}) do
        if t.winId == winId and t.tabIndex == tabIndex then return cb(t.url) end
    end
    cb(nil)
end

fake.activeUrls = {}   -- app -> the url its front tab is showing

function adapter.browserActiveURL(app)
    return fake.activeUrls[app]
end

function adapter.idleSeconds()
    return fake.idle
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

function adapter.httpGet(url, headers, cb)
    fake.httpRequests[#fake.httpRequests + 1] = { url = url, headers = headers }
    local r = fake.httpResponses[url]
    -- synchronous in tests (the native backend calls back async on main)
    if r then cb(r.status, r.body) else cb(0, nil) end
end

function adapter.downloadFile(url, path, cb)
    fake.downloads[#fake.downloads + 1] = { url = url, path = path }
    cb(fake.downloadOk)
end

function adapter.setWallpaper(path)
    fake.wallpapers[#fake.wallpapers + 1] = path
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
    local want = nil
    if mods then
        want = {}
        for _, m in ipairs(mods) do want[#want + 1] = m end
        table.sort(want)
        want = table.concat(want, ",")
    end
    for _, h in ipairs(fake.hotkeys) do
        if not h.stopped and h.key == key then
            local fire = true
            if want then
                local have = {}
                for _, m in ipairs(h.mods or {}) do have[#have + 1] = m end
                table.sort(have)
                fire = table.concat(have, ",") == want
            end
            if fire then h.fn() end
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

return fake
