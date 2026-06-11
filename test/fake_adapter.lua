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
fake.watchers      = {}   -- {event, fn, stopped}
fake.choosers      = {}   -- see adapter.chooser
fake.dialogs       = {}   -- see adapter.askChoice
fake.banners       = {}   -- {text, stopped}
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
    function h.stop()             freeOnce(c) end
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

function adapter.idleSeconds()
    return fake.idle
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

function fake.pressHotkey(key)
    for _, h in ipairs(fake.hotkeys) do
        if not h.stopped and h.key == key then h.fn() end
    end
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

return fake
