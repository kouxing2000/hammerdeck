-- test/run.lua -- headless platform + feature tests against the fake adapter.
--
-- Run from the repo root:  lua test/run.lua
--
-- Covers: manifest validation, action-feature trigger binding, service-feature
-- lifecycle, the three MVP features' main flows, and the scoped-ctx guarantee
-- that disable leaks nothing.

package.path = "app/?.lua;app/?/init.lua;test/?.lua;" .. package.path

-- Co-located layout: install the searcher that resolves platform/feature module
-- names into their `lua/` subfolders, before any platform require below.
require("loader").install()

local fake = require("fake_adapter")
package.loaded["platform.adapter"] = fake.adapter   -- preempt the seam

-- Pin the fake clock to a deterministic mid-day instant: the suite advances
-- time via fake.clockOffset, and a real near-midnight wall clock would
-- otherwise cross a day boundary mid-test (day-rollover resets fire).
local pin = os.date("*t") --[[@as osdateparam]]
pin.hour, pin.min, pin.sec = 10, 0, 0
fake.clockOffset = os.time(pin) - os.time()

local registry = require("platform.registry")

local passed = 0
local function ok(cond, msg)
    if not cond then error("FAIL: " .. msg, 2) end
    passed = passed + 1
end

local function minutesFromNow(min)
    return os.date("%H:%M", fake.now() + min * 60)
end

-- T0: fake-adapter <-> real-adapter SURFACE PARITY ----------------------------
-- The fake adapter must export exactly the same function surface as the real
-- seam (lua/platform/adapter.lua). Without this, a feature can pass headlessly
-- against a fake contract the real bridge doesn't provide (or the fake can rot
-- with dead reimplementations of removed functions). This pins both directions.
-- It does NOT prove behavioral equivalence -- only that the API shape matches;
-- behavior is covered per-function by the feature tests below and the real-
-- bridge Swift integration suite.
do
    -- Load the REAL adapter for inspection. adapter.lua assert()s `native` is a
    -- table at load, so stub it (we only read its key set, never call through).
    local savedNative = rawget(_G, "native")
    local savedAdapter = package.loaded["platform.adapter"]
    _G.native = setmetatable({}, { __index = function() return function() end end })
    package.loaded["platform.adapter"] = nil          -- force a fresh real load
    local okLoad, realAdapter = pcall(require, "platform.adapter")
    package.loaded["platform.adapter"] = savedAdapter  -- restore the fake preempt
    _G.native = savedNative
    ok(okLoad and type(realAdapter) == "table",
        "real adapter.lua loads for surface inspection")

    local function funcSet(t)
        local s = {}
        for k, v in pairs(t) do if type(v) == "function" then s[k] = true end end
        return s
    end
    local realFns, fakeFns = funcSet(realAdapter), funcSet(fake.adapter)
    for k in pairs(realFns) do
        ok(fakeFns[k], "fake adapter implements real adapter." .. k)
    end
    for k in pairs(fakeFns) do
        ok(realFns[k], "fake adapter." .. k .. " has a real counterpart (not dead/renamed)")
    end
end

-- T0b: i18n catalog (lookup, fallback, interpolation, plural) -----------------
-- The i18n module is locale-injected (not seam-coupled): configure() with a code
-- + appdir, assert against the shipped app/i18n/zh-Hans.json, then RESET to "en"
-- so the describe() tests below see the inline English source.
do
    local i18n    = require("platform.i18n")
    local windows = require("platform.windows")
    i18n.configure({ locale = "zh-Hans", appdir = "app" })

    ok(i18n.t("window.noFocused", "No focused window") == "没有聚焦的窗口",
        "i18n.t returns the zh-Hans translation for a global key")
    ok(i18n.t("missing.key", "fallback") == "fallback",
        "i18n.t falls back to the inline default for a missing key")
    ok(i18n.t("missing.key") == "missing.key",
        "i18n.t falls back to the key itself when no default is given")

    -- the template is localized; the caller interpolates -- placeholders are
    -- identical across locales, so string.format fills both %s the same way.
    local msg = string.format(
        i18n.t("window.axRequired", "%s needs Accessibility -- grant %s"),
        "Window Mode", "Hammerdeck")
    ok(msg:find("Window Mode", 1, true) and msg:find("Hammerdeck", 1, true)
        and msg:find("辅助功能", 1, true),
        "i18n template interpolates caller args into the zh-Hans string")

    ok(i18n.category(1) == "other" and i18n.category(5) == "other",
        "zh-Hans plural category collapses to other")
    local forms = { one = "%d window", other = "%d windows" }
    ok(i18n.plural("x.count", 5, forms) == "%d windows",
        "i18n.plural picks the other form from inline forms (no catalog entry)")

    -- platform.windows is a leaf: it localizes through the ctx handed to it, with
    -- NO require of i18n. A shared key resolves via ctx.t's global fallback.
    local alerted
    local fakeCtx = {
        window    = { frame = function() return nil end },
        axTrusted = function() return false end,
        axPrompt  = function() end,
        alert     = function(s) alerted = s end,
        appName   = "Hammerdeck",
        t         = function(k, d) return i18n.tFeature("window_modal", k, d) end,
    }
    windows.focusedOrAlert(fakeCtx, "Window Mode")
    ok(alerted and alerted:find("辅助功能", 1, true) and alerted:find("Hammerdeck", 1, true),
        "platform.windows localizes its Accessibility alert via ctx.t")

    -- P2 localization sweep: every feature that emits runtime user-facing strings
    -- must carry the zh-Hans key the code requests, or ctx.t silently falls back to
    -- English in zh (the leak this pass closed). Assert a representative NEW key per
    -- touched feature resolves to a translation (NOT the English default) -- the
    -- exact missing-key failure the en-locale tests below cannot see.
    do
        local sweep = {
            { "sleep_schedule",  "banner.countdown",    "System sleep in %s  --  Save your work!" },
            { "break_reminder",  "action.lock",         "Lock Screen" },
            { "window_modal",    "hud.footer",          "esc  exit" },
            { "text_actions",    "action.calculate",    "Calculate" },
            { "insert_datetime", "error.tableFormat",   "That format produces a table, not text (avoid *t)" },
            { "window_grid",     "hud.caption",         "press a number to place the window" },
            { "window_grid",     "hud.captionExtend",   "press a cell down-right to extend" },
            { "window_grid",     "flash.span",          "%d×%d region" },
            { "window_snap",     "option.presets.label", "Saved placements" },
            { "window_deck",     "pick.windows",        "Deck which windows?" },
        }
        for _, e in ipairs(sweep) do
            ok(i18n.tFeature(e[1], e[2], e[3]) ~= e[3],
                e[1] .. " localizes runtime key '" .. e[2] .. "' in zh (no English leak)")
        end
    end

    -- Leaf-util invariant: the leaf utils (platform.windows/hotkeys/json/urls/
    -- cyclingChooser) must have ZERO `require` -- that require-freedom is exactly what lets a feature
    -- `require` them safely (the layer map's leaf tier). Nothing else guards this
    -- (no luacheck / CI grep), so assert it HERE: it runs in both `lua test/run.lua`
    -- and `scripts/test-lua.sh` (the exact embedded engine), failing loudly if a
    -- ported window algorithm or a careless edit drags a require into the pure layer.
    -- Code lines only -- a comment mentioning "require" (windows.lua's header does)
    -- is skipped so prose never trips the guard.
    do
        local appdir = require("loader").appdir
        for _, leaf in ipairs({ "windows", "hotkeys", "json", "urls", "cyclingChooser" }) do
            local path = appdir .. "/platform/lua/" .. leaf .. ".lua"
            local fh = assert(io.open(path, "r"), "leaf-guard: cannot open " .. path)
            local offender
            for line in fh:lines() do
                if not line:match("^%s*%-%-") and line:match("require%s*[%(\"']") then
                    offender = line
                    break
                end
            end
            fh:close()
            ok(offender == nil,
                "leaf util platform." .. leaf .. " stays require-free (layer invariant)"
                .. (offender and (" -- found: " .. offender) or ""))
        end
    end

    -- RESET to the source language for the rest of the suite.
    i18n.configure({ locale = "en" })
    ok(i18n.t("window.noFocused", "No focused window") == "No focused window",
        "i18n.t returns the inline English source when locale is en")
    ok(i18n.plural("x.count", 1, forms) == "%d window",
        "en plural category splits one/other")
end

-- T1: all manifests register + validate --------------------------------------
-- loadCatalog (not three register() calls) so the catalog is recorded for the
-- hot-reload test (T11), exactly as the real bootstrap does.
registry.loadCatalog({
    "features.sleep_schedule",
    "features.break_reminder",
    "features.window_switcher",
})
ok(#registry.all() == 3, "3 features registered")

-- T2: the manifest contract is enforced ----------------------------------------
local manifest = require("platform.manifest")
local function rejects(m, why)
    ok(pcall(manifest.validate, m) == false, "manifest rejected: " .. why)
end
rejects({ api = 99, id = "x", name = "X", action = function() end }, "wrong api version")
rejects({ api = 1, id = "x", name = "X" }, "neither action nor start")
rejects({ api = 1, id = "x", name = "X", action = function() end, start = function() end },
    "both action and start")
rejects({ api = 1, id = "x", name = "X", start = function() end,
    defaultTrigger = { type = "hotkey" } }, "defaultTrigger on a service")
rejects({ api = 1, id = "x", name = "X", action = function() end,
    options = { { key = "k", type = "nope" } } }, "unknown option type")
rejects({ api = 1, id = "x", name = "X", action = function() end,
    options = { { key = "m", type = "enum", values = { "a" }, valuesFrom = "ghost" } } },
    "valuesFrom names no validate-able option")
rejects({ api = 1, id = "x", name = "X", action = function() end,
    options = { { key = "b", type = "bool", default = true, gatedBy = "ghost" } } },
    "gatedBy names no validate-able option")

-- T3: window_switcher (action feature: open, select; cycle on repeat) -------------
fake.windows = {
    { id = 11, title = "Current Window",  appName = "AppA", bundleID = "com.a" },
    { id = 22, title = "Previous Window", appName = "AppB", bundleID = "com.b" },
    { id = 33, title = "Older Window",    appName = "AppC", bundleID = "com.c" },
}
registry.setEnabled("window_switcher", true)
fake.pressHotkey("tab")
local ch = fake.visibleChooser()
ok(ch ~= nil, "window_switcher opened a chooser")
ok(#ch.choices == 3, "chooser lists all windows")
ok(ch.selectedRow == 2, "chooser preselects the previous window")
ok(ch.choices[1].image == "icon:com.a", "choices carry app icons")
ok(ch.title == "Switch Window" and ch.titleSymbol == "macwindow.on.rectangle"
    and ch.titleBadge == "3 windows",
    "header carries title, glyph symbol, and live count badge")
ch.userSelect(2)
ok(fake.focused[#fake.focused] == 22, "selecting focuses the chosen window")

-- repeat-invocation cycling, release modifier to pick
fake.pressHotkey("tab")                        -- reopen (row 2)
fake.pressHotkey("tab")                        -- cycle -> row 3
ch = fake.visibleChooser()
ok(ch.selectedRow == 3, "second invoke cycles the selection")
fake.modifiers.alt = false
fake.fireTimers("every", 0.1)                  -- modifier poll sees release
ok(fake.focused[#fake.focused] == 33, "releasing the modifier picks the row")

-- backward cycling (the donor's alt+`): wraps at the top
fake.modifiers.alt = true
fake.pressHotkey("tab")                        -- reopen (row 2)
fake.pressHotkey("`")                          -- backward -> row 1
ch = fake.visibleChooser()
ok(ch.selectedRow == 1, "backward action cycles up")
fake.pressHotkey("`")                          -- backward from 1 -> wrap to last
ok(ch.selectedRow == 3, "backward wraps to the bottom")
fake.modifiers.alt = false
fake.fireTimers("every", 0.1)
ok(fake.focused[#fake.focused] == 33, "release still picks after backward cycling")

-- subtext = browser tab count and/or screen name (app name dropped -- the icon
-- carries it); screen name only when the display is reported (native reports it
-- only on multi-display), tab count only for browser windows (native reports it
-- only for them). Either may be absent; both nil collapses the row to one line.
fake.windows = {
    { id = 11, title = "W1", appName = "AppA", bundleID = "com.a", screenName = "Studio Display", tabCount = 12 },
    { id = 22, title = "W2", appName = "AppB", bundleID = "com.b", tabCount = 1 },
    { id = 33, title = "W3", appName = "AppC", bundleID = "com.c", screenName = "Studio Display" },
    { id = 44, title = "W4", appName = "AppD", bundleID = "com.d" },
}
fake.modifiers.alt = true
fake.pressHotkey("tab")
ch = fake.visibleChooser()
ok(ch.choices[1].subText == "12 tabs · Studio Display",
    "tab count and screen name join in the subtext when both reported")
ok(ch.choices[2].subText == "1 tab",
    "tab count alone is the subtext (singular pluralization), no screen name")
ok(ch.choices[3].subText == "Studio Display",
    "screen name alone is the subtext when there is no tab count")
ok(ch.choices[4].subText == nil,
    "no tab count and no screen name collapses the row to one line")
ch.userSelect(1)
fake.modifiers.alt = false

registry.setEnabled("window_switcher", false)
ok(registry.liveHandleCount() == 0, "window_switcher disable left no live handles")

-- T4: sleep_schedule (service feature, graduated phases) -----------------------
fake.settings["hammerdeck.opt.sleep_schedule.weekendShiftMin"] = 0
fake.settings["hammerdeck.opt.sleep_schedule.hardCapAt"] = minutesFromNow(30)
fake.settings["hammerdeck.opt.sleep_schedule.sleepAt"] = minutesFromNow(7)

registry.setEnabled("sleep_schedule", true)
ok(registry.liveHandleCount() == 3, "sleep_schedule: poll timer + 2 watchers live")

fake.fireTimers("every", 10)
local dlg = fake.openDialog()
ok(dlg ~= nil, "phase 1: warning dialog at T-7min")
ok(dlg.actions[2] and dlg.actions[2]:find("^Snooze") ~= nil, "warning offers snooze")

dlg.choose(dlg.actions[2])                     -- snooze (+15min, cap now+30)
fake.fireTimers("every", 10)
ok(fake.openDialog() == nil, "after snooze: no immediate re-warning")
ok(fake.liveBanner() == nil, "after snooze: no countdown banner")

-- fresh enablement, inside the countdown window
registry.setEnabled("sleep_schedule", false)
fake.settings["hammerdeck.opt.sleep_schedule.sleepAt"] = minutesFromNow(4)
registry.setEnabled("sleep_schedule", true)
fake.fireTimers("every", 10)
local banner = fake.liveBanner()
ok(banner ~= nil, "phase 2: countdown banner at T-4min")
ok(banner.text:find("System sleep in") ~= nil, "banner shows countdown text")

fake.systemEvent("wake")                       -- wake resets stale UI
ok(fake.liveBanner() == nil, "wake/unlock dismisses the banner")

fake.fireTimers("every", 10)                   -- banner returns next poll
ok(fake.liveBanner() ~= nil, "banner re-shown after reset while still in window")

registry.setEnabled("sleep_schedule", false)
-- Target an exact minute boundary, then place "now" 5s past it so the poll
-- lands inside the T-0 window deterministically.
local target = fake.now() + 60
target = target - (target % 60)
fake.settings["hammerdeck.opt.sleep_schedule.sleepAt"] = os.date("%H:%M", target)
fake.clockOffset = fake.clockOffset + (target + 5 - fake.now())
registry.setEnabled("sleep_schedule", true)
fake.fireTimers("every", 10)
ok(fake.actions.sleep == 1, "phase 3: system sleep fired at T-0")
ok(fake.liveBanner() == nil, "phase 3 cleared the banner")

registry.setEnabled("sleep_schedule", false)
ok(registry.liveHandleCount() == 0, "sleep_schedule disable left no live handles")

-- T5: break_reminder (service feature: cycle, busy-retry, dialog, lock/unlock) -----
local notificationsBefore = #fake.notifications
registry.setEnabled("break_reminder", true)
ok(#fake.notifications == notificationsBefore + 1, "break_reminder announces the cycle")
ok(fake.fireTimers("every", 5) == 1, "idle-check timer is live")

fake.clockOffset = fake.clockOffset + 25 * 60  -- the work interval passes
fake.idle = 0
fake.fireTimers("after", 25 * 60)              -- rest timer fires; user busy
ok(fake.openDialog() == nil, "busy user: dialog deferred")
fake.idle = 3
fake.fireTimers("after", 3)                    -- retry fires, user now pausable
dlg = fake.openDialog()
ok(dlg ~= nil, "rest dialog shown after busy-retry")

dlg.choose("postpone 1 minute")
local foundPostpone = false
for _, t in ipairs(fake.timers) do
    if not t.stopped and t.kind == "after" and t.n == 60 then foundPostpone = true end
end
ok(foundPostpone, "postpone schedules a 60s timer")

fake.systemEvent("screenLock")                 -- lock pauses the cycle
ok(fake.fireTimers("after", 60) == 0, "lock cancelled the pending rest timer")

fake.clockOffset = fake.clockOffset + 3
local nBefore = #fake.notifications
fake.systemEvent("screenUnlock")               -- unlock starts a fresh cycle
ok(#fake.notifications == nBefore + 1, "unlock starts a fresh announced cycle")

fake.idle = 0
local stateBefore = tonumber(fake.settings["hammerdeck.state.break_reminder.workSeconds"] or 0)
fake.fireTimers("every", 5)
local stateAfter = tonumber(fake.settings["hammerdeck.state.break_reminder.workSeconds"] or 0)
ok(stateAfter == stateBefore + 5, "active tick accrues persisted work stats")

fake.idle = 6 * 60                             -- long idle pauses
fake.fireTimers("every", 5)
ok(fake.fireTimers("after") == 0, "long idle cancelled the rest timer")

registry.setEnabled("break_reminder", false)
ok(registry.liveHandleCount() == 0, "break_reminder disable left no live handles")

-- T6: nothing leaks globally ----------------------------------------------------
ok(fake.liveHandles == 0, "fake adapter reports zero live native resources")

-- T7: catalog description for the config UI --------------------------------------
local desc = registry.describe()
ok(#desc == 3, "describe lists all 3 features")
ok(desc[1].id == "break_reminder" and desc[1].kind == "service", "describe is sorted by id")
local jumpDesc = desc[3]
ok(jumpDesc.id == "window_switcher" and jumpDesc.kind == "action", "window_switcher is an action")
ok(jumpDesc.triggerDesc == "2 actions", "multi-action feature summarized in the list")
ok(jumpDesc.actions[1].triggerDesc == "hotkey: alt+tab", "per-action trigger described")
ok(type(jumpDesc.actions[1].mnemonic) == "string" and jumpDesc.actions[1].mnemonic:find("⌥Tab"),
    "per-action mnemonic surfaced in describe()")
ok(#jumpDesc.options == 0,
    "window_switcher exports no options (cycle modifier derives from the trigger)")
ok(jumpDesc.context == "window", "describe() surfaces the feature context")
ok(jumpDesc.requires[1] == "accessibility",
    "describe() surfaces OS preconditions (window features need Accessibility)")
-- The per-feature SF Symbol overlaid from feature.json (META_FIELDS) flows all
-- the way to describe(), so the menubar/Settings/Gallery can render it. nil when
-- a feature declares none (host then falls back to the category glyph).
ok(jumpDesc.icon == "macwindow.on.rectangle",
    "describe() surfaces the per-feature icon overlaid from feature.json")
-- typed option export incl. enum values, on a synthetic probe
package.loaded["features._enum_probe"] = {
    api = 1, id = "enum_probe", name = "Enum Probe",
    options = { { key = "mode", type = "enum", default = "a",
                  values = { "a", "b", "c" }, labels = { "Ay", "Bee", "Cee" },
                  label = "Mode" } },
    defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "9" },
    action = function() end,
}
registry.load("features._enum_probe")
local probeDesc0 = nil
for _, e in ipairs(registry.describe()) do
    if e.id == "enum_probe" then probeDesc0 = e end
end
ok(probeDesc0.options[1].key == "mode" and probeDesc0.options[1].type == "enum"
    and #probeDesc0.options[1].values == 3,
    "typed options (incl. enum values) exported for the form generator")
ok(probeDesc0.options[1].labels and probeDesc0.options[1].labels[2] == "Bee",
    "enum display labels exported parallel to values")
registry.unregister("enum_probe")

-- T7c: notify-on-automated-run preference ----------------------------------------
-- An action fired from an AUTOMATED trigger (event/schedule) shows a toast naming
-- the feature ONLY while the notify_on_trigger preference is on. Manual triggers
-- (hotkey/chord) and menubar/palette runs never reach the notify path. Scoped in
-- a `do` block so its locals release (the main chunk is near Lua's 200-local cap).
do
    package.loaded["features._notify_probe"] = {
        api = 1, id = "notify_probe", name = "Notify Probe",
        actions = { { id = "main", label = "Fire", automatable = true,
                      defaultTrigger = { type = "event", event = "wake" },
                      run = function() end } },
    }
    registry.load("features._notify_probe")
    registry.setEnabled("notify_probe", true)

    fake.settings["hammerdeck.enabled.notify_on_trigger"] = false
    local notifyBefore = #fake.notifications
    fake.systemEvent("wake")
    ok(#fake.notifications == notifyBefore,
        "automated fire with the notify preference OFF shows no notification")

    fake.settings["hammerdeck.enabled.notify_on_trigger"] = true
    fake.systemEvent("wake")
    ok(#fake.notifications == notifyBefore + 1
        and fake.notifications[#fake.notifications].title == "Notify Probe",
        "automated fire with the notify preference ON shows a toast naming the feature")

    -- The SAME action run manually (menubar/palette path) never notifies.
    local notifyManual = #fake.notifications
    registry.runAction("notify_probe", "main")
    ok(#fake.notifications == notifyManual,
        "a manual run does not notify even with the preference on")

    -- A crashed automated run must NOT report as a clean "Ran automatically":
    -- notify is gated on the action succeeding. Firing "wake" runs BOTH the
    -- (ok) notify_probe and this throwing one, so exactly one notification lands.
    package.loaded["features._throw_probe"] = {
        api = 1, id = "throw_probe", name = "Throw Probe",
        actions = { { id = "main", label = "Boom", automatable = true,
                      defaultTrigger = { type = "event", event = "wake" },
                      run = function() error("boom") end } },
    }
    registry.load("features._throw_probe")
    registry.setEnabled("throw_probe", true)
    local throwBefore = #fake.notifications
    fake.systemEvent("wake")
    ok(#fake.notifications == throwBefore + 1,
        "a crashed automated run does not notify (only the successful sibling did)")
    registry.setEnabled("throw_probe", false)
    registry.unregister("throw_probe")

    registry.setEnabled("notify_probe", false)
    registry.unregister("notify_probe")
    fake.settings["hammerdeck.enabled.notify_on_trigger"] = nil
end

-- T7d: confirm-shortcut (manual-trigger flash) -----------------------------------
-- A MANUAL trigger (hotkey/chord) flashes which action fired ONLY while the
-- confirm_shortcut preference is on. Automated triggers take the notify path, not
-- this. Scoped in a `do` block (main-chunk local budget, see T7c).
do
    package.loaded["features._flash_probe"] = {
        api = 1, id = "flash_probe", name = "Flash Probe", icon = "bolt.fill",
        defaultTrigger = { type = "hotkey", mods = { "ctrl", "alt" }, key = "8" },
        action = function() end,
    }
    registry.load("features._flash_probe")
    registry.setEnabled("flash_probe", true)

    fake.settings["hammerdeck.enabled.confirm_shortcut"] = false
    local flashBefore = #fake.flashes
    fake.pressHotkey("8", { "ctrl", "alt" })
    ok(#fake.flashes == flashBefore,
        "manual hotkey with the confirm preference OFF shows no flash")

    fake.settings["hammerdeck.enabled.confirm_shortcut"] = true
    fake.pressHotkey("8", { "ctrl", "alt" })
    ok(#fake.flashes == flashBefore + 1
        and fake.flashes[#fake.flashes].text == "Flash Probe"
        and fake.flashes[#fake.flashes].symbol == "bolt.fill",
        "manual hotkey with the confirm preference ON flashes the feature name + glyph")

    -- A self-evident feature (opens its own UI) suppresses the flash even with the
    -- preference ON -- the chooser/window it fronts is its own confirmation.
    package.loaded["features._selfev_probe"] = {
        api = 1, id = "selfev_probe", name = "Self Evident Probe", selfEvident = true,
        defaultTrigger = { type = "hotkey", mods = { "ctrl", "alt" }, key = "7" },
        action = function() end,
    }
    registry.load("features._selfev_probe")
    registry.setEnabled("selfev_probe", true)
    local selfevBefore = #fake.flashes
    fake.pressHotkey("7", { "ctrl", "alt" })
    ok(#fake.flashes == selfevBefore,
        "a selfEvident feature does not flash even with confirm_shortcut on")
    registry.setEnabled("selfev_probe", false)
    registry.unregister("selfev_probe")

    registry.setEnabled("flash_probe", false)
    registry.unregister("flash_probe")
    fake.settings["hammerdeck.enabled.confirm_shortcut"] = nil
end

-- T7f: ctx.confirmAction (a modal feature confirms its own real action) ----------
-- A modal feature suppresses the mode-entry flash (selfEvident) and instead fires
-- ctx.confirmAction when the real action lands. That flash is gated on the same
-- confirm_shortcut preference and carries the feature icon. Scoped `do` (see T7c).
do
    package.loaded["features._confirm_probe"] = {
        api = 1, id = "confirm_probe", name = "Confirm Probe", icon = "star.fill",
        selfEvident = true,   -- entry hotkey must NOT auto-flash; only confirmAction does
        defaultTrigger = { type = "hotkey", mods = { "ctrl", "alt" }, key = "6" },
        action = function(ctx) ctx.confirmAction() end,
    }
    registry.load("features._confirm_probe")
    registry.setEnabled("confirm_probe", true)

    fake.settings["hammerdeck.enabled.confirm_shortcut"] = false
    local cBefore = #fake.flashes
    fake.pressHotkey("6", { "ctrl", "alt" })
    ok(#fake.flashes == cBefore,
        "ctx.confirmAction does not flash while confirm_shortcut is off")

    fake.settings["hammerdeck.enabled.confirm_shortcut"] = true
    fake.pressHotkey("6", { "ctrl", "alt" })
    ok(#fake.flashes == cBefore + 1
        and fake.flashes[#fake.flashes].text == "Confirm Probe"
        and fake.flashes[#fake.flashes].symbol == "star.fill",
        "ctx.confirmAction flashes the feature name + icon once confirm_shortcut is on")

    registry.setEnabled("confirm_probe", false)
    registry.unregister("confirm_probe")
    fake.settings["hammerdeck.enabled.confirm_shortcut"] = nil
end

-- T7g: modal sticky-twin exception (the window_grid Hyper+4 -> cell 4 fix) --------
-- A modal binds each BARE key ALSO under the leader mods (sticky) so the user can
-- hold Hyper through. The entry key is normally EXCLUDED from twinning (so a TOGGLE
-- mode's re-press exits) -- but window_grid's entry key IS a cell, so it passes
-- stickyExceptKey=false to twin every key; else Hyper+<entry> re-enters instead of
-- placing that cell (cells 1-3 work, cell 4 didn't). Scoped `do` (see T7c).
do
    local modal = require("platform.modal")
    local HYPER = { "cmd", "alt", "ctrl" }
    local function twinBound(key)
        for _, h in ipairs(fake.hotkeys) do
            if not h.stopped and h.key == key and h.mods and #h.mods == 3 then return true end
        end
        return false
    end

    -- Toggle-mode default: the entry key ("4") is excluded from twinning.
    local hExcl = modal.enter({
        stickyMods = HYPER, stickyExceptKey = "4",
        bindings = { { key = "1", fn = function() end }, { key = "4", fn = function() end } },
    })
    ok(twinBound("1") and not twinBound("4"),
        "stickyExceptKey excludes the entry key's sticky twin (Hyper+1 yes, Hyper+4 no)")
    hExcl.stop()

    -- window_grid's fix: exception OFF -> every bare key twins, so Hyper+4 lands cell 4.
    local hAll = modal.enter({
        stickyMods = HYPER, stickyExceptKey = false,
        bindings = { { key = "1", fn = function() end }, { key = "4", fn = function() end } },
    })
    ok(twinBound("1") and twinBound("4"),
        "stickyExceptKey=false twins every bare key (Hyper+4 places cell 4, no re-enter)")
    hAll.stop()
end

-- T7e: defaultEnabled (ships on until the user says otherwise) --------------------
-- A feature with defaultEnabled=true reports enabled when NO stored choice exists,
-- but an explicit toggle always overrides it. Scoped in a `do` block (see T7c).
do
    package.loaded["features._defon_probe"] = {
        api = 1, id = "defon_probe", name = "Default On Probe",
        defaultEnabled = true, start = function() end,
    }
    registry.load("features._defon_probe")

    fake.settings["hammerdeck.enabled.defon_probe"] = nil
    ok(registry.isEnabled("defon_probe") == true,
        "defaultEnabled=true ships enabled when the user has never toggled it")
    fake.settings["hammerdeck.enabled.defon_probe"] = false
    ok(registry.isEnabled("defon_probe") == false,
        "an explicit user off overrides defaultEnabled=true")

    -- and a plain feature (no defaultEnabled) still ships OFF, as before.
    package.loaded["features._defoff_probe"] = {
        api = 1, id = "defoff_probe", name = "Default Off Probe", start = function() end,
    }
    registry.load("features._defoff_probe")
    fake.settings["hammerdeck.enabled.defoff_probe"] = nil
    ok(registry.isEnabled("defoff_probe") == false,
        "a feature without defaultEnabled stays off by default (blank-slate)")

    registry.unregister("defon_probe")
    registry.unregister("defoff_probe")
    fake.settings["hammerdeck.enabled.defon_probe"] = nil
end

-- labels must be a list parallel to values (and enum-only)
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
    options = { { key = "m", type = "enum", values = { "a", "b" }, labels = { "Only one" } } } }),
    "enum labels length must match values")
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
    options = { { key = "m", type = "string", labels = { "a" } } } }),
    "labels are rejected on a non-enum option")
-- multiline is a string-only boolean flag
ok(pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
    options = { { key = "s", type = "string", multiline = true } } }),
    "multiline accepted on a string option")
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
    options = { { key = "n", type = "int", multiline = true } } }),
    "multiline is rejected on a non-string option")
-- automatable: optional per-action boolean; default false; an automated
-- defaultTrigger implies it must be true.
do
    local m = manifest.validate({ api = 1, id = "x", name = "X", action = function() end })
    ok(m.actions[1].automatable == false, "automatable defaults to false")
    local m2 = manifest.validate({ api = 1, id = "y", name = "Y",
        actions = { { id = "a", run = function() end, automatable = true } } })
    ok(m2.actions[1].automatable == true, "automatable carried through when declared")
end
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X",
    actions = { { id = "a", run = function() end, automatable = "yes" } } }),
    "automatable must be a boolean")
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
    defaultTrigger = { type = "schedule", everyMin = 5 } }),
    "an automated defaultTrigger on a non-automatable action is rejected")
ok(pcall(manifest.validate, { api = 1, id = "x", name = "X",
    actions = { { id = "a", run = function() end, automatable = true,
        defaultTrigger = { type = "schedule", everyMin = 5 } } } }),
    "an automated defaultTrigger is fine when automatable = true")
-- context: optional grouping axis (when the feature applies); controlled vocab;
-- defaults to "anywhere".
do
    local m = manifest.validate({ api = 1, id = "ctxd", name = "Ctxd", action = function() end })
    ok(m.context == "anywhere", "context defaults to anywhere")
    local m2 = manifest.validate({ api = 1, id = "ctxw", name = "Ctxw", context = "window",
        action = function() end })
    ok(m2.context == "window", "context carried through when declared")
end
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", context = "nope",
    action = function() end }), "an unknown context value is rejected")
-- requires: optional OS-precondition list; controlled vocab; defaults to {}.
do
    local m = manifest.validate({ api = 1, id = "reqd", name = "Reqd", action = function() end })
    ok(type(m.requires) == "table" and #m.requires == 0, "requires defaults to an empty list")
    local m2 = manifest.validate({ api = 1, id = "reqa", name = "Reqa",
        requires = { "accessibility" }, action = function() end })
    ok(m2.requires[1] == "accessibility", "requires carried through when declared")
end
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X",
    requires = { "telepathy" }, action = function() end }),
    "an unknown requirement token is rejected")
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X",
    requires = "accessibility", action = function() end }),
    "requires must be a list, not a bare string")
-- recommended: optional boolean; the curated Essentials starter set.
do
    local m = manifest.validate({ api = 1, id = "recd", name = "Recd", action = function() end })
    ok(m.recommended == false, "recommended defaults to false")
    local m2 = manifest.validate({ api = 1, id = "rece", name = "Rece",
        recommended = true, action = function() end })
    ok(m2.recommended == true, "recommended carried through when declared")
end
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X",
    recommended = "yes", action = function() end }), "recommended must be a boolean")
-- mnemonic: optional per-action "why this key" string; carried through the
-- single-action sugar; rejected if not a string.
do
    local m = manifest.validate({ api = 1, id = "mn", name = "Mn", action = function() end,
        mnemonic = "P for Password" })
    ok(m.actions[1].mnemonic == "P for Password", "mnemonic flows through the single-action sugar")
    local m2 = manifest.validate({ api = 1, id = "mn2", name = "Mn2",
        actions = { { id = "a", run = function() end, mnemonic = "H for History" } } })
    ok(m2.actions[1].mnemonic == "H for History", "mnemonic carried through on an actions entry")
end
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X",
    actions = { { id = "a", run = function() end, mnemonic = 42 } } }),
    "mnemonic must be a string")
local sleepDesc = desc[2]
ok(sleepDesc.kind == "service" and sleepDesc.triggerDesc == "always-on service",
    "service features described as always-on")
ok(#sleepDesc.options == 6, "sleep_schedule exports all 6 options")
ok(sleepDesc.enabled == false, "describe reflects enabled state")

-- T7b: schedule() descriptor -> describe().schedule (the Automation Timeline) ----
-- A SERVICE's internal timers are invisible to the trigger model; the schedule
-- descriptor self-reports them. Derived times must track live option values,
-- and the editable rows carry the optionKey the Timeline writes through.
fake.settings["hammerdeck.opt.sleep_schedule.sleepAt"]   = "23:30"
fake.settings["hammerdeck.opt.sleep_schedule.warn1Min"]  = 10
fake.settings["hammerdeck.opt.sleep_schedule.warn2Min"]  = 5
fake.settings["hammerdeck.opt.sleep_schedule.hardCapAt"] = "01:00"
fake.settings["hammerdeck.opt.break_reminder.workMin"]   = 30
local descS = registry.describe()
local sched = {}
for _, e in ipairs(descS) do sched[e.id] = e.schedule end
ok(type(sched.sleep_schedule) == "table" and #sched.sleep_schedule == 4,
    "sleep_schedule reports 4 schedule entries")
ok(sched.sleep_schedule[1].kind == "at" and sched.sleep_schedule[1].at == "23:20",
    "first warning derived as sleepAt - warn1Min (23:30 - 10m)")
ok(sched.sleep_schedule[2].at == "23:25", "countdown overlay derived as sleepAt - warn2Min")
ok(sched.sleep_schedule[3].at == "23:30" and sched.sleep_schedule[3].optionKey == "sleepAt",
    "force-sleep marker maps to the sleepAt option for inline edit")
ok(sched.sleep_schedule[4].at == "01:00" and sched.sleep_schedule[4].optionKey == "hardCapAt",
    "hard-cap marker maps to the hardCapAt option")
ok(sched.sleep_schedule[1].optionKey == nil, "derived warnings are advisory (no optionKey)")
ok(sched.sleep_schedule[1].category == "health", "entries inherit the feature category")
ok(type(sched.break_reminder) == "table" and sched.break_reminder[1].kind == "everyMin"
    and sched.break_reminder[1].everyMin == 30 and sched.break_reminder[1].optionKey == "workMin",
    "break_reminder reports its recurring break from the live workMin option")
ok(sched.window_switcher == nil, "a feature with no schedule descriptor reports none")

-- malformed entries are skipped, not fatal; a throwing descriptor is quarantined
package.loaded["features._sched_probe"] = {
    api = 1, id = "sched_probe", name = "Sched Probe", category = "general",
    start = function() end,
    schedule = function()
        return {
            { label = "good", everyMin = 15 },
            { label = "bad-zero", everyMin = 0 },        -- skipped (non-positive)
            { everyMin = 5 },                            -- skipped (no label)
            { label = "bad-time", at = "9999" },         -- skipped (not HH:MM)
            { label = "out-of-range", at = "25:99" },    -- skipped (shape ok, range bad)
            { label = "note only", note = "after wake" },
        }
    end,
}
registry.load("features._sched_probe")
package.loaded["features._sched_throw"] = {
    api = 1, id = "sched_throw", name = "Sched Throw",
    start = function() end,
    schedule = function() error("boom") end,
}
registry.load("features._sched_throw")
local probeSched, throwRow
for _, e in ipairs(registry.describe()) do
    if e.id == "sched_probe" then probeSched = e.schedule end
    if e.id == "sched_throw" then throwRow = e end
end
ok(type(probeSched) == "table" and #probeSched == 2,
    "malformed schedule entries are dropped, valid ones kept")
ok(probeSched[2].kind == "note" and probeSched[2].note == "after wake",
    "a note entry routes to the conditions lane")
ok(throwRow ~= nil and throwRow.schedule == nil,
    "a throwing schedule() is quarantined -- describe() still returns the row")
registry.unregister("sched_probe")
registry.unregister("sched_throw")
-- the schedule field must be a function
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
    schedule = { { label = "nope" } } }),
    "schedule must be a function, not a table")

-- T8: re-enable works with fresh state ------------------------------------------
registry.setEnabled("window_switcher", true)
fake.pressHotkey("tab")
ok(fake.visibleChooser() ~= nil, "re-enabled feature works with a fresh ctx")
registry.setEnabled("window_switcher", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after re-enable cycle")

-- T9: plugin quarantine -- one bad plugin must never take the platform down ----
-- (a) a missing module is recorded, not thrown
ok(registry.load("features._does_not_exist") == nil, "load returns nil for a missing module")
ok(#registry.failures().load >= 1, "missing module recorded as a load failure")

-- (b) an invalid manifest fails at register, still quarantined
package.loaded["features._bad_manifest"] = { api = 1, id = "bad_manifest", name = "Bad" } -- no action/start
ok(registry.load("features._bad_manifest") == nil, "load returns nil for an invalid manifest")

-- (c) a feature that throws inside start(ctx) -- after creating a handle -- is
--     quarantined: enable doesn't throw, the partial scope is torn down, and
--     the failure is recorded + describable.
package.loaded["features._bad_start"] = {
    api = 1, id = "bad_start", name = "Bad Start",
    start = function(ctx)
        ctx.everySeconds(5, function() end)   -- a handle BEFORE the throw
        error("boom in start")
    end,
}
ok(registry.load("features._bad_start") ~= nil, "valid manifest with a throwing start registers fine")
ok(pcall(registry.setEnabled, "bad_start", true), "enabling a broken feature does not throw")
ok(registry.failures().start["bad_start"] ~= nil, "start failure recorded")
ok(registry.liveHandleCount() == 0, "broken start's partial handle was torn down")
ok(fake.liveHandles == 0, "no native resource leaked by the broken start")

local d = registry.describe()
local badRow, sawLoadFail = nil, false
for _, e in ipairs(d) do
    if e.id == "bad_start" then badRow = e end
    if e.category == "failed" then sawLoadFail = true end
end
ok(badRow ~= nil and badRow.failed == true, "describe marks the failed feature")
ok(sawLoadFail, "describe surfaces load failures as inert rows")

-- (d) disabling clears the recorded failure
registry.setEnabled("bad_start", false)
ok(registry.failures().start["bad_start"] == nil, "disable clears the start failure")

-- T10: trigger rebind -- bind ANY action to ANY trigger (the core promise) -----
local triggers = require("platform.triggers")

-- codec round-trips for every spec shape
local function roundtrip(spec) return triggers.decode(triggers.encode(spec)) end
local hk = roundtrip({ type = "hotkey", mods = { "cmd", "alt" }, key = "j" })
ok(hk.type == "hotkey" and hk.key == "j" and #hk.mods == 2, "hotkey codec round-trips")
ok(triggers.encode({ type = "hotkey", mods = { "cmd", "alt" }, key = "j" })
    == triggers.encode({ type = "hotkey", mods = { "alt", "cmd" }, key = "j" }),
    "hotkey encoding is canonical (mod order does not matter)")
ok(roundtrip({ type = "schedule", everyMin = 25 }).everyMin == 25, "schedule-every codec round-trips")
ok(roundtrip({ type = "schedule", at = "00:30" }).at == "00:30", "schedule-at codec round-trips")
ok(roundtrip({ type = "event", event = "wake" }).event == "wake", "event codec round-trips")
ok(triggers.decode("garbage") == nil, "decode rejects a malformed string")
ok(triggers.decode("event|bogus") == nil, "decode rejects an unknown event")

-- shared HH:MM parse: valid times parse to numbers, out-of-range/malformed reject
do
    local h, m = triggers.parseTimeOfDay("09:05")
    ok(h == 9 and m == 5, "parseTimeOfDay reads a valid HH:MM")
    local zh, zm = triggers.parseTimeOfDay("00:00")
    ok(zh == 0 and zm == 0, "parseTimeOfDay reads midnight (0 is a valid hour)")
    ok(triggers.parseTimeOfDay("29:99") == nil, "parseTimeOfDay rejects out-of-range 29:99")
    ok(triggers.parseTimeOfDay("8:5") == nil, "parseTimeOfDay rejects a 1-digit minute")
    ok(triggers.parseTimeOfDay("8") == nil, "parseTimeOfDay rejects a bare hour")
end
-- the gap the unified util closes: decode used to accept an out-of-range "at"
ok(triggers.decode("schedule|at|29:99") == nil, "decode rejects an out-of-range schedule at")
ok(triggers.decode("schedule|at|07:30").at == "07:30", "decode still accepts a valid schedule at")

-- validate rejects malformed specs
ok(not pcall(triggers.validate, { type = "hotkey" }), "validate rejects a hotkey with no key")
ok(not pcall(triggers.validate, { type = "event", event = "nope" }), "validate rejects an unknown event")
ok(not pcall(triggers.validate, { type = "schedule" }), "validate rejects a schedule with no when")
ok(not pcall(triggers.validate, { type = "schedule", at = "29:99" }),
    "validate rejects a schedule with an out-of-range at")

-- modifier NAMES are validated too (the Swift parsers used to drop an unknown
-- name silently, binding a less-modified combo); long aliases stay accepted.
ok(not pcall(triggers.validate, { type = "hotkey", mods = { "cmmd" }, key = "k" }),
    "validate rejects a hotkey with an unknown modifier")
ok(not pcall(triggers.validate, { type = "chord", mods = { "hyper" }, key = "a", follows = { "b" } }),
    "validate rejects a chord with an unknown modifier")
ok(pcall(triggers.validate, { type = "hotkey", mods = { "Command", "option" }, key = "k" }),
    "validate accepts long modifier aliases, case-insensitive")

-- the fake adapter mirrors the seam's loud token rejection (KeyModifier.swift):
-- a typo'd token errors in tests exactly like the real bridge would.
ok(not pcall(fake.adapter.bindHotkey, { "cmmd" }, "k", function() end),
    "fake bind_hotkey rejects an unknown modifier")
ok(not pcall(fake.adapter.keyStroke, { "comd" }, "v"), "fake key_stroke rejects an unknown modifier")
ok(not pcall(fake.adapter.keyStroke, { true }, "v"), "fake key_stroke rejects a non-string modifier")
ok(not pcall(fake.adapter.isModifierHeld, "atl"), "fake is_modifier_held rejects an unknown modifier")
ok(not pcall(fake.adapter.setAppearance, "drak"), "fake set_appearance rejects an unknown mode")
ok(pcall(fake.adapter.setAppearance, "toggle") and pcall(fake.adapter.setAppearance, nil),
    "fake set_appearance accepts toggle and nil (= toggle)")

-- spec -> string formatters (the verbose describe + compact glyph forms)
ok(triggers.describe(nil) == "no trigger", "describe: nil -> no trigger")
ok(triggers.describe({ type = "hotkey", mods = { "cmd", "shift" }, key = "v" })
    == "hotkey: cmd+shift+v", "describe: hotkey")
ok(triggers.describe({ type = "chord", mods = { "cmd" }, key = "a", follows = { "b", "c" } })
    == "chord: cmd+a then b c", "describe: chord")
ok(triggers.describe({ type = "schedule", everyMin = 25 }) == "schedule: every 25 min", "describe: schedule-every")
ok(triggers.describe({ type = "schedule", at = "00:30" }) == "schedule: daily at 00:30", "describe: schedule-at")
ok(triggers.describe({ type = "event", event = "wake" }) == "event: wake", "describe: event")
ok(triggers.glyph(nil) == nil, "glyph: nil -> nil")
ok(triggers.glyph({ type = "hotkey", mods = { "cmd", "shift" }, key = "v" }) == "⇧⌘V", "glyph: hotkey canonical order + upcase")
ok(triggers.glyph({ type = "hotkey", mods = { "control", "option" }, key = "left" }) == "⌃⌥←",
    "glyph: long-form mod aliases + named key")
ok(triggers.glyph({ type = "chord", mods = { "cmd" }, key = "a", follows = { "b" } }) == "⌘A B", "glyph: chord (follow keys upcased)")
ok(triggers.glyph({ type = "schedule", everyMin = 180 }) == "every 180m", "glyph: schedule-every")
ok(triggers.glyph({ type = "event", event = "wake" }) == "on wake", "glyph: event")

-- live rebind on a synthetic probe (counter action, no chooser state to manage)
local fires = 0
package.loaded["features._rebind_probe"] = {
    api = 1, id = "rebind_probe", name = "Rebind Probe",
    defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "p" },
    action = function() fires = fires + 1 end,
}
registry.load("features._rebind_probe")
registry.setEnabled("rebind_probe", true)
fake.pressHotkey("p")
ok(fires == 1, "default trigger fires the action")
ok(registry.setTrigger("rebind_probe", { type = "hotkey", mods = { "ctrl" }, key = "q" }) == true,
    "setTrigger rebinds successfully")
fake.pressHotkey("p")
ok(fires == 1, "the old hotkey no longer fires after rebind")
fake.pressHotkey("q")
ok(fires == 2, "the new hotkey fires the rebound action")
ok(fake.settings["hammerdeck.trigger.rebind_probe.main"] == "hotkey|ctrl|q",
    "the override is persisted as an encoded string (per-action key)")

-- conflict: a second enabled feature already owns ctrl+q
local fires2 = 0
package.loaded["features._rebind_other"] = {
    api = 1, id = "rebind_other", name = "Other Probe",
    defaultTrigger = { type = "hotkey", mods = { "alt" }, key = "z" },
    action = function() fires2 = fires2 + 1 end,
}
registry.load("features._rebind_other")
registry.setEnabled("rebind_other", true)
local okSet, reason = registry.setTrigger("rebind_other", { type = "hotkey", mods = { "ctrl" }, key = "q" })
ok(okSet == false and reason ~= nil, "setTrigger refuses a hotkey already taken by an enabled feature")
fake.pressHotkey("z")
ok(fires2 == 1, "the rejected rebind left the original binding intact")

-- a service has no rebindable trigger
ok(not pcall(registry.setTrigger, "sleep_schedule", { type = "event", event = "wake" }),
    "setTrigger rejects always-on service features")

-- describe exposes the editable trigger + override flag
local probeDesc
for _, d in ipairs(registry.describe()) do if d.id == "rebind_probe" then probeDesc = d end end
ok(probeDesc.actions[1].trigger and probeDesc.actions[1].trigger.key == "q",
    "describe exposes the current trigger spec")
ok(probeDesc.actions[1].triggerOverridden == true, "describe reports the override state")

-- automatable policy: schedule/event are the automated trigger types ----------
ok(triggers.isAutomated({ type = "schedule", everyMin = 5 }) == true, "schedule is automated")
ok(triggers.isAutomated({ type = "event", event = "wake" }) == true, "event is automated")
ok(triggers.isAutomated({ type = "hotkey", key = "p" }) == false, "hotkey is not automated")
ok(triggers.isAutomated({ type = "chord", key = "a", follows = { "b" } }) == false, "chord is not automated")

-- rebind_probe is the default (non-automatable): the seam refuses an automated
-- trigger but still accepts a manual one, and describe reports the flag.
ok(probeDesc.actions[1].automatable == false, "describe surfaces automatable=false by default")
local okAuto, whyAuto = registry.setTrigger("rebind_probe", { type = "schedule", everyMin = 5 })
ok(okAuto == false and whyAuto ~= nil, "seam refuses a schedule trigger on a non-automatable action")
local okAuto2 = registry.setTrigger("rebind_probe", { type = "event", event = "wake" })
ok(okAuto2 == false, "seam refuses an event trigger on a non-automatable action")

-- an automatable action accepts an automated trigger
local autoFires = 0
package.loaded["features._auto_probe"] = {
    api = 1, id = "auto_probe", name = "Auto Probe",
    actions = { { id = "main", automatable = true, run = function() autoFires = autoFires + 1 end } },
}
registry.load("features._auto_probe")
registry.setEnabled("auto_probe", true)
ok(registry.setTrigger("auto_probe", { type = "schedule", everyMin = 15 }) == true,
    "seam accepts a schedule trigger on an automatable action")
local autoDesc
for _, d in ipairs(registry.describe()) do if d.id == "auto_probe" then autoDesc = d end end
ok(autoDesc.actions[1].automatable == true, "describe surfaces automatable=true")
registry.setEnabled("auto_probe", false)
registry.unregister("auto_probe")

-- bind-on-load enforcement: a STALE stored automated override on a
-- non-automatable action (e.g. left behind after an author dropped automatable,
-- or hand-edited) must be ignored on read, not bound. rebind_probe is the
-- non-automatable hotkey probe; plant a schedule override directly in settings.
fake.settings["hammerdeck.trigger.rebind_probe.main"] = "schedule|every|5"
do
    local staleDesc
    for _, d in ipairs(registry.describe()) do if d.id == "rebind_probe" then staleDesc = d end end
    ok(staleDesc.actions[1].trigger.type == "hotkey",
        "a stale automated override on a non-automatable action is ignored (falls back to default)")
end
fake.settings["hammerdeck.trigger.rebind_probe.main"] = nil

-- clearTrigger reverts to the manifest default
registry.clearTrigger("rebind_probe")
ok(fake.settings["hammerdeck.trigger.rebind_probe.main"] == nil
    and fake.settings["hammerdeck.trigger.rebind_probe"] == nil,
    "clearTrigger removes the override")
fake.pressHotkey("p")
ok(fires == 3, "clearTrigger restored the default trigger")
fake.pressHotkey("q")
ok(fires == 3, "the override key is no longer bound after clear")

-- swapTriggers exchanges two actions' shortcuts (the Shortcut Map drag-to-swap).
-- probe is ctrl+p, other is alt+z; after the swap they trade.
local pf, of = fires, fires2
ok(registry.swapTriggers("rebind_probe", "main", "rebind_other", "main") == true,
    "swapTriggers returns true")
ok(fake.settings["hammerdeck.trigger.rebind_probe.main"] == "hotkey|alt|z",
    "probe took the other's hotkey (persisted)")
ok(fake.settings["hammerdeck.trigger.rebind_other.main"] == "hotkey|ctrl|p",
    "other took the probe's hotkey (persisted)")
fake.pressHotkey("z", { "alt" })
ok(fires == pf + 1, "after swap, probe fires on alt+z (the other's old key)")
fake.pressHotkey("p", { "ctrl" })
ok(fires2 == of + 1, "after swap, other fires on ctrl+p (the probe's old key)")
ok(fires == pf + 1, "probe no longer fires on ctrl+p")

registry.setEnabled("rebind_probe", false)
registry.setEnabled("rebind_other", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after trigger-rebind tests")

-- T11: hot reload -- re-read the catalog from disk, keep enabled-state ---------
-- Uses the real on-disk MVP modules (recorded as the catalog in T1), so the
-- package.loaded invalidation + re-require-from-disk path runs for real.
registry.setEnabled("window_switcher", true)
ok(registry.liveHandleCount() >= 1, "an enabled feature has a live binding before reload")

local summary = registry.reload()
ok(summary.count == 3, "reload re-registered exactly the catalog features")
ok(summary.failures == 0, "reload reported no load failures")
ok(registry.isEnabled("window_switcher"), "enabled-state persisted across reload")
ok(registry.liveHandleCount() >= 1, "reload re-bound the enabled feature")

-- the freshly re-required feature actually works (closure state was rebuilt)
fake.pressHotkey("tab")
ok(fake.visibleChooser() ~= nil, "feature functions after a hot reload")
fake.visibleChooser().userSelect(1)

-- a feature left disabled is registered but not bound after reload
local svcEnabled
for _, d in ipairs(registry.describe()) do
    if d.id == "sleep_schedule" then svcEnabled = d.enabled end
end
ok(svcEnabled == false, "a disabled feature stays disabled after reload")

-- the synthetic probes from T9/T10 (not in the catalog) are gone after reload
local stillHasProbe = false
for _, d in ipairs(registry.describe()) do
    if d.id == "rebind_probe" then stillHasProbe = true end
end
ok(not stillHasProbe, "non-catalog features are dropped by reload")

registry.setEnabled("window_switcher", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after hot-reload test")

-- T12: display_off (service: warn after idle, sleep display after lead time) ---
registry.register(require("features.display_off"))
fake.settings["hammerdeck.opt.display_off.idleThresholdMin"] = 5   -- 300s
-- (the 10s warning lead time is a constant now, not an option)
local dimsBefore   = fake.actions.displaySleep
local alertsBefore = #fake.alerts
registry.setEnabled("display_off", true)

-- active: no warning, no display sleep
fake.idle = 10
fake.fireTimers("every", 5)
ok(#fake.alerts == alertsBefore, "active: no idle warning")
ok(fake.actions.displaySleep == dimsBefore, "active: display not slept")

-- idle past threshold: warn exactly once
fake.idle = 6 * 60
fake.fireTimers("every", 5)
ok(#fake.alerts == alertsBefore + 1, "idle past threshold: warning shown")
fake.fireTimers("every", 5)
ok(#fake.alerts == alertsBefore + 1, "warning shown only once")
ok(fake.actions.displaySleep == dimsBefore, "no display sleep before the lead time")

-- lead time elapses: display sleeps exactly once
fake.clockOffset = fake.clockOffset + 10
fake.fireTimers("every", 5)
ok(fake.actions.displaySleep == dimsBefore + 1, "display slept after the lead time")
fake.fireTimers("every", 5)
ok(fake.actions.displaySleep == dimsBefore + 1, "display sleep fired only once")

-- returning to activity re-arms the cycle
fake.idle = 0
fake.fireTimers("every", 5)
fake.idle = 6 * 60
fake.fireTimers("every", 5)
ok(#fake.alerts == alertsBefore + 2, "returning to activity re-arms the warning")

registry.setEnabled("display_off", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after display_off test")

-- T13: plain_paste (action: rewrite clipboard as trimmed plain text) -------
registry.register(require("features.plain_paste"))
registry.setEnabled("plain_paste", true)

-- plainText mode: trims (and the string round-trip strips formatting)
fake.settings["hammerdeck.opt.plain_paste.mode"] = "plainText"
fake.pasteboard = "   padded text\t "
fake.pressHotkey("v")
ok(fake.pasteboard == "padded text", "plainText mode trims the clipboard")

-- newlinesToCommas mode
fake.settings["hammerdeck.opt.plain_paste.mode"] = "newlinesToCommas"
fake.pasteboard = "a\nb\r\nc"
fake.pressHotkey("v")
ok(fake.pasteboard == "a,b,c", "newlinesToCommas mode joins lines with commas")

-- empty clipboard: alert, no write
fake.pasteboard = ""
local alertsBefore = #fake.alerts
fake.pressHotkey("v")
ok(#fake.alerts == alertsBefore + 1, "empty clipboard alerts")
ok(fake.pasteboard == "", "empty clipboard left unchanged")

-- one behavior: clean, then a synthesized cmd+v after the settle wait
-- (immediate synthesis would merge with the still-held trigger modifiers)
fake.settings["hammerdeck.opt.plain_paste.mode"] = "plainText"
fake.pasteboard = "  pasted for you  "
local keysBefore = #fake.keyEvents
fake.pressHotkey("v")
ok(fake.pasteboard == "pasted for you" and #fake.keyEvents == keysBefore,
    "cleans immediately; the paste waits for the settle timer")
fake.fireTimers("after", 0.5)
local pasteKey = fake.keyEvents[#fake.keyEvents]
ok(pasteKey.key == "v" and pasteKey.mods[1] == "cmd", "then pastes (cmd+v)")

-- the "type" action types the cleaned clipboard as keystrokes
fake.pasteboard = "  secret token\n"
fake.pressHotkey("y")
ok(fake.typedTexts[#fake.typedTexts] == "secret token",
    "type action types the trimmed clipboard as keystrokes")

registry.setEnabled("plain_paste", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after plain_paste test")

-- T13c: password_generator (action: build a random password, copy to clipboard) --
registry.register(require("features.password_generator"))
fake.settings["hammerdeck.opt.password_generator.length"]         = 24
fake.settings["hammerdeck.opt.password_generator.avoidAmbiguous"] = true
registry.setEnabled("password_generator", true)

local pwNotes = #fake.notifications
fake.pasteboard = nil
fake.pressHotkey("p")
local pw = fake.pasteboard
ok(type(pw) == "string" and #pw == 24, "password_generator copies a 24-char password")
ok(#fake.notifications == pwNotes + 1, "password_generator notifies on copy")

-- avoidAmbiguous strips 0 O 1 l I; all four enabled classes still appear
ok(not pw:find("[0O1lI]"), "avoidAmbiguous strips ambiguous glyphs")
ok(pw:find("%l") and pw:find("%u") and pw:find("%d") and pw:find("[^%w]"),
    "all four character classes appear in the password")

-- consecutive generations differ (randomness sanity)
fake.pressHotkey("p"); local pw2 = fake.pasteboard
fake.pressHotkey("p"); local pw3 = fake.pasteboard
ok(pw2 ~= pw3, "consecutive passwords differ")

-- length floor: a length below the enabled-class count still fits one of each
fake.settings["hammerdeck.opt.password_generator.length"] = 2   -- < 4 classes
fake.pressHotkey("p")
ok(#fake.pasteboard == 4, "length below the class count widens to one char per class")

-- no character set enabled: clipboard untouched, a guidance notification fires
fake.settings["hammerdeck.opt.password_generator.lowercase"] = false
fake.settings["hammerdeck.opt.password_generator.uppercase"] = false
fake.settings["hammerdeck.opt.password_generator.digits"]    = false
fake.settings["hammerdeck.opt.password_generator.symbols"]   = false
fake.pasteboard = "UNCHANGED"
pwNotes = #fake.notifications
fake.pressHotkey("p")
ok(fake.pasteboard == "UNCHANGED", "no character set enabled: clipboard untouched")
ok(#fake.notifications == pwNotes + 1, "no character set enabled: guidance notification")

registry.setEnabled("password_generator", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after password_generator test")

-- (volume + media_keys were demoted from features to rules effect kinds; their
-- behavior is now covered by the effect-dispatch tests in T39.)

-- T13c2: describe() localizes feature metadata via per-feature catalogs --------
-- describe() applies i18n at CALL time: switch the locale, re-describe, and the
-- gallery/settings text returns translated -- the 8 SwiftUI views are unchanged
-- (they render whatever describe() returns). Reset to "en" so the rest of the
-- suite sees the English source. Runs here because the features it asserts on
-- (window_switcher / plain_paste / password_generator) are all registered now.
do
    local i18n = require("platform.i18n")
    i18n.configure({ locale = "zh-Hans", appdir = "app" })

    local byId = {}
    for _, d in ipairs(registry.describe()) do byId[d.id] = d end

    ok(byId.window_switcher and byId.window_switcher.name == "窗口切换器",
        "describe() localizes a feature name")
    ok(byId.plain_paste and byId.plain_paste.description
        and byId.plain_paste.description:find("无格式", 1, true) ~= nil,
        "describe() localizes a feature description")

    local mainAction
    for _, a in ipairs(byId.plain_paste.actions) do
        if a.id == "main" then mainAction = a end
    end
    ok(mainAction and mainAction.label == "粘贴为纯文本",
        "describe() localizes a per-action label")

    local modeOpt
    for _, o in ipairs(byId.plain_paste.options) do
        if o.key == "mode" then modeOpt = o end
    end
    ok(modeOpt and modeOpt.label == "转换", "describe() localizes an option label")
    ok(modeOpt and modeOpt.labels[1] == "纯文本" and modeOpt.labels[2] == "换行转逗号",
        "describe() localizes enum value labels (parallel to values)")

    -- field-level fallback: password_generator's NAME is translated, but it ships
    -- no action.<id>.label key, so the action label stays the English source.
    ok(byId.password_generator and byId.password_generator.name == "密码生成器"
        and byId.password_generator.actions[1].label == "Password Generator",
        "describe() falls back per-field to inline English for untranslated keys")

    -- Phase 3: runtime strings (the ctx.t call sites in features) resolve from
    -- the SAME per-feature catalogs, including interpolation placeholders.
    ok(i18n.tFeature("clipboard_history", "alert.empty", "x") == "剪贴板历史为空",
        "runtime ctx.t key resolves (clipboard_history alert)")
    ok(i18n.tFeature("text_actions", "alert.nothingSelected", "x") == "没有选中内容",
        "runtime ctx.t key resolves (text_actions alert)")
    ok(string.format(i18n.tFeature("count_down", "notify.up.title", "Time (%d min) is up!"), 5)
        == "时间 (5 分钟) 到了!",
        "runtime ctx.t key resolves with interpolation (count_down notify)")

    -- reset to the source language for the remaining assertions.
    i18n.configure({ locale = "en" })
    local backToEn
    for _, d in ipairs(registry.describe()) do
        if d.id == "window_switcher" then backToEn = d.name end
    end
    ok(backToEn == "Window Switcher",
        "describe() returns inline English when the locale resets to en")
end

-- T13d: insert_datetime (action: type the formatted current time) -------------
registry.register(require("features.insert_datetime"))
registry.setEnabled("insert_datetime", true)

-- a preset format types os.date(fmt, ctx.now()) -- driven by the fake clock
fake.settings["hammerdeck.opt.insert_datetime.format"] = "%Y-%m-%d %H:%M:%S"
local idtTyped = #fake.typedTexts
fake.pressHotkey("d")
ok(#fake.typedTexts == idtTyped + 1
    and fake.typedTexts[#fake.typedTexts] == os.date("%Y-%m-%d %H:%M:%S", fake.now()),
    "insert_datetime types the preset-formatted current time")

-- Custom format selected + a custom pattern set -> uses the custom pattern
fake.settings["hammerdeck.opt.insert_datetime.format"]       = "custom"
fake.settings["hammerdeck.opt.insert_datetime.customFormat"] = "%Y/%m/%d"
fake.pressHotkey("d")
ok(fake.typedTexts[#fake.typedTexts] == os.date("%Y/%m/%d", fake.now()),
    "insert_datetime honors a custom strftime pattern")

-- Custom selected but the field is empty -> nothing typed, a guidance note fires
fake.settings["hammerdeck.opt.insert_datetime.customFormat"] = ""
idtTyped = #fake.typedTexts
local idtNotes = #fake.notifications
fake.pressHotkey("d")
ok(#fake.typedTexts == idtTyped, "insert_datetime types nothing when custom format is empty")
ok(#fake.notifications == idtNotes + 1, "insert_datetime notifies when custom format is empty")

-- An INVALID strftime pattern RAISES in os.date -- the guard must catch it
-- (notify), not crash the action.
fake.settings["hammerdeck.opt.insert_datetime.customFormat"] = "%Q"
idtTyped = #fake.typedTexts
idtNotes = #fake.notifications
fake.pressHotkey("d")
ok(#fake.typedTexts == idtTyped, "insert_datetime types nothing on an invalid pattern")
ok(#fake.notifications == idtNotes + 1, "insert_datetime notifies (not crashes) on an invalid pattern")

-- The "Preview" validator button (optionAction) mirrors the action: it alerts
-- the formatted result for a good pattern and the reason for a bad one.
fake.settings["hammerdeck.opt.insert_datetime.customFormat"] = "%Y/%m/%d"
local idtAlerts = #fake.alerts
ok(registry.runOptionAction("insert_datetime", "customFormat") == true,
    "insert_datetime Preview button runs")
ok(#fake.alerts == idtAlerts + 1
    and fake.alerts[#fake.alerts]:find(os.date("%Y/%m/%d", fake.now()), 1, true),
    "Preview alerts the formatted current time for a valid pattern")
fake.settings["hammerdeck.opt.insert_datetime.customFormat"] = "%Q"
registry.runOptionAction("insert_datetime", "customFormat")
ok(fake.alerts[#fake.alerts]:find("Invalid", 1, true),
    "Preview alerts an Invalid-format message for a bad pattern")

registry.setEnabled("insert_datetime", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after insert_datetime test")

-- T14: feature autodiscovery -- scan the features dir instead of a fixed list --
-- (the fake adapter exposes bare names; the real modules are on disk, so the
--  re-require path works.)
fake.featureNames = { "window_switcher", "display_off", "plain_paste", "break_reminder", "sleep_schedule" }

local discovered = registry.discover("ignored-by-fake")
ok(#discovered == 5, "discover returns one module per feature on disk")
ok(discovered[1] == "features.break_reminder", "discover sorts + prefixes module names")

-- Switch to discovery mode and reload: it re-scans and ends with exactly the
-- discovered set (this also drops the non-catalog test probes from T9/T10).
registry.setFeatureDir("ignored-by-fake")
local sum = registry.reload()
ok(sum.count == 5 and sum.failures == 0, "reload in discovery mode loads the scanned features")

-- Hot-plug: a name newly appearing in the scan shows up on the next reload;
-- one that disappears is dropped.
fake.featureNames = { "window_switcher" }
local sum2 = registry.reload()
ok(sum2.count == 1, "reload re-scans -- a removed feature folder is dropped")
ok(registry.describe()[1].id == "window_switcher", "the surviving feature is the discovered one")

ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after autodiscovery test")

-- T15: multi-action features -- one plugin, several shortcuts ------------------
local hits = { a = 0, b = 0 }
local starts = 0
package.loaded["features._multi"] = {
    api = 1, id = "multi", name = "Multi",
    start = function(ctx) starts = starts + 1 end,   -- service + actions combo
    actions = {
        { id = "alpha", label = "Alpha",
          defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "1" },
          run = function() hits.a = hits.a + 1 end },
        { id = "beta", label = "Beta",
          defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "2" },
          run = function() hits.b = hits.b + 1 end },
    },
}
registry.load("features._multi")
registry.setEnabled("multi", true)
ok(starts == 1, "service starts alongside its actions")
fake.pressHotkey("1"); fake.pressHotkey("2")
ok(hits.a == 1 and hits.b == 1, "both actions fire on their own hotkeys")

-- per-action rebind: siblings and the running service are untouched
ok(registry.setTrigger("multi", "beta", { type = "hotkey", mods = { "ctrl" }, key = "3" }) == true,
    "one action rebinds")
ok(starts == 1, "rebinding one action does not restart the service")
fake.pressHotkey("2")
ok(hits.b == 1, "the rebound action's old key is dead")
fake.pressHotkey("3"); fake.pressHotkey("1")
ok(hits.b == 2 and hits.a == 2, "new key fires; the sibling action is unaffected")
ok(fake.settings["hammerdeck.trigger.multi.beta"] == "hotkey|ctrl|3",
    "per-action override key persisted")

-- sibling actions cannot collide on a hotkey
local okSet2, why2 = registry.setTrigger("multi", "alpha", { type = "hotkey", mods = { "ctrl" }, key = "3" })
ok(okSet2 == false and why2 ~= nil, "sibling actions cannot share a hotkey")

-- new-shape manifest validation
rejects({ api = 1, id = "x", name = "X", action = function() end,
          actions = { { id = "a", run = function() end } } }, "action AND actions together")
rejects({ api = 1, id = "x", name = "X",
          actions = { { id = "a", run = function() end },
                      { id = "a", run = function() end } } }, "duplicate action ids")
rejects({ api = 1, id = "x", name = "X", actions = { { id = "a" } } }, "action without run")

-- describe carries per-action trigger state
local multiDesc
for _, d in ipairs(registry.describe()) do if d.id == "multi" then multiDesc = d end end
ok(#multiDesc.actions == 2 and multiDesc.actions[2].id == "beta"
    and multiDesc.actions[2].trigger.key == "3"
    and multiDesc.actions[2].triggerOverridden == true,
    "describe exports per-action trigger state")
ok(multiDesc.kind == "service" and multiDesc.triggerDesc == "always-on service",
    "service+actions still reads as a service in the list")

-- legacy stored key (pre-multi-action) is honored for single-action sugar
package.loaded["features._legacy"] = {
    api = 1, id = "legacy", name = "Legacy",
    defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "8" },
    action = function() hits.a = hits.a + 100 end,
}
registry.load("features._legacy")
fake.settings["hammerdeck.trigger.legacy"] = "hotkey|ctrl|9"   -- old-style override
registry.setEnabled("legacy", true)
fake.pressHotkey("9")
ok(hits.a == 102, "legacy hammerdeck.trigger.<id> override is honored for sugar features")

registry.setEnabled("multi", false)
registry.setEnabled("legacy", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after multi-action tests")

-- T16: count_down (multi-action spoon port: prompt -> bar -> notify) -----------
registry.register(require("features.count_down"))
registry.setEnabled("count_down", true)

fake.fireChord({ "cmd", "alt", "ctrl" }, "c", { "c" })
local prompt = fake.openTextPrompt()
ok(prompt ~= nil, "countdown start prompts for minutes")
ok(prompt.default == "5", "prompt suggests the defaultMinutes option")
prompt.submit("2")                              -- 2 minutes = 120 ticks
local cdBar = fake.liveProgressBar()
ok(cdBar ~= nil, "countdown shows a progress strip")
fake.fireTimers("every", 1)
ok(math.abs(cdBar.fraction - 1 / 120) < 1e-9, "progress advances per second")

-- pause/resume now ships as a sibling chord under the same prefix (Hyper+C P)
fake.fireChord({ "cmd", "alt", "ctrl" }, "c", { "p" })   -- pause
ok(fake.fireTimers("every", 1) == 0, "paused countdown stops ticking")
fake.fireChord({ "cmd", "alt", "ctrl" }, "c", { "p" })   -- resume
ok(fake.fireTimers("every", 1) == 1, "resume restarts the tick")

-- invoking start while running cancels
fake.fireChord({ "cmd", "alt", "ctrl" }, "c", { "c" })
ok(fake.liveProgressBar() == nil, "start-while-running cancels the countdown")

-- completion notifies and clears the bar
fake.fireChord({ "cmd", "alt", "ctrl" }, "c", { "c" })
fake.openTextPrompt().submit("1")               -- 60 ticks
local cdN = #fake.notifications
for _ = 1, 60 do fake.fireTimers("every", 1) end
ok(#fake.notifications == cdN + 1, "completion notifies")
ok(fake.liveProgressBar() == nil, "completion clears the strip")

-- a dismissed prompt starts nothing
fake.fireChord({ "cmd", "alt", "ctrl" }, "c", { "c" })
fake.openTextPrompt().submit(nil)               -- Escape
ok(fake.liveProgressBar() == nil, "dismissed prompt starts nothing")

registry.setEnabled("count_down", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after count_down test")

-- T17: locate_pointer (locate pointer) -------------------------------------------
registry.register(require("features.locate_pointer"))
registry.setEnabled("locate_pointer", true)
fake.mouseLocates = {}   -- fresh recorder: this block asserts absolute counts/indices
fake.fireChord({ "cmd", "alt", "ctrl" }, "m", { "m" })
ok(#fake.mouseLocates == 1 and fake.mouseLocates[1] == 3,
    "locate-pointer fires with the configured duration")
fake.settings["hammerdeck.opt.locate_pointer.seconds"] = 7
fake.fireChord({ "cmd", "alt", "ctrl" }, "m", { "m" })
ok(fake.mouseLocates[2] == 7, "duration option applies live")
-- center the pointer on the focused window (sibling chord Hyper+M C)
fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
fake.fireChord({ "cmd", "alt", "ctrl" }, "m", { "c" })
ok(fake.mousePos.x == 300 and fake.mousePos.y == 250, "Hyper+M C centers the pointer on the window")
ok(fake.mouseLocates[#fake.mouseLocates] == 1, "and flashes the locator")
-- center the pointer on a screen (Hyper+M N = next display, wraps; Hyper+M S = main)
fake.screenList = {
    { x = 0,    y = 0, w = 1440, h = 900,  name = "Built-in", index = 1 },
    { x = 1440, y = 0, w = 2560, h = 1440, name = "DELL",     index = 2 },
}
fake.mousePos = { x = 10, y = 10 }   -- pointer parked on the Built-in screen
fake.fireChord({ "cmd", "alt", "ctrl" }, "m", { "n" })
ok(fake.mousePos.x == 2720 and fake.mousePos.y == 720, "Hyper+M N flings the pointer to the next display's center")
ok(fake.mouseLocates[#fake.mouseLocates] == 1, "and flashes the locator")
fake.fireChord({ "cmd", "alt", "ctrl" }, "m", { "n" })   -- now on DELL -> wraps back to the first
ok(fake.mousePos.x == 720 and fake.mousePos.y == 450, "Hyper+M N wraps from the last display back to the first")
fake.mousePos = { x = 2000, y = 100 }   -- pointer parked on DELL
fake.fireChord({ "cmd", "alt", "ctrl" }, "m", { "s" })
ok(fake.mousePos.x == 720 and fake.mousePos.y == 450, "Hyper+M S centers the pointer on the main screen")
-- active screen (Hyper+M A) = the screen holding the focused window; falls back
-- to the main screen when nothing is focused.
fake.focusedWindow = { x = 1500, y = 100, w = 400, h = 300, screenIndex = 2 }  -- on DELL
fake.mousePos = { x = 10, y = 10 }
fake.fireChord({ "cmd", "alt", "ctrl" }, "m", { "a" })
ok(fake.mousePos.x == 2720 and fake.mousePos.y == 720,
    "Hyper+M A centers the pointer on the active window's screen (DELL)")
fake.focusedWindow = nil
fake.mousePos = { x = 2000, y = 100 }   -- pointer parked on DELL
fake.fireChord({ "cmd", "alt", "ctrl" }, "m", { "a" })
ok(fake.mousePos.x == 2720 and fake.mousePos.y == 720,
    "Hyper+M A falls back to the pointer's screen (DELL) when nothing is focused")
fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1 } }
registry.setEnabled("locate_pointer", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after locate_pointer test")

-- T18: json decoder + bing_daily (service + dormant refresh action) ------------
local jsonlib = require("platform.json")
local jd = jsonlib.decode
ok(jd('{"a":1,"b":[true,false,"x"],"c":{"d":-2.5e2}}').c.d == -250, "json: nested object/array/number")
ok(jd('[1,2,3]')[3] == 3, "json: plain array")
ok(jd('"a\\"b\\n\\u0041\\ud83d\\ude00"') == 'a"b\nA\240\159\152\128', "json: escapes incl. surrogate pair")
ok(jd('  true  ') == true, "json: bare literal with whitespace")
ok(jd('{"a":}') == nil, "json: malformed -> nil")
ok(jd('[1,2,]') == nil, "json: trailing comma -> nil")
ok(jd('{"a":1} x') == nil, "json: trailing garbage -> nil")

-- __jsontype tags: array vs object disambiguation (decisive for empty tables),
-- honored symmetrically by encode (the Swift bridge reads the same metafield).
local je = jsonlib.encode
ok(je(jsonlib.asObject({})) == "{}", "json: empty object tag encodes as {}")
ok(je(jsonlib.asArray({})) == "[]", "json: empty array tag encodes as []")
ok(je({}) == "[]", "json: untagged empty table stays [] (back-compat default)")
ok(je(jd("{}")) == "{}", "json: decode->encode keeps an empty object")
ok(je(jd("[]")) == "[]", "json: decode->encode keeps an empty array")
ok(je(jsonlib.asObject({ a = 1 })) == '{"a":1}', "json: non-empty object unchanged by tag")
ok(select(2, je({ 1, 2, x = "oops" })) ~= nil,
    "json: a mixed array+string-key table is rejected loudly, not silently dropped")
-- The command_palette legacy case: a map persisted as "[]" decodes array-tagged;
-- re-tagging it object lets string keys be added and re-encoded without error.
local relabelled = jsonlib.asObject(jd("[]") --[[@as table]]); relabelled.k = 1
ok(je(relabelled) == '{"k":1}', "json: asObject re-tags a decoded [] so a map built on it is safe")

registry.register(require("features.bing_daily"))
local bingApi = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1"
fake.httpResponses[bingApi] = {
    status = 200,
    body = '{"images":[{"url":"/th?id=OHR.TestPic_1920x1080.jpg&rf=x.jpg&pid=hp"}]}',
}
registry.setEnabled("bing_daily", true)
ok(fake.fireTimers("after", 5) == 1, "bing: boot refresh scheduled")
ok(fake.httpRequests[#fake.httpRequests].headers["User-Agent"] ~= nil, "bing: sends a user agent")
local dl = fake.downloads[#fake.downloads]
ok(dl and dl.path == "/tmp/hammerdeck-fake-cache/OHR.TestPic_1920x1080.jpg",
    "bing: downloads the picture into the app cache by id")
ok(fake.wallpapers[#fake.wallpapers] == dl.path, "bing: sets the wallpaper")
ok(fake.wallpaperModes[#fake.wallpaperModes] == "all",
    "bing: applyTo defaults to all displays")
ok(fake.settings["hammerdeck.state.bing_daily.lastPic"] == "OHR.TestPic_1920x1080.jpg",
    "bing: remembers the applied picture")
do
    local bingRow
    for _, d in ipairs(registry.describe()) do if d.id == "bing_daily" then bingRow = d end end
    ok(bingRow and bingRow.actions[1].trigger and bingRow.actions[1].trigger.everyMin == 180,
        "bing: refresh action defaults to a 3h schedule trigger (visible + rebindable)")
end

-- a display change re-applies the CACHED wallpaper, no network round-trip
local reqBefore = #fake.httpRequests
local dlBefore = #fake.downloads
fake.systemEvent("screenChanged")
ok(fake.wallpapers[#fake.wallpapers] == dl.path
    and #fake.httpRequests == reqBefore and #fake.downloads == dlBefore,
    "bing: a screen change re-applies the cached wallpaper without hitting the network")

-- same picture on the next poll: re-applied, NOT re-downloaded
local dlCount = #fake.downloads
fake.fireTimers("every", 3 * 3600)
ok(#fake.downloads == dlCount, "bing: unchanged picture is not re-downloaded")
ok(fake.wallpapers[#fake.wallpapers] == dl.path, "bing: unchanged picture is re-applied")

-- the refresh action carries a default schedule trigger; rebinding to a hotkey
-- (this also drops the schedule timer, so subsequent refreshes fire on the key)
ok(registry.setTrigger("bing_daily", "refresh",
    { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "w" }) == true,
    "bing: refresh action rebinds to a hotkey")
fake.httpResponses[bingApi].body =
    '{"images":[{"url":"/th?id=OHR.NewPic_1920x1080.jpg&rf=y.jpg"}]}'
fake.settings["hammerdeck.opt.bing_daily.applyTo"] = "primary"
fake.pressHotkey("w")
ok(fake.downloads[#fake.downloads].path == "/tmp/hammerdeck-fake-cache/OHR.NewPic_1920x1080.jpg",
    "bing: manual refresh downloads the new picture")
ok(fake.wallpaperModes[#fake.wallpaperModes] == "primary",
    "bing: applyTo='primary' threads through to setWallpaper")
fake.settings["hammerdeck.opt.bing_daily.applyTo"] = nil

-- a failed request leaves state untouched (refresh now fires on the hotkey)
fake.httpResponses[bingApi] = { status = 500, body = nil }
local wallCount = #fake.wallpapers
fake.pressHotkey("w")
ok(#fake.wallpapers == wallCount, "bing: failed request changes nothing")

registry.setEnabled("bing_daily", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after bing_daily test")

-- (dark_mode was demoted from a feature to the `setAppearance` rules effect kind;
-- its behavior is now covered by the effect-dispatch tests in T39.)

-- T19: chord triggers -- prefix hotkey arms a follow-key sequence -------------
-- (`triggers` is the file-scope local from T10.)
do

-- codec round-trip: mods canonicalized (sorted), follow sequence ORDER kept
local chordEnc = triggers.encode(
    { type = "chord", mods = { "shift", "cmd" }, key = "a", follows = { "b", "c" } })
ok(chordEnc == "chord|cmd,shift|a|b,c", "chord encodes with sorted mods + ordered follows")
local chordDec = triggers.decode(chordEnc)
ok(chordDec.type == "chord" and chordDec.key == "a"
    and chordDec.follows[1] == "b" and chordDec.follows[2] == "c" and #chordDec.follows == 2,
    "chord decodes back to the same spec")
ok(triggers.decode("chord|cmd|a|") == nil, "a chord string with no follow keys decodes to nil")

-- validate rejects malformed chords
ok(pcall(triggers.validate, { type = "chord", mods = { "cmd" }, key = "a" }) == false,
    "chord without follows is rejected")
ok(pcall(triggers.validate,
    { type = "chord", mods = { "cmd" }, key = "a", follows = {} }) == false,
    "chord with empty follows is rejected")
ok(pcall(triggers.validate,
    { type = "chord", mods = { "cmd" }, key = "a", follows = { "escape" } }) == false,
    "escape cannot be a chord follow key (it always cancels)")

-- conflict semantics (the whole reason chords share prefixes)
local chordAB  = { type = "chord", mods = { "cmd", "shift" }, key = "a", follows = { "b" } }
local chordAC  = { type = "chord", mods = { "cmd", "shift" }, key = "a", follows = { "c" } }
local chordABC = { type = "chord", mods = { "cmd", "shift" }, key = "a", follows = { "b", "c" } }
local plainA   = { type = "hotkey", mods = { "shift", "cmd" }, key = "a" }
ok(triggers.conflicts(chordAB, chordAC) == false,
    "chords sharing a prefix with distinct follows do NOT conflict")
ok(triggers.conflicts(chordAB, chordABC) == true,
    "a follow sequence that is a prefix of another (same prefix) conflicts")
ok(triggers.conflicts(chordAB, plainA) == true,
    "a plain hotkey collides with a chord's prefix combo")
ok(triggers.conflicts(plainA, { type = "hotkey", mods = { "cmd", "shift" }, key = "b" }) == false,
    "different plain hotkeys do not conflict")

-- end-to-end binding through the registry: two chords share one prefix
local chordHits = { x = 0, y = 0 }
package.loaded["features._chordy"] = {
    api = 1, id = "chordy", name = "Chordy",
    actions = {
        { id = "x", label = "X",
          defaultTrigger = { type = "chord", mods = { "cmd", "shift" }, key = "a", follows = { "b" } },
          run = function() chordHits.x = chordHits.x + 1 end },
        { id = "y", label = "Y",   -- SAME prefix, different follow key
          defaultTrigger = { type = "chord", mods = { "shift", "cmd" }, key = "a", follows = { "c" } },
          run = function() chordHits.y = chordHits.y + 1 end },
    },
}
registry.load("features._chordy")
registry.setEnabled("chordy", true)
ok(fake.fireChord({ "cmd", "shift" }, "a", { "b" }) == 1, "prefix cmd+shift+a then b fires action x")
ok(chordHits.x == 1 and chordHits.y == 0, "only the matching chord ran")
ok(fake.fireChord({ "shift", "cmd" }, "a", { "c" }) == 1,
    "the sibling chord (same prefix, follow c) fires action y")
ok(chordHits.y == 1, "follow c ran action y")
ok(fake.fireChord({ "cmd", "shift" }, "a", { "z" }) == 0, "an unmatched follow fires nothing")

-- rebind a chord action to a deeper sequence; the old sequence goes dead
ok(registry.setTrigger("chordy", "x",
    { type = "chord", mods = { "cmd", "shift" }, key = "a", follows = { "d", "e" } }) == true,
    "a chord action rebinds to a deeper sequence")
fake.fireChord({ "cmd", "shift" }, "a", { "b" })
ok(chordHits.x == 1, "the old chord sequence is dead after rebind")
ok(fake.fireChord({ "cmd", "shift" }, "a", { "d", "e" }) == 1, "the new (deeper) sequence fires")
ok(chordHits.x == 2, "the deeper follow sequence ran action x")
ok(fake.settings["hammerdeck.trigger.chordy.x"] == "chord|cmd,shift|a|d,e",
    "the chord override persisted encoded")

-- a chord whose follow seq is a prefix of an enabled sibling is refused
local okPrefix, whyPrefix = registry.setTrigger("chordy", "y",
    { type = "chord", mods = { "cmd", "shift" }, key = "a", follows = { "d" } })
ok(okPrefix == false and whyPrefix ~= nil, "a prefix-of-sibling chord is refused as a conflict")

-- a plain hotkey colliding with an enabled chord's prefix is refused
package.loaded["features._plain"] = {
    api = 1, id = "plain", name = "Plain",
    defaultTrigger = { type = "hotkey", mods = { "cmd", "shift" }, key = "a" },
    action = function() end,
}
registry.load("features._plain")
local okPlain, whyPlain = registry.setTrigger("plain",
    { type = "hotkey", mods = { "cmd", "shift" }, key = "a" })
ok(okPlain == false and whyPlain ~= nil, "a plain hotkey on a chord's prefix combo is refused")

registry.setEnabled("chordy", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after chord tests")

end
-- T19b: registry.hyperLegend() -- which-key legend of enabled Hyper bindings ---
package.loaded["features._hyperprobe"] = {
    api = 1, id = "hyperprobe", name = "Hyper Probe",
    actions = {
        { id = "go", label = "Go",
          defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "h" },
          run = function() end },
        { id = "no", label = "NotHyper",   -- only cmd: must be excluded
          defaultTrigger = { type = "hotkey", mods = { "cmd" }, key = "j" },
          run = function() end },
    },
}
registry.load("features._hyperprobe")
registry.setEnabled("hyperprobe", true)
local function legendHas(rows, key, label)
    for _, it in ipairs(rows) do
        if it.key == key and it.label == label then return true end
    end
    return false
end
local function legendHasLabel(rows, label)
    for _, it in ipairs(rows) do if it.label == label then return true end end
    return false
end
local legend = registry.hyperLegend()
ok(legendHas(legend, "h", "Go"), "hyperLegend lists a Hyper binding as { key, label }")
ok(not legendHasLabel(legend, "NotHyper"), "hyperLegend excludes non-Hyper bindings")
registry.setEnabled("hyperprobe", false)
ok(not legendHasLabel(registry.hyperLegend(), "Go"),
    "hyperLegend drops a disabled feature's bindings")

-- T20: usage_stats (service: sessions + per-app focus time to CSV) ------------
do
fake.reset()   -- clean input slate: isolate from any preset an upstream section left
registry.register(require("features.usage_stats"))

-- Re-pin the clock to a fresh morning so this test owns its day arithmetic.
local pin20 = os.date("*t") --[[@as osdateparam]]
pin20.hour, pin20.min, pin20.sec = 9, 0, 0
fake.clockOffset = os.time(pin20) - os.time()
fake.idle = 0

-- pin the storage folder to an absolute path (no ~ expansion) so the CSV
-- paths below stay deterministic; the months live directly under it
fake.settings["hammerdeck.opt.usage_stats.dir"] = "/fake/data/usage"
local day20 = os.date("%Y-%m-%d", fake.now()) --[[@as string]]
local appsCsv = "/fake/data/usage/" .. day20:sub(1, 7) .. "/" .. day20 .. "-apps.csv"
local sessCsv = "/fake/data/usage/" .. day20:sub(1, 7) .. "/" .. day20 .. ".csv"

fake.frontmost = "Code"
registry.setEnabled("usage_stats", true)

-- focus time accrues to the frontmost app; switching apps flushes
fake.clockOffset = fake.clockOffset + 120
fake.activateApp("Safari")
fake.clockOffset = fake.clockOffset + 60
fake.fireTimers("every", 600)   -- the 10-min flush writes the apps CSV
local csv = fake.files[appsCsv]
ok(csv ~= nil and csv:match("^app,context,seconds\n"), "apps CSV written with header")
ok(csv:match("\nCode,,120\n") and csv:match("\nSafari,,60\n"),
    "both apps accrued their focus seconds (context column empty for now)")
ok(csv:find("Code,,120") < csv:find("Safari,,60"), "rows sorted by time descending")

-- a fully-idle interval is discarded; partial idle is subtracted
fake.clockOffset = fake.clockOffset + 50
fake.idle = 100                                    -- idle >= elapsed: discard
fake.fireTimers("every", 600)
ok(fake.files[appsCsv]:match("\nSafari,,60\n") ~= nil, "fully-idle interval added nothing")
fake.idle = 10
fake.clockOffset = fake.clockOffset + 40           -- 40s elapsed, 10s idle
fake.fireTimers("every", 600)
ok(fake.files[appsCsv]:match("\nSafari,,90\n") ~= nil, "partial idle subtracted (60+30)")
fake.idle = 0

-- locking records the session (wake -> lock, minutes rounded)
fake.clockOffset = fake.clockOffset + 60
fake.systemEvent("screenLock")
local sess = fake.files[sessCsv]
ok(sess ~= nil and sess:match("^wake_time,sleep_time,duration_min\n"),
    "session CSV written with header")
ok(sess:match(",6\n") ~= nil, "session duration recorded (330s -> 6 min)")

-- locked time accrues to nothing; unlock starts a new session
fake.clockOffset = fake.clockOffset + 600
fake.systemEvent("screenUnlock")
fake.clockOffset = fake.clockOffset + 45
fake.systemEvent("screenLock")
local _, sessLines = fake.files[sessCsv]:gsub("\n", "")
ok(sessLines == 3, "second session appended; locked time not counted")
ok(fake.files[appsCsv]:match("\nSafari,,195\n") ~= nil,
    "post-unlock focus accrued to the frontmost app (90+60 at lock, +45)")

-- sub-30s wake/lock blips are ignored
fake.systemEvent("screenUnlock")
fake.clockOffset = fake.clockOffset + 10
fake.systemEvent("screenLock")
local _, sessLines2 = fake.files[sessCsv]:gsub("\n", "")
ok(sessLines2 == 3, "short session skipped")

-- desktop widget: fed on each refresh tick; option toggle shows/hides live
local widget = fake.liveUsageWidget()
ok(widget ~= nil, "widget shown by default (showWidget=true)")
fake.fireTimers("every", 60)   -- the refresh tick pushes data
ok(widget.data ~= nil and widget.data.total == 325,
    "widget data total matches accrued time (120 + 195 + the 10s blip's focus)")
ok(#widget.data.week == 7 and widget.data.week[7].today == true,
    "widget gets a 7-day series ending today")
ok(widget.data.apps[1].app == "Safari" and widget.data.apps[1].secs == 205,
    "widget app rows sorted descending")
fake.settings["hammerdeck.opt.usage_stats.showWidget"] = false
fake.fireTimers("every", 60)
ok(fake.liveUsageWidget() == nil, "widget hides when the option is switched off")
fake.settings["hammerdeck.opt.usage_stats.showWidget"] = true
fake.fireTimers("every", 60)
ok(fake.liveUsageWidget() ~= nil, "widget re-shows when the option returns")

-- the Settings store pings optionChanged on every write: the toggle applies
-- INSTANTLY, no waiting for the 60s tick
fake.settings["hammerdeck.opt.usage_stats.showWidget"] = false
registry.optionChanged("usage_stats", "showWidget")
ok(fake.liveUsageWidget() == nil, "onOptionChange hides the widget immediately")
fake.settings["hammerdeck.opt.usage_stats.showWidget"] = true
registry.optionChanged("usage_stats", "showWidget")
ok(fake.liveUsageWidget() ~= nil, "and shows it back immediately")
registry.optionChanged("usage_stats", "someOtherKey")      -- ignored key: no-op
registry.optionChanged("count_down", "defaultMinutes")     -- no handler: no-op
ok(fake.liveUsageWidget() ~= nil, "unrelated keys and handler-less features no-op")
fake.settings["hammerdeck.opt.usage_stats.showWidget"] = nil

-- accumulated time survives a disable/re-enable (reloaded from the CSV)
registry.setEnabled("usage_stats", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "usage_stats leaks nothing")
fake.systemEvent("screenUnlock")   -- no live watchers: must be inert
registry.setEnabled("usage_stats", true)
fake.fireTimers("every", 600)
ok(fake.files[appsCsv]:match("\nCode,,120\n") and fake.files[appsCsv]:match("\nSafari,,205\n"),
    "today's totals (incl. the blip's focus, flushed on disable) restored after re-enable")
-- context enrichment: browser domain + editor project fill the CSV column.
-- Chrome-site tracking is opt-in, so enable it for this slice (editor project
-- context is always on and needs no opt-in).
fake.settings["hammerdeck.opt.usage_stats.trackChromeSite"] = true
fake.activeUrls["Google Chrome"] = "https://github.com/owner/repo"
fake.activateApp("Google Chrome")              -- switch reads the context
fake.clockOffset = fake.clockOffset + 90
fake.activeUrls["Google Chrome"] = "https://news.site/page"
fake.fireTimers("every", 30)                   -- tab switch: poll splits the slice
fake.clockOffset = fake.clockOffset + 60
fake.fireTimers("every", 600)                  -- flush + write
local csvC = fake.files[appsCsv]
ok(csvC:match("\nGoogle Chrome,github.com,90\n") ~= nil,
    "browser context = active tab's domain (pre-switch slice)")
ok(csvC:match("\nGoogle Chrome,news.site,60\n") ~= nil,
    "the 30s context poll splits accrual on a tab change")

fake.windowTitle = "main.swift — hammerdeck [SSH: devbox]"
fake.activateApp("Code")
fake.clockOffset = fake.clockOffset + 45
fake.fireTimers("every", 600)
ok(fake.files[appsCsv]:match("\nCode,hammerdeck,45\n") ~= nil,
    "editor context = project from the window title, suffix stripped")

-- widget aggregates per app and carries the top context sub-rows
fake.fireTimers("every", 60)
local wd = fake.liveUsageWidget().data
local chromeRow
for _, r in ipairs(wd.apps) do if r.app == "Google Chrome" then chromeRow = r end end
ok(chromeRow and chromeRow.secs == 150 and #chromeRow.contexts == 2
    and chromeRow.contexts[1].name == "github.com" and chromeRow.contexts[1].secs == 90,
    "widget aggregates contexts under the app, sorted by time")
fake.settings["hammerdeck.opt.usage_stats.trackChromeSite"] = nil
fake.windowTitle = nil

-- the widget screen option recreates the panel on the chosen display instantly
ok(fake.liveUsageWidget().screen == 1, "widget defaults to the primary screen")
fake.settings["hammerdeck.opt.usage_stats.screen"] = "secondary"
registry.optionChanged("usage_stats", "screen")
ok(fake.liveUsageWidget().screen == 2, "screen option moves the widget immediately")
fake.settings["hammerdeck.opt.usage_stats.screen"] = nil

-- retention: month dirs older than keepMonths are swept (once per day)
local oldMonth = os.date("%Y-%m", fake.now() - 100 * 86400)   -- >3 months back
local oldFile = "/fake/data/usage/" .. oldMonth .. "/" .. oldMonth .. "-15-apps.csv"
fake.files[oldFile] = "app,context,seconds\nOldApp,,999\n"
fake.settings["hammerdeck.opt.usage_stats.keepMonths"] = 2
fake.fireTimers("every", 600)   -- flush cadence runs the daily sweep
ok(fake.files[oldFile] == nil, "retention sweep deletes months past the keep window")
ok(fake.files[appsCsv] ~= nil, "the current month survives the sweep")
fake.settings["hammerdeck.opt.usage_stats.keepMonths"] = nil

-- CSV injection guard: an app name with a comma is quoted on write and parsed
-- back on reload, instead of shifting the context/seconds columns
fake.windowTitle = nil
fake.activateApp("Excel, Inc.")
fake.clockOffset = fake.clockOffset + 40
fake.fireTimers("every", 600)
ok(fake.files[appsCsv]:match('\n"Excel, Inc%.",,40\n') ~= nil,
    "an app name with a comma is CSV-quoted on write")
registry.setEnabled("usage_stats", false)   -- stop() flushes the tail
registry.setEnabled("usage_stats", true)     -- re-enable reloads from the CSV
fake.fireTimers("every", 600)
ok(fake.files[appsCsv]:match('\n"Excel, Inc%.",') ~= nil,
    "the quoted app round-trips through reload (parsed back, not column-shifted)")

-- browser SITE (domain) tracking is OPT-IN and PER-BROWSER, verified on a FRESH
-- day so these assertions own their CSV (a rollover clears the accumulated app
-- time first). Chrome's incognito is excluded upstream in the Swift seam; the
-- fake seam just returns the URL we set, so this covers the pieces that live in
-- Lua: the per-browser consent gate and the domain-only reduction. (do-scoped:
-- main chunk is at the 200-local cap; a single reused `csv` local keeps it lean.)
do
    fake.clockOffset = fake.clockOffset + 86400          -- next day -> rollover resets appTime
    fake.idle = 0
    fake.windowTitle = nil
    local d2    = os.date("%Y-%m-%d", fake.now())
    local apps2 = "/fake/data/usage/" .. d2:sub(1, 7) .. "/" .. d2 .. "-apps.csv"
    local csv
    fake.activeUrls["Google Chrome"] = "https://github.com/acme/repo?token=secret"

    -- Chrome OFF by default: time accrues, but with an EMPTY context (no domain)
    fake.settings["hammerdeck.opt.usage_stats.trackChromeSite"] = nil
    fake.activateApp("Google Chrome")                    -- rolls to d2, opens the app
    fake.clockOffset = fake.clockOffset + 60
    fake.fireTimers("every", 600)
    csv = fake.files[apps2]
    ok(csv ~= nil and csv:match("\nGoogle Chrome,,%d+\n") ~= nil,
        "Chrome site OFF by default: time keyed with an EMPTY context")
    ok(csv:find("github") == nil, "no Chrome domain recorded without consent")

    -- opt in to Chrome: the domain (only) becomes the context on the next poll
    fake.settings["hammerdeck.opt.usage_stats.trackChromeSite"] = true
    fake.fireTimers("every", 30)
    fake.clockOffset = fake.clockOffset + 60
    fake.fireTimers("every", 600)
    csv = fake.files[apps2]
    ok(csv:match("Google Chrome,github%.com,%d+") ~= nil,
        "after opt-in, Chrome time keys by DOMAIN (github.com)")
    ok(csv:find("token=secret") == nil and csv:find("/acme/repo") == nil,
        "only the domain is stored -- never the full URL/path")

    -- Safari has an INDEPENDENT gate: Chrome ON but trackSafariSite OFF must NOT
    -- record a Safari domain (proving the two toggles are not shared).
    fake.activeUrls["Safari"] = "https://duckduckgo.com/?q=x"
    fake.settings["hammerdeck.opt.usage_stats.trackSafariSite"] = nil
    fake.activateApp("Safari")
    fake.clockOffset = fake.clockOffset + 60
    fake.fireTimers("every", 600)
    csv = fake.files[apps2]
    ok(csv:match("\nSafari,,%d+\n") ~= nil,
        "Safari OFF stays empty-context even while Chrome tracking is ON")
    ok(csv:find("duckduckgo") == nil, "Safari domain not recorded under Chrome's toggle")

    -- opt in to Safari specifically -> its own domain is recorded (its own risk)
    fake.settings["hammerdeck.opt.usage_stats.trackSafariSite"] = true
    fake.fireTimers("every", 30)
    fake.clockOffset = fake.clockOffset + 60
    fake.fireTimers("every", 600)
    ok(fake.files[apps2]:match("Safari,duckduckgo%.com,%d+") ~= nil,
        "Safari ON: records its own domain via its independent toggle")

    fake.settings["hammerdeck.opt.usage_stats.trackChromeSite"] = nil
    fake.settings["hammerdeck.opt.usage_stats.trackSafariSite"] = nil
end

registry.setEnabled("usage_stats", false)
fake.settings["hammerdeck.opt.usage_stats.dir"] = nil
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after usage_stats test")

end
-- T21: Accessibility onboarding (window_switcher with no windows) ------------------
registry.setEnabled("window_switcher", true)
fake.windows = {}

-- untrusted: fires the system prompt + explains
fake.axTrusted = false
local alertsBefore, promptsBefore = #fake.alerts, fake.axPrompts
fake.pressHotkey("tab")
ok(fake.axPrompts == promptsBefore + 1, "untrusted empty list fires the AX prompt")
ok(#fake.alerts == alertsBefore + 1 and fake.alerts[#fake.alerts]:match("Accessibility"),
    "the alert explains the Accessibility grant")
ok(fake.visibleChooser() == nil, "no chooser opens without windows")

-- trusted but genuinely no windows: plain message, no prompt
fake.axTrusted = true
fake.pressHotkey("tab")
ok(fake.axPrompts == promptsBefore + 1, "trusted empty list does not re-prompt")
ok(fake.alerts[#fake.alerts]:match("No windows"), "trusted empty list says so plainly")

registry.setEnabled("window_switcher", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after AX onboarding test")

-- T22: text_actions (selection capture -> open/transform/paste back) ----------
do
local OPENAI_TEST_URL = "https://api.openai.com/v1/chat/completions"

-- urls.encodeComponent: unreserved passthrough, space, and per-octet UTF-8
do
    local u = require("platform.urls")
    ok(u.encodeComponent("aZ9-_.~") == "aZ9-_.~", "encodeComponent: unreserved set passes through")
    ok(u.encodeComponent("a b") == "a%20b", "encodeComponent: space -> %20")
    ok(u.encodeComponent("词") == "%E8%AF%8D", "encodeComponent: CJK char -> UTF-8 octets")
end

registry.register(require("features.text_actions"))
registry.setEnabled("text_actions", true)

local function invokeOnSelection(text)
    fake.pasteboard = nil
    fake.pressHotkey("o")
    local last = fake.keyEvents[#fake.keyEvents]
    ok(last.key == "c" and last.mods[1] == "cmd", "invocation synthesizes cmd+c")
    fake.pasteboard = text            -- the "copied selection" arrives
    fake.fireTimers("after", 0.15)    -- the settle timer reads it
end

-- a URL selection opens directly, no picker
invokeOnSelection("  https://example.test/page  ")
ok(fake.openedUrls[#fake.openedUrls] == "https://example.test/page",
    "URL selection opens (trimmed), no picker")
ok(fake.openDialog() == nil, "no picker for URLs")

-- lowercase pastes back over the selection. Not validated -> only the four base
-- transforms appear (the six AI entries are gated on a VALIDATED key, the flag
-- the host sets on a successful Validate -- NOT mere key presence).
invokeOnSelection("Hello WORLD")
local dlg = fake.openDialog()
ok(dlg ~= nil and #dlg.actions == 4, "not validated: picker offers only the four base actions")
dlg.choose("lowercase")
ok(fake.pasteboard == "hello world", "lowercase result lands on the clipboard")
ok(fake.keyEvents[#fake.keyEvents].key == "v", "and is pasted back (cmd+v)")

-- calculate evaluates the selection in a math-only sandbox
invokeOnSelection("6*7")
fake.openDialog().choose("Calculate")
ok(fake.pasteboard == "42", "calculate replaces the selection with just the result")
invokeOnSelection("os.exit()")
fake.openDialog().choose("Calculate")
ok(fake.pasteboard == "os.exit()", "sandbox: non-math globals are nil (eval fails, alert)")
ok(fake.alerts[#fake.alerts]:match("Calculation failed") ~= nil, "failed eval alerts")

-- dictionary (default, empty dictApp): opens the macOS Dictionary via dict://,
-- the word percent-encoded. A CJK word must encode per UTF-8 octet.
invokeOnSelection("ubiquitous")
fake.openDialog().choose("Dictionary")
ok(fake.openedUrls[#fake.openedUrls] == "dict://ubiquitous",
    "default Dictionary opens dict:// with the word")
invokeOnSelection("词典")
fake.openDialog().choose("Dictionary")
ok(fake.openedUrls[#fake.openedUrls] == "dict://%E8%AF%8D%E5%85%B8",
    "CJK word percent-encoded per UTF-8 byte for dict://")

-- dictionary (custom app override): launch/focus by bundle id, paste, return.
fake.settings["hammerdeck.opt.text_actions.dictApp"] = "com.youdao.dict"
fake.uninstalledApps = { ["com.youdao.dict"] = true }
invokeOnSelection("ubiquitous")
fake.openDialog().choose("Dictionary")
ok(fake.alerts[#fake.alerts]:match("Could not open the dictionary app") ~= nil,
    "an unresolvable dict app alerts")
fake.uninstalledApps = nil
invokeOnSelection("ubiquitous")
fake.openDialog().choose("Dictionary")
fake.fireTimers("after", 0.75)
ok(fake.launchedApps[#fake.launchedApps] == "com.youdao.dict",
    "custom dict app launched/focused by bundle id")
ok(fake.pasteboard == "ubiquitous"
    and fake.keyEvents[#fake.keyEvents].key == "return",
    "the word is pasted into the custom dict + return")

-- the Settings "Test" button (option-action) looks up a fixed word, no selection
fake.settings["hammerdeck.opt.text_actions.dictApp"] = "com.youdao.dict"
ok(registry.runOptionAction("text_actions", "dictApp") == true, "dictApp test option-action runs")
fake.fireTimers("after", 0.75)
ok(fake.launchedApps[#fake.launchedApps] == "com.youdao.dict", "test launches the dict app")
ok(fake.pasteboard == "peace", "test pastes the fixed word 'peace'")
ok(registry.runOptionAction("text_actions", "nope") == false, "an unknown option-action is refused")
fake.settings["hammerdeck.opt.text_actions.dictApp"] = nil

-- a key present but NOT yet validated still shows no AI entries (gating is on
-- the validated flag, not key presence).
fake.secrets["hammerdeck.opt.text_actions.openaiKey"] = "sk-test"
invokeOnSelection("draft text")
ok(#fake.openDialog().actions == 4, "key present but unvalidated: still only the four base actions")
fake.openDialog().choose(nil)

-- AI actions: appear once the key validates (host sets the validated state flag),
-- send the selection to OpenAI, and paste the reply back.
fake.settings["hammerdeck.state.text_actions.openaiKey__validated"] = true
fake.httpResponses[OPENAI_TEST_URL] =
    { status = 200, body = '{"choices":[{"message":{"content":"  REFINED  "}}]}' }
invokeOnSelection("draft text")
local aiDlg = fake.openDialog()
ok(#aiDlg.actions == 10, "validated: picker offers the four base + six AI actions")
aiDlg.choose("AI: Refine")
local req = fake.httpRequests[#fake.httpRequests]
ok(req.url == OPENAI_TEST_URL and req.method == "POST", "AI action POSTs to OpenAI")
ok(req.headers["Authorization"] == "Bearer sk-test"
    and req.headers["Content-Type"] == "application/json", "carries auth + json headers")
local sent = require("platform.json").decode(req.body)
ok(sent.model == "gpt-4o-mini" and sent.messages[2].content == "draft text",
    "request body carries the model and the selected text as the user message")
ok(fake.pasteboard == "REFINED", "AI result trimmed and pasted back")
ok(sent.messages[1].content:match("^Refine and improve") ~= nil,
    "default refine system prompt sent when not customized")

-- the per-action system prompt is editable: a custom aiRefinePrompt is what gets sent
fake.settings["hammerdeck.opt.text_actions.aiRefinePrompt"] = "Make it pirate-speak."
invokeOnSelection("draft text")
fake.openDialog().choose("AI: Refine")
local custom = require("platform.json").decode(fake.httpRequests[#fake.httpRequests].body)
ok(custom.messages[1].content == "Make it pirate-speak.",
    "customized refine prompt is sent as the system message")
fake.settings["hammerdeck.opt.text_actions.aiRefinePrompt"] = nil

-- per-action toggles: disabling an action removes it from the popup (key set)
fake.settings["hammerdeck.opt.text_actions.showCalculate"] = false
fake.settings["hammerdeck.opt.text_actions.showAiSummary"] = false
invokeOnSelection("draft text")
local toggled = fake.openDialog()
ok(#toggled.actions == 8, "disabling one base + one AI action drops both from the picker")
local seen = {}
for _, a in ipairs(toggled.actions) do seen[a] = true end
ok(not seen["Calculate"] and not seen["AI: Summary"], "the disabled actions are absent")
ok(seen["Dictionary"] and seen["AI: Refine"], "the still-enabled actions remain")
toggled.choose(nil)   -- dismiss without acting (onChoose(nil))
fake.settings["hammerdeck.opt.text_actions.showCalculate"] = nil
fake.settings["hammerdeck.opt.text_actions.showAiSummary"] = nil

-- translate prompts for a language, then weaves it into the system prompt
invokeOnSelection("hello")
fake.openDialog().choose("AI: Translate")
fake.openTextPrompt().submit("French")
ok(fake.httpRequests[#fake.httpRequests].method == "POST", "translate fires after the language prompt")
local tReq = require("platform.json").decode(fake.httpRequests[#fake.httpRequests].body)
ok(tReq.messages[1].content:match("French") ~= nil, "target language woven into the system prompt")

-- a custom translate template's {lang} token is substituted with the entered language
fake.settings["hammerdeck.opt.text_actions.aiTranslatePrompt"] = "Render into {lang} only."
invokeOnSelection("hello")
fake.openDialog().choose("AI: Translate")
fake.openTextPrompt().submit("Japanese")
local tReq2 = require("platform.json").decode(fake.httpRequests[#fake.httpRequests].body)
ok(tReq2.messages[1].content == "Render into Japanese only.",
    "custom translate template substitutes {lang}")
fake.settings["hammerdeck.opt.text_actions.aiTranslatePrompt"] = nil

-- failure path: a non-200 alerts and does not paste
fake.pasteboard = "untouched"
fake.httpResponses[OPENAI_TEST_URL] = { status = 500, body = "oops" }
invokeOnSelection("draft text")
fake.openDialog().choose("AI: Refine")
ok(fake.alerts[#fake.alerts]:match("AI request failed") ~= nil, "AI failure alerts")
fake.secrets["hammerdeck.opt.text_actions.openaiKey"] = nil
fake.settings["hammerdeck.state.text_actions.openaiKey__validated"] = nil

-- empty selection: trusted -> plain alert (no AX prompt)
fake.pressHotkey("o")
fake.pasteboard = nil
fake.fireTimers("after", 0.15)
ok(fake.alerts[#fake.alerts]:match("Nothing selected") ~= nil, "empty selection says so")

registry.setEnabled("text_actions", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after text_actions test")

end
-- T23: site_switcher / "Quick Sites" (a list of favorite sites in a searchable
-- chooser; pick a row -- click, Enter, or cmd+<n> -- to focus that site's tab,
-- open it, or open it as a standalone app window) ----------------------------
do
registry.register(require("features.site_switcher"))
registry.setEnabled("site_switcher", true)

-- several sites: the shortcut pops a chooser listing them (domain text, url sub)
fake.settings["hammerdeck.opt.site_switcher.sites"] =
    "https://www.otter.ai/\nhttps://github.com/\n"
fake.browserTabs = { "https://github.com/x", "https://www.otter.ai/meetings" }
fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
local ch = fake.visibleChooser()
ok(ch ~= nil and #ch.choices == 2
    and ch.choices[1].text == "otter.ai"
    and ch.choices[1].subText == "https://www.otter.ai/"
    and ch.choices[2].text == "github.com",
    "the shortcut pops a chooser of the sites (domain text, url subtext)")
ch.userSelect(1)
ok(fake.focusedTabs[#fake.focusedTabs] == "https://www.otter.ai/meetings",
    "picking row 1 focuses the first site's tab")
ok(fake.visibleChooser() == nil, "the chooser closes after a pick")

-- a later row (what cmd+2 / arrow+Enter resolves to) jumps to its site
fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
fake.visibleChooser().userSelect(2)
ok(fake.focusedTabs[#fake.focusedTabs] == "https://github.com/x",
    "picking row 2 focuses the second site's tab")

-- dismissing the chooser (Escape -> onSelect(nil)) jumps nothing
local focusedCount = #fake.focusedTabs
fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
fake.visibleChooser().userSelect(0)   -- out-of-range = dismissed
ok(#fake.focusedTabs == focusedCount, "dismissing the chooser jumps nothing")

-- a single configured site skips the list and jumps straight (donor behavior)
fake.settings["hammerdeck.opt.site_switcher.sites"] = "https://github.com/"
fake.browserTabs = { "https://github.com/x" }
fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
ok(fake.visibleChooser() == nil
    and fake.focusedTabs[#fake.focusedTabs] == "https://github.com/x",
    "one site needs no list -- jumps straight")

-- no match opens the fallback URL in a new tab
fake.settings["hammerdeck.opt.site_switcher.sites"] = "https://www.otter.ai/"
fake.browserTabs = { "https://github.com/x" }
fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
ok(fake.openedNewTabs[#fake.openedNewTabs] == "https://www.otter.ai/",
    "no match opens the fallback URL")

-- a scheme-less entry is normalized to https:// so it actually navigates
-- (the "opened bing.com" dead-tab bug)
fake.settings["hammerdeck.opt.site_switcher.sites"] = "bing.com"
fake.browserTabs = {}
fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
ok(fake.openedNewTabs[#fake.openedNewTabs] == "https://bing.com",
    "a scheme-less site gets https:// before opening (no more dead tab)")

-- the legacy single-URL key seeds the one site when the list is empty
fake.settings["hammerdeck.opt.site_switcher.sites"] = nil
fake.settings["hammerdeck.opt.site_switcher.openURL"] = "https://www.otter.ai/"
fake.browserTabs = { "https://www.otter.ai/meetings" }
fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
ok(fake.focusedTabs[#fake.focusedTabs] == "https://www.otter.ai/meetings",
    "the legacy openURL migrates as the one site when the list is empty")
fake.settings["hammerdeck.opt.site_switcher.openURL"] = nil

-- a `Name | URL` line shows the friendly name (URL as subtext), with a favicon
-- once it is cached
fake.settings["hammerdeck.opt.site_switcher.openURL"] = nil
fake.chromeFavicons = { ["github.com"] = true }
fake.settings["hammerdeck.opt.site_switcher.sites"] =
    "GitHub | github.com\nGmail | mail.google.com"
fake.browserTabs = {}
fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
local nc = fake.visibleChooser()
ok(nc ~= nil and nc.choices[1].text == "GitHub"
    and nc.choices[1].subText == "https://github.com"
    and nc.choices[2].text == "Gmail",
    "a `Name | URL` line shows the friendly name (URL as subtext)")
ok(nc.choices[1].image == "file:/tmp/hammerdeck-fake-cache/favicons/github.com.png",
    "a cached favicon renders next to its row")
nc.userSelect(0)   -- dismiss

-- `| app` opens a standalone Chrome app window when Chrome is the default browser
fake.defaultBrowserBundle = "com.google.Chrome"
fake.settings["hammerdeck.opt.site_switcher.sites"] = "Gmail | mail.google.com | app"
fake.browserTabs = {}
fake.appWindows = {}
fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
ok(fake.visibleChooser() == nil
    and fake.appWindows[#fake.appWindows] == "https://mail.google.com",
    "an `| app` site with no open tab opens a standalone app window")

-- an already-open app site is focused, not relaunched
fake.appWindows = {}
fake.browserTabs = { "https://mail.google.com/u/0/inbox" }
fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
ok(#fake.appWindows == 0
    and fake.focusedTabs[#fake.focusedTabs] == "https://mail.google.com/u/0/inbox",
    "an open app site is focused instead of relaunched")

-- when the resolved browser isn't Chrome, an app site routes through openSite to
-- that browser (which opens a plain tab -- app/profile don't apply there)
fake.defaultBrowserBundle = "com.apple.Safari"
fake.appWindows = {}
fake.siteOpens = {}
fake.browserTabs = {}
fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
ok(#fake.appWindows == 0
    and fake.siteOpens[#fake.siteOpens] ~= nil
    and fake.siteOpens[#fake.siteOpens].bundleId == "com.apple.Safari"
    and fake.siteOpens[#fake.siteOpens].url == "https://mail.google.com",
    "an app site whose browser isn't Chrome routes through openSite (no app window)")
fake.defaultBrowserBundle = "com.google.Chrome"
fake.chromeFavicons = {}

-- JSON storage with per-site browser + Chrome profile routing
fake.settings["hammerdeck.opt.site_switcher.sites"] =
    '[{"name":"Otter","url":"otter.ai","browser":"com.google.Chrome","profile":"Profile 2","app":true},'
    .. '{"name":"News","url":"news.ycombinator.com","browser":"org.mozilla.firefox"}]'
fake.browserTabs = {}
fake.siteOpens = {}
fake.appWindows = {}
fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
local jc = fake.visibleChooser()
ok(jc ~= nil and jc.choices[1].text == "Otter" and jc.choices[2].text == "News",
    "JSON site records render as named rows")
jc.userSelect(1)   -- Otter: Chrome + a non-default profile + app -> routed launch
ok(#fake.siteOpens == 1
    and fake.siteOpens[1].bundleId == "com.google.Chrome"
    and fake.siteOpens[1].profile == "Profile 2"
    and fake.siteOpens[1].app == true
    and fake.siteOpens[1].url == "https://otter.ai",
    "a Chrome-profile app site routes through openSite with the profile + app flag")
fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
fake.visibleChooser().userSelect(2)   -- News: Firefox (non-scriptable) -> openSite tab
ok(#fake.siteOpens == 2
    and fake.siteOpens[2].bundleId == "org.mozilla.firefox"
    and fake.siteOpens[2].app == false
    and fake.siteOpens[2].url == "https://news.ycombinator.com",
    "a site routed to a non-scriptable browser opens via openSite")

-- a Safari-routed site (no app) focuses its existing Safari tab via focusSafariTab
-- (NOT openSite), and opens it when absent
fake.settings["hammerdeck.opt.site_switcher.sites"] =
    '[{"name":"News","url":"news.ycombinator.com","browser":"com.apple.Safari"}]'
fake.browserTabs = { "https://news.ycombinator.com/item?id=1" }
fake.siteOpens = {}
fake.focusedTabs = {}
fake.openedNewTabs = {}
fake.pressHotkey("u", { "cmd", "alt", "ctrl" })   -- one site -> jumps straight
ok(#fake.siteOpens == 0
    and fake.focusedTabs[#fake.focusedTabs] == "https://news.ycombinator.com/item?id=1",
    "a Safari-routed site focuses its open Safari tab (not openSite)")
fake.browserTabs = {}
fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
ok(fake.openedNewTabs[#fake.openedNewTabs] == "https://news.ycombinator.com",
    "a Safari-routed site with no open tab opens it")

-- no sites at all -> a clear hint, not silence
fake.settings["hammerdeck.opt.site_switcher.sites"] = nil
fake.pressHotkey("u", { "cmd", "alt", "ctrl" })
ok(fake.alerts[#fake.alerts]:match("No sites yet") ~= nil,
    "empty config alerts instead of doing nothing")

registry.setEnabled("site_switcher", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after site_switcher test")

-- Quick Sites' favicon prefetch writes into the same global recorders that
-- later feature tests inspect; reset them so those assert only on their own activity.
fake.downloads = {}
fake.extractedBatches = {}
fake.chromeFavicons = {}

end
-- T24: window_snap (snap halves, max toggle, throw across screens) ---------
registry.register(require("features.window_snap"))
registry.setEnabled("window_snap", true)

fake.screenList = {
    { x = 0, y = 0, w = 1000, h = 800 },        -- primary
    { x = 1000, y = 0, w = 2000, h = 1200 },    -- bigger secondary
}
local AC = { "cmd", "alt", "ctrl" }
local function lastFrame() return fake.windowFrames[#fake.windowFrames] end

-- halves snap against the window's own screen
fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
fake.pressHotkey("left", AC)
local lf = lastFrame()
ok(lf.x == 0 and lf.y == 0 and lf.w == 500 and lf.h == 800, "left half snaps")
fake.pressHotkey("right", AC)
lf = lastFrame()
ok(lf.x == 500 and lf.w == 500 and lf.h == 800, "right half snaps")
fake.pressHotkey("down", AC)
lf = lastFrame()
ok(lf.y == 400 and lf.w == 1000 and lf.h == 400, "bottom half snaps")

-- toggle: full-width window -> centered 75%; then -> maximize
fake.pressHotkey("return", AC)             -- bottom half is full-width
lf = lastFrame()
ok(lf.x == 125 and lf.y == 100 and lf.w == 750 and lf.h == 600,
    "full-dimension window toggles to centered 75%")
fake.pressHotkey("return", AC)
lf = lastFrame()
ok(lf.x == 0 and lf.y == 0 and lf.w == 1000 and lf.h == 800,
    "75% window toggles to maximized")

-- fullscreen: exits, then retries after the settle timer
fake.focusedWindow = { x = 0, y = 0, w = 1000, h = 800, screenIndex = 1, fullscreen = true }
local framesBefore = #fake.windowFrames
fake.pressHotkey("return", AC)
ok(fake.fullscreenSets[#fake.fullscreenSets] == false and #fake.windowFrames == framesBefore,
    "fullscreen exits first, no frame change yet")
fake.fireTimers("after", 0.5)
lf = lastFrame()
ok(lf.w == 750 and lf.h == 600, "the retry then applies the toggle")

-- throw to the bigger screen: least-distortion scale (1.5), per-axis offsets
fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
fake.mousePos = { x = 150, y = 200 }
fake.pressHotkey("]", AC)
lf = lastFrame()
ok(lf.w == 600 and lf.h == 450, "frame scales by the axis ratio closer to 1 (1.5)")
ok(lf.x == 1200 and lf.y == 150, "position scales per axis onto the target screen")
-- pointer tracks the WINDOW, not the raw screen offset: it was 12.5% across /
-- 33% down the old window {100,100,400,300}, so on the new frame {1200,150,600,450}
-- it lands at 1200+0.125*600, 150+(1/3)*450 = 1275, 300 -- INSIDE the window (the
-- old screen-relative carry gave 1150, left of the window's x=1200 edge).
ok(fake.mousePos.x == 1275 and fake.mousePos.y == 300, "pointer carried to its spot inside the window")
ok(fake.mouseLocates[#fake.mouseLocates] == 2, "pointer flashed after the throw")

-- and back, wrapping
fake.focusedWindow.screenIndex = 2
fake.pressHotkey("[", AC)
ok(lastFrame().x >= 0 and lastFrame().x < 1000, "previous wraps back to the primary")

-- a huge window clamps into the smaller target screen
fake.focusedWindow = { x = 1000, y = 0, w = 2000, h = 1200, screenIndex = 2 }
fake.pressHotkey("[", AC)
lf = lastFrame()
ok(lf.x == 0 and lf.y == 0 and lf.w == 1000 and lf.h == 800,
    "oversized throw clamps to the target screen")

-- direction needs 3+ screens to be observable (with 2, next and prev both
-- wrap to the other screen -- which is how a "previous" that never matched
-- adjacentScreen's "prev" and fell through to next hid here): from the
-- middle screen, ] must land right and [ must land left.
do
    local saved = fake.screenList
    fake.screenList = {
        { x = -800, y = 0, w = 800, h = 600 },   -- left
        { x = 0, y = 0, w = 800, h = 600 },      -- middle (primary)
        { x = 800, y = 0, w = 800, h = 600 },    -- right
    }
    fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 2 }
    fake.pressHotkey("]", AC)
    ok(lastFrame().x >= 800, "] throws to the screen on the right")
    fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 2 }
    fake.pressHotkey("[", AC)
    ok(lastFrame().x < 0, "[ throws to the screen on the left")
    fake.screenList = saved
end

-- (The thirds are no longer hardcoded snap actions: they live as a QUICK-ADD
-- recipe library in the placement editor -- a Swift-side affordance that appends a
-- normal preset. Nothing to test at the Lua layer; the preset -> action apply path
-- is covered by T24p above.)

-- swap the ACTIVE display's windows with another (no trigger -> runAction). Two
-- displays: no choice to make, so it swaps immediately. Focus is on screen 1
-- (activeIdx=1); each live window lands on the OTHER screen, rescaled; minimized
-- and fullscreen windows are skipped.
do
    fake.screenList = {
        { x = 0,    y = 0, w = 1000, h = 800 },      -- A (primary)
        { x = 1000, y = 0, w = 2000, h = 1200 },     -- B (bigger)
    }
    fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 } -- active = A
    fake.windows = {
        { id = 11, x = 100,  y = 100, w = 400, h = 300 },                    -- on A: moves
        { id = 12, x = 1200, y = 150, w = 600, h = 450 },                    -- on B: moves
        { id = 13, x = 200,  y = 200, w = 100, h = 100, minimized = true },  -- A, minimized: skip
        { id = 14, x = 1300, y = 100, w = 200, h = 200, fullscreen = true }, -- B, fullscreen: skip
    }
    fake.windowFrameSets = {}
    assert(registry.runAction("window_snap", "swap_screens"))
    local byId = {}
    for _, s in ipairs(fake.windowFrameSets) do byId[s.id] = s end
    ok(byId[11] and byId[12], "two displays swap immediately (no picker)")
    ok(not byId[13] and not byId[14], "minimized and fullscreen windows are skipped")
    -- w11 A->B: sx=2, sy=1.5; 1.5 is nearer 1 -> scale 1.5. 400x300 -> 600x450.
    -- pos: 1000+100*2=1200, 0+100*1.5=150.
    ok(byId[11].x == 1200 and byId[11].y == 150 and byId[11].w == 600 and byId[11].h == 450,
        "window on A lands on B, rescaled by the least-distortion axis")
    -- w12 B->A: sx=0.5, sy=2/3; 2/3 nearer 1 -> scale 2/3. 600x450 -> 400x300.
    -- pos: 0+(1200-1000)*0.5=100, 0+150*(2/3)=100.
    ok(byId[12].x == 100 and byId[12].y == 100 and byId[12].w == 400 and byId[12].h == 300,
        "window on B lands on A, rescaled back")
end
-- three displays: NO auto-swap -- the spatial picker opens to pick ANY two
-- displays (the active one is only the sticky DEFAULT, passed LAST in preselect;
-- no locked "current"). Each display carries its window count. Equal-size screens
-- keep the geometry trivial (scale 1, +/-1000 shift).
do
    fake.screenList = {
        { x = 0,    y = 0, w = 1000, h = 800, name = "Left"   },
        { x = 1000, y = 0, w = 1000, h = 800, name = "Middle" },
        { x = 2000, y = 0, w = 1000, h = 800, name = "Right"  },
    }
    fake.focusedWindow = { x = 1100, y = 100, w = 200, h = 150, screenIndex = 2 } -- active = Middle
    fake.windows = {
        { id = 41, x = 100,  y = 100, w = 200, h = 150 },   -- Left   (1 window)
        { id = 42, x = 1100, y = 100, w = 200, h = 150 },   -- Middle
        { id = 43, x = 2100, y = 200, w = 300, h = 200 },   -- Right  (1 window)
        { id = 44, x = 1200, y = 300, w = 200, h = 150 },   -- Middle (2nd -> count 2)
    }
    fake.windowFrameSets = {}
    local nPickers = #fake.displayPickers
    assert(registry.runAction("window_snap", "swap_screens"))
    ok(#fake.windowFrameSets == 0, "3 displays: nothing moves until the user confirms")
    ok(#fake.displayPickers == nPickers + 1, "3 displays: the spatial display picker opens")
    local dp = fake.displayPickers[#fake.displayPickers]
    ok(dp.selectCount == 2, "picker asks for a pair (selectCount 2)")
    ok(#dp.preselect == 2 and dp.preselect[#dp.preselect] == 2,
        "the active display (Middle) is the sticky default -- passed LAST in preselect")
    ok(#dp.displays == 3, "the whole arrangement is drawn")
    ok(dp.displays[1].windows == 1 and dp.displays[2].windows == 2 and dp.displays[3].windows == 1,
        "each display carries its (minimized/fullscreen-excluded) window count")
    -- the user is free to pick ANY two -- confirm Left + Right (neither is active)
    dp.userConfirm({ 1, 3 })
    local byId = {}
    for _, s in ipairs(fake.windowFrameSets) do byId[s.id] = s end
    ok(not byId[42] and not byId[44], "windows on the un-chosen display (Middle) are left alone")
    ok(byId[41] and byId[41].x == 2100 and byId[41].y == 100 and byId[41].w == 200 and byId[41].h == 150,
        "a window on the first picked display (Left) moves to the second (Right)")
    ok(byId[43] and byId[43].x == 100 and byId[43].y == 200 and byId[43].w == 300 and byId[43].h == 200,
        "a window on the second picked display (Right) moves to the first (Left)")
end
-- one display -> alerts, moves nothing, no picker
do
    fake.screenList = { { x = 0, y = 0, w = 1000, h = 800 } }
    fake.focusedWindow = nil
    fake.windows = { { id = 31, x = 10, y = 10, w = 100, h = 100 } }
    fake.windowFrameSets = {}
    local before, nPickers = #fake.alerts, #fake.displayPickers
    assert(registry.runAction("window_snap", "swap_screens"))
    ok(#fake.windowFrameSets == 0 and #fake.alerts > before and #fake.displayPickers == nPickers,
        "swap with one display alerts, moves nothing, opens no picker")
    fake.windows = {}
end
-- swap without Accessibility: onboard (prompt + alert), don't silently no-op or
-- open a picker full of "0 windows" displays.
do
    fake.screenList = {
        { x = 0, y = 0, w = 1000, h = 800 },
        { x = 1000, y = 0, w = 2000, h = 1200 },
    }
    fake.focusedWindow = nil
    fake.windows = { { id = 61, x = 100, y = 100, w = 200, h = 150 } }
    fake.windowFrameSets = {}
    fake.axTrusted = false
    local before, nPickers = #fake.alerts, #fake.displayPickers
    assert(registry.runAction("window_snap", "swap_screens"))
    ok(#fake.windowFrameSets == 0 and #fake.alerts > before and #fake.displayPickers == nPickers,
        "swap without Accessibility onboards (alert), moves nothing, opens no picker")
    fake.axTrusted = true
    fake.windows = {}
end

-- no focused window -> plain alert (trusted)
fake.focusedWindow = nil
fake.pressHotkey("left", AC)
ok(fake.alerts[#fake.alerts]:match("No focused window") ~= nil, "no window alerts plainly")

registry.setEnabled("window_snap", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after window_snap test")

-- T24b: pointer_follows_window (a window move carries the pointer, relative pos) --
-- Reuses window_snap (already registered above) as the mover under test: the
-- follow lives at the ctx.window.setFrame -> window_ops seam, so ANY feature that
-- moves the focused window exercises it. Screen 1 = {0,0,1000,800}; "left" snaps
-- to {0,0,500,800}.
registry.register(require("features.pointer_follows_window"))
registry.setEnabled("window_snap", true)

-- pointer_follows_window declares itself a global PREFERENCE (feature.json
-- "preference": true), so the host surfaces it in Settings > General > Behavior
-- and filters it OUT of the feature catalog -- describe() must carry the flag.
do
    local pfw
    for _, e in ipairs(registry.describe()) do
        if e.id == "pointer_follows_window" then pfw = e end
    end
    ok(pfw ~= nil and pfw.preference == true, "describe() flags pointer_follows_window as a preference")
end
fake.screenList = {
    { x = 0, y = 0, w = 1000, h = 800 },
    { x = 1000, y = 0, w = 2000, h = 1200 },
}
local function snapLeftFromCorner()
    fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
    fake.mousePos      = { x = 200, y = 250 }   -- 25% across, 50% down the window
    fake.pressHotkey("left", AC)                 -- -> {0,0,500,800}
end

-- toggle OFF: the snap moves the window but leaves the pointer alone
registry.setEnabled("pointer_follows_window", false)
snapLeftFromCorner()
ok(fake.mousePos.x == 200 and fake.mousePos.y == 250,
    "pointer_follows_window OFF: a snap leaves the pointer where it was")

-- toggle ON: the pointer rides the window, keeping its relative position
-- (25% across, 50% down -> 0+0.25*500, 0+0.5*800 = 125, 400)
registry.setEnabled("pointer_follows_window", true)
snapLeftFromCorner()
ok(fake.mousePos.x == 125 and fake.mousePos.y == 400,
    "pointer_follows_window ON: pointer keeps its relative spot after a snap")

-- a pointer parked OUTSIDE the moved window is never yanked
fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
fake.mousePos      = { x = 5, y = 5 }
fake.pressHotkey("left", AC)
ok(fake.mousePos.x == 5 and fake.mousePos.y == 5,
    "pointer_follows_window: a pointer outside the window is left alone")

-- moveScreen + pointer_follows_window ON: the mover reads the pointer BEFORE
-- ctx.window.setFrame (which itself carries it), so the two window-relative
-- carries AGREE instead of compounding. Throw {100,100,400,300} on screen 1 to
-- the bigger screen 2 (new frame {1200,150,600,450}); the pointer at 12.5%/33%
-- lands at 1275,300 -- NOT the 2275 the old read-after-move carry produced.
registry.setEnabled("pointer_follows_window", true)
fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
fake.mousePos      = { x = 150, y = 200 }
fake.pressHotkey("]", AC)
ok(fake.mousePos.x == 1275 and fake.mousePos.y == 300,
    "moveScreen + follow ON: pointer tracks the window, no double-carry drift")

registry.setEnabled("pointer_follows_window", false)
registry.setEnabled("window_snap", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after pointer_follows_window test")

-- T24p: window_snap PLACEMENT PRESETS -- the dynamicActions hook turns each saved
-- preset (a JSON array in the feature's OWN option) into its own rebindable action
-- (preset_<uuid>). Exercises: expansion, apply via rectFromRatios, stable-id
-- trigger survival across a re-register (what reload() does), rename relabel, and
-- tolerance of a corrupt setting. All in window_snap's own namespace -- no other
-- feature involved (the decoupled design the owner asked for).
do
    local pjson = require("platform.json")
    local presetsKey = "hammerdeck.opt.window_snap.presets"

    -- Re-register window_snap from a FRESH module (clears the require cache like
    -- reload() does, so the static action list is expanded anew from the CURRENT
    -- setting -- never double-appended), then enable it.
    local function reregister()
        pcall(registry.setEnabled, "window_snap", false)
        registry.unregister("window_snap")
        package.loaded["features.window_snap"] = nil
        registry.register(require("features.window_snap"))
        registry.setEnabled("window_snap", true)
    end
    -- The described action row for an id, or nil.
    local function snapAction(id)
        for _, f in ipairs(registry.describe()) do
            if f.id == "window_snap" then
                for _, a in ipairs(f.actions) do
                    if a.id == id then return a end
                end
            end
        end
        return nil
    end

    fake.screenList    = { { x = 0, y = 0, w = 1200, h = 900 } }
    fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }

    -- (1) two presets -> two bindable actions (clean 0.5 fractions so the frame is exact)
    fake.settings[presetsKey] = pjson.encode({
        { id = "aaa", name = "Left half",         x = 0,   y = 0, w = 0.5, h = 1 },
        { id = "bbb", name = "Top-right quarter", x = 0.5, y = 0, w = 0.5, h = 0.5 },
    })
    reregister()
    ok(snapAction("preset_aaa") ~= nil and snapAction("preset_bbb") ~= nil,
        "each stored preset becomes a bindable action")
    ok(snapAction("preset_aaa").label == "Left half",
        "the action takes the preset's name as its label")
    ok(registry.isActionAutomatable("window_snap", "preset_aaa") == false,
        "a preset action is manual-only (not automatable)")
    ok(snapAction("preset_aaa").defaultTrigger == nil,
        "a preset ships dormant -- no default trigger (no uninvited hotkey grab)")
    -- The dynamic tag is what the config UI reads to HIDE these from the generic
    -- per-action trigger sections (they are bound inline in Saved placements); a
    -- built-in action must stay non-dynamic.
    ok(snapAction("preset_aaa").dynamic == true,
        "a preset action is tagged dynamic (config UI hides its duplicate trigger section)")
    ok(snapAction("left").dynamic == false,
        "a built-in action is not dynamic")

    -- (2) firing a preset applies its fractions via rectFromRatios
    assert(registry.runAction("window_snap", "preset_aaa"))
    local lf = lastFrame()
    ok(lf.x == 0 and lf.y == 0 and lf.w == 600 and lf.h == 900,
        "preset_aaa applies the left-half rectangle")
    assert(registry.runAction("window_snap", "preset_bbb"))
    lf = lastFrame()
    ok(lf.x == 600 and lf.y == 0 and lf.w == 600 and lf.h == 450,
        "preset_bbb applies the top-right-quarter rectangle")

    -- (3) stable id: a bound shortcut survives a re-register (reload's essence),
    -- because the trigger override keys on preset_<uuid>, not the array index.
    ok(registry.setTrigger("window_snap", "preset_aaa",
        { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "1" }),
        "a preset action binds a hotkey")
    reregister()
    local a = snapAction("preset_aaa")
    ok(a ~= nil and a.triggerOverridden == true and a.trigger and a.trigger.key == "1",
        "the bound shortcut survives a re-register (stable preset id)")

    -- (4) rename (same id, new name) -> new label, SAME binding
    fake.settings[presetsKey] = pjson.encode({
        { id = "aaa", name = "My Big Left",       x = 0,   y = 0, w = 0.5, h = 1 },
        { id = "bbb", name = "Top-right quarter", x = 0.5, y = 0, w = 0.5, h = 0.5 },
    })
    reregister()
    a = snapAction("preset_aaa")
    ok(a ~= nil and a.label == "My Big Left", "a rename updates the action label")
    ok(a.triggerOverridden == true, "a rename keeps the shortcut (the id is unchanged)")

    -- (5) tolerance: a corrupt setting yields NO preset actions, but the built-in
    -- snaps still bind (a bad value must never disable the feature)
    fake.settings[presetsKey] = "{ not json"
    reregister()
    ok(snapAction("preset_aaa") == nil, "a corrupt presets value drops the preset actions")
    ok(snapAction("left") ~= nil, "... and the built-in snaps still bind")

    -- clean up: clear the setting + the override, re-register a clean window_snap,
    -- leave it DISABLED as the earlier tests left it.
    fake.settings[presetsKey] = nil
    fake.settings["hammerdeck.trigger.window_snap.preset_aaa"] = nil
    pcall(registry.setEnabled, "window_snap", false)
    registry.unregister("window_snap")
    package.loaded["features.window_snap"] = nil
    registry.register(require("features.window_snap"))
    ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
        "clean after window_snap presets test")
end

-- T24r: window_rewind -- single-step undo of the last window LAYOUT change. It
-- records at the window_ops funnel (the same seam window_snap/deck move through),
-- so a snap, a whole-display swap, or a deck retile is all undoable by one global
-- Hyper+Z. window_snap (registered above, left disabled) is the real mover here;
-- window_rewind only records + restores.
fake.reset()   -- clean input slate: isolate from the prior window sections
registry.register(require("features.window_rewind"))
registry.setEnabled("window_rewind", true)   -- start(ctx) turns recording on
registry.setEnabled("window_snap", true)     -- a real mover to generate history

-- (a) BY-ID batch: a two-display swap fires many setFrameFor in one synchronous
-- loop -> ONE undo group. Undo restores every moved window to its pre-swap frame
-- AND the pointer to where it was when the swap began. (Keys on the STABLE wid,
-- re-resolved to a live id at undo time -- the ids-only-valid-until-next-list rule.)
do
    fake.screenList = {
        { x = 0,    y = 0, w = 1000, h = 800 },      -- A
        { x = 1000, y = 0, w = 2000, h = 1200 },     -- B (bigger)
    }
    fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 } -- active = A
    fake.windows = {
        { id = 11, wid = 111, x = 100,  y = 100, w = 400, h = 300 },   -- on A -> moves to B
        { id = 12, wid = 222, x = 1200, y = 150, w = 600, h = 450 },   -- on B -> moves to A
    }
    fake.mousePos = { x = 150, y = 200 }         -- captured at group start
    local A = { x = 100,  y = 100, w = 400, h = 300 }
    local B = { x = 1200, y = 150, w = 600, h = 450 }

    assert(registry.runAction("window_snap", "swap_screens"))
    ok(fake.windows[1].x ~= A.x, "precondition: the swap actually moved the windows")

    fake.mousePos = { x = 999, y = 999 }         -- user drifts the pointer after the swap
    fake.windowFrameSets = {}
    assert(registry.runAction("window_rewind", "undo"))
    ok(#fake.windowFrameSets == 2, "undo moved back exactly the two swapped windows")
    ok(fake.windows[1].x == A.x and fake.windows[1].y == A.y
        and fake.windows[1].w == A.w and fake.windows[1].h == A.h,
        "window A restored to its pre-swap frame")
    ok(fake.windows[2].x == B.x and fake.windows[2].y == B.y
        and fake.windows[2].w == B.w and fake.windows[2].h == B.h,
        "window B restored to its pre-swap frame")
    ok(fake.mousePos.x == 150 and fake.mousePos.y == 200,
        "undo returns the pointer to the group-start position")

    fake.windowFrameSets = {}
    assert(registry.runAction("window_rewind", "undo"))
    ok(#fake.windowFrameSets == 0, "single-step: a second undo is a no-op (the group was consumed)")
end

-- (b) FOCUSED move: recorded via focusedWindowFrame()+focusedWindowWid() (no
-- list() -- that path must never rebuild the AX cache mid-batch), restored by
-- re-resolving the stored wid to a live id. The prior group was consumed by (a)'s
-- undo, so this snap starts a fresh group.
do
    fake.screenList = { { x = 0, y = 0, w = 1000, h = 800 } }
    fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
    fake.focusedWid = 111
    fake.windows = { { id = 11, wid = 111, x = 100, y = 100, w = 400, h = 300 } }
    fake.pressHotkey("left", AC)                  -- window_snap "left" -> focused {0,0,500,800}
    ok(fake.focusedWindow.x == 0 and fake.focusedWindow.w == 500,
        "precondition: the snap moved the focused window")
    -- The fake keeps the window LIST and the focused frame in separate stores;
    -- mirror what a real listWindows() would now report (the moved frame) so undo's
    -- re-list resolves wid 111 to id 11.
    fake.windows = { { id = 11, wid = 111, x = 0, y = 0, w = 500, h = 800 } }
    fake.windowFrameSets = {}
    assert(registry.runAction("window_rewind", "undo"))
    ok(#fake.windowFrameSets == 1
        and fake.windows[1].x == 100 and fake.windows[1].y == 100
        and fake.windows[1].w == 400 and fake.windows[1].h == 300,
        "undo restores a focused snap to its pre-snap frame")
end

-- disabling window_rewind clears any pending history (nothing to undo afterward)
do
    fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
    fake.focusedWid = 111
    fake.windows = { { id = 11, wid = 111, x = 100, y = 100, w = 400, h = 300 } }
    fake.pressHotkey("left", AC)                  -- record a change...
    registry.setEnabled("window_rewind", false)   -- ...then disable: history is cleared
    registry.setEnabled("window_rewind", true)
    fake.windowFrameSets = {}
    assert(registry.runAction("window_rewind", "undo"))
    ok(#fake.windowFrameSets == 0, "disabling window_rewind clears pending history")
end

-- (d) a move we CAN'T record (unresolvable window id, a fresh action >1s later)
-- must NOT clobber the still-valid prior undo group into an empty one -- the
-- earlier change stays undoable. (Without the record-side guard, the id-less move
-- would replace the pending group with an empty one and undo would restore
-- nothing.)
do
    fake.screenList = { { x = 0, y = 0, w = 1000, h = 800 } }
    fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
    fake.focusedWid = 111
    fake.windows = { { id = 11, wid = 111, x = 100, y = 100, w = 400, h = 300 } }
    fake.pressHotkey("left", AC)                  -- group A: before-frame {100,100,400,300}
    ok(fake.focusedWindow.x == 0 and fake.focusedWindow.w == 500,
        "precondition: the first snap moved and recorded the window")
    fake.clockOffset = fake.clockOffset + 2       -- a fresh action window (>GAP)
    fake.focusedWid = 0                            -- unresolvable id: this move can't be recorded
    fake.pressHotkey("right", AC)                 -- moves via AX, but records nothing
    fake.focusedWid = 111
    fake.windows = { { id = 11, wid = 111, x = 500, y = 0, w = 500, h = 800 } }  -- mirror the moved frame
    fake.windowFrameSets = {}
    assert(registry.runAction("window_rewind", "undo"))
    ok(#fake.windowFrameSets == 1
        and fake.windows[1].x == 100 and fake.windows[1].y == 100
        and fake.windows[1].w == 400 and fake.windows[1].h == 300,
        "an unrecordable move does not clobber the prior undo group (it still restores)")
end

fake.focusedWid = nil
registry.setEnabled("window_snap", false)
registry.setEnabled("window_rewind", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after window_rewind test")

-- T25: window_modal (modal hotkey group over the frame surface) ----------------
registry.register(require("features.window_modal"))
registry.setEnabled("window_modal", true)
fake.settings["hammerdeck.opt.window_modal.stepParts"] = 10   -- step = 100 x 80

fake.screenList = {
    { x = 0, y = 0, w = 1000, h = 800 },
    { x = 1000, y = 0, w = 2000, h = 1200 },
}
fake.focusedWindow = { x = 200, y = 200, w = 400, h = 300, screenIndex = 1 }

-- enter the mode: HUD up, bare keys live
fake.pressHotkey("w", { "cmd", "alt", "ctrl" })
ok(fake.liveHud() ~= nil and fake.liveHud().title == "Window Mode",
    "entering the mode shows the HUD")
fake.pressHotkey("a", {})
ok(fake.focusedWindow.x == 100, "A step-moves left by screen/stepParts")
fake.pressHotkey("s", {})
ok(fake.focusedWindow.y == 280, "S step-moves down")
fake.pressHotkey("h", {})
ok(fake.focusedWindow.w == 500 and fake.focusedWindow.h == 800 and fake.focusedWindow.x == 0,
    "H snaps the left half")
fake.pressHotkey("i", {})
ok(fake.focusedWindow.x == 500 and fake.focusedWindow.y == 400
    and fake.focusedWindow.w == 500 and fake.focusedWindow.h == 400,
    "I snaps the SE corner quadrant")
fake.pressHotkey("l", { "shift" })
ok(fake.focusedWindow.w == 600, "shift+L widens by one step")
fake.pressHotkey("c", {})
ok(fake.focusedWindow.x == 200 and fake.focusedWindow.y == 200,
    "C centers keeping the size")
fake.pressHotkey("=", {})
ok(fake.focusedWindow.x == 100 and fake.focusedWindow.w == 800
    and fake.focusedWindow.y == 120 and fake.focusedWindow.h == 560,
    "= expands one step on every side, center fixed")

-- undo unwinds, redo replays
fake.pressHotkey("[", {})
ok(fake.focusedWindow.x == 200 and fake.focusedWindow.w == 600, "[ undoes the expand")
fake.pressHotkey("]", {})
ok(fake.focusedWindow.x == 100 and fake.focusedWindow.w == 800, "] redoes it")

-- throw to the screen on the right (size kept, position scaled, clamped)
fake.pressHotkey("right", {})
ok(fake.focusedWindow.screen == nil or true, "noop guard")
ok(fake.windowFrames[#fake.windowFrames].x == 1200
    and fake.windowFrames[#fake.windowFrames].w == 800,
    "right-arrow moves to the right screen, size kept")

-- escape exits: banner gone, bare keys dead
local xBefore = fake.focusedWindow.x
fake.pressHotkey("escape", {})
ok(fake.liveHud() == nil, "escape drops the HUD")
fake.pressHotkey("a", {})
ok(fake.focusedWindow.x == xBefore, "bare keys are dead after exit")

-- the trigger toggles: enter, then the same hotkey exits
fake.pressHotkey("w", { "cmd", "alt", "ctrl" })
ok(fake.liveHud() ~= nil, "re-enter works")
fake.pressHotkey("w", { "cmd", "alt", "ctrl" })
ok(fake.liveHud() == nil, "the enter hotkey toggles the mode off")

-- disabling mid-mode leaks nothing
fake.pressHotkey("w", { "cmd", "alt", "ctrl" })
ok(fake.liveHud() ~= nil, "mode active before disable")
registry.setEnabled("window_modal", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
    "disable mid-mode tears everything down")
fake.settings["hammerdeck.opt.window_modal.stepParts"] = nil

-- T25c: windows.moveToScreen geometry (the pure shared core of both features) ---
local W = require("platform.windows")
local function frameEq(nf, x, y, w, h, msg)
    ok(nf.x == x and nf.y == y and nf.w == w and nf.h == h,
        msg .. " (got " .. nf.x .. "," .. nf.y .. "," .. nf.w .. "," .. nf.h .. ")")
end
local s1 = { x = 0, y = 0, w = 1000, h = 800 }
-- default (window_snap): same-size target, scale 1 -> position shifts, size kept.
frameEq(W.moveToScreen({ x = 100, y = 100, w = 400, h = 300 }, s1, { x = 1000, y = 0, w = 1000, h = 800 }),
    1100, 100, 400, 300, "moveToScreen default: equal screens just translate")
-- default: 2x larger target -> least-distortion scale 2 on both dims + position.
frameEq(W.moveToScreen({ x = 100, y = 100, w = 400, h = 300 }, s1, { x = 0, y = 0, w = 2000, h = 1600 }),
    200, 200, 800, 600, "moveToScreen default: larger screen scales both dims")
-- default fill-clamp: scaled window wider than target -> filled to the target edge.
frameEq(W.moveToScreen({ x = 0, y = 0, w = 1000, h = 800 }, s1, { x = 1000, y = 0, w = 800, h = 800 }),
    1000, 0, 800, 800, "moveToScreen default: oversize result fills the target edge")
-- keepSize (window_modal): size kept but shrunk to fit, clamped back inside.
frameEq(W.moveToScreen({ x = 100, y = 100, w = 1500, h = 1000 }, s1, { x = 1000, y = 0, w = 800, h = 600 },
    { keepSize = true }),
    1000, 0, 800, 600, "moveToScreen keepSize: shrinks to fit and clamps inside")

-- T25c-2: windows.adjacentScreen / screenIndexAt -- "next/prev screen" must
-- follow the PHYSICAL arrangement (left-to-right), NOT adapter.screenFrames'
-- array order (NSScreen.screens = primary first, then OS registration order).
-- Three monitors registered OUT of spatial order proves it: array is A,C,B but
-- physically A(left) B(middle) C(right). The old (i % n)+1 cycle would step
-- A -> C (skipping the middle); the spatial helper steps A -> B -> C.
do
    local scr = {
        { x = -1000, y = 0, w = 1000, h = 800, name = "A" },  -- index 1, leftmost
        { x = 1000,  y = 0, w = 1000, h = 800, name = "C" },  -- index 2, rightmost
        { x = 0,     y = 0, w = 1000, h = 800, name = "B" },  -- index 3, middle
    }
    local f, i = W.adjacentScreen(scr, 1, "next")
    ok(f.name == "B" and i == 3, "adjacentScreen next follows spatial L-to-R, not array order")
    f, i = W.adjacentScreen(scr, 1, "prev")
    ok(f.name == "C" and i == 2, "adjacentScreen prev from leftmost wraps to rightmost")
    ok(W.adjacentScreen(scr, 3, "next").name == "C", "adjacentScreen next from middle -> right")
    ok(W.adjacentScreen(scr, 2, "next").name == "A", "adjacentScreen next from rightmost wraps to leftmost")

    -- vertical stack: tie-break top-to-bottom by y (top-left origin, so y asc = top).
    local stack = {
        { x = 0, y = 800, w = 1000, h = 800, name = "bottom" },  -- index 1
        { x = 0, y = 0,   w = 1000, h = 800, name = "top" },     -- index 2
    }
    ok(W.adjacentScreen(stack, 2, "next").name == "bottom", "adjacentScreen tie-breaks top-to-bottom by y")

    -- degenerate arities: single screen re-centers on itself; none -> nil.
    local solo = W.adjacentScreen({ { x = 0, y = 0, w = 1, h = 1, name = "solo" } }, 1, "next")
    ok(solo and solo.name == "solo", "adjacentScreen on one screen re-centers on itself")
    ok(W.adjacentScreen({}, 1, "next") == nil, "adjacentScreen on no screens returns nil")

    -- a direction outside W.DIR errors loudly instead of silently stepping
    -- "next" (the '"previous"' bug class); a typo'd FIELD (W.DIR.PREVIOUS)
    -- is nil and takes the same loud path.
    ok(not pcall(W.adjacentScreen, scr, 1, "previous"), "adjacentScreen rejects a non-enum direction loudly")
    ok(not pcall(W.adjacentScreen, scr, 1, W.DIR.PREVIOUS), "a typo'd DIR field is nil and rejected loudly")

    -- screenIndexAt: the frame containing the point, defaulting to 1 off-screen.
    ok(W.screenIndexAt(scr, 500, 400) == 3, "screenIndexAt returns the frame under the point (middle)")
    ok(W.screenIndexAt(scr, -500, 400) == 1, "screenIndexAt returns the leftmost frame")
    ok(W.screenIndexAt(scr, 99999, 400) == 1, "screenIndexAt defaults to 1 when the point is off every screen")
end

-- T25d: windows.gridCellToFrame -- the ported grid cell-placement algorithm ------
-- A 3x1 grid on a 1200x900 screen -> 400-wide full-height columns. `do`-scoped
-- to keep its locals off the flat main chunk (Lua's 200-locals-per-function cap).
do
    local g3 = { w = 3, h = 1 }
    local gs = { x = 0, y = 0, w = 1200, h = 900 }
    frameEq(W.gridCellToFrame(gs, g3, { x = 0, y = 0, w = 1, h = 1 }),
        0, 0, 400, 900, "gridCellToFrame: left column of a 3x1 grid")
    frameEq(W.gridCellToFrame(gs, g3, { x = 1, y = 0, w = 2, h = 1 }),
        400, 0, 800, 900, "gridCellToFrame: a 2-column span from offset 1")
    -- A 2x2 grid with a 10pt gutter insets each placed cell on every side.
    frameEq(W.gridCellToFrame({ x = 0, y = 0, w = 1000, h = 800 }, { w = 2, h = 2 },
        { x = 0, y = 0, w = 1, h = 1 }, { x = 10, y = 10 }),
        10, 10, 480, 380, "gridCellToFrame: a margin insets each window by the gutter")
    -- The screen origin is honored (placed relative to a secondary screen's frame).
    frameEq(W.gridCellToFrame({ x = 1000, y = 0, w = 1200, h = 900 }, g3, { x = 2, y = 0, w = 1, h = 1 }),
        1800, 0, 400, 900, "gridCellToFrame: cell placed relative to the screen origin")
end

-- T25d2: windows.gridDimsForScreen -- orientation-aware split (Window Grid's 6) --
do
    local land = { w = 1600, h = 900 }   -- landscape: more columns
    local port = { w = 900,  h = 1600 }  -- portrait:  more rows
    local d
    d = W.gridDimsForScreen(6, land); ok(d.w == 3 and d.h == 2, "gridDimsForScreen(6, landscape) = 3x2")
    d = W.gridDimsForScreen(6, port); ok(d.w == 2 and d.h == 3, "gridDimsForScreen(6, portrait) = 2x3")
    -- Square counts are aspect-agnostic (same either way).
    d = W.gridDimsForScreen(4, land); ok(d.w == 2 and d.h == 2, "gridDimsForScreen(4) = 2x2 (square)")
    d = W.gridDimsForScreen(9, port); ok(d.w == 3 and d.h == 3, "gridDimsForScreen(9) = 3x3 (square)")
    -- A square screen (w == h) takes the landscape branch (>=): more columns.
    d = W.gridDimsForScreen(6, { w = 1000, h = 1000 }); ok(d.w == 3 and d.h == 2,
        "gridDimsForScreen(6, square screen) = 3x2 (w>=h -> wide)")
    -- Balanced-factor pick, not naive: 3 -> 3x1/1x3, prime 5 -> 5x1/1x5, 1 -> 1x1.
    d = W.gridDimsForScreen(3, land); ok(d.w == 3 and d.h == 1, "gridDimsForScreen(3, landscape) = 3x1")
    d = W.gridDimsForScreen(5, port); ok(d.w == 1 and d.h == 5, "gridDimsForScreen(5, portrait) = 1x5 (prime)")
    d = W.gridDimsForScreen(1, land); ok(d.w == 1 and d.h == 1, "gridDimsForScreen(1) = 1x1")
end

-- T25e: window_grid ENTRY -- Hyper+N shows the numbered grid; the FIRST cell press
-- places that single cell immediately AND arms the mode (no longer single-shot).
do
    registry.register(require("features.window_grid"))
    registry.setEnabled("window_grid", true)
    fake.screenList = { { x = 0, y = 0, w = 1200, h = 900 } }
    fake.focusedWindow = { x = 0, y = 0, w = 100, h = 100, screenIndex = 1 }
    local HYP = { "cmd", "alt", "ctrl" }
    local gf

    -- 3x3: Hyper+9 shows the numbered HUD; the first digit (2) lands the window
    -- top-middle (cell 2 = row0,col1 -> 400,0,400x300) IMMEDIATELY and ARMS.
    fake.pressHotkey("9", HYP)
    ok(fake.liveHud() ~= nil and fake.liveHud().title == "3×3 Grid",
        "Hyper+9 shows the 3x3 grid HUD")
    fake.pressHotkey("2", {})
    gf = fake.windowFrames[#fake.windowFrames]
    ok(gf.x == 400 and gf.y == 0 and gf.w == 400 and gf.h == 300,
        "3x3 first press: cell 2 places top-middle (col1,row0) at once")
    ok(fake.liveHud() ~= nil, "the first press ARMS -- the mode stays open (not single-shot)")
    fake.pressHotkey("escape", {})
    ok(fake.liveHud() == nil, "escape exits the armed grid")

    -- 2x2: Hyper+4 -> first digit 3 lands bottom-left (cell 3 = row1,col0 -> 0,450,600x450).
    fake.pressHotkey("4", HYP)
    ok(fake.liveHud() ~= nil and fake.liveHud().title == "2×2 Grid",
        "Hyper+4 shows the 2x2 grid HUD")
    fake.pressHotkey("3", {})
    gf = fake.windowFrames[#fake.windowFrames]
    ok(gf.x == 0 and gf.y == 450 and gf.w == 600 and gf.h == 450,
        "2x2 first press: cell 3 places bottom-left (col0,row1)")
    fake.pressHotkey("escape", {})

    -- 6-cell grid, ORIENTED to the screen. Landscape (1200x900, w>h) -> 3x2:
    -- Hyper+6 shows a "3×2 Grid" HUD; cell 5 lands middle-bottom (400,450,400x450).
    fake.pressHotkey("6", HYP)
    ok(fake.liveHud() ~= nil and fake.liveHud().title == "3×2 Grid",
        "Hyper+6 on a landscape screen shows a 3×2 grid HUD")
    fake.pressHotkey("5", {})
    gf = fake.windowFrames[#fake.windowFrames]
    ok(gf.x == 400 and gf.y == 450 and gf.w == 400 and gf.h == 450,
        "6-grid cell 5 -> middle-bottom of a 3x2 (col1,row1)")
    fake.pressHotkey("escape", {})

    -- SAME action, PORTRAIT screen (900x1200, h>w) -> 2x3: the shape follows the
    -- aspect, not a fixed square. Cell 5 lands bottom-left (col0,row2 -> 0,800,450x400).
    fake.screenList = { { x = 0, y = 0, w = 900, h = 1200 } }
    fake.focusedWindow = { x = 0, y = 0, w = 100, h = 100, screenIndex = 1 }
    fake.pressHotkey("6", HYP)
    ok(fake.liveHud() ~= nil and fake.liveHud().title == "2×3 Grid",
        "Hyper+6 on a portrait screen shows a 2×3 grid HUD (oriented)")
    fake.pressHotkey("5", {})
    gf = fake.windowFrames[#fake.windowFrames]
    ok(gf.x == 0 and gf.y == 800 and gf.w == 450 and gf.h == 400,
        "6-grid cell 5 -> bottom-left of a 2x3 (col0,row2)")
    fake.pressHotkey("escape", {})
    fake.screenList = { { x = 0, y = 0, w = 1200, h = 900 } }   -- restore landscape for the rest
    fake.focusedWindow = { x = 0, y = 0, w = 100, h = 100, screenIndex = 1 }

    -- STICKY MODIFIER + SHADOW: the leader (Hyper) held THROUGH the cell digit
    -- still fires it -- the user need not release Caps between Hyper+4 and the
    -- number. ctx.modal binds each bare cell key ALSO under the entering trigger's
    -- mods (Hyper), and that sticky twin SHADOWS any standalone on the combo for
    -- the mode's life -- the exact "leaked to a global Hyper+1 (window_deck)" bug.
    -- A stand-in global Hyper+1 proves it: silent while the grid is live, fires
    -- again after exit. (Under place-and-extend the first sticky press ARMS.)
    local stickyGlobalFires = 0
    local stickyGlobal = fake.adapter.bindHotkey(HYP, "1", function() stickyGlobalFires = stickyGlobalFires + 1 end)
    fake.pressHotkey("4", HYP)
    ok(fake.liveHud() ~= nil, "re-enter 2x2 for the sticky-modifier check")
    fake.pressHotkey("1", HYP)   -- Hyper still held through the cell key
    gf = fake.windowFrames[#fake.windowFrames]
    ok(gf.x == 0 and gf.y == 0 and gf.w == 600 and gf.h == 450,
        "2x2 cell 1 fires (arms) with the leader (Hyper) held through the digit")
    ok(stickyGlobalFires == 0, "the standalone Hyper+1 is shadowed while the grid is live")
    ok(fake.liveHud() ~= nil, "the sticky first press ARMS -- the grid stays open")
    fake.pressHotkey("escape", {})
    ok(fake.liveHud() == nil, "escape exits the armed grid")
    fake.pressHotkey("1", HYP)
    ok(stickyGlobalFires == 1, "the shadowed Hyper+1 fires again once the grid exits")
    stickyGlobal.stop()

    -- esc cancels with no placement.
    local nBefore = #fake.windowFrames
    fake.pressHotkey("9", HYP)
    ok(fake.liveHud() ~= nil, "re-enter shows the HUD again")
    fake.pressHotkey("escape", {})
    ok(fake.liveHud() == nil and #fake.windowFrames == nBefore,
        "esc cancels the grid without placing")

    -- no focused window -> alert, never an empty grid.
    fake.focusedWindow = nil
    fake.pressHotkey("9", HYP)
    ok(fake.liveHud() == nil, "no focused window -> no grid shown")
    fake.focusedWindow = { x = 0, y = 0, w = 100, h = 100, screenIndex = 1 }
end

-- T25e2: window_grid TWO-CORNER placement (place-and-extend, directional). First
-- cell = top-left corner-A; a second cell DOWN-RIGHT of it fills the rectangle.
do
    fake.screenList = { { x = 0, y = 0, w = 1200, h = 900 } }
    fake.focusedWindow = { x = 0, y = 0, w = 100, h = 100, screenIndex = 1 }
    local HYP = { "cmd", "alt", "ctrl" }
    local gf

    -- PLACE-AND-EXTEND: on the 3x2 (Hyper+6, cw=400 ch=450), press corner-A
    -- (cell 1 = top-left) then a down-right cell (5) -> the window fills the 2x2
    -- span = left 2/3, full height (0,0,800,900), and the mode commits.
    fake.pressHotkey("6", HYP)
    fake.pressHotkey("1", {})
    ok(fake.liveHud() ~= nil, "first corner arms; the mode stays open")
    gf = fake.windowFrames[#fake.windowFrames]
    ok(gf.x == 0 and gf.y == 0 and gf.w == 400 and gf.h == 450,
        "corner-A (cell 1) is placed as a single cell immediately")
    fake.pressHotkey("5", {})   -- down-right of 1 -> extend
    gf = fake.windowFrames[#fake.windowFrames]
    ok(gf.x == 0 and gf.y == 0 and gf.w == 800 and gf.h == 900,
        "extend 1->5 fills the 2x2 span (left 2/3, full height)")
    ok(fake.liveHud() == nil, "a valid extension commits and exits")

    -- DIRECTIONAL "no turn back": on a 3x3 (cw=400 ch=300), cell 3 (top-right)
    -- then cell 4 (middle-left) is NOT a valid down-right corner -> it RE-PICKS:
    -- cell 4 becomes a fresh single placement (0,300,400x300), never a 3->4 span.
    fake.pressHotkey("9", HYP)
    fake.pressHotkey("3", {})   -- arm corner-A = cell 3 (col2,row0)
    local armedHandles = registry.liveHandleCount()   -- baseline: modal + one idle timer
    local nBeforeRepick = #fake.windowFrames
    local logsBeforeRepick = #fake.logs
    fake.pressHotkey("4", {})   -- backward -> re-pick
    gf = fake.windowFrames[#fake.windowFrames]
    ok(gf.x == 0 and gf.y == 300 and gf.w == 400 and gf.h == 300,
        "backward press 3->4 re-picks cell 4 as a single placement")
    ok(fake.liveHud() ~= nil, "re-pick keeps the mode armed on the new corner")
    ok(#fake.windowFrames == nBeforeRepick + 1, "re-pick places one cell, not a span")
    -- re-pick must STOP the old idle timer before re-arming: the live scoped-handle
    -- count is unchanged (a leak would push it to baseline+1).
    ok(registry.liveHandleCount() == armedHandles,
        "re-pick stops the old idle timer before re-arming -- no leaked handle")
    local sawRepick = false
    for i = logsBeforeRepick + 1, #fake.logs do
        if fake.logs[i]:find("re%-pick") then sawRepick = true end
    end
    ok(sawRepick, "the re-pick is logged")
    -- the timer was re-armed on the NEW corner: firing it dismisses cleanly (proves
    -- it is the fresh timer, not a stale one left running on the old corner).
    fake.fireTimers("after", 2.5)
    ok(fake.liveHud() == nil, "the re-armed idle timer dismisses on the new corner")

    -- SAME-CELL commit: pressing corner-A again (B == A, trivially down-right)
    -- commits that single cell and exits -- a natural "done".
    fake.pressHotkey("9", HYP)
    fake.pressHotkey("5", {})   -- arm center (col1,row1 -> 400,300,400x300)
    ok(fake.liveHud() ~= nil, "single press arms")
    fake.pressHotkey("5", {})
    gf = fake.windowFrames[#fake.windowFrames]
    ok(gf.x == 400 and gf.y == 300 and gf.w == 400 and gf.h == 300,
        "same-cell 5->5 commits the single center cell")
    ok(fake.liveHud() == nil, "same-cell press commits and exits")

    -- SINGLE-CELL auto-dismiss: press one cell, then let the arm window (ARM_IDLE
    -- = 2.5s) lapse -> the single placement stands, no extra frame, mode dismisses.
    fake.pressHotkey("9", HYP)
    fake.pressHotkey("1", {})
    ok(fake.liveHud() ~= nil, "armed after the single press")
    local nBeforeTimeout = #fake.windowFrames
    local logsBeforeTimeout = #fake.logs
    fake.fireTimers("after", 2.5)
    ok(fake.liveHud() == nil, "the arm window lapsing dismisses the mode")
    ok(#fake.windowFrames == nBeforeTimeout, "timeout adds no frame (the cell was already placed)")
    local sawTimeout = false
    for i = logsBeforeTimeout + 1, #fake.logs do
        if fake.logs[i]:find("timeout%-dismiss") then sawTimeout = true end
    end
    ok(sawTimeout, "the timeout-dismiss is logged")

    -- HUD STATE TAGS: after the first press on a 3x3, corner-A is "corner", cells
    -- down-right are "valid", up/left are "dim", and the caption switches to the
    -- extend prompt -- proving the live updateHud seam end-to-end (modal -> hud).
    fake.pressHotkey("9", HYP)
    fake.pressHotkey("5", {})    -- corner-A = center (col1,row1)
    local hud = fake.liveHud()
    ok(hud ~= nil, "armed HUD is live")
    local stateAt, previewAt = {}, {}
    for _, c in ipairs(hud.spec.cells) do
        stateAt[c.col .. "," .. c.row] = c.state
        previewAt[c.col .. "," .. c.row] = c.preview
    end
    ok(stateAt["1,1"] == "corner", "corner-A cell is tagged 'corner'")
    ok(stateAt["2,2"] == "valid", "a down-right cell is tagged 'valid'")
    ok(stateAt["0,0"] == "dim", "an up-left cell is tagged 'dim'")
    ok(hud.spec.caption == "press a cell down-right to extend",
        "the caption switches to the extend prompt")
    -- each valid cell carries the window-size preview (fractions of the grid):
    -- corner-A = cell 5 (col1,row1), so 5->9 = the bottom-right 2/3 x 2/3 block.
    local p9 = previewAt["2,2"]
    ok(p9 ~= nil and math.abs(p9.x - 1 / 3) < 1e-9 and math.abs(p9.y - 1 / 3) < 1e-9
        and math.abs(p9.w - 2 / 3) < 1e-9 and math.abs(p9.h - 2 / 3) < 1e-9,
        "a valid cell carries the window-size preview (5->9 = bottom-right 2/3)")
    ok(previewAt["0,0"] == nil, "a dim cell carries no preview")
    fake.pressHotkey("escape", {})

    -- disabling mid-grid while ARMED (a live idle timer) tears the HUD + digit
    -- bindings + the afterSeconds timer down with no leak.
    fake.pressHotkey("9", HYP)
    fake.pressHotkey("5", {})   -- arm -> a live afterSeconds idle timer
    ok(fake.liveHud() ~= nil, "grid HUD is up (armed) before the disable")
    registry.setEnabled("window_grid", false)
    ok(fake.liveHud() == nil, "disable mid-grid drops the HUD")
    ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
        "clean after window_grid test (armed idle timer torn down)")
end

-- T25e: window_deck pure leaves (identity keys + color dealing) ----------------
-- These moved out of init.lua's stateful controller into pure sibling modules;
-- test them directly (no deck, no fake adapter) since that is now possible.
do
    local ident  = require("features.window_deck.identity")
    local colors = require("features.window_deck.colors")
    local focus  = require("features.window_deck.focus")

    -- focus.classify: the pure 5-way decision core reconcile dispatches on, run
    -- AFTER the shell handles settling + presence. Every row of the table,
    -- including precedence (isHero beats listed/heroMode; peek beats all).
    ok(focus.classify({ hasMember = false }) == "peek",
        "classify: no deck window focused -> peek")
    ok(focus.classify({ hasMember = true, isHero = true, listed = true, heroMode = true })
        == "return", "classify: the current hero regained front -> return")
    ok(focus.classify({ hasMember = true, isHero = true, listed = false, heroMode = false })
        == "return", "classify: isHero wins even when not listed / hero off")
    ok(focus.classify({ hasMember = true, isHero = false, listed = false, heroMode = true })
        == "ignore", "classify: a deck window not yet listed -> ignore (race)")
    ok(focus.classify({ hasMember = true, isHero = false, listed = true, heroMode = false })
        == "gridFocus", "classify: Hero-off mode -> gridFocus, never promote")
    ok(focus.classify({ hasMember = true, isHero = false, listed = true, heroMode = true })
        == "promote", "classify: non-hero deck window in Hero mode -> promote")

    -- keyOf identity ladder: a real wid keys by wid (survives retitles); a
    -- missing/zero wid falls back to bundleID+title. The two spaces never
    -- collide (distinct \0-prefixes), and a retitle changes ONLY the title key.
    ok(ident.keyOf({ bundleID = "com.x", wid = 42, title = "A" })
        == ident.widKey("com.x", 42), "keyOf uses the wid key when wid is real")
    ok(ident.keyOf({ bundleID = "com.x", wid = 42, title = "A" })
        == ident.keyOf({ bundleID = "com.x", wid = 42, title = "RENAMED" }),
        "keyOf is title-independent when keyed by wid (survives retitle)")
    ok(ident.keyOf({ bundleID = "com.x", wid = 0, title = "A" })
        == ident.titleKey("com.x", "A"), "keyOf falls back to the title key when wid is 0")
    ok(ident.widKey("com.x", 1) ~= ident.titleKey("com.x", "1"),
        "wid and title key spaces never collide")

    -- onScreen: window CENTRE inside the screen rect.
    local scr = { x = 0, y = 0, w = 1000, h = 800 }
    ok(ident.onScreen({ x = 400, y = 300, w = 200, h = 200 }, scr),
        "onScreen true when centre is inside")
    ok(not ident.onScreen({ x = 1200, y = 300, w = 200, h = 200 }, scr),
        "onScreen false when centre is outside")

    -- frameFar: >6px on any axis is "far" (drives the Rearrange dirty flag).
    ok(not ident.frameFar({ x = 0, y = 0, w = 10, h = 10 }, { x = 5, y = 0, w = 10, h = 10 }),
        "frameFar false within the 6px threshold")
    ok(ident.frameFar({ x = 0, y = 0, w = 10, h = 10 }, { x = 20, y = 0, w = 10, h = 10 }),
        "frameFar true past the threshold")
    ok(not ident.frameFar(nil, { x = 0 }), "frameFar false when a frame is missing")

    -- colors.assign: a recolored app (stored) keeps its color; others deal the
    -- next FREE palette color, so no two windows share a color until exhaustion.
    local wins = {
        { bundleID = "com.a" }, { bundleID = "com.b" }, { bundleID = "com.c" },
    }
    local pal = colors.PALETTE
    local dealt = colors.assign(wins, { ["com.b"] = pal[5] })
    ok(dealt[2] == pal[5], "assign keeps a recolored app's stored color")
    ok(dealt[1] ~= dealt[2] and dealt[1] ~= dealt[3] and dealt[2] ~= dealt[3],
        "assign deals distinct colors and never reuses the stored one")
    ok(dealt[1] ~= pal[5] and dealt[3] ~= pal[5],
        "assign skips the palette color already taken by the stored app")
    -- The stored color applies to the FIRST window of that app; a second
    -- same-app window falls through to positional dealing (seenApp guard), so
    -- it gets a DIFFERENT color -- the documented per-app-first-window rule.
    local sameApp = colors.assign({ { bundleID = "com.a" }, { bundleID = "com.a" } },
        { ["com.a"] = pal[1] })
    ok(sameApp[1] == pal[1], "assign gives the stored app's first window its stored color")
    ok(sameApp[2] ~= pal[1], "a second same-app window deals a fresh positional color")

    -- matchMembers: rebuild a saved deck from the live windows (drives "restore
    -- last deck"). wid matches within a session (survives a retitle); title
    -- matches across an app restart (new wid, same title); each live window is
    -- claimed once; a missing member simply drops (a partial restore).
    local saved = {
        { bundleID = "com.a", title = "A1", wid = 11 },
        { bundleID = "com.a", title = "A2", wid = 12 },
        { bundleID = "com.b", title = "B",  wid = 21 },
    }
    -- same session: A1 retitled to "A1*" but its wid still matches
    local inSession = ident.matchMembers(saved, {
        { id = 1, bundleID = "com.a", title = "A1*", wid = 11 },
        { id = 2, bundleID = "com.a", title = "A2",  wid = 12 },
        { id = 3, bundleID = "com.b", title = "B",   wid = 21 },
    })
    ok(#inSession == 3, "matchMembers: all three match in-session (wid survives a retitle)")
    -- after a restart: fresh wids, titles carry the match; B is closed -> 2 of 3
    local crossRestart = ident.matchMembers(saved, {
        { id = 1, bundleID = "com.a", title = "A1", wid = 91 },
        { id = 2, bundleID = "com.a", title = "A2", wid = 92 },
    })
    ok(#crossRestart == 2 and crossRestart[1].title == "A1" and crossRestart[2].title == "A2",
        "matchMembers: cross-restart title match; a closed window drops (2 of 3)")
    -- two same-app saved members must not both collapse onto one live window
    ok(#ident.matchMembers(
        { { bundleID = "com.a", title = "A1", wid = 0 }, { bundleID = "com.a", title = "A1", wid = 0 } },
        { { id = 1, bundleID = "com.a", title = "A1", wid = 0 } }) == 1,
        "matchMembers claims each live window once (no collapse)")
    -- wid BEATS title: two same-app windows share a title in one session, listed
    -- wid-descending. A single greedy (wid OR title) pass would bind the first
    -- saved member to the wrong window through the title; the wid-first split
    -- binds each to its own wid regardless of list order.
    local mt = ident.matchMembers(
        { { bundleID = "com.a", title = "T", wid = 100 },
          { bundleID = "com.a", title = "T", wid = 200 } },
        { { id = 200, bundleID = "com.a", title = "T", wid = 200 },   -- B's window first
          { id = 100, bundleID = "com.a", title = "T", wid = 100 } })
    ok(#mt == 2 and mt[1].id == 100 and mt[2].id == 200,
        "matchMembers: wid wins over title (each twin binds to its own wid, not the title-first hit)")
    -- a member with neither a real wid nor a title can't be identified
    ok(#ident.matchMembers(
        { { bundleID = "com.a", title = "", wid = 0 } },
        { { id = 1, bundleID = "com.a", title = "", wid = 0 } }) == 0,
        "matchMembers: an unidentifiable (no wid, no title) member never matches")
end

-- T25e-store: the last-deck round-trip -- PROVE the PRIMARY wid identity flows
-- through save -> json -> read -> PASS 1. (The T-WD-restore integration below
-- uses quadWindows(), which carry no wid, so it exercises only the title path;
-- this closes that gap: a regression in the wid encode/read chain would slip
-- past a title-only test.)
do
    local store = require("features.window_deck.store")
    local ident = require("features.window_deck.identity")
    local mem = {}
    local persist = store.new({ getState = function(k) return mem[k] end,
                                setState = function(k, v) mem[k] = v end })
    ok(persist.readLastDeck() == nil, "readLastDeck: nil when nothing is stored")
    persist.saveLastDeck("Main", {
        { bundleID = "com.a", title = "Doc A", wid = 4242 },
        { bundleID = "com.b", title = "Doc B", wid = 4243 },
    })
    local last = persist.readLastDeck()
    ok(last and last.screen == "Main" and #last.members == 2,
        "saveLastDeck/readLastDeck round-trips the screen + membership")
    ok(last.members[1].wid == 4242 and last.members[1].title == "Doc A",
        "a member's wid + title survive the json round-trip")
    -- PASS 1 binds by the round-tripped wid even after a RETITLE -- only wid
    -- (not title) could carry this match, so it proves the primary path E2E.
    local matched = ident.matchMembers(last.members, {
        { id = 1, bundleID = "com.a", title = "Doc A -- edited", wid = 4242 },  -- retitled
        { id = 2, bundleID = "com.b", title = "Doc B",          wid = 4243 },
    })
    ok(#matched == 2 and matched[1].id == 1,
        "restored wid matches through save/read despite a retitle (PASS 1 proven end-to-end)")
    -- a one-member store is rejected (a deck needs two)
    persist.saveLastDeck("Main", { { bundleID = "com.a", title = "solo", wid = 7 } })
    ok(persist.readLastDeck() == nil, "readLastDeck rejects a < 2 member record")
end

-- T25f: window_deck (grid <-> focus-driven hero over the by-id frame surface) ----
do
    local Wd = require("platform.windows")
    registry.register(require("features.window_deck"))
    fake.settings["hammerdeck.opt.window_deck.gutter"]        = 8
    fake.settings["hammerdeck.opt.window_deck.heroPercent"]   = 78
    fake.settings["hammerdeck.opt.window_deck.restoreOnExit"] = true
    local HYP = { "cmd", "alt", "ctrl" }

    local function near(a, b) return math.abs(a - b) < 0.5 end

    -- Four windows, one per quadrant of a 1440x900 screen, with the BOTTOM-RIGHT
    -- window listed FIRST -- so a naive row-major fill would mis-place it and the
    -- nearest-cell assignment is provable. Fresh copies each enter (placement
    -- mutates the rows).
    local function quadWindows()
        return {
            { id = 1, title = "BR", appName = "AppBR", bundleID = "com.br", x = 900,  y = 550, w = 300, h = 200 },
            { id = 2, title = "TL", appName = "AppTL", bundleID = "com.tl", x = 100,  y = 100, w = 300, h = 200 },
            { id = 3, title = "TR", appName = "AppTR", bundleID = "com.tr", x = 1000, y = 100, w = 300, h = 200 },
            { id = 4, title = "BL", appName = "AppBL", bundleID = "com.bl", x = 100,  y = 550, w = 300, h = 200 },
        }
    end
    -- The 2x2 slots (gutter 8) in reading order and the hero, from the same math
    -- the feature uses -- so the test tracks the algorithm, not a magic number.
    local SCREEN = { x = 0, y = 0, w = 1440, h = 900, name = "Main", index = 1, builtin = true }
    local slots  = Wd.tileSlots(SCREEN, 4, 8)          -- {TL, TR, BL, BR}
    local TLslot, TRslot, BLslot, BRslot = slots[1], slots[2], slots[3], slots[4]
    local HERO   = Wd.centeredRect(SCREEN, 0.78)

    -- simulate the user focusing the window with id `id`: set the AX focused-
    -- window identity the feature reads (frontmost app bundle id + focused title),
    -- then fire the matching watcher. `within` = a same-app switch (focus observer
    -- only, no app activation); otherwise a cross-app activation. NOTE: the feature
    -- keys off this identity, NOT list order -- the CG z-order lags the real event.
    local function focusWin(id, within, noFlush)
        local w
        for _, r in ipairs(fake.windows) do if r.id == id then w = r end end
        fake.windowTitle = w.title
        if within then
            fake.frontmost, fake.frontmostId = w.appName, w.bundleID
            fake.focusWindowChanged()
        else
            fake.activateApp(w.appName, w.bundleID)
        end
        -- `noFlush` leaves the beat mid-flight so the caller can assert the
        -- dispatch order (the window's move fires at flight START, under the
        -- ring); the caller flushes the timers itself.
        if noFlush then return end
        -- flush twice: the first fire lands the beat's ring flight (the FLIGHT
        -- timer) + any settle window; the landing may arm a NEW settle, which
        -- the second fire clears so the next focus event registers.
        fake.fireTimers("after")
        fake.fireTimers("after")
    end
    local function lastSetFor(id)                        -- most recent by-id move
        for i = #fake.windowFrameSets, 1, -1 do
            if fake.windowFrameSets[i].id == id then return fake.windowFrameSets[i] end
        end
        return nil
    end

    -- Enter the deck through the v1.1 pick flow (picker on every toggle): press
    -- the toggle, take the active screen if a multi-monitor screen chooser opens,
    -- then confirm the window multi-select with ALL rows checked -- the common
    -- "deck everything" path. (Sub-tests that exclude/cancel drive the picker by
    -- hand instead.) Exiting is a plain toggle press -- no picker on the way out.
    local function enterDeck()
        fake.pressHotkey("k", HYP)
        local dp = fake.openDisplayPicker()
        if dp then dp.userConfirm(dp.preselect) end   -- take the default (current) display
        local p = fake.openWindowPicker()
        if p then p.confirm(nil) end
        fake.fireTimers("after")   -- flush the deck's settle window (see beginSettle)
    end

    -- placement-math unit checks (pure) ---------------------------------------
    ok(Wd.gridDims(4).w == 2 and Wd.gridDims(4).h == 2, "gridDims(4) = 2x2")
    ok(Wd.gridDims(5).w == 3 and Wd.gridDims(5).h == 2, "gridDims(5) = 3x2 (partial last row)")
    ok(Wd.gridDims(7).w == 4 and Wd.gridDims(7).h == 2, "gridDims(7) = 4x2 override")
    ok(Wd.gridDims(9).w == 3 and Wd.gridDims(9).h == 3, "gridDims(9) = 3x3")
    do
        local s5 = Wd.tileSlots(SCREEN, 5, 8)
        ok(#s5 == 5, "tileSlots(5) yields 5 slots")
        ok(near(s5[1].w, 1440 / 3 - 16), "full-row cell is a third wide (minus gutters)")
        ok(near(s5[4].w, 1440 / 2 - 16) and near(s5[5].w, 1440 / 2 - 16),
            "partial last row of 2 stretches each to a half (no dead cells)")
    end

    -- T-WD1: enter -> flat GRID with nearest-cell assignment ------------------
    fake.focusedWindow = nil            -- pickScreen falls back to the cursor (screen 1)
    fake.mousePos = { x = 10, y = 10 }
    fake.screenList = { SCREEN }
    fake.windows = quadWindows()
    fake.windowFrameSets = {}
    registry.setEnabled("window_deck", true)
    ok(registry.liveHandleCount() == 1, "enabled service binds just the toggle hotkey")

    fake.raises = {}
    enterDeck()
    ok(#fake.windowFrameSets == 4, "entering the deck tiles all four windows")
    do
        local raised = fake.raisedSet()
        ok(raised[1] and raised[2] and raised[3] and raised[4],
            "entering raises every deck window above non-deck windows on the screen")
    end
    local brSet = lastSetFor(1)
    ok(brSet and near(brSet.x, BRslot.x) and near(brSet.y, BRslot.y)
        and near(brSet.w, BRslot.w) and near(brSet.h, BRslot.h),
        "the bottom-right window (listed first) lands in the bottom-right slot -- nearest-cell, not row-major")
    local tlSet = lastSetFor(2)
    ok(tlSet and near(tlSet.x, TLslot.x) and near(tlSet.y, TLslot.y),
        "the top-left window lands in the top-left slot")
    ok(fake.liveScrim() ~= nil, "the container scrim shows while the deck is active")
    do
        local sf = fake.liveScrim().screenFrame
        ok(sf and sf.x == SCREEN.x and sf.w == SCREEN.w,
            "the scrim is pinned to the DECK's screen, not the key window's screen")
        ok(#fake.liveScrim().holes == 4, "the scrim punches a hole for each deck window (GRID)")
    end
    ok(#fake.liveOutlines("member") == 4, "every deck member gets a subtle border (GRID)")
    do
        local seen, n = {}, 0
        for _, o in ipairs(fake.liveOutlines("member")) do
            if o.color ~= "" and not seen[o.color] then seen[o.color] = true; n = n + 1 end
        end
        ok(n == 4, "each deck member border has a distinct color")
    end
    ok(fake.liveOutline("hero") == nil and fake.liveOutline("ghost") == nil,
        "no hero/ghost border in the flat grid (no hero yet)")
    ok(fake.liveWidget() ~= nil, "the draggable indicator widget shows while the deck is active")
    ok(registry.liveHandleCount() == 16,
        "active deck = 7 base + frame watcher + 4 member borders + 4 ⌥number hotkeys")

    -- toggle off -> restore original frames, scrim gone
    local before = #fake.windowFrameSets
    fake.pressHotkey("k", HYP)
    ok(#fake.windowFrameSets == before + 4, "exiting restores every window")
    local brRestore = lastSetFor(1)
    ok(brRestore and brRestore.x == 900 and brRestore.y == 550
        and brRestore.w == 300 and brRestore.h == 200,
        "the bottom-right window is restored to its original frame")
    ok(fake.liveScrim() == nil, "the scrim is dismissed on exit")
    ok(registry.liveHandleCount() == 1, "exit drops the deck handles, keeps the toggle")

    -- disable WHILE decked -> stop(ctx) restores, then teardown leaves nothing
    fake.windows = quadWindows()
    fake.windowFrameSets = {}
    enterDeck()                                    -- re-enter
    ok(registry.liveHandleCount() == 16,
        "re-entered the deck (7 base + frame watcher + 4 member borders + 4 ⌥number hotkeys)")
    registry.setEnabled("window_deck", false)      -- disable mid-deck
    ok(lastSetFor(1) and lastSetFor(1).w == 300,
        "disabling mid-deck restores original frames via stop()")
    ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
        "clean after disable-while-decked")

    -- T-WD-pick: the entry picker (v1.1) -- exclude, cancel, min-guard --------
    registry.setEnabled("window_deck", true)
    -- exclude one: the picker lists all four pre-checked; drop the 4th (BL) row.
    -- The minimized and fullscreen rows appended below must NOT be offered at
    -- all -- AX lists them with their normal frames, but a deck slot for an
    -- invisible window is a ring around empty space.
    fake.windows = quadWindows()
    fake.windows[#fake.windows + 1] = { id = 66, title = "Hidden", appName = "AppMin",
        bundleID = "com.min", x = 150, y = 150, w = 300, h = 200, minimized = true }
    fake.windows[#fake.windows + 1] = { id = 67, title = "Full", appName = "AppFS",
        bundleID = "com.fs", x = 0, y = 0, w = 1440, h = 900, fullscreen = true }
    fake.windowFrameSets = {}
    fake.pressHotkey("k", HYP)
    do
        local p = fake.openWindowPicker()
        ok(p ~= nil and #p.items == 4,
            "the picker lists every deckable window -- minimized/fullscreen excluded")
        ok(p.min == 2, "the picker requires at least two to be kept")
        p.confirm({ 1, 2, 3 })                     -- keep BR, TL, TR; drop BL (id 4)
    end
    fake.fireTimers("after")   -- flush the deck's settle window (see beginSettle)
    ok(#fake.windowFrameSets == 3, "excluding a window decks only the kept three")
    ok(lastSetFor(4) == nil, "the excluded window is left untouched")
    ok(#fake.liveOutlines("member") == 3, "only the kept three windows get member borders")
    ok(fake.liveScrim() ~= nil and registry.liveHandleCount() == 14,
        "the deck is live after an exclude (7 base + frame watcher + 3 member borders + 3 ⌥number hotkeys)")
    fake.pressHotkey("k", HYP)                      -- exit
    ok(registry.liveHandleCount() == 1, "clean after the exclude test")

    -- cancel: dismissing the picker enters no deck and drops the picker handle
    fake.windows = quadWindows()
    fake.windowFrameSets = {}
    fake.pressHotkey("k", HYP)
    do
        local p = fake.openWindowPicker()
        ok(p ~= nil, "the picker opens on enter")
        p.cancel()
    end
    ok(#fake.windowFrameSets == 0, "cancelling the picker tiles nothing")
    ok(fake.liveScrim() == nil and registry.liveHandleCount() == 1,
        "cancelling leaves no deck and drops the picker handle")

    -- min-guard: confirming with fewer than two checked is refused (panel stays)
    fake.pressHotkey("k", HYP)
    do
        local p = fake.openWindowPicker()
        ok(p.confirm({ 1 }) == false, "confirming with one window is refused (needs >= 2)")
        ok(p.open, "the picker stays open after a refused confirm")
        p.cancel()
    end
    ok(registry.liveHandleCount() == 1, "clean after the min-guard test")

    -- recolor + persistence: pick a custom color in the picker -> the border uses
    -- it; re-open the picker later -> the same app is offered that color again
    fake.windows = quadWindows()
    fake.windowFrameSets = {}
    fake.pressHotkey("k", HYP)
    do
        local p = fake.openWindowPicker()
        ok(p.items[1].color ~= nil and p.items[1].color ~= "",
            "picker rows carry a border-color preview")
        ok(type(p.palette) == "table" and #p.palette > 0,
            "the picker gets the recolor palette (dot-click cycles it)")
        p.recolor(1, "#123456")                    -- recolor the BR window's app
        p.confirm(nil)
    end
    fake.fireTimers("after")
    do
        local found = false
        for _, o in ipairs(fake.liveOutlines("member")) do
            if o.color == "#123456" then found = true end
        end
        ok(found, "a recolored window's deck border uses the chosen color")
    end
    fake.pressHotkey("k", HYP)                      -- exit
    fake.windows = quadWindows()
    fake.pressHotkey("k", HYP)                      -- re-open the picker
    do
        local p = fake.openWindowPicker()
        ok(p.items[1].color == "#123456",
            "the chosen color persists for the app across decks")
        p.cancel()
    end

    -- T-WD-restore: the screen-selector "restore last deck" BUTTON (multi-monitor).
    -- A FRESH pick saves its membership as a template; a later trigger offers
    -- "Restore last deck" as the map's secondary action and rebuilds the SAME set
    -- with no window multi-select. Availability is smart: a closed member drops,
    -- the label reads "N of M", and the template is NOT eroded by a partial restore.
    do
        local S2 = { x = 1440, y = 0, w = 1440, h = 900, name = "Ext", index = 2 }
        fake.screenList = { SCREEN, S2 }              -- 2 screens -> the selector opens
        fake.focusedWindow = nil
        fake.mousePos = { x = 10, y = 10 }            -- active screen = 1 (SCREEN)
        fake.settings["hammerdeck.state.window_deck.lastDeck"] = nil   -- no template yet

        -- 1) fresh pick on screen 1, keep BR+TL+TR (drop BL) -> saves a 3-member template
        fake.windows = quadWindows()
        fake.windowFrameSets = {}
        fake.pressHotkey("k", HYP)
        do
            local dp = fake.openDisplayPicker()
            ok(dp and dp.title == "Deck which screen?", "multi-monitor opens the display map")
            ok(#dp.displays == 2 and dp.extraLabel == "",
                "no last deck yet -> the map shows two displays and no restore button")
            dp.userConfirm({ 1 })                     -- deck the current display (screen 1)
        end
        do
            local p = fake.openWindowPicker()
            ok(p ~= nil, "choosing a screen opens the window multi-select")
            p.confirm({ 1, 2, 3 })                    -- keep BR, TL, TR; drop BL (id 4)
        end
        fake.fireTimers("after")
        ok(#fake.liveOutlines("member") == 3, "fresh pick decked the chosen three")
        fake.pressHotkey("k", HYP)                    -- exit

        -- 2) trigger again with everything open: the selector now leads with restore
        fake.windows = quadWindows()
        fake.windowFrameSets = {}
        fake.pressHotkey("k", HYP)
        do
            local dp = fake.openDisplayPicker()
            ok(dp and #dp.displays == 2, "the map shows the two displays")
            ok(dp.preselect[1] == 1 and dp.displays[1].name == "Main",
                "the current display (screen 1) is the pre-selected default (Enter decks it)")
            ok(dp.extraLabel == "Restore last deck (3 windows)",
                "a restorable last deck is offered as the secondary-action button (full count)")
            dp.userExtra()                            -- press Restore last deck
        end
        fake.fireTimers("after")
        ok(fake.openWindowPicker() == nil, "restore skips the window multi-select")
        ok(#fake.liveOutlines("member") == 3, "restore rebuilt the three-window deck")
        ok(lastSetFor(4) == nil, "the window dropped from the template (BL) is not restored")
        fake.pressHotkey("k", HYP)                    -- exit

        -- 3) smart availability: close a template member (TR, id 3). Restore is
        -- still offered around the gap and reads "2 of 3 available".
        local q = quadWindows()
        fake.windows = { q[1], q[2], q[4] }           -- BR, TL, BL  (TR closed)
        fake.windowFrameSets = {}
        fake.pressHotkey("k", HYP)
        do
            local dp = fake.openDisplayPicker()
            ok(dp.extraLabel == "Restore last deck (2 of 3 available)",
                "a closed member drops from the count without blocking restore")
            dp.userExtra()                            -- restore around the missing one
        end
        fake.fireTimers("after")
        ok(#fake.liveOutlines("member") == 2, "a partial restore decks the survivors (2 of 3)")
        fake.pressHotkey("k", HYP)                    -- exit

        -- the template was NOT overwritten by the partial restore: with TR open
        -- again, restore offers the full three once more.
        fake.windows = quadWindows()
        fake.pressHotkey("k", HYP)
        do
            local dp = fake.openDisplayPicker()
            ok(dp.extraLabel == "Restore last deck (3 windows)",
                "a partial restore did not erode the saved template")
            dp.cancel()                               -- cancel out
        end

        -- 4) beyond the 9-cap: with many windows open, template members sitting
        -- PAST the MRU top-9 must still be found -- restore matches an UNCAPPED
        -- list, else an open member would read as "missing" (regression guard).
        local q2 = quadWindows()
        local many = {}
        for i = 1, 9 do
            many[i] = { id = 100 + i, title = "Decoy" .. i, appName = "Decoy" .. i,
                bundleID = "com.decoy" .. i, x = 50, y = 50, w = 200, h = 150 }
        end
        many[10], many[11], many[12] = q2[1], q2[2], q2[3]   -- BR, TL, TR after 9 decoys
        fake.windows = many
        fake.pressHotkey("k", HYP)
        do
            local dp = fake.openDisplayPicker()
            ok(dp.extraLabel == "Restore last deck (3 windows)",
                "template members past the MRU top-9 are still found (uncapped restore match)")
            dp.cancel()                               -- cancel out
        end

        fake.screenList = { SCREEN }                  -- back to single-screen for later tests
        fake.windows = quadWindows()
    end

    registry.setEnabled("window_deck", false)
    ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after the picker tests")

    -- T-WD-blink: apps that ACTIVATE on raise must not make the hero/peek fight --
    -- Regression for the focus-fight blink: raiseDeck's raises emit activation
    -- echoes; UNGUARDED, each echo re-enters reconcile and promotes -- forever
    -- (with raiseActivates on, an unguarded deck recurses until the Lua stack
    -- overflows). The settle guard keeps every raise pass bounded; a plain
    -- promote never raises, and a bare peek-return raises NOTHING either (the
    -- "return blink" fix) -- only enter and a post-peek beat landing raise.
    do
        fake.windows = quadWindows()
        fake.raiseActivates = true
        registry.setEnabled("window_deck", true)

        fake.raises = {}
        enterDeck()                    -- enter -> raiseDeck -> 4 activation echoes, all absorbed
        ok(#fake.raises == 4,
            "enter raises each deck window once even when raising activates the app (no loop)")

        fake.raises = {}
        focusWin(2)                    -- a plain promote does NOT raise -> no echoes, no fight
        ok(#fake.raises == 0, "a plain promote does not raise (no activation echoes to fight)")

        -- a peek then a bare return must raise NOTHING: any raise to an
        -- activating app fronts a member over the hero for a beat -- the
        -- "return blink". The user's own click already fronted the hero.
        table.insert(fake.windows, 1,
            { id = 77, title = "X", appName = "Other", bundleID = "com.x", x = 5, y = 5, w = 90, h = 90 })
        focusWin(77)                   -- peek a non-deck window (sets peeked)
        fake.raises, fake.focused = {}, {}
        focusWin(2)                    -- return to the hero: NO raises, NO focus
        ok(#fake.raises == 0 and #fake.focused == 0,
            "a peek-return raises and focuses NOTHING (the no-blink guarantee)")
        -- the deferred reclean lands on the NEXT beat (a swap), under motion
        -- cover: members re-raised, then the hero lifted LAST via a real FOCUS
        -- (beats an activating member). Ordering proof: under raiseActivates
        -- the LAST activation wins, so the hero's app ending frontmost shows
        -- the hero lift came after the member raises.
        fake.raises, fake.focused = {}, {}
        focusWin(3)                    -- swap -> beat -> landHero -> reclean
        ok(#fake.raises == 3 and #fake.focused == 1 and fake.focused[1] == 3,
            "the next beat recleans: 3 member raises + exactly one hero FOCUS "
            .. "(activation echoes never re-promote, no loop)")
        ok(fake.frontmostId == "com.tr",
            "the hero's own app is frontmost after the reclean (hero lift came last)")
        fake.fireTimers("after")       -- clear the reclean's settle window
        ok(registry.liveHandleCount() == 17,
            "no stray handle: 7 base + frame watcher + 4 member borders + 1 ghost + 4 ⌥number hotkeys (FOCUS)")

        fake.pressHotkey("k", HYP)     -- exit
        ok(registry.liveHandleCount() == 1, "clean after the blink regression")
        registry.setEnabled("window_deck", false)
        fake.raiseActivates = false
    end

    -- T-WD-peek-mid-flight: a peek during a promote flight keeps its focus ----
    -- landHero's reclean then runs while a NON-deck window holds focus. The
    -- hero's lift must fall back to the surgical raise: a real focus would
    -- yank focus off the peek, breaking "a peek stays on top while it holds
    -- focus". raiseDeck gates on focusedMember() captured BEFORE the raises.
    do
        fake.windows = quadWindows()
        registry.setEnabled("window_deck", true)
        enterDeck()
        focusWin(2)                    -- promote TL -> hero
        table.insert(fake.windows, 1,
            { id = 88, title = "P", appName = "Peek", bundleID = "com.peek", x = 5, y = 5, w = 90, h = 90 })
        focusWin(88)                   -- peek a non-deck window (sets peeked)
        focusWin(3, nil, true)         -- back to TR -> swap beat starts, mid-flight
        focusWin(88, nil, true)        -- user peeks AGAIN during the flight
        fake.raises, fake.focused = {}, {}
        fake.fireTimers("after")       -- step 1 lands -> step 2 launches
        fake.fireTimers("after")       -- step 2 lands -> landHero -> reclean
        ok(#fake.focused == 0,
            "reclean under a mid-flight peek never FOCUSES the hero (the peek keeps focus)")
        ok(#fake.raises == 4 and fake.raises[#fake.raises] == 3,
            "the hero is still lifted surgically, last, above the members")
        fake.pressHotkey("k", HYP)     -- exit
        registry.setEnabled("window_deck", false)
        ok(registry.liveHandleCount() == 0, "clean after the mid-flight peek regression")
    end

    -- T-WD-chrome-peek: the deck chrome (scrim + rings) is bound to the deck's
    -- FRONT context. It hides while a non-deck window is focused (a peek) so a
    -- ring never floats OVER that window and the scrim never dims it, then
    -- re-shows on return. Pure overlay ordering -- no window raise, no blink.
    do
        fake.windows = quadWindows()
        registry.setEnabled("window_deck", true)
        enterDeck()
        focusWin(2)                    -- promote a hero: chrome shown
        ok(fake.liveScrim() and not fake.liveScrim().hidden,
            "the scrim is visible while the deck holds focus")
        table.insert(fake.windows, 1,
            { id = 91, title = "N", appName = "NonDeck", bundleID = "com.n", x = 5, y = 5, w = 90, h = 90 })
        focusWin(91)                   -- peek a non-deck window
        ok(fake.liveScrim().hidden,
            "a peek hides the container scrim (no dim floats over the non-deck window)")
        ok(fake.liveWidget().hidden, "a peek hides the indicator widget too")
        do
            local anyShown = false
            for _, o in ipairs(fake.liveOutlines()) do
                if not o.hidden then anyShown = true end
            end
            ok(not anyShown, "a peek hides every ring (none floats over the non-deck window)")
        end
        focusWin(2)                    -- return to the hero
        ok(not fake.liveScrim().hidden, "returning to the deck re-shows the scrim")
        ok(not fake.liveWidget().hidden, "returning to the deck re-shows the widget")
        do
            local anyHidden = false
            for _, o in ipairs(fake.liveOutlines()) do
                if o.hidden then anyHidden = true end
            end
            ok(not anyHidden, "returning to the deck re-shows every ring")
        end
        fake.pressHotkey("k", HYP)     -- exit
        registry.setEnabled("window_deck", false)
        ok(registry.liveHandleCount() == 0, "clean after the chrome-peek test")
    end

    -- T-WD-widget-drag: dragging the indicator persists its position as an
    -- OFFSET from the deck screen, so it returns there on the next deck.
    do
        fake.windows = quadWindows()
        fake.screenList = { SCREEN }
        registry.setEnabled("window_deck", true)
        enterDeck()
        local w = fake.liveWidget()
        ok(w and w.pos.x == SCREEN.x + 20 and w.pos.y == SCREEN.y + 20,
            "the widget starts at the default top-left inset (20, 20)")
        w.onMove(SCREEN.x + 300, SCREEN.y + 140)   -- simulate a drag
        fake.pressHotkey("k", HYP)                  -- exit (feature stays enabled)
        enterDeck()                                 -- re-enter
        local w2 = fake.liveWidget()
        ok(w2 and w2.pos.x == SCREEN.x + 300 and w2.pos.y == SCREEN.y + 140,
            "the dragged position persists to the next deck (offset from the screen)")
        w2.onMove(SCREEN.x + 20, SCREEN.y + 20)     -- restore default for later tests
        fake.pressHotkey("k", HYP)
        registry.setEnabled("window_deck", false)
    end

    -- T-WD-widget-exit: the widget carries the deck screen's display name, and
    -- its Exit button exits the deck (full teardown, like a double ⌥Esc).
    do
        fake.windows = quadWindows()
        fake.screenList = { SCREEN }
        registry.setEnabled("window_deck", true)
        enterDeck()
        local w = fake.liveWidget()
        ok(w and w.name == SCREEN.name, "the widget shows the deck screen's display name")
        ok(w.screen and w.screen.w == SCREEN.w, "the widget gets the deck screen as its drag clamp")
        ok(fake.liveScrim() ~= nil and registry.liveHandleCount() == 16, "deck live before the Exit click")
        w.onExit()                                  -- click the Exit button
        ok(fake.liveScrim() == nil and registry.liveHandleCount() == 1,
            "the widget Exit button exits the deck (chrome gone, only the toggle left)")
        registry.setEnabled("window_deck", false)
    end

    -- T-WD-switcher: the widget's mini-map has a cell per window (row-major),
    -- lights the hero's cell, switches the hero on a cell click, and drops to
    -- the flat grid when you click the hero's own cell.
    do
        fake.windows = quadWindows()
        fake.screenList = { SCREEN }
        registry.setEnabled("window_deck", true)
        enterDeck()
        local w = fake.liveWidget()
        ok(w and w.cols == 2 and #w.colors == 4,
            "the mini-map has a cell per window at the grid's column count (2x2)")
        ok(w.hero == 0, "no cell is lit in the flat grid (no hero yet)")
        focusWin(2)                    -- promote the top-left window (id 2) -> cell 1
        ok(w.hero == 1, "promoting the top-left window lights mini-map cell 1")
        -- click a NON-hero cell -> focuses that window (drives the promote beat
        -- through the existing path; cell 4 = bottom-right = id 1)
        fake.focused = {}
        w.onSwitch(4)
        ok(fake.focused[#fake.focused] == 1,
            "clicking cell 4 focuses the bottom-right window (reuses the promote path)")
        -- click the HERO's own cell -> drop back to the flat grid
        focusWin(2)                    -- re-establish the TL hero at cell 1
        ok(w.hero == 1, "TL hero re-lit at cell 1")
        w.onSwitch(1)
        fake.fireTimers("after")       -- land the drop beat -> renderBorders -> setHero
        ok(w.hero == 0 and fake.liveOutline("hero") == nil,
            "clicking the hero's own cell drops back to the flat grid (no hero lit)")
        fake.pressHotkey("k", HYP)
        registry.setEnabled("window_deck", false)
    end

    -- T-WD-numkeys: ⌥1-9 switch the hero to that mini-map cell (shares
    -- switchToCell with the mini-map clicks).
    do
        fake.windows = quadWindows()
        fake.screenList = { SCREEN }
        registry.setEnabled("window_deck", true)
        enterDeck()
        local w = fake.liveWidget()
        fake.focused = {}
        fake.pressHotkey("4", { "alt" })   -- ⌥4 -> cell 4 = bottom-right = id 1
        ok(fake.focused[#fake.focused] == 1,
            "⌥4 focuses the bottom-right window (same as clicking mini-map cell 4)")
        focusWin(2)                        -- TL -> hero at cell 1
        ok(w.hero == 1, "TL promoted to hero (cell 1)")
        fake.pressHotkey("1", { "alt" })   -- ⌥1 on the hero's own cell
        fake.fireTimers("after")
        ok(w.hero == 0 and fake.liveOutline("hero") == nil,
            "⌥ on the hero's own cell drops back to the flat grid")
        fake.pressHotkey("k", HYP)
        registry.setEnabled("window_deck", false)
    end

    -- T-WD-hero-toggle: the widget's Hero switch gates promotion -- off = a pure
    -- grid tiler (focusing a window does not zoom it) -- and the choice persists.
    do
        fake.windows = quadWindows()
        fake.screenList = { SCREEN }
        registry.setEnabled("window_deck", true)
        enterDeck()
        local w = fake.liveWidget()
        ok(w.heroMode == true, "Hero starts ON by default")
        local hintOn = w.switchHint
        focusWin(2)
        ok(w.hero == 1 and fake.liveOutline("hero") ~= nil,
            "with Hero on, focusing a window zooms it into a hero")
        w.onToggleHero(false)          -- flip Hero OFF
        fake.fireTimers("after")       -- land the drop beat
        ok(w.hero == 0 and fake.liveOutline("hero") == nil,
            "flipping Hero off drops the current hero back to the grid")
        ok(w.switchHint ~= hintOn, "the mini-map hint rewords for grid-only mode when Hero is off")
        focusWin(3)                    -- focus another window
        ok(fake.liveOutline("hero") == nil,
            "with Hero off, focusing a window does not zoom it (pure grid tiler)")
        ok(#fake.liveOutlines("focus") == 1 and #fake.liveOutlines("member") == 3,
            "with Hero off, the focused window gets a bold FOCUS ring; the rest stay subtle members")
        w.onToggleHero(true)           -- flip Hero back ON
        ok(w.switchHint == hintOn, "the hint reverts when Hero is toggled back on")
        focusWin(3)
        ok(fake.liveOutline("hero") ~= nil and w.hero ~= 0,
            "flipping Hero on restores focus-to-hero")
        -- persistence: off -> exit -> re-enter starts off
        w.onToggleHero(false)
        fake.fireTimers("after")
        fake.pressHotkey("k", HYP)
        enterDeck()
        ok(fake.liveWidget().heroMode == false, "the Hero choice persists to the next deck")
        fake.liveWidget().onToggleHero(true)   -- restore default for later tests
        fake.pressHotkey("k", HYP)
        registry.setEnabled("window_deck", false)
    end

    -- T-WD-picker-hero: the picker's Hero switch sets (and persists) the deck's
    -- starting mode.
    do
        fake.windows = quadWindows()
        fake.screenList = { SCREEN }
        registry.setEnabled("window_deck", true)
        fake.pressHotkey("k", HYP)
        local dp = fake.openDisplayPicker()
        if dp then dp.userConfirm(dp.preselect) end
        local p = fake.openWindowPicker()
        ok(p ~= nil and p.hero == true,
            "the picker's Hero switch starts from the persisted value (on)")
        p.setHero(false)               -- flip the picker's Hero switch off
        p.confirm(nil)
        fake.fireTimers("after")
        ok(fake.liveWidget().heroMode == false,
            "confirming the picker with Hero off enters a grid-only deck")
        fake.pressHotkey("k", HYP)     -- exit
        enterDeck()                    -- default enter -> starts off (persisted)
        ok(fake.liveWidget().heroMode == false, "the picker's Hero choice persisted")
        fake.liveWidget().onToggleHero(true)   -- restore default for later tests
        fake.pressHotkey("k", HYP)
        registry.setEnabled("window_deck", false)
    end

    -- T-WD-rearrange: dragging a window off its slot enables the widget's
    -- Rearrange button; clicking it snaps every window home and clears the state.
    do
        fake.windows = quadWindows()
        fake.screenList = { SCREEN }
        registry.setEnabled("window_deck", true)
        enterDeck()
        local w = fake.liveWidget()
        ok(w.dirty == false, "Rearrange starts disabled -- the deck is freshly tiled")
        fake.fireFrameEvent{ bundleID = "com.tl", title = "TL", x = 500, y = 400, w = 300, h = 200 }
        fake.fireTimers("after")       -- settle -> renderBorders -> dirty recompute
        ok(w.dirty == true, "dragging a window off its slot enables Rearrange")
        fake.windowFrameSets = {}
        w.onRearrange()                -- click Rearrange
        local back = lastSetFor(2)     -- TL is window id 2
        ok(back and near(back.x, TLslot.x) and near(back.y, TLslot.y),
            "Rearrange snaps the dragged window back to its slot")
        ok(w.dirty == false, "Rearrange clears the dirty state (every window home)")
        fake.pressHotkey("k", HYP)
        registry.setEnabled("window_deck", false)
    end

    -- T-WD-reorder: dragging one mini-map CELL onto another (in the widget)
    -- swaps the two windows' slots and re-colors the mini-map to match.
    do
        fake.windows = quadWindows()
        fake.screenList = { SCREEN }
        registry.setEnabled("window_deck", true)
        enterDeck()
        local w = fake.liveWidget()
        local c1, c3 = w.colors[1], w.colors[3]   -- TL cell + BL cell colors
        fake.windowFrameSets = {}
        w.onReorder(1, 3)              -- drag mini-map cell 1 (TL) onto cell 3 (BL)
        local moved = lastSetFor(2)    -- TL window (id 2) -> BL slot
        ok(moved and near(moved.x, BLslot.x) and near(moved.y, BLslot.y),
            "reordering cell 1 onto cell 3 moves the TL window into the BL slot")
        ok(w.colors[1] == c3 and w.colors[3] == c1,
            "the mini-map cell colors swap to match the new arrangement")
        ok(w.dirty == false, "after a cell-swap every window sits on a slot (not dirty)")
        fake.pressHotkey("k", HYP)
        registry.setEnabled("window_deck", false)
    end

    -- T-WD-screenchange: the deck's screen is powered off / reconfigured. The
    -- old fixed-rect banner got orphaned onto a surviving display; the scrim's
    -- title rides a full-screen element the deck RE-ANCHORS -- or, if the deck's
    -- screen is GONE, the deck exits cleanly (its tiled world no longer exists)
    -- instead of stranding chrome on another screen.
    do
        -- (a) screen still present but moved/resized -> re-anchor, deck stays
        fake.screenList = { SCREEN }
        fake.windows = quadWindows()
        registry.setEnabled("window_deck", true)
        enterDeck()
        ok(fake.liveScrim() ~= nil, "deck live with a scrim before the reconfig")
        fake.screenList = { { x = 200, y = 0, w = 1600, h = 1000,
                              name = "Main", index = 1, builtin = true } }
        fake.systemEvent("screenChanged")
        ok(fake.liveScrim() ~= nil,
            "a moved/resized deck screen keeps the deck (not orphaned, not exited)")
        ok(fake.liveScrim().screenFrame.w == 1600,
            "the scrim re-anchors to the deck screen's new frame")
        ok(fake.liveWidget() and fake.liveWidget().pos.x == 200 + 20,
            "the widget re-anchors onto the moved deck screen (offset preserved)")

        -- (b) deck screen GONE -> exit cleanly, no orphaned chrome
        fake.screenList = { { x = 0, y = 0, w = 1440, h = 900,
                              name = "External", index = 1, builtin = false } }
        fake.systemEvent("screenChanged")
        ok(fake.liveScrim() == nil,
            "when the deck's screen disconnects the deck exits (no scrim orphaned elsewhere)")
        ok(registry.liveHandleCount() == 1, "the disconnect exit drops every deck handle but the toggle")

        registry.setEnabled("window_deck", false)
        fake.screenList = { SCREEN }
        ok(registry.liveHandleCount() == 0, "clean after the screen-change test")
    end

    -- T-WD2: focus-driven promotion + swap + escalating Escape ----------------
    fake.windows = quadWindows()
    registry.setEnabled("window_deck", true)
    enterDeck()                                    -- GRID
    fake.windowFrameSets = {}

    fake.raises = {}
    focusWin(2, nil, true)                        -- focus TL (cross-app), mid-flight
    do
        -- the polish: the real window's move is DISPATCHED at flight START (the
        -- ring covers the async AX apply), not when the ring lands -- the ring
        -- sat alone at the hero rect while the window popped in late otherwise
        local mid = lastSetFor(2)
        ok(mid and near(mid.w, HERO.w) and near(mid.h, HERO.h),
            "the promoted window's move is dispatched at flight start (under the ring)")
    end
    fake.fireTimers("after")
    fake.fireTimers("after")
    local heroSet = lastSetFor(2)
    ok(heroSet and near(heroSet.x, HERO.x) and near(heroSet.w, HERO.w)
        and near(heroSet.h, HERO.h),
        "focusing a group window promotes it to the centered hero (~78%)")
    do
        local hb = fake.liveOutline("hero")
        ok(hb and near(hb.frame.x, HERO.x) and near(hb.frame.w, HERO.w) and near(hb.frame.h, HERO.h),
            "a strong hero border marks the hero's bounds at the ~78% rect")
        local ghost = fake.liveOutline("ghost")
        ok(ghost and near(ghost.frame.x, TLslot.x) and near(ghost.frame.y, TLslot.y),
            "a ghost border marks the hero's home slot (where it drops back to)")
        ok(hb and ghost and hb.color ~= "" and hb.color == ghost.color,
            "the hero border and its ghost share the hero window's own color")
        ok(#fake.liveOutlines("member") == 3, "the other three members keep their subtle borders")
        local holed = 0
        for _, o in ipairs(fake.liveOutlines("member")) do
            if o.hole and near(o.hole.x, HERO.x) and near(o.hole.w, HERO.w) then holed = holed + 1 end
        end
        ok(holed == 3 and ghost.hole and near(ghost.hole.x, HERO.x),
            "member + ghost borders clip the hero rect out (no lines drawn across the hero)")
    end
    ok(#fake.raises == 0,
        "a plain promote does NOT re-raise the deck (already on top -- no needless blink)")

    fake.windowFrameSets = {}
    focusWin(3, nil, true)                        -- focus TR -> swap, step 1 mid-flight
    ok(lastSetFor(2) ~= nil and lastSetFor(3) == nil,
        "swap step 1: the old hero steps home first -- the incoming window has not moved yet")
    fake.fireTimers("after")                      -- step 1 lands -> step 2 launches
    ok(lastSetFor(3) ~= nil,
        "swap step 2: the incoming window's move dispatches as its ring lifts off")
    fake.fireTimers("after")                      -- step 2 lands
    local demoted = lastSetFor(2)
    ok(demoted and near(demoted.x, TLslot.x) and near(demoted.y, TLslot.y),
        "the outgoing hero drops back into its grid slot")
    local promoted = lastSetFor(3)
    ok(promoted and near(promoted.x, HERO.x) and near(promoted.w, HERO.w),
        "the newly-focused window becomes the hero")
    ok(fake.liveOutline("hero") ~= nil and #fake.liveOutlines("member") == 3,
        "after a swap: one hero border, three member borders (re-styled, not leaked)")
    do
        -- the sequenced beat: the outgoing hero's step-back is recorded BEFORE
        -- the incoming hero's grow (old back first, then the new steps out)
        local di, pi
        for i, s in ipairs(fake.windowFrameSets) do
            if s.id == 2 and not di then di = i end
            if s.id == 3 and not pi then pi = i end
        end
        ok(di and pi and di < pi,
            "the swap plays as a beat: the old hero steps back before the new one grows")
        local hb2 = fake.liveOutline("hero")
        ok(hb2 and (hb2.flights or 0) >= 1,
            "the incoming window's ring FLIES to the hero rect (the flight carries the eye)")
    end

    -- blur = stay: focusing a NON-group window changes nothing (it's a peek --
    -- left on top, deck NOT re-raised, so the peeked window stays visible)
    fake.windowFrameSets = {}
    fake.raises = {}
    table.insert(fake.windows, 1,
        { id = 99, title = "Inbox", appName = "Mail", bundleID = "com.mail", x = 200, y = 200, w = 300, h = 200 })
    focusWin(99)                                   -- focus a NON-group window
    ok(#fake.windowFrameSets == 0, "focus leaving the group is ignored -- no reshuffle")
    ok(#fake.raises == 0, "peeking a non-deck window does NOT raise the deck (peek stays on top)")

    -- returning to the hero after a peek moves no frames AND raises nothing --
    -- the user's own click already fronted the hero; raising here is what
    -- flashed members over the hero (the "return blink"). The reclean that
    -- sinks the ex-peek waits for the next beat's motion cover.
    fake.windowFrameSets = {}
    fake.raises, fake.focused = {}, {}
    focusWin(3)                                   -- return to the current hero after the peek
    ok(#fake.windowFrameSets == 0, "re-focusing the current hero moves no frames")
    ok(#fake.raises == 0 and #fake.focused == 0,
        "the bare return raises nothing (no-blink); the reclean is deferred to the next beat")

    -- escalating Escape: first drops the hero to GRID (banner stays), second exits.
    -- The drop is a reverse ring flight: the window's move home is dispatched at
    -- flight START (read before the flush proves it), the flush then lands the
    -- ring and re-renders the borders. The drop is also a beat: the reclean the
    -- peek above deferred lands HERE, under the drop's motion cover.
    fake.windowFrameSets = {}
    fake.raises, fake.focused = {}, {}
    fake.pressHotkey("escape", { "alt" })
    local dropped = lastSetFor(3)                  -- BEFORE the flight timer fires
    ok(dropped and near(dropped.x, TRslot.x) and near(dropped.y, TRslot.y),
        "first ⌥Esc dispatches the hero's move home at flight start (under the ring)")
    fake.fireTimers("after")
    fake.fireTimers("after")
    ok(fake.liveScrim() ~= nil, "first ⌥Esc keeps the deck active (scrim still up)")
    ok(#fake.raises == 4 and #fake.focused == 0,
        "the deferred reclean lands on the drop beat: all four members re-raised "
        .. "above the ex-peek (no hero left, so no focus lift)")
    ok(fake.liveOutline("hero") == nil and fake.liveOutline("ghost") == nil
        and #fake.liveOutlines("member") == 4,
        "dropping the hero to GRID: hero/ghost borders gone, all four back to member borders")
    do
        local anyHole = false
        for _, o in ipairs(fake.liveOutlines("member")) do
            if o.hole then anyHole = true end
        end
        ok(not anyHole, "back in GRID the borders clear their hero hole (full rings again)")
    end
    fake.pressHotkey("escape", { "alt" })
    ok(fake.liveScrim() == nil, "second ⌥Esc exits the deck")
    ok(registry.liveHandleCount() == 1, "exit left only the toggle bound")

    -- T-WD2b: a fast second switch mid-flight ---------------------------------
    -- The beat dispatches the promoted window toward the hero rect at flight
    -- START, so a beat cancelled mid-air (a newer promotion) must step that
    -- half-flown window back to its slot -- never strand it at centre.
    fake.windows = quadWindows()
    enterDeck()
    fake.windowFrameSets = {}
    focusWin(2, nil, true)                        -- TL's beat starts (mid-flight)
    focusWin(3, nil, true)                        -- TR takes over before the ring lands
    do
        local back = lastSetFor(2)
        ok(back and near(back.x, TLslot.x) and near(back.y, TLslot.y),
            "a beat cancelled mid-flight steps its half-flown window back to its slot")
    end
    fake.fireTimers("after")
    fake.fireTimers("after")
    do
        local hero2 = lastSetFor(3)
        ok(hero2 and near(hero2.w, HERO.w), "the newer focus wins the hero")
    end
    fake.pressHotkey("k", HYP)                     -- exit
    ok(registry.liveHandleCount() == 1, "clean after the mid-flight cancel test")

    -- T-WD3: within-app promotion via the focus observer (cmd+`) --------------
    -- Two windows of the SAME app: only the AXObserver path (onFocusChanged) can
    -- see this switch -- app activation never fires.
    fake.windows = {
        { id = 10, title = "Downloads", appName = "Finder", bundleID = "com.apple.finder", x = 100, y = 500, w = 400, h = 300 },
        { id = 11, title = "Documents", appName = "Finder", bundleID = "com.apple.finder", x = 100, y = 100, w = 400, h = 300 },
    }
    enterDeck()                                    -- GRID (2 Finder windows)
    fake.windowFrameSets = {}
    focusWin(11, true)                            -- focus the other Finder window (same app)
    local within = lastSetFor(11)
    ok(within and near(within.x, HERO.x) and near(within.w, HERO.w),
        "a within-app focus change (focus observer) promotes the newly-focused window")
    fake.pressHotkey("k", HYP)                     -- exit
    ok(registry.liveHandleCount() == 1, "clean after within-app test")

    -- T-WD4: edges -----------------------------------------------------------
    -- window closes mid-deck: the gone window is never rewritten, no crash
    fake.windows = quadWindows()
    enterDeck()
    focusWin(2)                                   -- TL is hero
    fake.windowFrameSets = {}
    do                                             -- BL (id=4) closes
        local kept = {}
        for _, w in ipairs(quadWindows()) do if w.id ~= 4 then kept[#kept + 1] = w end end
        fake.windows = kept
    end
    focusWin(3)                                   -- promote TR; BL is gone
    ok(lastSetFor(4) == nil, "a window that closed mid-deck is never rewritten")
    ok(lastSetFor(3) ~= nil, "the still-open windows keep working after one closes")
    fake.pressHotkey("k", HYP)                     -- exit

    -- hero closes -> deck falls back to GRID, so the next ⌥Esc EXITS (not drop)
    fake.windows = quadWindows()
    enterDeck()
    focusWin(2)                                   -- TL is hero
    do
        local kept = {}
        for _, w in ipairs(quadWindows()) do if w.id ~= 2 then kept[#kept + 1] = w end end
        table.insert(kept, 1,
            { id = 98, title = "Inbox", appName = "Mail", bundleID = "com.mail", x = 200, y = 200, w = 300, h = 200 })
        fake.windows = kept
    end
    focusWin(98)                                  -- hero gone; focus a non-group window
    fake.pressHotkey("escape", { "alt" })          -- mode is GRID now -> exits
    ok(fake.liveBanner() == nil,
        "when the hero window closes, the deck drops to GRID (one ⌥Esc then exits)")
    ok(registry.liveHandleCount() == 1, "clean after hero-closes test")

    -- >9 windows: the grid caps at 9
    do
        local many = {}
        for i = 1, 11 do
            many[i] = { id = 100 + i, title = "W" .. i, appName = "App" .. i,
                        bundleID = "com.w" .. i, x = (i % 4) * 200 + 20, y = math.floor(i / 4) * 200 + 20,
                        w = 150, h = 120 }
        end
        fake.windows = many
        fake.windowFrameSets = {}
        enterDeck()
        ok(#fake.windowFrameSets == 9, "the deck caps the grid at 9 windows")
        fake.pressHotkey("k", HYP)                  -- exit
    end

    -- colors: CHARACTERIZATION, not a regression test -- stored per-app
    -- colors load from state into the picker preview, and a full deck's
    -- colors stay distinct around them. (No 9-window input can force the
    -- dealer to duplicate -- cap == #PALETTE -- so distinctness here pins the
    -- property, it does not discriminate dealer implementations.)
    fake.settings["hammerdeck.state.window_deck.colors"] =
        '{"com.w2":"#30D158","com.w4":"#123456"}'   -- the LAST palette slot + a custom hex
    do
        local many = {}
        for i = 1, 9 do
            many[i] = { id = 300 + i, title = "C" .. i, appName = "App" .. i,
                        bundleID = "com.w" .. i, x = (i % 3) * 300 + 20,
                        y = (i % 3) * 200 + 20, w = 150, h = 120 }
        end
        fake.windows = many
        fake.pressHotkey("k", HYP)
        local p = fake.openWindowPicker()
        ok(p ~= nil and #p.items == 9 and p.items[2].color == "#30D158",
            "stored per-app colors load into the picker preview")
        local seen, dup = {}, false
        for _, it in ipairs(p.items) do
            if it.color and seen[it.color] then dup = true end
            seen[it.color] = true
        end
        ok(not dup, "a 9-window deck deals DISTINCT border colors even with stored colors in play")
        p.cancel()
    end
    fake.settings["hammerdeck.state.window_deck.colors"] = nil

    -- hero is set to the FULL ~78% and is NOT shrunk by an immediate read-back.
    -- (Regression: an earlier read-back-recenter ran ctx.window.frame() right
    -- after the async AX setFrame, saw the stale slot-sized frame, and re-centred
    -- the hero back down to a grid cell -- the ~25% hero bug. fake.focusedWindow is
    -- a deliberately tiny stale frame; the hero must still be full-size and no
    -- focused-window setFrame may fire.)
    fake.windows = quadWindows()
    enterDeck()
    fake.focusedWindow = { x = 0, y = 0, w = 200, h = 150, screenIndex = 1 }  -- stale/small read-back
    fake.windowFrameSets = {}
    local framesBefore = #fake.windowFrames
    focusWin(2)
    local promo = lastSetFor(2)
    ok(promo and near(promo.w, HERO.w) and near(promo.h, HERO.h),
        "the hero is set to the full ~78% size, not shrunk to its slot")
    ok(#fake.windowFrames == framesBefore,
        "no read-back re-center fires (it raced AX and shrank the hero to a grid cell)")
    fake.focusedWindow = nil
    fake.pressHotkey("k", HYP)                      -- exit

    -- T-WD5: the USER drags/resizes a member -> hide the ring until stable ----
    -- Live tracking would trail the drag (AX events throttle), so the deck
    -- hides the ring while frame events flow and re-shows it at the REAL frame
    -- once they go quiet. Our OWN AX moves echo the same events -- the echo
    -- guard must keep them from hiding rings mid-beat.
    fake.windows = quadWindows()
    enterDeck()
    do
        local function hiddenCount()   -- across ALL kinds (a hero ring can hide too)
            local n = 0
            for _, o in ipairs(fake.liveOutlines()) do
                if o.hidden then n = n + 1 end
            end
            return n
        end
        -- a drag starts: first frame event hides TL's ring
        fake.fireFrameEvent{ bundleID = "com.tl", title = "TL", x = 400, y = 300, w = 300, h = 200 }
        ok(hiddenCount() == 1, "a user-dragged member hides its ring while in motion")
        -- more motion, then quiet: the stable timer re-shows at the REAL frame
        fake.fireFrameEvent{ bundleID = "com.tl", title = "TL", x = 500, y = 320, w = 300, h = 200 }
        fake.fireTimers("after")                    -- the stable timer fires
        local shown
        for _, o in ipairs(fake.liveOutlines("member")) do
            if o.frame and near(o.frame.x, 500) and near(o.frame.y, 320) then shown = o end
        end
        ok(shown ~= nil and not shown.hidden,
            "once stable, the ring re-shows at the window's REAL frame (not the stale slot)")
        -- our own beat moves must NOT hide rings: promote TL, then replay the
        -- move/resize echo the AX observer would deliver for our own setFrame
        focusWin(2, nil, true)                      -- beat dispatched, mid-flight
        fake.fireFrameEvent{ bundleID = "com.tl", title = "TL",
                             x = HERO.x, y = HERO.y, w = HERO.w, h = HERO.h }
        ok(hiddenCount() == 0, "our own AX move's echo does not hide the ring (echo guard)")
        -- ...but a frame that DIVERGES from what we dispatched, even under an
        -- armed guard, is the user grabbing the window (promote-then-drag) --
        -- it must still be detected as motion
        fake.fireFrameEvent{ bundleID = "com.tl", title = "TL", x = 30, y = 700, w = 300, h = 200 }
        ok(hiddenCount() == 1,
            "a diverging frame under an armed echo guard is a USER drag -- ring hides")
        fake.fireTimers("after")
        fake.fireTimers("after")                    -- land the beat + settle the drag
        ok(hiddenCount() == 0, "all rings shown again after the beat and the drag settle")
        -- a render mid-drag must not un-hide a hidden ring: drag BL, then land
        -- a full swap beat with SELECTIVE flushes (flight timers only, 0.15s)
        -- while BL's stable timer (0.35s) is still pending -- the landing
        -- renderBorders must skip the dragged member
        fake.fireFrameEvent{ bundleID = "com.bl", title = "BL", x = 40, y = 40, w = 300, h = 200 }
        ok(hiddenCount() == 1, "BL's ring hides as its drag starts")
        focusWin(3, nil, true)                      -- swap toward TR, mid-drag
        fake.fireTimers("after", 0.15)              -- step 1 lands -> step 2 launches
        fake.fireTimers("after", 0.15)              -- step 2 lands -> renderBorders
        ok(hiddenCount() == 1,
            "a beat landing mid-drag does not re-show the dragged member's ring")
        fake.fireTimers("after")                    -- BL's stable timer fires
        ok(hiddenCount() == 0, "the dragged ring re-shows once its window settles")
    end
    fake.pressHotkey("k", HYP)                      -- exit
    ok(registry.liveHandleCount() == 1, "clean after the hide-until-stable test")

    -- T-WD6: retitling windows keep their deck identity (adoption) ------------
    -- Regression for the stranded-hero bug: members are keyed bundleID+title,
    -- so a retitle (browser tab switch, editor file switch -- sometimes caused
    -- by our own resize) used to break every later by-key lookup: the old hero
    -- could not be stepped home (it stayed at the hero rect UNDER the new
    -- hero) and exit could not restore the window. resolveIds adopts the
    -- renamed window (same app, unclaimed, at the member's last-known frame).
    fake.windows = quadWindows()
    enterDeck()
    focusWin(2)                                    -- TL is hero
    do
        for _, w in ipairs(fake.windows) do        -- the hero window RETITLES
            if w.id == 2 then w.title = "TL - now renamed" end
        end
        fake.windowFrameSets = {}
        focusWin(3)                                -- swap: the retitled old hero must step home
        local back = lastSetFor(2)
        ok(back and near(back.x, TLslot.x) and near(back.y, TLslot.y),
            "a RETITLED old hero is adopted and steps home -- never stranded under the new hero")
        local promoted = lastSetFor(3)
        ok(promoted and near(promoted.w, HERO.w),
            "the swap still promotes the newly-focused window after an adoption")
    end
    do                                             -- retitle a plain member, then exit
        for _, w in ipairs(fake.windows) do
            if w.id == 4 then w.title = "BL - renamed" end
        end
        fake.windowFrameSets = {}
        fake.pressHotkey("k", HYP)                 -- exit -> restore
        local restored = lastSetFor(4)
        ok(restored and restored.x == 100 and restored.y == 550,
            "a retitled member is adopted on exit and restored to its ORIGINAL frame")
    end
    ok(registry.liveHandleCount() == 1, "clean after the retitle-adoption test")

    -- T-WD7: wid-based identity (the hybrid) ----------------------------------
    -- Rows that carry the bridge-resolved CGWindowID are keyed by it, so a
    -- retitle never even needs the adoption fallback, and focus matching works
    -- through the wid ladder regardless of what the title says.
    fake.windows = quadWindows()
    for _, w in ipairs(fake.windows) do w.wid = 9000 + w.id end   -- stable OS ids
    enterDeck()
    fake.windowFrameSets = {}
    do
        -- promote via the focused WID while the reported title is nonsense --
        -- the ladder must match on wid, never looking at the title
        fake.windowTitle = "totally unrelated title"
        fake.frontmost, fake.frontmostId = "AppTL", "com.tl"
        fake.focusedWid = 9002
        fake.activateApp("AppTL", "com.tl")
        fake.fireTimers("after")
        fake.fireTimers("after")
        local promo = lastSetFor(2)
        ok(promo and near(promo.w, HERO.w),
            "promotion matches the focused window by its stable wid, not the title")
        -- the hero retitles: identity survives WITHOUT adoption (key = wid)
        for _, w in ipairs(fake.windows) do
            if w.id == 2 then w.title = "renamed again" end
        end
        fake.windowFrameSets = {}
        fake.focusedWid = 9003
        focusWin(3)                                -- swap (focusWin sets title too)
        local back = lastSetFor(2)
        ok(back and near(back.x, TLslot.x) and near(back.y, TLslot.y),
            "a retitled wid-keyed hero steps home -- identity held by the wid itself")
    end
    fake.pressHotkey("k", HYP)                      -- exit
    fake.focusedWid = nil
    ok(registry.liveHandleCount() == 1, "clean after the wid-identity test")

    -- multi-monitor: only the focused screen's windows are decked
    fake.screenList = {
        { x = 0,    y = 0, w = 1440, h = 900, name = "Left",  index = 1, builtin = true },
        { x = 1440, y = 0, w = 1440, h = 900, name = "Right", index = 2, builtin = false },
    }
    fake.windows = {
        { id = 201, title = "L1", appName = "AppL1", bundleID = "com.l1", x = 100,  y = 100, w = 300, h = 200 },
        { id = 202, title = "L2", appName = "AppL2", bundleID = "com.l2", x = 100,  y = 500, w = 300, h = 200 },
        { id = 203, title = "R1", appName = "AppR1", bundleID = "com.r1", x = 1600, y = 100, w = 300, h = 200 },
        { id = 204, title = "R2", appName = "AppR2", bundleID = "com.r2", x = 1600, y = 500, w = 300, h = 200 },
    }
    fake.focusedWindow = { x = 1600, y = 100, w = 300, h = 200, screenIndex = 2 }  -- focus on the right screen
    fake.windowFrameSets = {}
    fake.pressHotkey("k", HYP)
    -- multi-monitor: the display map opens with the ACTIVE screen pre-selected as
    -- the default, so a single Enter decks it.
    local dp = fake.openDisplayPicker()
    ok(dp and dp.title == "Deck which screen?"
        and #dp.displays == 2
        and dp.preselect[1] == 2
        and dp.displays[2].name == "Right",
        "multi-monitor opens the map with the CURRENT display (Right) pre-selected")
    ok(dp.displays[1].name == "Left",
        "the map lists displays in screen order (Left, Right)")
    dp.userConfirm(dp.preselect)   -- 'press Enter' on the pre-selected current display
    local wp = fake.openWindowPicker()
    ok(wp ~= nil and #wp.items == 2,
        "picking a screen leads to a window multi-select of only that screen's windows")
    ok(wp.screenFrame and wp.screenFrame.x == 1440,
        "the window picker opens centered on the PICKED display, not the key screen")
    wp.confirm(nil)
    ok(#fake.windowFrameSets == 2, "only the focused screen's two windows are decked")
    ok((lastSetFor(203) and lastSetFor(203).x >= 1440)
        and (lastSetFor(204) and lastSetFor(204).x >= 1440),
        "the decked windows are tiled onto the right screen")
    ok(lastSetFor(201) == nil and lastSetFor(202) == nil,
        "windows on the other screen are left untouched")
    fake.pressHotkey("k", HYP)                      -- exit

    registry.setEnabled("window_deck", false)
    ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after window_deck test")

    -- restore the shared fake globals this block mutated, so downstream tests
    -- (which assume an empty windowFrameSets and the default single screen) are
    -- not disturbed.
    fake.focusedWindow  = nil
    fake.windows        = {}
    fake.windowFrameSets = {}
    fake.raises         = {}
    fake.raiseActivates = false
    fake.mousePos       = { x = 0, y = 0 }
    fake.windowTitle    = nil
    fake.frontmost      = nil
    fake.frontmostId    = ""
    fake.focusedWid     = nil
    fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1, builtin = true } }
end

-- T25g: no two shipped features declare COLLIDING default shortcuts ------------
-- There is no single registry of default triggers -- each feature declares its
-- own defaultTrigger in init.lua. Nothing bound them into one namespace, so a new
-- feature could silently reuse a shortcut another feature already defaults to; the
-- only check was interactive (the "already bound to X" wall a USER hits when
-- rebinding in Settings). This scans the WHOLE on-disk catalog and fails loudly on
-- any default-vs-default conflict, catching it at authoring time / CI instead.
-- (window_deck once shipped Hyper+D, already Insert Date/Time's default -- exactly
-- the class of bug this guards.) Runs on both engines (lua run.lua + test-lua.sh).
do
    local appdir = require("loader").appdir

    -- enumerate every feature dir that has a lua/init.lua (the shipped catalog)
    local ids = {}
    local pipe = io.popen('ls "' .. appdir .. '/features" 2>/dev/null')
    if pipe then
        for name in pipe:lines() do
            local fh = io.open(appdir .. "/features/" .. name .. "/lua/init.lua", "r")
            if fh then fh:close(); ids[#ids + 1] = name end
        end
        pipe:close()
    end
    ok(#ids >= 20, "default-trigger scan enumerated the on-disk catalog (" .. #ids .. " features)")

    -- collect every declared default hotkey/chord straight from init.lua (raw,
    -- not validated: feature.json -- the source of `name` -- is overlaid only at
    -- register time, and defaults live in init.lua regardless). Handle both the
    -- actions[] shape and the single-action sugar (top-level action+defaultTrigger).
    local defaults = {}
    local function record(id, action, t)
        if t and (t.type == "hotkey" or t.type == "chord") then
            defaults[#defaults + 1] = { feature = id, action = action, spec = t }
        end
    end
    for _, id in ipairs(ids) do
        local mod = require("features." .. id)
        if type(mod.actions) == "table" then
            for _, a in ipairs(mod.actions) do record(id, a.id or "?", a.defaultTrigger) end
        else
            record(id, "main", mod.defaultTrigger)   -- single-action sugar
        end
    end

    -- pairwise: two DIFFERENT features must not default to conflicting shortcuts
    -- (triggers.conflicts encodes the hotkey/chord-prefix rules; same-prefix chords
    -- with different follow keys are legitimately NOT a conflict).
    local clashes = {}
    for i = 1, #defaults do
        for j = i + 1, #defaults do
            local A, B = defaults[i], defaults[j]
            if A.feature ~= B.feature and triggers.conflicts(A.spec, B.spec) then
                clashes[#clashes + 1] = A.feature .. "." .. A.action
                    .. " vs " .. B.feature .. "." .. B.action
                    .. " (" .. triggers.describe(A.spec) .. ")"
            end
        end
    end
    ok(#clashes == 0,
        "no two features ship colliding default shortcuts"
        .. (#clashes > 0 and (" -- " .. table.concat(clashes, "; ")) or ""))
end

-- T26: tab_switcher (cross-browser tab switcher, MRU-first) ----------------------
do
local jsonlib = require("platform.json")

-- the new encoder round-trips what the feature persists
local encT = jsonlib.encode({ b = { ["https://x.y/z?a=1"] = 123 }, n = 1.5, s = 'q"q' })
local decT = jsonlib.decode(encT)
ok(decT.b["https://x.y/z?a=1"] == 123 and decT.n == 1.5 and decT.s == 'q"q',
    "json.encode round-trips nested tables, floats, and quotes")
ok(jsonlib.encode({ 1, 2, 3 }) == "[1,2,3]", "arrays encode as arrays")
ok(jsonlib.encode(function() end) == nil, "unencodable values return nil, not a throw")

registry.register(require("features.tab_switcher"))

local mruPath = "/fake/data/tab_switcher/mru.json"
local nowT = fake.now()
fake.files[mruPath] = jsonlib.encode({
    ["Google Chrome"] = {
        ["https://github.com/x"] = nowT - 60,             -- fresh: sorts first
        ["https://dead.example/old"] = nowT - 40 * 86400, -- stale: pruned
    },
    ["Safari"] = { ["https://apple.com/"] = nowT - 3600 },
})
fake.runningApps["Google Chrome"] = true
fake.runningApps["Safari"] = true
fake.chromeFavicons["github.com"] = true   -- Chrome's icon DB knows github
fake.browserTabsByApp = {
    ["Google Chrome"] = {
        { title = "Docs", url = "https://docs.example/d", winId = 1, tabIndex = 1, visible = true },
        { title = "GitHub", url = "https://github.com/x", winId = 1, tabIndex = 2, visible = true },
        { title = "Shortcut App", url = "https://app.example/", winId = 7, tabIndex = 1, visible = false },
    },
    ["Safari"] = {
        { title = "Apple", url = "https://apple.com/", winId = 9, tabIndex = 1, visible = true },
    },
}

registry.setEnabled("tab_switcher", true)
ok(fake.files[mruPath]:find("dead.example") == nil or true, "noop guard")

fake.modifiers.alt = true
fake.pressHotkey("tab", { "ctrl", "alt" })
local tch = fake.visibleChooser()
ok(tch ~= nil, "tab chooser opened")
ok(#tch.choices == 3, "visible tabs listed; invisible shortcut-app window skipped")
ok(tch.choices[1].text == "GitHub", "freshest MRU stamp sorts first")
ok(tch.choices[2].text == "[Safari] Apple", "Safari tabs are prefixed and ranked by stamp")
ok(tch.choices[1].image == "file:/tmp/hammerdeck-fake-cache/favicons/github.com.png",
    "a Chrome-DB icon shows as soon as extraction lands (show-time resolution)")
ok(tch.choices[3].image == "icon:com.google.Chrome",
    "no cached favicon -> the browser's app icon")
ok(tch.selectedRow == 2, "the previous tab is preselected")
ok(#fake.extractedBatches >= 1 and #fake.extractedBatches[1].domains >= 2,
    "missing favicons go to Chrome's icon DB first")
local dlSeen = {}
for _, d in ipairs(fake.downloads) do dlSeen[d.path] = d.url end
ok(dlSeen["/tmp/hammerdeck-fake-cache/favicons/docs.example.png"]
        == "https://docs.example/favicon.ico",
    "domains Chrome doesn't know fall back to the site's own /favicon.ico")
ok(dlSeen["/tmp/hammerdeck-fake-cache/favicons/github.com.png"] == nil,
    "extracted domains are not re-downloaded")

-- release the modifier: the armed auto-jump picks the selected row
fake.modifiers.alt = false
fake.fireTimers("every", 0.1)
ok(fake.tabJumps[#fake.tabJumps].app == "Safari" and fake.tabJumps[#fake.tabJumps].winId == 9,
    "releasing the modifier jumps to the selected tab")
ok(fake.files[mruPath]:find("apple.com", 1, true) ~= nil
    and fake.files[mruPath]:find("dead.example", 1, true) == nil,
    "the landed tab is stamped; 30-day-old entries were pruned")

-- the extracted favicon upgrades the row on the next open (show-time icon
-- re-resolution -- no relist needed)
fake.frontmost = "Google Chrome"
fake.activeUrls["Google Chrome"] = "https://news.example/today"
fake.fireTimers("every", 10)   -- the MRU poll stamps + marks dirty
ok(fake.files[mruPath]:find("news.example", 1, true) ~= nil,
    "the 10s poll stamps the active browser url")
fake.modifiers.alt = true
fake.pressHotkey("tab", { "ctrl", "alt" })
tch = fake.visibleChooser()
ok(tch.choices[1].text == "[Safari] Apple",
    "the jumped-to tab now ranks first (stamped at jump time)")
local ghChoice
for _, c in ipairs(tch.choices) do if c.text == "GitHub" then ghChoice = c end end
ok(ghChoice and ghChoice.image == "file:/tmp/hammerdeck-fake-cache/favicons/github.com.png",
    "a cached favicon replaces the app icon after refresh")

-- cycling: a second invocation advances the row; wrap works
local rowBefore = tch.selectedRow
fake.pressHotkey("tab", { "ctrl", "alt" })
ok(tch.selectedRow == rowBefore + 1, "repeat invocation cycles forward")
fake.pressHotkey("`", { "ctrl", "alt" })
ok(tch.selectedRow == rowBefore, "the backward action cycles back")

-- a drifted/closed tab alerts and triggers a relist
fake.jumpUrlOverride = false
tch.userSelect(1)
ok(fake.alerts[#fake.alerts]:match("moved") ~= nil, "a vanished tab alerts to retry")
fake.jumpUrlOverride = nil
fake.modifiers.alt = false

registry.setEnabled("tab_switcher", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after tab_switcher test")

end
-- T27: registry.runAction -- the menubar's quick triggers ----------------------
registry.register(require("features.plain_paste"))   -- dropped by T14's reload
registry.setEnabled("plain_paste", true)
fake.pasteboard = "  menu fired  "
ok(registry.runAction("plain_paste", "main") == true, "runAction fires an enabled action")
ok(fake.pasteboard == "menu fired", "the action really ran")
local okRun, why = registry.runAction("plain_paste", "nope")
ok(okRun == false and why:match("no action"), "unknown action refused with a reason")
registry.setEnabled("plain_paste", false)
okRun, why = registry.runAction("plain_paste", "main")
ok(okRun == false and why:match("not enabled"), "disabled feature refused")
ok(registry.runAction("ghost_feature") == false, "unknown feature refused")
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after runAction test")

-- T28: clipboard_history (poll, conceal, dedup, cap, persist, pick-to-paste) --
do
registry.register(require("features.clipboard_history"))
registry.setEnabled("clipboard_history", true)
local histPath = "/fake/data/clipboard_history/history.json"

fake.copyText("alpha")
fake.fireTimers("every", 0.8)
ok(fake.files[histPath]:find("alpha", 1, true) ~= nil, "a copied entry is recorded + persisted")
fake.copyText("beta")
fake.fireTimers("every", 0.8)
fake.copyText("the-password!", true)   -- concealed: password manager
fake.fireTimers("every", 0.8)
ok(fake.files[histPath]:find("the%-password") == nil,
    "concealed clips are NEVER recorded (checked before reading)")
fake.copyText("alpha")                 -- re-copy: dedup moves to front
fake.fireTimers("every", 0.8)

fake.pressHotkey("h", { "cmd", "alt", "ctrl" })
local hch = fake.visibleChooser()
ok(hch ~= nil and #hch.choices == 2, "history chooser opens, deduped")
ok(hch.choices[1].text == "alpha" and hch.choices[2].text == "beta",
    "newest first, re-copy bumped alpha to the front")

-- selecting writes the clipboard and pastes (paste_on_select donor default)
fake.copyText("other")                 -- clipboard currently holds something else
fake.fireTimers("every", 0.8)
fake.pressHotkey("h", { "cmd", "alt", "ctrl" })
fake.visibleChooser().userSelect(3)    -- pick "beta" (other, alpha, beta)
ok(fake.pasteboard == "beta", "selection puts the entry on the clipboard")
fake.fireTimers("after", 0.15)
local pk = fake.keyEvents[#fake.keyEvents]
ok(pk.key == "v" and pk.mods[1] == "cmd", "and pastes it (cmd+v)")

-- pasteOnSelect off: clipboard only
fake.settings["hammerdeck.opt.clipboard_history.pasteOnSelect"] = false
local keysBefore28 = #fake.keyEvents
fake.pressHotkey("h", { "cmd", "alt", "ctrl" })
fake.visibleChooser().userSelect(2)
fake.fireTimers("after", 0.15)
ok(#fake.keyEvents == keysBefore28, "pasteOnSelect off -> no synthesized paste")
fake.settings["hammerdeck.opt.clipboard_history.pasteOnSelect"] = nil

-- the cap drops the oldest
fake.settings["hammerdeck.opt.clipboard_history.historySize"] = nil
fake.settings["hammerdeck.opt.clipboard_history.historySize"] = 2
fake.copyText("gamma")
fake.fireTimers("every", 0.8)
fake.pressHotkey("h", { "cmd", "alt", "ctrl" })
ok(#fake.visibleChooser().choices == 2, "historySize caps the list")
fake.visibleChooser().userSelect(1)
fake.fireTimers("after", 0.15)
fake.settings["hammerdeck.opt.clipboard_history.historySize"] = nil

-- history survives a disable/re-enable (restored from disk)
registry.setEnabled("clipboard_history", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clipboard_history leaks nothing")
registry.setEnabled("clipboard_history", true)
fake.pressHotkey("h", { "cmd", "alt", "ctrl" })
ok(#fake.visibleChooser().choices >= 1, "history restored from disk after re-enable")
fake.visibleChooser().userSelect(1)
fake.fireTimers("after", 0.15)
registry.setEnabled("clipboard_history", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after clipboard_history test")

end
-- T29: command_palette (fuzzy launcher over every enabled feature) -------------
do
registry.register(require("features.command_palette"))

-- the capability gate is enforced at manifest validation
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
    capabilities = { "bogus" } }), "manifest rejects an unknown capability")
ok(pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
    capabilities = { "commands" } }), "manifest accepts the known capability")

-- two dummy features populate the palette: a single-action one and a
-- multi-action one (one of whose actions is left unbound).
local palHits = { a = 0, one = 0, two = 0 }
package.loaded["features._cmd_a"] = {
    api = 1, id = "cmd_a", name = "Cmd A",
    defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "5" },
    action = function() palHits.a = palHits.a + 1 end,
}
package.loaded["features._cmd_b"] = {
    api = 1, id = "cmd_b", name = "Cmd B",
    actions = {
        { id = "one", label = "Do one",
          defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "7" },
          run = function() palHits.one = palHits.one + 1 end },
        { id = "two", label = "Do two",   -- no trigger: dormant, manual-only
          run = function() palHits.two = palHits.two + 1 end },
    },
}
package.loaded["features._cmd_off"] = {   -- registered but never enabled
    api = 1, id = "cmd_off", name = "Cmd Off",
    defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "8" },
    action = function() end,
}
registry.load("features._cmd_a")
registry.load("features._cmd_b")
registry.load("features._cmd_off")
registry.setEnabled("cmd_a", true)
registry.setEnabled("cmd_b", true)
registry.setEnabled("command_palette", true)

fake.pressHotkey("space", { "cmd", "alt", "ctrl" })
local pch = fake.visibleChooser()
ok(pch ~= nil, "palette opened a chooser")
-- cmd_a (1) + cmd_b (2) = 3 rows; the palette excludes itself, disabled cmd_off excluded
ok(#pch.choices == 3, "lists enabled features' actions; self + disabled excluded")
local sub, sc, seen = {}, {}, {}
for _, c in ipairs(pch.choices) do sub[c.text] = c.subText; sc[c.text] = c.shortcut; seen[c.text] = true end
ok(seen["Cmd A"], "a single-action feature shows its name as the command")
ok(seen["Do one"] and seen["Do two"], "a multi-action feature contributes one row per action")
ok(sub["Cmd A"] == nil, "a single-action feature omits the redundant source column")
ok(sc["Cmd A"] == "⌃5", "showShortcuts puts the compact trigger glyph in the shortcut column")
ok(sub["Do one"] == "Cmd B" and sub["Do two"] == "Cmd B", "multi-action rows show their source feature")
ok(sc["Do one"] == "⌃7", "a bound multi-action row shows its own shortcut")
ok(sc["Do two"] == nil, "an unbound action has no shortcut")

-- selecting a row runs that command -- on the next tick, after the panel yields
local target
for i, c in ipairs(pch.choices) do if c.text == "Do two" then target = i end end
pch.userSelect(target)
ok(palHits.two == 0, "selection is deferred until the panel yields focus")
fake.fireTimers("after", 0)
ok(palHits.two == 1, "the deferred command actually ran via ctx.runCommand")

-- showShortcuts off -> bare feature name, no trigger suffix
fake.settings["hammerdeck.opt.command_palette.showShortcuts"] = false
fake.pressHotkey("space", { "cmd", "alt", "ctrl" })
local pchNo = fake.visibleChooser()
local subNo, scNo = {}, {}
for _, c in ipairs(pchNo.choices) do subNo[c.text] = c.subText; scNo[c.text] = c.shortcut end
ok(scNo["Cmd A"] == nil, "showShortcuts off drops the shortcut column")
ok(subNo["Do one"] == "Cmd B", "source feature stays regardless of showShortcuts")
ok(pchNo.choices[1].text == "Do two",
    "frecency: the previously-run command sorts to the top")
pchNo.userSelect(0)   -- dismiss
fake.settings["hammerdeck.opt.command_palette.showShortcuts"] = nil

-- empty catalog: a single non-selectable info row instead of a blank panel
registry.setEnabled("cmd_a", false)
registry.setEnabled("cmd_b", false)
fake.pressHotkey("space", { "cmd", "alt", "ctrl" })
local pchEmpty = fake.visibleChooser()
ok(pchEmpty ~= nil and #pchEmpty.choices == 1 and pchEmpty.choices[1].valid == false,
    "empty catalog shows a single info row")
pchEmpty.userSelect(0)

-- a plain feature does NOT receive the capability methods (least privilege)
package.loaded["features._cmd_plain"] = {
    api = 1, id = "cmd_plain", name = "Cmd Plain",
    defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "9" },
    action = function(ctx)
        palHits.plainHasCommands = (ctx.commands ~= nil)
    end,
}
registry.load("features._cmd_plain")
registry.setEnabled("cmd_plain", true)
fake.pressHotkey("9", { "ctrl" })
ok(palHits.plainHasCommands == false,
    "a feature without the capability never gets ctx.commands")

registry.setEnabled("cmd_plain", false)
registry.setEnabled("command_palette", false)
registry.setEnabled("cmd_off", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after command_palette test")

end
-- T30: fire-time error surfacing -- repeated failures raise ONE visible alert --
local boomCount = 0
package.loaded["features._boom"] = {
    api = 1, id = "boom", name = "Boom Feature",
    defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "0" },
    action = function() boomCount = boomCount + 1; error("kaboom") end,
}
registry.load("features._boom")
registry.setEnabled("boom", true)
local alertsBoom = #fake.alerts
fake.pressHotkey("0")   -- failure 1
fake.pressHotkey("0")   -- failure 2
ok(#fake.alerts == alertsBoom, "early failures stay quiet (logged only)")
fake.pressHotkey("0")   -- failure 3 -> alert
ok(#fake.alerts == alertsBoom + 1 and fake.alerts[#fake.alerts]:match("keeps failing"),
    "the third consecutive failure raises one visible alert")
fake.pressHotkey("0")   -- failure 4 -> no more spam
ok(#fake.alerts == alertsBoom + 1, "further failures do not spam additional alerts")
ok(boomCount == 4, "a throwing action is contained, not silently swallowed (still ran each time)")
registry.setEnabled("boom", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after error-surfacing test")

-- T31: modal auto-repeat -- hold a `repeats` key to fire it steadily, key-up
-- (or exit) stops it. Carbon gives no native repeat, so modal.lua builds it
-- from the press+release edges and a delay/tick timer pair.
local modal = require("platform.modal")
local repHits, plainHits = 0, 0
local m = modal.enter {
    name = "RepeatTest",
    bindings = {
        { key = "w", repeats = true, fn = function() repHits = repHits + 1 end },
        { key = "f", fn = function() plainHits = plainHits + 1 end },
    },
}

fake.pressHotkey("w", {})
ok(repHits == 1, "press fires a repeating key once immediately")
ok(fake.fireTimers("every", 0.04) == 0, "no steady tick until the hold delay elapses")

fake.fireTimers("after", 0.3)                  -- hold delay elapses -> tick arms
ok(repHits == 1, "the delay itself does not fire the action again")
fake.fireTimers("every", 0.04)
ok(repHits == 2, "after the delay, each tick fires the action")
fake.fireTimers("every", 0.04)
ok(repHits == 3, "and keeps firing while held")

fake.releaseHotkey("w", {})                    -- key up cancels the repeat
local heldTo = repHits
ok(fake.fireTimers("every", 0.04) == 0, "release cancels the steady tick")
ok(repHits == heldTo, "no further fires after release")

fake.pressHotkey("f", {})
ok(plainHits == 1, "a non-repeating key still fires")
ok(fake.fireTimers("after", 0.3) == 0 and fake.fireTimers("every", 0.04) == 0,
    "a non-repeating key arms no repeat timers")

-- holding a key, then exiting the mode, must not leak the repeat timers
fake.pressHotkey("w", {})
fake.fireTimers("after", 0.3)                  -- tick armed and live
m.stop()
ok(fake.liveHandles == 0, "exiting mid-hold tears down the repeat timers")

-- T: shortcut advisories (soft system / common-app collision warnings) --------
-- `triggers` is the module required at T10 above.
local function hasWarn(list, needle)
    for _, s in ipairs(list) do if s:find(needle, 1, true) then return true end end
    return false
end

-- curated macOS factory defaults (present even with an empty live read)
fake.systemHotkeys = {}
ok(hasWarn(triggers.advisories({ type = "hotkey", mods = { "cmd" }, key = "space" }), "Spotlight"),
    "cmd+space warns about Spotlight")
ok(hasWarn(triggers.advisories({ type = "hotkey", mods = { "cmd", "alt" }, key = "space" }),
    "Finder search"), "cmd+alt+space warns about Finder search")
-- the command palette's shipped default must be clean out of the box
ok(#triggers.advisories({ type = "hotkey", mods = { "cmd", "shift" }, key = "space" }) == 0,
    "command palette default (shift+cmd+space) is conflict-free")
-- common-app shadow (case-insensitive on the typed key)
ok(hasWarn(triggers.advisories({ type = "hotkey", mods = { "cmd" }, key = "W" }), "Close Window"),
    "cmd+W warns it shadows Close Window")
-- a free, ergonomic combo is clean
ok(#triggers.advisories({ type = "hotkey", mods = { "ctrl", "alt", "cmd" }, key = "j" }) == 0,
    "ctrl+alt+cmd+j has no advisories")
-- a chord prefix that collides still warns (the prefix is a real global hotkey)
ok(hasWarn(triggers.advisories({ type = "chord", mods = { "cmd" }, key = "space", follows = { "b" } }),
    "Spotlight"), "a chord whose prefix is cmd+space warns about Spotlight")
-- non-keyboard triggers never produce advisories
ok(#triggers.advisories({ type = "schedule", everyMin = 5 }) == 0, "schedule trigger: no advisories")
-- the live read is honored: a user-customized system shortcut is detected
fake.systemHotkeys = { { mods = { "ctrl", "shift" }, key = "k", name = "My Custom Action" } }
ok(hasWarn(triggers.advisories({ type = "hotkey", mods = { "ctrl", "shift" }, key = "k" }),
    "My Custom Action"), "live-read system shortcut is detected")
fake.systemHotkeys = {}

-- T32: usage_stats report.range -- historical aggregation over the CSVs --------
-- The Homepage "Usage" tab calls features.usage_stats.report.range(from,to) via
-- lua.call; it reads straight from disk (works even when the feature is off).
-- Seed a few daily apps/sessions CSVs under the default dir (~/.computer-usage,
-- so /fake/home/.computer-usage) and assert the rolled-up shape.
do
    local function approx(a, b) return math.abs(a - b) < 1e-6 end
    local U = "/fake/home/.computer-usage"
    -- range 2026-06-20 .. 22 (22 has no data -> inactive day)
    fake.files[U .. "/2026-06/2026-06-20-apps.csv"] =
        "app,context,seconds\nCode,projA,3600\nGoogle Chrome,github.com,1800\n"
    fake.files[U .. "/2026-06/2026-06-21-apps.csv"] =
        "app,context,seconds\nCode,projA,1200\nGoogle Chrome,news.example,600\nSlack,,300\n"
    fake.files[U .. "/2026-06/2026-06-20.csv"] =
        "wake_time,sleep_time,duration_min\n09:00:00,17:00:00,480\n"
    -- a day in the PRECEDING equal-length period (17..19) -> drives prevTotal
    fake.files[U .. "/2026-06/2026-06-19-apps.csv"] =
        "app,context,seconds\nCode,projA,1000\n"

    local report = require("features.usage_stats.report")
    local r = report.range("2026-06-20", "2026-06-22")

    ok(r.total == 7500, "report total sums all apps across the range")
    ok(r.activeDays == 2, "activeDays counts only days with recorded time")
    ok(r.dailyAvg == 3750, "dailyAvg = total / active days")
    ok(#r.days == 3 and r.days[3].date == "2026-06-22" and r.days[3].secs == 0,
        "days series has an entry per day, empty day = 0")

    ok(#r.apps == 3, "all apps ranked (uncapped)")
    ok(r.apps[1].app == "Code" and r.apps[1].secs == 4800, "apps ranked by total secs")
    ok(r.apps[2].app == "Google Chrome" and r.apps[2].secs == 2400, "second-ranked app")
    ok(r.apps[3].app == "Slack" and r.apps[3].secs == 300, "long-tail app kept")
    ok(approx(r.apps[1].share, 4800 / 7500), "app share = secs / range total")
    ok(r.busiestApp == "Code", "busiestApp is the top app")

    -- contexts merge across days and carry a within-app share
    ok(#r.apps[1].contexts == 1 and r.apps[1].contexts[1].name == "projA"
        and r.apps[1].contexts[1].secs == 4800, "context merged across days")
    ok(approx(r.apps[1].contexts[1].share, 1.0), "single-context app -> share 1.0")
    ok(#r.apps[2].contexts == 2, "two distinct browser domains kept as contexts")
    ok(r.apps[2].contexts[1].name == "github.com" and r.apps[2].contexts[1].secs == 1800,
        "top context first")
    ok(approx(r.apps[2].contexts[1].share, 1800 / 2400), "context share is within its app")

    -- sessions (machine-active spans)
    ok(#r.sessions == 1 and r.sessions[1].date == "2026-06-20", "session row read")
    ok(r.sessions[1].wakeMin == 540 and r.sessions[1].sleepMin == 1020,
        "session wake/sleep parsed to minutes-of-day")
    ok(r.firstWakeMin == 540 and r.lastSleepMin == 1020, "first wake / last sleep")
    ok(r.sessionCount == 1 and r.longestSessionMin == 480 and r.activeMinutes == 480,
        "session summary metrics")

    -- previous equal-length period (17..19): only 19 seeded
    ok(r.prevTotal == 1000 and r.prevHasData == true,
        "prevTotal sums the preceding equal-length period")

    -- empty range -> safe zeros, empty arrays (the report's empty state)
    local e = report.range("2025-01-01", "2025-01-03")
    ok(e.total == 0 and e.activeDays == 0 and #e.apps == 0 and e.busiestApp == nil,
        "empty history -> zeroed report, no apps")

    -- tidy up so later code never trips over the seeded files
    fake.files[U .. "/2026-06/2026-06-20-apps.csv"] = nil
    fake.files[U .. "/2026-06/2026-06-21-apps.csv"] = nil
    fake.files[U .. "/2026-06/2026-06-20.csv"] = nil
    fake.files[U .. "/2026-06/2026-06-19-apps.csv"] = nil
end

-- T33: manifest `page` -- feature-contributed native pages -------------------
-- A feature may declare page = { title, icon } to dock a native Homepage view.
-- Validate the shape, and that describe() passes it through for the host.
do
    local mok = manifest.validate({ api = 1, id = "p1", name = "P1",
        action = function() end, page = { title = "Usage", icon = "chart.bar.xaxis" } })
    ok(mok.page.title == "Usage" and mok.page.icon == "chart.bar.xaxis",
        "valid page declaration accepted")
    -- icon is optional (host defaults it)
    ok(pcall(manifest.validate, { api = 1, id = "p2", name = "P2",
        action = function() end, page = { title = "Just Title" } }),
        "page.icon is optional")
    rejects({ api = 1, id = "p3", name = "P3", action = function() end, page = {} },
        "page without a title")
    rejects({ api = 1, id = "p4", name = "P4", action = function() end,
        page = { title = "X", icon = 42 } }, "page.icon must be a string")
    rejects({ api = 1, id = "p5", name = "P5", action = function() end, page = "Usage" },
        "page must be a table")

    -- describe() surfaces it (with the icon defaulted) so the sidebar is data-driven
    local reg2 = require("platform.registry")
    reg2.register({ api = 1, id = "page_probe", name = "Page Probe",
        action = function() end, page = { title = "Probe" } })
    local found
    for _, row in ipairs(reg2.describe()) do
        if row.id == "page_probe" then found = row end
    end
    ok(found and found.page and found.page.title == "Probe" and found.page.icon == "doc",
        "describe() emits page with a defaulted icon")
end

-- T34: rules engine (M0) -- bind ANY trigger to ANY effect across features -----
-- The automation framework spine: a rule fires an effect (M0 effect = run a
-- feature action) on a trigger, with the same automatable context policy the
-- registry enforces per action. Pure Lua over the fake adapter.
do
    local rules = require("platform.rules")
    local json  = require("platform.json")

    -- An AUTOMATABLE target action (so event/schedule rules are allowed) with
    -- no defaultTrigger -- it exists only to be fired by rules.
    local ranAuto = 0
    package.loaded["features._rule_auto"] = {
        api = 1, id = "rule_auto", name = "Rule Auto",
        actions = { { id = "go", label = "Go", automatable = true,
                      run = function() ranAuto = ranAuto + 1 end } },
    }
    -- A NON-automatable target (context-dependent -- the default).
    package.loaded["features._rule_manual"] = {
        api = 1, id = "rule_manual", name = "Rule Manual",
        actions = { { id = "go", run = function() end } },
    }
    registry.load("features._rule_auto")
    registry.load("features._rule_manual")
    registry.setEnabled("rule_auto", true)
    registry.setEnabled("rule_manual", true)

    -- (a) an event rule fires the target action
    ok(rules.load({
        { id = "wake-go", on = { type = "event", event = "wake" },
          effect = { kind = "command", feature = "rule_auto", action = "go" } },
    }) == 1, "rules.load keeps a valid rule")
    rules.startAll()
    ok(rules.liveCount() == 1, "startAll bound the rule")
    fake.systemEvent("wake")
    ok(ranAuto == 1, "event rule fired the target feature's action")

    -- (b) a manual hotkey rule fires the same action
    ok(rules.load({
        { id = "hk-go", on = { type = "hotkey", mods = { "ctrl" }, key = "f13" },
          effect = { kind = "command", feature = "rule_auto", action = "go" } },
    }) == 1, "load replaces the rule set")
    rules.startAll()
    fake.systemEvent("wake")
    ok(ranAuto == 1, "the replaced (event) rule no longer fires after reload")
    fake.pressHotkey("f13", { "ctrl" })
    ok(ranAuto == 2, "hotkey rule fired the action")

    -- (c) CONTEXT POLICY: an automated trigger on a non-automatable effect is
    -- refused at load; a manual trigger on the same effect loads fine.
    local kept = rules.load({
        { id = "bad-auto", on = { type = "event", event = "wake" },
          effect = { kind = "command", feature = "rule_manual", action = "go" } },
        { id = "ok-manual", on = { type = "hotkey", mods = { "ctrl" }, key = "f14" },
          effect = { kind = "command", feature = "rule_manual", action = "go" } },
    })
    ok(kept == 1, "automated trigger on a non-automatable effect refused; manual kept")
    local ids = {}
    for _, r in ipairs(rules.all()) do ids[r.id] = true end
    ok(ids["ok-manual"] and not ids["bad-auto"],
        "the manual rule survived; the context-violating automated rule was dropped")

    -- (d) malformed rules are quarantined (no id, unknown effect kind), valid kept
    ok(rules.load({
        { id = "good", on = { type = "event", event = "wake" },
          effect = { kind = "command", feature = "rule_auto", action = "go" } },
        { on = { type = "event", event = "wake" },                       -- no id
          effect = { kind = "command", feature = "rule_auto", action = "go" } },
        { id = "badeffect", on = { type = "event", event = "wake" },
          effect = { kind = "teleport" } },                              -- unknown kind
    }) == 1, "malformed rules quarantined; the valid one is kept")

    -- (e) a rule whose target feature is DISABLED still loads, and firing it is a
    -- logged no-op (not a crash)
    registry.setEnabled("rule_auto", false)
    ok(rules.load({
        { id = "disabled-target", on = { type = "hotkey", mods = { "ctrl" }, key = "f15" },
          effect = { kind = "command", feature = "rule_auto", action = "go" } },
    }) == 1, "a rule targeting a disabled feature still loads (manual trigger)")
    rules.startAll()
    local before = ranAuto
    fake.pressHotkey("f15", { "ctrl" })
    ok(ranAuto == before, "firing a rule whose target is disabled is a no-op, not a crash")

    -- (f) loadFromSettings reads the JSON `hammerdeck.rules` key (the M4-UI source)
    registry.setEnabled("rule_auto", true)
    fake.settings["hammerdeck.rules"] = json.encode({
        { id = "from-settings", on = { type = "event", event = "wake" },
          effect = { kind = "command", feature = "rule_auto", action = "go" } },
    })
    ok(rules.loadFromSettings() == 1, "loadFromSettings decodes + loads the rules JSON setting")
    rules.startAll()
    before = ranAuto
    fake.systemEvent("wake")
    ok(ranAuto == before + 1, "a rule loaded from settings fires")
    fake.settings["hammerdeck.rules"] = nil

    -- (g) teardown leaks nothing
    rules.stopAll()
    ok(rules.liveCount() == 0, "stopAll unbound every rule")
    rules.load({})
    ok(rules.count() == 0, "rules.load({}) clears the set")

    registry.setEnabled("rule_auto", false)
    registry.setEnabled("rule_manual", false)
    registry.unregister("rule_auto")
    registry.unregister("rule_manual")
    ok(fake.liveHandles == 0, "no native handle leaked across the rules engine tests")
end

-- T35: rules engine (M1) -- state-signal triggers, notify effect, mutation API --
-- The condition/state half of the framework: a rule fires on a STATE SIGNAL
-- crossing a value (frontmostApp becomes/leaves), the observable `notify` effect,
-- and the add/setEnabled/remove + describe surface the Settings Rules tab calls.
do
    local rules   = require("platform.rules")
    local effects = require("platform.effects")
    local json    = require("platform.json")

    -- (a) a `state` trigger fires on the enter transition, not on stay/leave
    fake.frontmost = "Finder"
    local nB = #fake.notifications
    ok(rules.load({
        { id = "safari-front",
          on = { type = "state", signal = "frontmostApp", becomes = "Safari" },
          effect = { kind = "notify", title = "HD", text = "Safari front" } },
    }) == 1, "state-trigger rule with a notify effect loads (notify is context-free)")
    rules.startAll()
    ok(rules.liveCount() == 1, "state rule bound")
    fake.activateApp("Mail")
    ok(#fake.notifications == nB, "switching to a non-target app does not fire")
    fake.activateApp("Safari")
    ok(#fake.notifications == nB + 1, "frontmost BECOMES Safari -> notify fires (enter)")
    fake.activateApp("Safari")
    ok(#fake.notifications == nB + 1, "re-activating Safari (no value change) does not re-fire")
    fake.activateApp("Notes")
    ok(#fake.notifications == nB + 1, "leaving Safari does not fire a 'becomes' rule")

    -- (b) a `leaves` trigger fires on the exit transition, not on enter
    rules.load({
        { id = "safari-leave",
          on = { type = "state", signal = "frontmostApp", leaves = "Safari" },
          effect = { kind = "notify", title = "HD", text = "left Safari" } },
    })
    rules.startAll()
    local nL = #fake.notifications
    fake.activateApp("Safari")
    ok(#fake.notifications == nL, "a 'leaves' rule does not fire on enter")
    fake.activateApp("Mail")
    ok(#fake.notifications == nL + 1, "frontmost LEAVES Safari -> notify fires (exit)")

    -- (c) context policy: a state trigger (automated) cannot run a non-automatable command
    package.loaded["features._m1_manual"] = {
        api = 1, id = "m1_manual", name = "M1 Manual",
        actions = { { id = "go", run = function() end } },
    }
    registry.load("features._m1_manual"); registry.setEnabled("m1_manual", true)
    ok(rules.load({
        { id = "bad", on = { type = "state", signal = "frontmostApp", becomes = "X" },
          effect = { kind = "command", feature = "m1_manual", action = "go" } },
    }) == 0, "state trigger on a non-automatable command is refused (context policy)")

    -- (d) an unknown signal is refused
    ok(rules.load({
        { id = "badsig", on = { type = "state", signal = "ghost", becomes = "X" },
          effect = { kind = "notify", title = "x" } },
    }) == 0, "a rule on an unknown signal is refused")

    -- (e) mutation API + persistence + describe (the UI surface)
    local ran = 0
    package.loaded["features._m1_auto"] = {
        api = 1, id = "m1_auto", name = "M1 Auto",
        actions = { { id = "go", automatable = true, run = function() ran = ran + 1 end } },
    }
    registry.load("features._m1_auto"); registry.setEnabled("m1_auto", true)
    fake.settings["hammerdeck.rules"] = nil
    rules.load({})
    local okAdd, rid = rules.add({ on = { type = "event", event = "wake" },
        effect = { kind = "command", feature = "m1_auto", action = "go" } })
    ok(okAdd and type(rid) == "string", "add() assigns an id and returns it")
    ok(rules.count() == 1 and rules.liveCount() == 1, "added rule is loaded + bound")
    ok(type(fake.settings["hammerdeck.rules"]) == "string", "add() persisted to hammerdeck.rules")
    local persisted = json.decode(fake.settings["hammerdeck.rules"])
    ok(type(persisted) == "table" and persisted[1].id == rid, "persisted JSON carries the rule")

    local d = rules.describe()
    ok(#d == 1 and d[1].id == rid and d[1].enabled == true
        and d[1].triggerDesc:find("wake") and d[1].effectDesc:find("Run M1 Auto"),
        "describe() yields {id, enabled, triggerDesc, effectDesc} for the UI")
    -- the command effect names the action by its friendly "Do"-dropdown label
    -- (the feature name for a sole action), not the raw "m1_auto.go" id.
    ok(effects.describe({ kind = "command", feature = "m1_auto", action = "go" }) == "Run M1 Auto",
        "describe command uses the friendly action label")
    -- fallback: an unloaded/parked feature's command shows the raw ids (no blank)
    ok(effects.describe({ kind = "command", feature = "ghost", action = "x" }) == "Run ghost.x",
        "describe command falls back to raw ids when the feature isn't loaded")
    -- fallback: a LOADED feature but an unknown action (a stale rule whose action
    -- was renamed/removed) -- resolveAction fails -> raw ids, not a blank
    ok(effects.describe({ kind = "command", feature = "m1_auto", action = "bogus" }) == "Run m1_auto.bogus",
        "describe command falls back to raw ids for an unknown action on a loaded feature")

    local logsBefore = #fake.logs
    fake.systemEvent("wake")
    ok(ran == 1, "the added rule fires")
    local sawFireLog = false
    for i = logsBefore + 1, #fake.logs do
        if fake.logs[i]:find("fired") then sawFireLog = true end
    end
    ok(sawFireLog, "a fired rule logs a diagnostic trace (so silent no-fires are debuggable)")
    ok(rules.setEnabled(rid, false) == true, "setEnabled(false) succeeds")
    ok(rules.count() == 1 and rules.liveCount() == 0, "a disabled rule stays loaded but unbound")
    fake.systemEvent("wake")
    ok(ran == 1, "a disabled rule does not fire")
    ok(rules.setEnabled(rid, true) == true, "setEnabled(true) re-binds")
    fake.systemEvent("wake")
    ok(ran == 2, "the re-enabled rule fires again")

    -- update in place: keep the id, change the effect (the UI "Save changes")
    ok(rules.update(rid, { on = { type = "event", event = "wake" },
        effect = { kind = "notify", title = "updated" } }) == true,
        "update() replaces a rule's spec in place")
    local du = rules.describe()
    ok(#du == 1 and du[1].id == rid and du[1].effectDesc:find("updated") ~= nil,
        "update kept the id and changed the effect")
    ok(du[1].on ~= nil and du[1].effect ~= nil,
        "describe() carries the raw on/effect spec (so the edit form can pre-fill)")
    -- the context policy is enforced on update too, not just add
    ok(rules.update(rid, { on = { type = "state", signal = "frontmostApp", becomes = "X" },
        effect = { kind = "command", feature = "m1_manual", action = "go" } }) == false,
        "update() refuses a context-violating change (policy enforced on edit)")

    -- (e2) advanced "Edit as JSON": specJSON exposes one rule's full stored spec,
    -- and updateJSON round-trips it -- including fields the guided form can't build
    -- (a placement's titlePattern). Bad input is refused with a reason, never thrown.
    local sj = rules.specJSON(rid)
    ok(type(sj) == "string" and json.decode(sj).id == rid,
        "specJSON returns the rule's full spec as JSON")
    ok(select(1, rules.specJSON("nope")) == nil, "specJSON(unknown id) returns nil + reason")
    ok(rules.updateJSON(rid, '{"on":{"type":"event","event":"sleep"},'
        .. '"effect":{"kind":"layout","placements":[{"app":"Safari",'
        .. '"titlePattern":"Docs","screen":"DELL","pos":"left"}]}}') == true,
        "updateJSON accepts a spec with a placement titlePattern (the advanced field)")
    ok(rules.describe()[1].effect.placements[1].titlePattern == "Docs",
        "the titlePattern survived the JSON round-trip into the stored spec")
    ok(select(1, rules.updateJSON(rid, "{not json")) == false,
        "updateJSON refuses malformed JSON with a reason (no crash)")
    ok(select(1, rules.updateJSON(rid, '{"on":{"type":"event","event":"wake"},'
        .. '"effect":{"kind":"layout","placements":[{"app":"Safari",'
        .. '"titlePattern":123,"screen":"DELL","pos":"left"}]}}')) == false,
        "updateJSON rejects a non-string titlePattern (validate guards the advanced path)")

    ok(rules.remove(rid) == true and rules.count() == 0, "remove() drops the rule")

    -- (f) formOptions feeds the Add form's dropdowns
    local fo = rules.formOptions()
    local sawFrontmost = false
    for _, s in ipairs(fo.signals) do if s == "frontmostApp" then sawFrontmost = true end end
    ok(type(fo.signals) == "table" and sawFrontmost, "formOptions lists the available signals")
    local sawNotify = false
    for _, e in ipairs(fo.effects) do if e.kind == "notify" then sawNotify = true end end
    ok(sawNotify, "formOptions offers the notify effect")

    -- (g) rule NAMES + the on-demand "Test" (rules.fire) ----------------------
    -- Wrapped in a nested do...end so its locals release before the block's tail
    -- (Lua caps a function at 200 locals; this big T35 block runs close).
    do
        rules.load({})
        local okN, nid = rules.add({ name = "Dock at desk",
            on = { type = "event", event = "wake" },
            effect = { kind = "notify", title = "HD", text = "docked" } })
        ok(okN, "add() accepts an optional rule name")
        ok(rules.describe()[1].name == "Dock at desk", "describe() surfaces the rule name")

        -- describe() also carries the plain-English sentence -- the same read-back the
        -- editor's Name placeholder shows, so an unnamed rule lists AS that sentence.
        local specs = rules.all()
        local d1 = rules.describe()[1]
        ok(#specs >= 1 and #d1.sentence > 0 and d1.sentence == rules.sentence(specs[1]),
            "describe() carries the read-back sentence (the list shows it for unnamed rules)")

        -- an UNNAMED rule reports name == "" -- the fallback the list row leans on
        -- (it shows the trigger text when the name is blank, never a nil/"rule2").
        local _, nid2 = rules.add({ on = { type = "event", event = "wake" },
            effect = { kind = "notify", title = "HD" } })
        local unnamed
        for _, r in ipairs(rules.describe()) do if r.id == nid2 then unnamed = r end end
        ok(unnamed ~= nil and unnamed.name == "", "an unnamed rule reports name == \"\" (list-row fallback)")
        rules.remove(nid2)

        -- fire() runs the effect ON DEMAND, bypassing the trigger (the Test button)
        local nF = #fake.notifications
        local fOk, fNote = rules.fire(nid)
        ok(fOk == true and #fake.notifications == nF + 1,
            "fire() runs the effect on demand -- no trigger needed")
        ok(fNote == nil or fNote == "", "a clean fire returns no partial-success note")

        -- a manual test tags the log [test] so it never reads like a real trigger fire
        local taggedTest = false
        for i = 1, #fake.logs do if fake.logs[i]:find("%[test%]") then taggedTest = true end end
        ok(taggedTest, "fire() tags its log trace as a manual [test]")

        -- fire() tests a DISABLED rule too (you verify the effect, not the binding)
        rules.setEnabled(nid, false)
        local nD = #fake.notifications
        ok(select(1, rules.fire(nid)) == true and #fake.notifications == nD + 1,
            "fire() tests a disabled rule (verify the effect before enabling it)")

        ok(select(1, rules.fire("nope")) == false, "fire(unknown id) returns false + reason")

        -- a non-string name is refused by validate (guards the JSON path too)
        ok(select(1, rules.add({ name = 123,
            on = { type = "event", event = "wake" },
            effect = { kind = "notify", title = "x" } })) == false,
            "add() rejects a non-string name")

        -- a state trigger with an empty/non-string value is refused -- it would
        -- otherwise bind happily and silently NEVER fire (sig.match never matches
        -- "" or a number against a string-valued signal). The form blocks an empty
        -- value, but the JSON authoring path needs this engine-side backstop.
        ok(select(1, rules.add({ on = { type = "state", signal = "frontmostApp", becomes = "" },
            effect = { kind = "notify", title = "x" } })) == false,
            "add() rejects a state trigger with an empty value (silent-dead-rule guard)")
        ok(select(1, rules.add({ on = { type = "state", signal = "frontmostApp", becomes = 5 },
            effect = { kind = "notify", title = "x" } })) == false,
            "add() rejects a non-string state trigger value")

        -- a daily-at schedule must be a REAL clock time: "29:79" matched the old
        -- HH:MM regex but could never fire correctly -- now range-checked.
        ok(select(1, rules.add({ on = { type = "schedule", at = "29:79" },
            effect = { kind = "notify", title = "x" } })) == false,
            "add() rejects an out-of-range daily-at time (29:79)")
        ok(rules.add({ on = { type = "schedule", at = "23:59" },
            effect = { kind = "notify", title = "x" } }) == true,
            "add() still accepts a valid edge time (23:59)")
    end

    -- cleanup
    rules.load({})
    fake.settings["hammerdeck.rules"] = nil
    registry.setEnabled("m1_manual", false); registry.unregister("m1_manual")
    registry.setEnabled("m1_auto", false); registry.unregister("m1_auto")
    ok(fake.liveHandles == 0, "no native handle leaked across the M1 rules tests")
end

-- T35a-P10: a rule whose effect keeps FAILING raises ONE visible alert after 3
-- consecutive REAL fires (the directly-bound automated path already does this via
-- registry.FAIL_ALERT_AFTER; rules now mirror it, keyed per RULE). Manual "Test"
-- fires don't count toward the streak, and a success resets it -- so a scheduled
-- rule silently dying surfaces, without per-effect popup spam.
do
    local rules = require("platform.rules")
    -- An automatable action that throws on demand (toggle `boom` to make it succeed).
    local boom = true
    package.loaded["features._m1_fail"] = {
        api = 1, id = "m1_fail", name = "M1 Fail",
        actions = { { id = "boom", automatable = true,
                      run = function() if boom then error("kaboom") end end } },
    }
    registry.load("features._m1_fail"); registry.setEnabled("m1_fail", true)

    fake.frontmost = "Finder"
    ok(rules.load({
        { id = "flaky", name = "Flaky rule",
          on = { type = "state", signal = "frontmostApp", becomes = "Zoom" },
          effect = { kind = "command", feature = "m1_fail", action = "boom" } },
    }) == 1, "a rule on an automatable (but throwing) command loads")
    rules.startAll()
    ok(rules.liveCount() == 1, "failing-effect rule bound")

    -- Drive exactly one REAL fire (enter Zoom from elsewhere).
    local function enterZoom()
        fake.activateApp("Finder")   -- leave Zoom (a `becomes` rule does not fire on leave)
        fake.activateApp("Zoom")     -- enter -> one real fire
    end

    local aB = #fake.alerts
    enterZoom()
    ok(#fake.alerts == aB, "1st real failure: logged, no alert yet")
    enterZoom()
    ok(#fake.alerts == aB, "2nd real failure: still no alert")
    -- A manual Test fire fails too, but must NOT advance the streak.
    rules.fire("flaky")
    ok(#fake.alerts == aB, "a failing manual Test fire does not count toward the streak")
    enterZoom()
    ok(#fake.alerts == aB + 1, "3rd consecutive REAL failure raises exactly one alert")
    ok(fake.alerts[#fake.alerts]:find("Flaky rule", 1, true)
        and fake.alerts[#fake.alerts]:find("keeps failing", 1, true),
        "the alert names the rule and says it keeps failing")
    enterZoom()
    ok(#fake.alerts == aB + 1, "further failures stay quiet -- no popup spam")

    -- A SUCCESS clears the streak: it then takes 3 fresh failures to alert again.
    boom = false
    enterZoom()
    ok(#fake.alerts == aB + 1, "a successful fire raises no alert (and clears the streak)")
    boom = true
    enterZoom(); enterZoom()
    ok(#fake.alerts == aB + 1, "two failures after the reset: below threshold, still quiet")
    enterZoom()
    ok(#fake.alerts == aB + 2, "streak restarted post-success -> 3 more failures, one new alert")

    -- cleanup
    rules.load({})
    registry.setEnabled("m1_fail", false); registry.unregister("m1_fail")
    ok(fake.liveHandles == 0, "no native handle leaked across the P10 fail-alert test")
end

-- T35b: frontmostApp matches by BUNDLE ID when the rule carries `on.bundleId` -- so a
-- rule keyed to an app fires regardless of the app's localized name (locale / rename),
-- and a DIFFERENT app that merely shares the display name does NOT. A rule with no
-- bundle id (free-typed) still matches by name. Exercises the real signal value
-- ({name, bundleId}) + rules.bindOne's bundle-id-first target + sig.match.
do
    local rules   = require("platform.rules")
    local effects = require("platform.effects")
    fake.settings["hammerdeck.rules"] = nil
    fake.frontmost = "Finder"; fake.frontmostId = "com.apple.finder"

    -- (a) bundle-id rule: becomes = display name, bundleId = the stable match key
    rules.load({
        { id = "slack-front",
          on = { type = "state", signal = "frontmostApp", becomes = "Slack",
                 bundleId = "com.tinyspeck.slackmacgap" },
          effect = { kind = "notify", title = "HD", text = "Slack front" } },
    })
    rules.startAll()
    local nB = #fake.notifications
    -- the app reports a DIFFERENT localized name but the matching bundle id -> fires
    fake.activateApp("Slack (Beta)", "com.tinyspeck.slackmacgap")
    ok(#fake.notifications == nB + 1,
        "frontmostApp matches by bundle id despite a different localized name")

    -- a same-NAME app of a DIFFERENT bundle does not fire (bundle id is authoritative)
    fake.activateApp("Finder", "com.apple.finder")   -- leave -> reset the edge
    local nB2 = #fake.notifications
    fake.activateApp("Slack", "com.other.slackclone")
    ok(#fake.notifications == nB2,
        "a same-named app of a different bundle does not fire a bundle-id rule")

    -- (b) a free-typed rule (no bundleId) still matches by name
    rules.load({
        { id = "notes-front",
          on = { type = "state", signal = "frontmostApp", becomes = "Notes" },
          effect = { kind = "notify", title = "HD", text = "Notes" } },
    })
    rules.startAll()
    local nN = #fake.notifications
    fake.activateApp("Notes", "com.apple.Notes")
    ok(#fake.notifications == nN + 1, "a rule with no bundle id matches by name (free-text)")

    -- (c) the engine IGNORES a stray on.bundleId on a signal that doesn't support it
    -- (sig.bundleIdMatch=false) -- so a hand-authored JSON rule (or a stale id left by
    -- switching signals in the form) on an enum/name/set signal still fires by its real
    -- value, instead of matching a bundle id it never satisfies (a silent dead rule).
    fake.appearance = "light"
    rules.load({
        { id = "appdark",
          on = { type = "state", signal = "appearance", becomes = "dark", bundleId = "com.stray.id" },
          effect = { kind = "notify", title = "Dark" } },
    })
    rules.startAll()
    local nD = #fake.notifications
    fake.appearance = "dark"; fake.systemEvent("appearanceChanged")
    ok(#fake.notifications == nD + 1,
        "a stray on.bundleId on a non-app signal is ignored -- the rule fires by its value, not dead")

    -- (d) from-trigger (@trigger:app) on a bundle-id rule resolves to the BUNDLE ID, so
    -- the effect finds the running app even when its localized name has drifted from the
    -- name the rule was authored with -- the case bundle-id matching exists for.
    rules.load({
        { id = "min-front",
          on = { type = "state", signal = "frontmostApp", becomes = "Slack",
                 bundleId = "com.tinyspeck.slackmacgap" },
          effect = { kind = "minimizeApp", app = effects.TRIGGER_APP } },
    })
    rules.startAll()
    local nMin = #fake.minimized
    fake.activateApp("Slack (Renamed)", "com.tinyspeck.slackmacgap")
    ok(#fake.minimized == nMin + 1 and fake.minimized[#fake.minimized] == "com.tinyspeck.slackmacgap",
        "from-trigger @trigger:app on a bundle-id rule passes the BUNDLE ID to the effect")

    rules.load({}); fake.frontmost = nil; fake.frontmostId = ""; fake.appearance = "light"
end

-- T35p: PARKING -- a stored rule whose target is absent THIS boot (a renamed/gone
-- signal or feature) is PRESERVED + surfaced as "unavailable", never silently
-- deleted on the next mutation, and re-activates when its target returns ----------
do
    local rules = require("platform.rules")
    fake.settings["hammerdeck.rules"] = nil

    -- reason attribution: a rule with a gone signal AND a command effect blames the
    -- SIGNAL (the verifiable cause), not the feature -- the parkReason ordering.
    rules.load({ { id = "both", on = { type = "state", signal = "ghostSignal", becomes = "X" },
        effect = { kind = "command", feature = "whatever", action = "go" } } })
    local both
    for _, r in ipairs(rules.describe()) do if r.id == "both" then both = r end end
    ok(both ~= nil and both.reason:find("ghostSignal", 1, true) ~= nil,
        "a gone-signal + command rule blames the signal, not the feature")

    -- one valid rule + one referencing a signal that no longer exists (same failure
    -- shape as a feature renamed/removed across an app update).
    local kept = rules.load({
        { id = "good",  on = { type = "event", event = "wake" },
          effect = { kind = "notify", title = "ok" } },
        { id = "ghost", on = { type = "state", signal = "ghostSignal", becomes = "X" },
          effect = { kind = "notify", title = "z" } },
    })
    ok(kept == 1, "load keeps the valid rule and PARKS the unavailable one (count excludes it)")
    rules.startAll()
    ok(rules.liveCount() == 1, "a parked rule is not bound")

    -- the parked rule is SURFACED (greyed/unavailable), not vanished
    local ghost
    for _, r in ipairs(rules.describe()) do if r.id == "ghost" then ghost = r end end
    ok(ghost ~= nil and ghost.unavailable == true, "describe() surfaces the parked rule as unavailable")
    ok(type(ghost.reason) == "string" and ghost.reason:find("ghostSignal", 1, true) ~= nil,
        "the unavailable reason names the missing target")

    -- THE BUG: a mutation must NOT erase the parked rule. setEnabled persists, then
    -- a fresh load from settings must still find BOTH.
    rules.setEnabled("good", false)
    rules.loadFromSettings()
    local stillGhost = false
    for _, r in ipairs(rules.describe()) do if r.id == "ghost" then stillGhost = true end end
    ok(stillGhost, "a mutation re-persists the parked rule -- it is NOT silently deleted")

    -- a parked rule is deletable
    ok(rules.remove("ghost") == true, "a parked rule can be removed")
    local gone = true
    for _, r in ipairs(rules.describe()) do if r.id == "ghost" then gone = false end end
    ok(gone, "removing a parked rule drops it from the list")

    -- editing a parked rule's JSON to a VALID spec un-parks it into the live set
    rules.load({
        { id = "fix", on = { type = "state", signal = "ghostSignal", becomes = "X" },
          effect = { kind = "notify", title = "z" } },
    })
    ok(rules.count() == 0 and select(1, rules.specJSON("fix")) ~= nil,
        "a parked rule is editable (specJSON returns it) though count excludes it")
    ok(rules.update("fix", { on = { type = "event", event = "wake" },
        effect = { kind = "notify", title = "z" } }) == true,
        "updating a parked rule to a valid spec succeeds (un-parks)")
    ok(rules.count() == 1, "the fixed rule un-parks into the live set")
    local fixed
    for _, r in ipairs(rules.describe()) do if r.id == "fix" then fixed = r end end
    ok(fixed ~= nil and fixed.unavailable ~= true, "the un-parked rule is now a normal live rule")

    -- cleanup
    rules.stopAll()
    rules.load({})
    fake.settings["hammerdeck.rules"] = nil
    ok(fake.liveHandles == 0, "no native handle leaked across the parking tests")
end

-- T35f: per-rule FIRE STATUS -- describe() reports when a rule last fired, whether
-- it was a Test, and whether the effect succeeded, so a silently-dead rule shows --
do
    local rules = require("platform.rules")
    fake.settings["hammerdeck.rules"] = nil
    fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1 } }
    fake.windows = {}

    local function row(rid)
        for _, r in ipairs(rules.describe()) do if r.id == rid then return r end end
    end

    rules.load({})
    local _, nid = rules.add({ on = { type = "event", event = "wake" },
        effect = { kind = "notify", title = "hi" } })
    rules.startAll()
    ok(row(nid).lastFired == nil, "a fresh rule reports no last-fired time (not fired yet)")

    -- a REAL trigger fire stamps lastFired -- not a test, effect succeeded
    fake.systemEvent("wake")
    local r1 = row(nid)
    ok(type(r1.lastFired) == "number" and r1.lastFiredTest ~= true and r1.lastFiredOk == true,
        "a real trigger fire records lastFired (via trigger, ok)")

    -- a TEST fire is tagged so the UI can say 'tested' not 'fired'
    rules.fire(nid)
    ok(row(nid).lastFiredTest == true, "a Test fire is tagged lastFiredTest")

    -- editing a rule clears its fire history (the old fire no longer describes it)
    rules.update(nid, { on = { type = "event", event = "wake" },
        effect = { kind = "notify", title = "changed" } })
    ok(row(nid).lastFired == nil, "update() clears the fire history (behavior changed)")

    -- a FAILED effect (layout with no present display) records lastFiredOk = false
    local _, lid = rules.add({ on = { type = "event", event = "wake" },
        effect = { kind = "layout", placements = { { app = "X", screen = "Ghost", pos = "full" } } } })
    rules.startAll()
    fake.systemEvent("wake")
    ok(row(lid).lastFiredOk == false, "a failed effect records lastFiredOk = false")

    -- removing a rule drops its fire history; a fresh load clears it all
    rules.remove(nid)
    ok(row(nid) == nil, "a removed rule leaves no row")
    rules.load({ { id = nid, on = { type = "event", event = "wake" },
        effect = { kind = "notify", title = "hi" } } })
    ok(row(nid).lastFired == nil, "load() clears the fire history (a fresh session)")

    -- cleanup
    rules.stopAll()
    rules.load({})
    fake.settings["hammerdeck.rules"] = nil
    fake.windows = {}
    ok(fake.liveHandles == 0, "no native handle leaked across the fire-status tests")
end

-- T36: window-layout effect (M2) -- place windows on named displays, self-gating,
-- capture-current-arrangement, and the screenChanged -> layout pipeline ---------
-- The seed automation: an external monitor connects (screenChanged) and assigned
-- apps snap to assigned rects on assigned displays. A layout placement is
-- SELF-GATING -- it targets a display by name, so it no-ops when that monitor is
-- unplugged, which is why a coarse screenChanged trigger is enough.
do
    local effects = require("platform.effects")
    local rules   = require("platform.rules")
    local W       = require("platform.windows")
    local json    = require("platform.json")

    local function approx(a, b) return type(a) == "number" and math.abs(a - b) < 1e-6 end

    -- Two displays: the laptop (primary) + an external to its right.
    fake.screenList = {
        { x = 0,    y = 0, w = 1440, h = 900,  name = "Built-in", index = 1, builtin = true },
        { x = 1440, y = 0, w = 2560, h = 1440, name = "DELL",     index = 2 },
    }
    fake.windows = {
        { id = 1, appName = "Safari", title = "Safari",   x = 100,  y = 100, w = 400, h = 300 },
        { id = 2, appName = "Code",   title = "main.lua", x = 1500, y = 100, w = 800, h = 600 },
    }

    -- (a) layout effects are context-free + validated
    ok(effects.requiresContext({ kind = "layout", placements = {} }) == false,
        "a layout effect is context-free (safe on automated triggers)")
    local okV = pcall(effects.validate, { kind = "layout", placements = {} })
    ok(okV == false, "validate rejects a layout with no placements")
    okV = pcall(effects.validate, { kind = "layout",
        placements = { { app = "Safari", screen = "DELL", pos = "nope" } } })
    ok(okV == false, "validate rejects a placement with an unknown position")

    -- (b) dispatch places each matching window on its named display's rect
    local layout = { kind = "layout", placements = {
        { app = "Safari", screen = "Built-in", pos = "left" },  -- left half of laptop
        { app = "Code",   screen = "DELL",     pos = "full" },  -- fill the external
    } }
    ok(select(1, effects.dispatch(layout)) == true, "layout dispatch reports success")
    ok(#fake.windowFrameSets == 2, "both matching windows were moved")
    local s1 = fake.windowFrameSets[1]
    ok(s1.id == 1 and approx(s1.x, 0) and approx(s1.y, 0) and approx(s1.w, 720) and approx(s1.h, 900),
        "Safari snapped to the left half of the Built-in display")
    local s2 = fake.windowFrameSets[2]
    ok(s2.id == 2 and approx(s2.x, 1440) and approx(s2.y, 0) and approx(s2.w, 2560) and approx(s2.h, 1440),
        "Code filled the DELL display (offset by its origin)")

    -- (b2) titlePattern picks ONE of several same-app windows (the advanced
    -- disambiguator -- two Safari windows, only the "Docs" one moves)
    fake.windows = {
        { id = 11, appName = "Safari", title = "Gmail - Inbox",  x = 5,  y = 5, w = 50, h = 50 },
        { id = 12, appName = "Safari", title = "Docs - report",  x = 60, y = 5, w = 50, h = 50 },
    }
    fake.windowFrameSets = {}
    ok(W.windowMatches(fake.windows[2], { app = "Safari", titlePattern = "Docs" }) == true
        and W.windowMatches(fake.windows[1], { app = "Safari", titlePattern = "Docs" }) == false,
        "windowMatches honors titlePattern (plain substring of the title)")
    ok(W.windowMatches(fake.windows[2], { app = "Safari", titlePattern = "docs" }) == true,
        "titlePattern is case-insensitive ('docs' matches 'Docs - report')")
    local okT = effects.dispatch({ kind = "layout", placements = {
        { app = "Safari", titlePattern = "Docs", screen = "DELL", pos = "full" } } })
    ok(okT == true and #fake.windowFrameSets == 1 and fake.windowFrameSets[1].id == 12,
        "a layout placement with titlePattern moves only the matching same-app window")

    -- (b3) PARTIAL miss: a present-display placement whose app is closed doesn't
    -- silently vanish -- dispatch still succeeds (some moved) but returns a note
    -- naming the unmatched placement, so a half-firing rule is debuggable.
    -- (scoped in do...end -- these locals would otherwise push the big T36 block
    -- past Lua's 200-locals-per-function limit)
    do
    fake.windowFrameSets = {}
    local okP, note = effects.dispatch({ kind = "layout", placements = {
        { app = "Safari", screen = "DELL", pos = "left" },   -- present + matches
        { app = "Mail",   screen = "DELL", pos = "right" },  -- present, but Mail is closed
    } })
    ok(okP == true and #fake.windowFrameSets == 1, "a partial layout still moves the windows it can")
    ok(type(note) == "string" and note:find("1/2", 1, true) and note:find("Mail", 1, true),
        "a partial fire returns a note naming the unmatched placement (moved 1/2 -- no window for Mail)")
    -- a placement on an ABSENT display is NOT counted as a miss (self-gating, silent)
    fake.windowFrameSets = {}
    local okG, noteG = effects.dispatch({ kind = "layout", placements = {
        { app = "Safari", screen = "DELL",        pos = "left" },   -- present, matches
        { app = "Mail",   screen = "Thunderbolt", pos = "right" },  -- display absent -> self-gated
    } })
    ok(okG == true and noteG == nil, "an absent-display placement self-gates silently (not a partial-miss note)")
    -- self-gated placements don't inflate the denominator (only 1 present display)
    fake.windowFrameSets = {}
    local okD2, noteD2 = effects.dispatch({ kind = "layout", placements = {
        { app = "Safari", screen = "DELL",        pos = "left" },   -- present, matches
        { app = "Mail",   screen = "DELL",        pos = "right" },  -- present, no Mail window
        { app = "Notes",  screen = "Thunderbolt", pos = "full" },   -- absent -> self-gated
    } })
    ok(okD2 == true and noteD2:find("1/2", 1, true) ~= nil and noteD2:find("3", 1, true) == nil,
        "the partial-fire denominator counts only present-display placements (1/2, not 1/3)")

    -- (b4) matched-but-move-FAILED: the window is found but the AX move is refused
    -- -- surfaced in the note, never a silent "fired"
    fake.windows = {
        { id = 21, appName = "Safari", title = "ok",   x = 5,  y = 5, w = 50, h = 50 },
        { id = 22, appName = "Code",   title = "stuck", x = 60, y = 5, w = 50, h = 50 },
    }
    fake.windowFrameSets = {}
    fake.failWindowFrameIds = { [22] = true }
    local okF, noteF = effects.dispatch({ kind = "layout", placements = {
        { app = "Safari", screen = "DELL", pos = "left" },   -- moves
        { app = "Code",   screen = "DELL", pos = "right" },  -- matches but move fails
    } })
    ok(okF == true and #fake.windowFrameSets == 1, "the movable window still moves")
    ok(type(noteF) == "string" and noteF:find("move failed", 1, true) and noteF:find("Code", 1, true),
        "a matched-but-move-failed placement is surfaced (not silently dropped)")
    -- every move failing -> reports failure with the accurate reason (not 'no matching windows')
    fake.windowFrameSets = {}
    fake.failWindowFrameIds = { [21] = true }
    local okZ, reasonZ = effects.dispatch({ kind = "layout", placements = {
        { app = "Safari", screen = "DELL", pos = "left" } } })
    ok(okZ == false and reasonZ:find("move failed", 1, true) ~= nil,
        "all-moves-failed reports a move-failure reason, not a false 'no matching windows'")
    fake.failWindowFrameIds = {}
    end

    -- (c) self-gating: a placement on an ABSENT display is skipped; an all-absent
    -- layout reports no-op (so the trace explains why nothing happened)
    fake.windowFrameSets = {}
    local okD, reason = effects.dispatch({ kind = "layout",
        placements = { { app = "Safari", screen = "Thunderbolt 5K", pos = "full" } } })
    -- The reason must NAME the unplugged display + say it's not connected -- the
    -- Test button surfaces this verbatim, so "no matching windows" (= a closed app)
    -- would point the user at the wrong problem.
    ok(okD == false and type(reason) == "string"
        and reason:find("Thunderbolt 5K", 1, true) ~= nil
        and reason:find("not connected", 1, true) ~= nil,
        "an all-absent layout names the unplugged display (not a false 'no matching windows')")
    ok(#fake.windowFrameSets == 0, "no window moved when the target display is unplugged")

    -- (d) capture the CURRENT arrangement -> exact ratios on each window's display.
    -- Built-in-display windows are SKIPPED: a captured layout restores an external
    -- display's arrangement, and the built-in is always present.
    fake.windows = {
        { id = 1, appName = "Safari", title = "S", x = 100,  y = 100, w = 720,  h = 900  }, -- Built-in (skipped)
        { id = 2, appName = "Code",   title = "C", x = 1440, y = 0,   w = 2560, h = 1440 }, -- DELL, full
    }
    local snap = effects.captureLayout()
    ok(#snap == 1, "captureLayout snapshots only external-display windows (built-in skipped)")
    local code = snap[1]
    ok(code.screen == "DELL" and code.app == "Code"
        and approx(code.pos.x, 0) and approx(code.pos.y, 0)
        and approx(code.pos.w, 1) and approx(code.pos.h, 1),
        "a maximized window on the external captures as full-screen ratios on DELL")
    for _, p in ipairs(snap) do
        ok(p.screen ~= "Built-in", "no built-in-display window leaks into a capture")
    end

    -- (d2) scoped capture: with multiple monitors, naming a display grabs ONLY
    -- that display's windows (the "when <display> connects" rule case).
    fake.screenList = {
        { x = 0,    y = 0,    w = 1440, h = 900,  name = "Built-in",    index = 1, builtin = true },
        { x = 1440, y = 0,    w = 2560, h = 1440, name = "DELL",        index = 2 },
        { x = 1440, y = 1440, w = 2560, h = 1440, name = "Thunderbolt", index = 3 },
    }
    fake.windows = {
        { id = 1, appName = "Safari", title = "S", x = 100,  y = 100,  w = 720,  h = 900  }, -- Built-in
        { id = 2, appName = "Code",   title = "C", x = 1440, y = 0,     w = 2560, h = 1440 }, -- DELL
        { id = 3, appName = "Mail",   title = "M", x = 1440, y = 1440,  w = 1280, h = 1440 }, -- Thunderbolt, left half
    }
    local tb = effects.captureLayout("Thunderbolt")
    ok(#tb == 1 and tb[1].screen == "Thunderbolt" and tb[1].app == "Mail",
        "scoped capture takes ONLY the named display's windows (3-monitor setup)")
    ok(approx(tb[1].pos.x, 0) and approx(tb[1].pos.w, 0.5),
        "scoped capture keeps the window's exact ratios on its display")
    ok(#effects.captureLayout("Nonexistent") == 0,
        "scoping to an absent display captures nothing")
    ok(#effects.captureLayout() == 2,
        "unscoped capture still grabs every external display (DELL + Thunderbolt)")
    -- a captured (explicit-ratio) placement is valid + re-applies
    ok(pcall(effects.validate, { kind = "layout", placements = snap }) == true,
        "a captured layout (explicit ratios) validates")

    -- (e) the full pipeline: screenChanged event -> layout, via the rules engine
    fake.settings["hammerdeck.rules"] = nil
    rules.load({})
    fake.windows = {
        { id = 7, appName = "Safari", title = "S", x = 5, y = 5, w = 50, h = 50 },
    }
    fake.windowFrameSets = {}
    local okAdd = rules.add({
        on = { type = "event", event = "screenChanged" },
        effect = { kind = "layout", placements = {
            { app = "Safari", screen = "DELL", pos = "right" },
        } },
    })
    ok(okAdd == true, "a screenChanged -> layout rule loads (layout is context-free)")
    local d = rules.describe()
    ok(d[1].effectDesc == "Arrange 1 window", "describe() labels a single-placement layout")
    fake.systemEvent("screenChanged")
    ok(#fake.windowFrameSets == 1 and fake.windowFrameSets[1].id == 7,
        "firing screenChanged applies the layout (Safari moved)")
    -- right half of DELL: x = 1440 + 2560*0.5 = 2720, w = 1280
    ok(approx(fake.windowFrameSets[1].x, 2720) and approx(fake.windowFrameSets[1].w, 1280),
        "the window landed on the right half of the external display")

    -- (f) formOptions feeds the layout editor's pickers
    local fo = rules.formOptions()
    local sawLayout = false
    for _, e in ipairs(fo.effects) do if e.kind == "layout" then sawLayout = true end end
    ok(sawLayout, "formOptions offers the layout effect")
    ok(type(fo.layoutDisplays) == "table" and fo.layoutDisplays[1] == "Built-in"
        and fo.layoutDisplays[2] == "DELL", "formOptions lists the connected displays")
    ok(type(fo.layoutPositions) == "table" and #fo.layoutPositions == 9
        and fo.layoutPositions[1].id == "full" and type(fo.layoutPositions[1].label) == "string",
        "formOptions lists the named snap positions with labels")

    -- cleanup
    rules.load({})
    fake.settings["hammerdeck.rules"] = nil
    fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1 } }
    fake.windows = {}
    fake.windowFrameSets = {}
    ok(fake.liveHandles == 0, "no native handle leaked across the layout tests")
end

-- T37: displaysPresent signal (M2) -- "monitor connected/disconnected" as a named
-- state trigger. The precise form of the coarse screenChanged event: a rule on
-- `displaysPresent becomes "DELL"` fires when THAT monitor connects (membership
-- enter), `leaves` when it disconnects -- so the seed "external monitor" case is
-- expressible by name, with a symmetric disconnect for free.
do
    local rules   = require("platform.rules")
    local signals = require("platform.signals")

    -- docked to the laptop only
    fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1 } }
    fake.settings["hammerdeck.rules"] = nil
    rules.load({})

    -- (a) displaysPresent is a known signal; its value is the connected-display set
    ok(signals.exists("displaysPresent"), "displaysPresent is a registered signal")
    local sig = signals.get("displaysPresent")
    local cur = sig.read()
    ok(type(cur) == "table" and cur[1] == "Built-in", "displaysPresent reads the connected display set")
    ok(sig.match(cur, "Built-in") == true and sig.match(cur, "DELL") == false,
        "membership match: Built-in is present, DELL is not")

    -- (b) a 'becomes' rule fires when THAT monitor connects, not on unrelated changes
    local nB = #fake.notifications
    ok(rules.add({
        on = { type = "state", signal = "displaysPresent", becomes = "DELL" },
        effect = { kind = "notify", title = "Docked", text = "DELL connected" },
    }) == true, "a displaysPresent-becomes rule loads (automated trigger, context-free effect)")
    fake.systemEvent("screenChanged")   -- same set (e.g. a resolution tweak)
    ok(#fake.notifications == nB, "screenChanged with no new display does not fire the connect rule")
    fake.screenList = {
        { x = 0,    y = 0, w = 1440, h = 900,  name = "Built-in", index = 1 },
        { x = 1440, y = 0, w = 2560, h = 1440, name = "DELL",     index = 2 },
    }
    fake.systemEvent("screenChanged")
    ok(#fake.notifications == nB + 1, "DELL connects -> the rule fires (membership enter)")
    fake.systemEvent("screenChanged")
    ok(#fake.notifications == nB + 1, "a further screenChanged with DELL still present does not re-fire")

    -- (c) a 'leaves' rule fires on DISCONNECT; the 'becomes' rule does not
    rules.add({
        on = { type = "state", signal = "displaysPresent", leaves = "DELL" },
        effect = { kind = "notify", title = "Undocked", text = "DELL gone" },
    })
    local nL = #fake.notifications
    fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1 } }
    fake.systemEvent("screenChanged")
    ok(#fake.notifications == nL + 1, "DELL disconnects -> only the 'leaves' rule fires")

    -- (d) formOptions exposes displaysPresent + its candidate displays
    local fo = rules.formOptions()
    local sawDisplays = false
    for _, s in ipairs(fo.signals) do if s == "displaysPresent" then sawDisplays = true end end
    ok(sawDisplays, "formOptions lists displaysPresent as a signal")
    ok(type(fo.signalCandidates.displaysPresent) == "table"
        and fo.signalCandidates.displaysPresent[1] == "Built-in",
        "formOptions offers the connected displays as candidates")

    -- cleanup
    rules.load({})
    fake.settings["hammerdeck.rules"] = nil
    fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1 } }
    ok(fake.liveHandles == 0, "no native handle leaked across the displaysPresent tests")
end

-- T38: the new state signals (M2) -- appearance (scalar), runningApps (membership),
-- powerSource (scalar). Each re-reads on a coarse onSystemEvent and fires on the
-- becomes/leaves transition; formOptions carries each signal's UI metadata so the
-- Rules form needs no per-signal Swift code.
do
    local rules   = require("platform.rules")
    local signals = require("platform.signals")

    fake.settings["hammerdeck.rules"] = nil
    rules.load({})

    -- (a) appearance: a scalar "dark"/"light" signal, fires on the transition
    fake.appearance = "light"
    ok(signals.exists("appearance"), "appearance is a registered signal")
    ok(signals.get("appearance").read() == "light", "appearance reads the current mode")
    local nB = #fake.notifications
    rules.add({ on = { type = "state", signal = "appearance", becomes = "dark" },
                effect = { kind = "notify", title = "Dark" } })
    fake.systemEvent("appearanceChanged")   -- still light
    ok(#fake.notifications == nB, "appearanceChanged with no real change does not fire")
    fake.appearance = "dark"
    fake.systemEvent("appearanceChanged")
    ok(#fake.notifications == nB + 1, "appearance becomes dark -> fires")

    -- (b) runningApps: a membership set signal, "launches"/"quits". Like frontmostApp
    -- it now matches by the stable BUNDLE ID (name as a fallback); the value is a list
    -- of { name, bundleId }.
    rules.load({})
    fake.runningAppInfoList = { { name = "Finder", bundleId = "com.apple.finder" } }
    ok(signals.get("runningApps").match(
        { { name = "Finder", bundleId = "com.apple.finder" },
          { name = "Safari", bundleId = "com.apple.Safari" } }, "com.apple.Safari") == true,
        "runningApps membership matches by bundle id")
    ok(signals.get("runningApps").match(
        { { name = "Finder", bundleId = "com.apple.finder" } }, "Finder") == true,
        "runningApps membership also matches by name (fallback)")
    local nL = #fake.notifications
    rules.add({ on = { type = "state", signal = "runningApps", becomes = "Slack",
                       bundleId = "com.tinyspeck.slackmacgap" },
                effect = { kind = "notify", title = "Slack up" } })
    fake.runningAppInfoList = { { name = "Finder", bundleId = "com.apple.finder" },
                               { name = "Slack",  bundleId = "com.tinyspeck.slackmacgap" } }
    fake.systemEvent("appsChanged")
    ok(#fake.notifications == nL + 1, "Slack launches (matched by bundle id) -> the runningApps rule fires")
    fake.runningAppInfoList = { { name = "Finder", bundleId = "com.apple.finder" } }
    fake.systemEvent("appsChanged")
    ok(#fake.notifications == nL + 1, "Slack quitting does not fire a 'launches' rule")

    -- (c) powerSource: scalar "ac"/"battery"
    rules.load({})
    fake.power = "ac"
    local nP = #fake.notifications
    rules.add({ on = { type = "state", signal = "powerSource", becomes = "battery" },
                effect = { kind = "notify", title = "Unplugged" } })
    fake.power = "battery"
    fake.systemEvent("powerChanged")
    ok(#fake.notifications == nP + 1, "unplugging (powerSource becomes battery) -> fires")

    -- (d) formOptions carries signal metadata (label + transition verbs) for the form
    local fo = rules.formOptions()
    ok(type(fo.signalMeta) == "table", "formOptions includes signalMeta")
    ok(fo.signalMeta.appearance and fo.signalMeta.appearance.label == "Appearance",
        "signalMeta carries a label per signal")
    ok(fo.signalMeta.runningApps and fo.signalMeta.runningApps.enterVerb == "launches",
        "signalMeta carries the transition verbs (runningApps: launches/quits)")
    -- bundleIdMatch rides signalMeta so the host gates its installed-apps app picker on
    -- the signal's capability, not a hardcoded name: true for the app-identity signals,
    -- false (default) for an enum signal like appearance.
    ok(fo.signalMeta.frontmostApp and fo.signalMeta.frontmostApp.bundleIdMatch == true,
        "signalMeta marks frontmostApp as bundleIdMatch")
    ok(fo.signalMeta.runningApps and fo.signalMeta.runningApps.bundleIdMatch == true,
        "signalMeta marks runningApps as bundleIdMatch")
    ok(fo.signalMeta.appearance and fo.signalMeta.appearance.bundleIdMatch == false,
        "signalMeta marks an enum signal (appearance) as NOT bundleIdMatch")
    -- goneOnLeave rides signalMeta so the host can warn when a from-trigger effect
    -- binds on a leave edge whose entity is gone (runningApps quits, displaysPresent
    -- disconnects) -- but NOT frontmostApp, whose "loses focus" keeps the app alive.
    ok(fo.signalMeta.runningApps and fo.signalMeta.runningApps.goneOnLeave == true,
        "signalMeta marks runningApps goneOnLeave (a quit app is gone)")
    ok(fo.signalMeta.displaysPresent and fo.signalMeta.displaysPresent.goneOnLeave == true,
        "signalMeta marks displaysPresent goneOnLeave (a disconnected display is gone)")
    ok(fo.signalMeta.frontmostApp and not fo.signalMeta.frontmostApp.goneOnLeave,
        "signalMeta does NOT mark frontmostApp goneOnLeave (losing focus keeps it alive)")
    -- timing subtitle (the verb-popover footgun-killer) rides signalMeta too
    ok(fo.signalMeta.frontmostApp and fo.signalMeta.frontmostApp.leaveWhen == "the moment you click away",
        "signalMeta carries the per-edge timing copy (frontmostApp leaveWhen)")
    ok(type(fo.signalCandidates.powerSource) == "table"
        and fo.signalCandidates.powerSource[1] == "ac",
        "powerSource offers ac/battery as candidates")

    -- cleanup
    rules.load({})
    fake.settings["hammerdeck.rules"] = nil
    fake.appearance = "light"; fake.runningAppInfoList = {}; fake.power = "ac"
    ok(fake.liveHandles == 0, "no native handle leaked across the new-signal tests")
end

-- T39: curated atomic effects (M3) -- runShortcut (the Shortcuts escape hatch),
-- openURL, lockScreen. All context-free, so they validate + fire on automated
-- triggers and the form's Do dropdown offers them.
do
    local effects = require("platform.effects")
    local rules   = require("platform.rules")

    fake.settings["hammerdeck.rules"] = nil
    rules.load({})

    -- context-free + validated
    ok(effects.requiresContext({ kind = "runShortcut", name = "X" }) == false, "runShortcut is context-free")
    ok(effects.requiresContext({ kind = "openURL", url = "x" }) == false, "openURL is context-free")
    ok(effects.requiresContext({ kind = "lockScreen" }) == false, "lockScreen is context-free")
    ok(pcall(effects.validate, { kind = "runShortcut" }) == false, "runShortcut requires a name")
    ok(pcall(effects.validate, { kind = "openURL" }) == false, "openURL requires a url")
    ok(pcall(effects.validate, { kind = "lockScreen" }) == true, "lockScreen needs no params")

    -- dispatch routes to the adapter
    local nS = #fake.shortcutsRun
    effects.dispatch({ kind = "runShortcut", name = "Wind Down" })
    ok(#fake.shortcutsRun == nS + 1 and fake.shortcutsRun[#fake.shortcutsRun] == "Wind Down",
        "runShortcut dispatch runs the named Shortcut")
    local nU = #fake.openedUrls
    effects.dispatch({ kind = "openURL", url = "https://hammerdeck.app" })
    ok(#fake.openedUrls == nU + 1, "openURL dispatch opens the url")
    local nL = fake.actions.lock
    effects.dispatch({ kind = "lockScreen" })
    ok(fake.actions.lock == nL + 1, "lockScreen dispatch locks the screen")

    -- startScreensaver: a param-free context-free effect (sibling of lockScreen)
    ok(effects.requiresContext({ kind = "startScreensaver" }) == false, "startScreensaver is context-free")
    ok(pcall(effects.validate, { kind = "startScreensaver" }) == true, "startScreensaver needs no params")
    ok(effects.describe({ kind = "startScreensaver" }) == "Start the screensaver", "describe labels startScreensaver")
    local nSS = fake.actions.screensaver
    effects.dispatch({ kind = "startScreensaver" })
    ok(fake.actions.screensaver == nSS + 1, "startScreensaver dispatch starts the screensaver")

    -- speak: a context-free parameterized effect (a spoken sibling of notify)
    ok(effects.requiresContext({ kind = "speak", text = "hi" }) == false, "speak is context-free")
    ok(pcall(effects.validate, { kind = "speak", text = "hello" }) == true, "speak validates with text")
    ok(pcall(effects.validate, { kind = "speak" }) == false, "speak requires text")
    ok(pcall(effects.validate, { kind = "speak", text = "" }) == false, "speak rejects empty text")
    ok(effects.describe({ kind = "speak", text = "Standup" }) == 'Say "Standup"', "describe labels a speak effect")
    local nSp = #fake.spokenTexts
    effects.dispatch({ kind = "speak", text = "Battery low" })
    ok(#fake.spokenTexts == nSp + 1 and fake.spokenTexts[#fake.spokenTexts] == "Battery low",
        "speak dispatch says the text")

    -- emptyTrash / eject: param-free context-free system effects
    ok(effects.requiresContext({ kind = "emptyTrash" }) == false, "emptyTrash is context-free")
    ok(effects.requiresContext({ kind = "eject" }) == false, "eject is context-free")
    ok(pcall(effects.validate, { kind = "emptyTrash" }) == true, "emptyTrash needs no params")
    ok(pcall(effects.validate, { kind = "eject" }) == true, "eject needs no params")
    ok(effects.describe({ kind = "emptyTrash" }) == "Empty the Trash", "describe labels emptyTrash")
    ok(effects.describe({ kind = "eject" }) == "Eject external disks", "describe labels eject")
    local nT = fake.trashEmptied
    fake.trashReturn = 3
    local okT, noteT = effects.dispatch({ kind = "emptyTrash" })
    ok(fake.trashEmptied == nT + 1, "emptyTrash dispatch empties the trash")
    ok(okT == true and noteT == "emptied 3 items", "emptyTrash surfaces the count as a note")
    fake.trashReturn = 0   -- already empty: clean success, no note
    local okT0, noteT0 = effects.dispatch({ kind = "emptyTrash" })
    ok(okT0 == true and noteT0 == nil, "empty Trash is a clean success with no note")
    fake.trashReturn = -1  -- found items, removed none: a Full Disk Access denial
    local okTf, noteTf = effects.dispatch({ kind = "emptyTrash" })
    ok(okTf == false and noteTf:find("Full Disk Access"), "emptyTrash -1 surfaces a real failure")
    fake.trashReturn = 3   -- restore default
    local nEj = fake.ejected
    fake.ejectReturn = 1
    local okE, noteE = effects.dispatch({ kind = "eject" })
    ok(fake.ejected == nEj + 1, "eject dispatch ejects disks")
    ok(okE == true and noteE == "ejected 1 disk", "eject surfaces the count as a note")
    fake.ejectReturn = -1  -- disks present but all busy
    local okEf, noteEf = effects.dispatch({ kind = "eject" })
    ok(okEf == false and noteEf:find("busy"), "eject -1 surfaces a real failure")
    fake.ejectReturn = 1   -- restore default

    -- setAppearance / volume / mediaKey: the three system state-changers demoted
    -- from thin standalone features to grouped rules atoms. Each carries one enum
    -- param the guided form's sub-picker sets; all context-free.
    ok(effects.requiresContext({ kind = "setAppearance", mode = "dark" }) == false, "setAppearance is context-free")
    ok(pcall(effects.validate, { kind = "setAppearance", mode = "dark" }) == true, "setAppearance validates a mode")
    ok(pcall(effects.validate, { kind = "setAppearance" }) == false, "setAppearance requires a mode")
    ok(pcall(effects.validate, { kind = "setAppearance", mode = "sepia" }) == false, "setAppearance rejects a bad mode")
    ok(effects.describe({ kind = "setAppearance", mode = "dark" }) == "Switch to dark", "describe labels setAppearance dark")
    ok(effects.describe({ kind = "setAppearance", mode = "toggle" }) == "Toggle dark mode", "describe labels setAppearance toggle")
    local nA = #fake.appearanceSet
    effects.dispatch({ kind = "setAppearance", mode = "light" })
    ok(#fake.appearanceSet == nA + 1 and fake.appearanceSet[#fake.appearanceSet] == "light",
        "setAppearance dispatch sets the appearance")

    ok(effects.requiresContext({ kind = "volume", op = "up" }) == false, "volume is context-free")
    ok(pcall(effects.validate, { kind = "volume", op = "mute" }) == true, "volume validates an op")
    ok(pcall(effects.validate, { kind = "volume" }) == false, "volume requires an op")
    ok(pcall(effects.validate, { kind = "volume", op = "max" }) == false, "volume rejects a bad op")
    ok(effects.describe({ kind = "volume", op = "mute" }) == "Toggle mute", "describe labels volume mute")
    fake.volume = 50; fake.muted = false
    effects.dispatch({ kind = "volume", op = "up" })
    ok(fake.volume == 60, "volume up nudges +10")
    effects.dispatch({ kind = "volume", op = "down" })
    ok(fake.volume == 50, "volume down nudges -10")
    effects.dispatch({ kind = "volume", op = "mute" })
    ok(fake.muted == true, "volume mute toggles mute")
    fake.volumeReturn = -1   -- AppleScript error: adjustVolume returns -1
    local okVf, noteVf = effects.dispatch({ kind = "volume", op = "up" })
    ok(okVf == false and noteVf ~= nil, "volume -1 surfaces a real failure, not a lying green")
    fake.volumeReturn = nil   -- restore

    ok(effects.requiresContext({ kind = "mediaKey", key = "playpause" }) == false, "mediaKey is context-free")
    ok(pcall(effects.validate, { kind = "mediaKey", key = "next" }) == true, "mediaKey validates a key")
    ok(pcall(effects.validate, { kind = "mediaKey" }) == false, "mediaKey requires a key")
    ok(pcall(effects.validate, { kind = "mediaKey", key = "rewind" }) == false, "mediaKey rejects a bad key")
    ok(effects.describe({ kind = "mediaKey", key = "previous" }) == "Previous track", "describe labels mediaKey previous")
    fake.mediaKeys = {}
    effects.dispatch({ kind = "mediaKey", key = "playpause" })
    ok(#fake.mediaKeys == 1 and fake.mediaKeys[1] == "playpause", "mediaKey dispatch posts the transport key")

    -- end-to-end on an automated trigger: on wake -> run a Shortcut
    rules.add({ on = { type = "event", event = "wake" },
                effect = { kind = "runShortcut", name = "Morning" } })
    ok(rules.describe()[1].effectDesc == 'Run Shortcut "Morning"', "describe labels a runShortcut effect")
    local nS2 = #fake.shortcutsRun
    fake.systemEvent("wake")
    ok(#fake.shortcutsRun == nS2 + 1, "on wake -> the Shortcut runs")

    -- the Do dropdown offers all three (context-free survive automatedOnly)
    local seen = {}
    for _, e in ipairs(effects.catalog(true)) do seen[e.kind] = true end
    ok(seen.runShortcut and seen.openURL and seen.lockScreen,
        "catalog offers runShortcut + openURL + lockScreen on automated triggers")
    ok(seen.setAppearance and seen.volume and seen.mediaKey,
        "catalog offers the appearance / volume / media atoms on automated triggers")

    rules.load({}); fake.settings["hammerdeck.rules"] = nil
    ok(fake.liveHandles == 0, "no native handle leaked across the effect tests")
end

-- T39b: solidWallpaper effect -- paint a solid color on a chosen display; context-
-- free, and its `display` may be a literal/category OR drawn from the trigger
-- ("the connecting display", via the effects.TRIGGER_DISPLAY sentinel).
do
    local effects = require("platform.effects")
    local rules   = require("platform.rules")
    fake.settings["hammerdeck.rules"] = nil
    rules.load({})

    -- context-free + validated (needs a #RRGGBB color and a non-empty display)
    ok(effects.requiresContext({ kind = "solidWallpaper", color = "#FFFFFF", display = "all" }) == false,
        "solidWallpaper is context-free")
    ok(pcall(effects.validate, { kind = "solidWallpaper", display = "all" }) == false,
        "solidWallpaper requires a color")
    ok(pcall(effects.validate, { kind = "solidWallpaper", color = "white", display = "all" }) == false,
        "solidWallpaper rejects a non-#RRGGBB color")
    ok(pcall(effects.validate, { kind = "solidWallpaper", color = "#FFFFFF" }) == false,
        "solidWallpaper requires a display")
    ok(pcall(effects.validate, { kind = "solidWallpaper", color = "#FFFFFF", display = "all" }) == true,
        "solidWallpaper with a #RRGGBB color + display validates")

    -- dispatch routes to the adapter with a LITERAL display name
    local nW = #fake.wallpaperColors
    effects.dispatch({ kind = "solidWallpaper", color = "#FFFFFF", display = "DELL U2720Q" })
    local w = fake.wallpaperColors[#fake.wallpaperColors]
    ok(#fake.wallpaperColors == nW + 1 and w.hex == "#FFFFFF" and w.target == "DELL U2720Q",
        "solidWallpaper dispatch paints the named display")

    -- from-trigger: the sentinel resolves to context.display
    effects.dispatch({ kind = "solidWallpaper", color = "#000000", display = effects.TRIGGER_DISPLAY },
        { display = "Paperlike H D" })
    local w2 = fake.wallpaperColors[#fake.wallpaperColors]
    ok(w2.hex == "#000000" and w2.target == "Paperlike H D",
        "solidWallpaper resolves the from-trigger sentinel from the context")

    -- from-trigger with NO context display -> failure, nothing painted
    local nW2 = #fake.wallpaperColors
    local okNo = effects.dispatch({ kind = "solidWallpaper", color = "#FFFFFF", display = effects.TRIGGER_DISPLAY })
    ok(okNo == false and #fake.wallpaperColors == nW2,
        "solidWallpaper from-trigger with no connecting display does nothing")

    -- describe
    ok(effects.describe({ kind = "solidWallpaper", color = "#FFFFFF", display = "external" })
        == "Set wallpaper white on external displays", "describe labels a literal-display solidWallpaper")
    ok(effects.describe({ kind = "solidWallpaper", color = "#FFFFFF", display = effects.TRIGGER_DISPLAY })
        == "Set wallpaper white on the triggering display", "describe labels a from-trigger solidWallpaper")

    -- end-to-end: "Paperlike H D connects" -> paint THE connecting display white.
    -- triggerContext derives {display = becomes}, so the sentinel resolves to it.
    local _, sid = rules.add({
        on = { type = "state", signal = "displaysPresent", becomes = "Paperlike H D" },
        effect = { kind = "solidWallpaper", color = "#FFFFFF", display = effects.TRIGGER_DISPLAY } })
    local nW3 = #fake.wallpaperColors
    ok(rules.fire(sid) == true, "a solidWallpaper rule fires (Test)")
    local w3 = fake.wallpaperColors[#fake.wallpaperColors]
    ok(#fake.wallpaperColors == nW3 + 1 and w3.hex == "#FFFFFF" and w3.target == "Paperlike H D",
        "the connecting display name flows from the rule's condition into the effect")

    -- the Do dropdown offers it on automated triggers
    local seen = {}
    for _, e in ipairs(effects.catalog(true)) do seen[e.kind] = true end
    ok(seen.solidWallpaper, "catalog offers solidWallpaper on automated triggers")

    rules.load({}); fake.settings["hammerdeck.rules"] = nil
    ok(fake.liveHandles == 0, "no native handle leaked across the solidWallpaper tests")
end

-- T39b2: setWallpaperImage effect -- the sibling of solidWallpaper that paints a
-- photo (adapter.setWallpaper) instead of a flat color; same display param model
-- (literal / category / from-trigger), context-free.
do
    local effects = require("platform.effects")
    fake.settings["hammerdeck.rules"] = nil

    ok(effects.requiresContext({ kind = "setWallpaperImage", image = "/x.jpg", display = "all" }) == false,
        "setWallpaperImage is context-free")
    ok(pcall(effects.validate, { kind = "setWallpaperImage", display = "all" }) == false,
        "setWallpaperImage requires an image path")
    ok(pcall(effects.validate, { kind = "setWallpaperImage", image = "/x.jpg" }) == false,
        "setWallpaperImage requires a display")
    ok(pcall(effects.validate, { kind = "setWallpaperImage", image = "/x.jpg", display = "all" }) == true,
        "setWallpaperImage with an image + display validates")

    -- dispatch routes to adapter.setWallpaper(path, target)
    local nW = #fake.wallpapers
    effects.dispatch({ kind = "setWallpaperImage", image = "/Users/me/Pictures/sunset.jpg", display = "DELL U2720Q" })
    ok(#fake.wallpapers == nW + 1
        and fake.wallpapers[#fake.wallpapers] == "/Users/me/Pictures/sunset.jpg"
        and fake.wallpaperModes[#fake.wallpaperModes] == "DELL U2720Q",
        "setWallpaperImage dispatch sets the photo on the named display")

    -- from-trigger sentinel resolves from context.display; missing context -> fail
    effects.dispatch({ kind = "setWallpaperImage", image = "/p.jpg", display = effects.TRIGGER_DISPLAY },
        { display = "Paperlike H D" })
    ok(fake.wallpaperModes[#fake.wallpaperModes] == "Paperlike H D",
        "setWallpaperImage resolves the from-trigger display")
    local nW2 = #fake.wallpapers
    ok(effects.dispatch({ kind = "setWallpaperImage", image = "/p.jpg", display = effects.TRIGGER_DISPLAY }) == false
        and #fake.wallpapers == nW2,
        "setWallpaperImage from-trigger with no connecting display does nothing")

    -- describe shows the file NAME, not the full path
    ok(effects.describe({ kind = "setWallpaperImage", image = "/Users/me/Pictures/sunset.jpg", display = "external" })
        == "Set wallpaper sunset.jpg on external displays", "describe labels setWallpaperImage by basename")
    ok(effects.describe({ kind = "setWallpaperImage", image = "/a/b.png", display = effects.TRIGGER_DISPLAY })
        == "Set wallpaper b.png on the triggering display", "describe: from-trigger setWallpaperImage")

    local seen = {}
    for _, e in ipairs(effects.catalog(true)) do seen[e.kind] = true end
    ok(seen.setWallpaperImage, "catalog offers setWallpaperImage on automated triggers")
end

-- T39b3: moveAppToDisplay effect -- relocate an app's window to another display
-- KEEPING its size (vs layout, which resizes). Reuses listWindows/screenFrames/
-- setWindowFrame; context-free; app/display may be from-trigger.
do
    local effects = require("platform.effects")
    fake.settings["hammerdeck.rules"] = nil
    fake.screenList = {
        { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1, builtin = true },
        { x = 1440, y = 0, w = 2560, h = 1440, name = "DELL U2720Q", index = 2 },
    }
    fake.windows = { { id = 7, appName = "Slack", x = 100, y = 120, w = 400, h = 300, title = "Slack" } }
    fake.windowFrameSets = {}

    ok(effects.requiresContext({ kind = "moveAppToDisplay", app = "Slack", display = "DELL U2720Q" }) == false,
        "moveAppToDisplay is context-free")
    ok(pcall(effects.validate, { kind = "moveAppToDisplay", app = "Slack" }) == false,
        "moveAppToDisplay requires a display")
    ok(pcall(effects.validate, { kind = "moveAppToDisplay", display = "DELL U2720Q" }) == false,
        "moveAppToDisplay requires an app")
    ok(pcall(effects.validate, { kind = "moveAppToDisplay", app = "Slack", display = "DELL U2720Q" }) == true,
        "moveAppToDisplay with app + display validates")

    -- dispatch keeps the SIZE (400x300) and preserves the within-screen offset:
    -- from Built-in (0,0) offset (100,120) -> DELL (1440,0) => (1540,120).
    ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Slack", display = "DELL U2720Q" }) == true,
        "moveAppToDisplay moves a matching window")
    local s = fake.windowFrameSets[#fake.windowFrameSets]
    ok(s and s.id == 7 and s.x == 1540 and s.y == 120 and s.w == 400 and s.h == 300,
        "moveAppToDisplay relocates to the display keeping the window's size + offset")

    -- a disconnected/typo'd display -> failure, no move
    fake.windowFrameSets = {}
    ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Slack", display = "Ghost" }) == false
        and #fake.windowFrameSets == 0, "moveAppToDisplay fails when the display isn't connected")

    -- no matching window -> failure
    ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Nope", display = "DELL U2720Q" }) == false,
        "moveAppToDisplay fails when no window matches the app")

    -- from-trigger: app + display resolve from context
    fake.windowFrameSets = {}
    effects.dispatch({ kind = "moveAppToDisplay", app = effects.TRIGGER_APP, display = effects.TRIGGER_DISPLAY },
        { app = "Slack", display = "DELL U2720Q" })
    ok(fake.windowFrameSets[#fake.windowFrameSets] and fake.windowFrameSets[#fake.windowFrameSets].x == 1540,
        "moveAppToDisplay resolves from-trigger app + display")

    ok(effects.describe({ kind = "moveAppToDisplay", app = "Slack", display = "DELL U2720Q" })
        == "Move Slack to DELL U2720Q", "describe labels moveAppToDisplay")

    -- restore the single-screen default so a later screen-reading test isn't
    -- polluted by this block's 2-screen config (matches the layout block's teardown)
    fake.windows = {}; fake.windowFrameSets = {}
    fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1, builtin = true } }
end

-- T39b4: app-target effects match by BUNDLE ID when the rule carries one (the
-- stable key, set when the user picks from the installed-apps list) -- falling back
-- to the display name for legacy rules + the from-trigger path. Proves (a) the
-- minimize/hide/quit trio pass the bundle id to the adapter, and (b) moveAppToDisplay
-- matches a window by bundleID even when its localized appName differs.
do
    local effects = require("platform.effects")
    fake.settings["hammerdeck.rules"] = nil

    -- minimize: with appBundleId set, the adapter is called with the BUNDLE ID.
    local nM = #fake.minimized
    effects.dispatch({ kind = "minimizeApp", app = "Slack", appBundleId = "com.tinyspeck.slackmacgap" })
    ok(#fake.minimized == nM + 1 and fake.minimized[#fake.minimized] == "com.tinyspeck.slackmacgap",
        "minimizeApp prefers the bundle id when the rule has one")

    -- no appBundleId -> the display name (legacy / from-trigger fallback).
    effects.dispatch({ kind = "minimizeApp", app = "Slack" })
    ok(fake.minimized[#fake.minimized] == "Slack",
        "minimizeApp falls back to the name with no bundle id")

    -- an empty-string appBundleId is treated as absent (name fallback), not "".
    effects.dispatch({ kind = "quitApp", app = "Slack", appBundleId = "" })
    ok(fake.quit[#fake.quit] == "Slack", "an empty appBundleId falls back to the name")

    -- moveAppToDisplay: match by bundleID even when the window's appName differs from
    -- the rule's stored display name (locale/rename drift -- exactly what bundle-id
    -- identity fixes).
    fake.screenList = {
        { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1, builtin = true },
        { x = 1440, y = 0, w = 2560, h = 1440, name = "DELL U2720Q", index = 2 },
    }
    fake.windows = { { id = 9, appName = "Slack (renamed)", bundleID = "com.tinyspeck.slackmacgap",
                       x = 100, y = 120, w = 400, h = 300, title = "Slack" } }
    fake.windowFrameSets = {}
    ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Slack",
            appBundleId = "com.tinyspeck.slackmacgap", display = "DELL U2720Q" }) == true,
        "moveAppToDisplay matches a window by bundle id despite a different appName")
    local s = fake.windowFrameSets[#fake.windowFrameSets]
    ok(s and s.id == 9 and s.x == 1540, "the bundle-id-matched window is the one moved")

    -- neither name nor bundle id matches -> no move (bundleID isn't a wildcard).
    fake.windowFrameSets = {}
    ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Nope",
            appBundleId = "com.example.nope", display = "DELL U2720Q" }) == false
        and #fake.windowFrameSets == 0,
        "moveAppToDisplay does not move when neither name nor bundle id matches")

    -- strict: with a bundle id, a DIFFERENT app that merely shares the display name
    -- is NOT moved -- bundle id is authoritative, no name over-match.
    fake.windows = { { id = 5, appName = "Slack", bundleID = "com.other.slackclone",
                       x = 10, y = 10, w = 200, h = 200, title = "x" } }
    fake.windowFrameSets = {}
    ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Slack",
            appBundleId = "com.tinyspeck.slackmacgap", display = "DELL U2720Q" }) == false
        and #fake.windowFrameSets == 0,
        "moveAppToDisplay with a bundle id ignores a same-named app of a different bundle")

    fake.windows = {}; fake.windowFrameSets = {}
    fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1, builtin = true } }
end

-- T39b5: launchApp effect (Open an app) -- the positive counterpart to quit. Unlike
-- minimize/hide/quit (which act on a RUNNING app by name or id), launch needs the
-- BUNDLE ID (the only launchable identifier), so validate requires appBundleId; `app`
-- is just the readable name for the sentence/log. Context-free, so it can fire on an
-- automated trigger ("open Slack at 9am").
do
    local effects = require("platform.effects")
    fake.settings["hammerdeck.rules"] = nil

    ok(effects.requiresContext({ kind = "launchApp", app = "Slack", appBundleId = "com.tinyspeck.slackmacgap" }) == false,
        "launchApp is context-free (fires on an automated trigger)")
    -- validate needs BOTH the bundle id (launch key) and a name (for the sentence).
    ok(pcall(effects.validate, { kind = "launchApp", app = "Slack" }) == false,
        "launchApp requires a bundle id, not just a name")
    ok(pcall(effects.validate, { kind = "launchApp", appBundleId = "com.tinyspeck.slackmacgap" }) == false,
        "launchApp requires an app name for the sentence")
    ok(pcall(effects.validate, { kind = "launchApp", app = "Slack", appBundleId = "com.tinyspeck.slackmacgap" }) == true,
        "launchApp with a name + bundle id validates")
    -- no @trigger:app form (launch targets a specific installed app) -- a hand-authored
    -- one is rejected, not silently launched while the sentence reads the raw sentinel.
    ok(pcall(effects.validate, { kind = "launchApp", app = effects.TRIGGER_APP, appBundleId = "x" }) == false,
        "launchApp rejects the @trigger:app sentinel")

    -- dispatch launches by the BUNDLE ID (not the name).
    local nL = #fake.launchedApps
    ok(effects.dispatch({ kind = "launchApp", app = "Slack", appBundleId = "com.tinyspeck.slackmacgap" }) == true,
        "launchApp dispatch launches the app")
    ok(#fake.launchedApps == nL + 1 and fake.launchedApps[#fake.launchedApps] == "com.tinyspeck.slackmacgap",
        "launchApp passes the bundle id to launchOrFocusApp")

    -- a bundle id no installed app carries -> a real failure (not a lying green fire).
    fake.uninstalledApps = { ["com.example.ghost"] = true }
    ok(effects.dispatch({ kind = "launchApp", app = "Ghost", appBundleId = "com.example.ghost" }) == false,
        "launchApp fails when no installed app carries the bundle id")
    fake.uninstalledApps = nil

    -- describe reads "Open <app>" (the readable name, never the raw bundle id).
    ok(effects.describe({ kind = "launchApp", app = "Slack", appBundleId = "com.tinyspeck.slackmacgap" })
        == "Open Slack", "describe labels launchApp by name")

    -- it appears in the Do dropdown catalog (context-free -> survives automatedOnly).
    local found = false
    for _, e in ipairs(effects.catalog(true)) do if e.kind == "launchApp" then found = true end end
    ok(found, "launchApp is offered in the effects catalog for automated triggers")
end

-- T39c: minimizeApp effect -- minimize a named app's window; context-free, and its
-- `app` may be drawn from the trigger ("the app from the trigger"). The SECOND
-- context-bound effect, and the first that binds on the `leaves` edge (an app
-- losing focus) -- proving from-trigger isn't display/becomes-only.
do
    local effects = require("platform.effects")
    local rules   = require("platform.rules")
    fake.settings["hammerdeck.rules"] = nil
    rules.load({})

    -- context-free + validated (needs a non-empty app)
    ok(effects.requiresContext({ kind = "minimizeApp", app = "Slack" }) == false,
        "minimizeApp is context-free")
    ok(pcall(effects.validate, { kind = "minimizeApp" }) == false,
        "minimizeApp requires an app")
    ok(pcall(effects.validate, { kind = "minimizeApp", app = "Slack" }) == true,
        "minimizeApp with an app validates")

    -- dispatch routes to the adapter with a LITERAL app name
    local nM = #fake.minimized
    effects.dispatch({ kind = "minimizeApp", app = "Slack" })
    ok(#fake.minimized == nM + 1 and fake.minimized[#fake.minimized] == "Slack",
        "minimizeApp dispatch minimizes the named app")

    -- from-trigger: the sentinel resolves to context.app
    effects.dispatch({ kind = "minimizeApp", app = effects.TRIGGER_APP }, { app = "Notes" })
    ok(fake.minimized[#fake.minimized] == "Notes",
        "minimizeApp resolves the from-trigger sentinel from the context")

    -- from-trigger with NO context app -> failure, nothing minimized
    local nM2 = #fake.minimized
    local okNo = effects.dispatch({ kind = "minimizeApp", app = effects.TRIGGER_APP })
    ok(okNo == false and #fake.minimized == nM2,
        "minimizeApp from-trigger with no app does nothing")

    -- describe
    ok(effects.describe({ kind = "minimizeApp", app = "Slack" }) == "Minimize Slack",
        "describe labels a literal-app minimizeApp")
    ok(effects.describe({ kind = "minimizeApp", app = effects.TRIGGER_APP }) == "Minimize the triggering app",
        "describe labels a from-trigger minimizeApp")

    -- end-to-end on the LEAVES edge: "frontmost app leaves Slack" -> minimize Slack.
    -- triggerContext yields {app = leaves}, proving from-trigger works on `leaves`,
    -- not just `becomes` (the generalization the focus-loss case forced).
    local _, mid = rules.add({
        on = { type = "state", signal = "frontmostApp", leaves = "Slack" },
        effect = { kind = "minimizeApp", app = effects.TRIGGER_APP } })
    local nM3 = #fake.minimized
    ok(rules.fire(mid) == true, "a minimizeApp rule fires (Test)")
    ok(#fake.minimized == nM3 + 1 and fake.minimized[#fake.minimized] == "Slack",
        "the app that lost focus flows from the rule's leaves condition into the effect")

    -- usesTriggerContext + describe.contextBound -- the host hides "Test" for a
    -- reactive (from-trigger) rule, since a manual fire has no live trigger context.
    ok(effects.usesTriggerContext({ kind = "minimizeApp", app = effects.TRIGGER_APP }) == true,
        "usesTriggerContext detects a from-trigger param")
    ok(effects.usesTriggerContext({ kind = "minimizeApp", app = "Slack" }) == false,
        "usesTriggerContext is false for a literal param")
    ok(effects.usesTriggerContext({ kind = "chain", effects = {
        { kind = "lockScreen" },
        { kind = "solidWallpaper", color = "#FFFFFF", display = effects.TRIGGER_DISPLAY } } }) == true,
        "usesTriggerContext recurses into chain steps")
    do
        local row
        for _, r in ipairs(rules.describe()) do if r.id == mid then row = r end end
        ok(row and row.contextBound == true, "describe flags a from-trigger rule as contextBound")
    end

    -- hideApp / quitApp: same {app} shape + context-binding, different verb.
    ok(pcall(effects.validate, { kind = "hideApp" }) == false, "hideApp requires an app")
    ok(pcall(effects.validate, { kind = "quitApp", app = "Mail" }) == true, "quitApp with an app validates")
    ok(effects.requiresContext({ kind = "hideApp", app = "Mail" }) == false, "hideApp is context-free")
    local nH = #fake.hidden
    effects.dispatch({ kind = "hideApp", app = "Mail" })
    ok(#fake.hidden == nH + 1 and fake.hidden[#fake.hidden] == "Mail", "hideApp dispatch hides the app")
    local nQ = #fake.quit
    effects.dispatch({ kind = "quitApp", app = effects.TRIGGER_APP }, { app = "Notes" })
    ok(#fake.quit == nQ + 1 and fake.quit[#fake.quit] == "Notes", "quitApp resolves @trigger:app from context")
    ok(effects.describe({ kind = "hideApp", app = "Mail" }) == "Hide Mail", "describe labels hideApp")
    ok(effects.describe({ kind = "quitApp", app = effects.TRIGGER_APP }) == "Quit the triggering app",
        "describe labels a from-trigger quitApp")

    -- the Do dropdown offers them on automated triggers
    local seen = {}
    for _, e in ipairs(effects.catalog(true)) do seen[e.kind] = true end
    ok(seen.minimizeApp and seen.hideApp and seen.quitApp,
        "catalog offers minimizeApp + hideApp + quitApp on automated triggers")

    rules.load({}); fake.settings["hammerdeck.rules"] = nil
    ok(fake.liveHandles == 0, "no native handle leaked across the app-target effect tests")
end

-- T40: chain effect (M3) -- run several sub-effects IN ORDER; context-free iff every
-- step is; partial-success aggregation names the failed steps --------------------
do
    local effects = require("platform.effects")
    local rules   = require("platform.rules")
    fake.settings["hammerdeck.rules"] = nil
    rules.load({})

    -- validate: needs >= 1 step, each a valid effect, no nesting
    ok(pcall(effects.validate, { kind = "chain", effects = {} }) == false,
        "a chain needs at least one step")
    ok(pcall(effects.validate, { kind = "chain", effects = {
        { kind = "chain", effects = { { kind = "lockScreen" } } } } }) == false,
        "a chain step cannot itself be a chain (no nesting)")
    ok(pcall(effects.validate, { kind = "chain", effects = { { kind = "notify" } } }) == false,
        "a chain rejects an invalid step (notify needs a title)")
    ok(pcall(effects.validate, { kind = "chain", effects = {
        { kind = "notify", title = "hi" }, { kind = "runShortcut", name = "DND" } } }) == true,
        "a chain of valid steps validates")

    -- context policy: context-free iff EVERY step is
    ok(effects.requiresContext({ kind = "chain", effects = {
        { kind = "notify", title = "hi" }, { kind = "lockScreen" } } }) == false,
        "a chain of context-free steps is context-free")
    ok(effects.requiresContext({ kind = "chain", effects = {
        { kind = "notify", title = "hi" }, { kind = "command", feature = "ghost", action = "x" } } }) == true,
        "a chain with a context-requiring step requires context")

    -- describe lists the steps (the compact list-row / fire-log form)
    ok(effects.describe({ kind = "chain", effects = {
        { kind = "notify", title = "hi" }, { kind = "runShortcut", name = "DND" } } })
        == '2 steps: Notify "hi" -> Run Shortcut "DND"', "describe lists the chain steps")
    -- pronoun mode renders the chain as one flowing sentence (the read-back),
    -- lowercasing each step after the first and joining with ", then ".
    ok(effects.describe({ kind = "chain", effects = {
        { kind = "minimizeApp", app = effects.TRIGGER_APP }, { kind = "notify", title = "Done" } } },
        { pronoun = true })
        == 'Minimize it, then notify "Done"', "describe chain pronoun mode joins with 'then'")

    -- dispatch runs every step IN ORDER
    local nN, nS = #fake.notifications, #fake.shortcutsRun
    ok(effects.dispatch({ kind = "chain", effects = {
        { kind = "notify", title = "one" }, { kind = "runShortcut", name = "two" } } }) == true
        and #fake.notifications == nN + 1 and #fake.shortcutsRun == nS + 1,
        "a chain dispatches every step")

    -- partial: one step fails (layout with no present display) -> ran K/N note
    fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1 } }
    fake.windows = {}
    local okP, noteP = effects.dispatch({ kind = "chain", effects = {
        { kind = "notify", title = "ok" },
        { kind = "layout", placements = { { app = "X", screen = "Ghost", pos = "full" } } } } })
    ok(okP == true and type(noteP) == "string" and noteP:find("1/2", 1, true) ~= nil
        and noteP:find("step 2", 1, true) ~= nil,
        "a partial chain returns a note naming the failed step (ran 1/2)")

    -- every step fails -> (false, reason)
    local okF, reasonF = effects.dispatch({ kind = "chain", effects = {
        { kind = "layout", placements = { { app = "X", screen = "Ghost", pos = "full" } } } } })
    ok(okF == false and reasonF:find("every step failed", 1, true) ~= nil,
        "an all-failed chain reports failure")

    -- end-to-end: on wake -> notify + runShortcut (all context-free, so allowed)
    local nS3 = #fake.shortcutsRun
    ok(rules.add({ on = { type = "event", event = "wake" },
        effect = { kind = "chain", effects = {
            { kind = "notify", title = "morning" }, { kind = "runShortcut", name = "Coffee" } } } }) == true,
        "a chain rule on an automated trigger loads (all steps context-free)")
    fake.systemEvent("wake")
    ok(#fake.shortcutsRun == nS3 + 1, "on wake -> the chain runs its Shortcut step")

    -- context policy backstop: a chain with a context step is REFUSED on an automated trigger
    ok(select(1, rules.add({ on = { type = "event", event = "wake" },
        effect = { kind = "chain", effects = {
            { kind = "command", feature = "ghost", action = "x" } } } })) == false,
        "an automated trigger refuses a chain with a context-requiring step")

    -- the Do dropdown offers chain
    local seen = {}
    for _, e in ipairs(effects.catalog(true)) do seen[e.kind] = true end
    ok(seen.chain, "catalog offers the chain effect")

    rules.load({}); fake.settings["hammerdeck.rules"] = nil
    fake.windows = {}
    ok(fake.liveHandles == 0, "no native handle leaked across the chain tests")
end

-- T40b: rules.sentence -- the plain-language read-back shown live above the rule
-- form (the redesign's comprehension win: a rule reads as one English line, and a
-- from-trigger param reads as "it"). Pure formatting over signals.meta + describe.
do
    local effects = require("platform.effects")
    local rules   = require("platform.rules")

    -- ENTITY signal, leaves edge, app drawn from the trigger -> "it"
    ok(rules.sentence({
        on = { type = "state", signal = "frontmostApp", leaves = "Slack" },
        effect = { kind = "minimizeApp", app = effects.TRIGGER_APP } })
        == "When Slack loses focus, minimize it.",
        "sentence: app loses focus -> minimize it")
    -- ENTITY signal, becomes edge, display from the trigger
    ok(rules.sentence({
        on = { type = "state", signal = "displaysPresent", becomes = "DELL U2720Q" },
        effect = { kind = "solidWallpaper", color = "#FFFFFF", display = effects.TRIGGER_DISPLAY } })
        == "When DELL U2720Q connects, set wallpaper white on it.",
        "sentence: display connects -> wallpaper on it")
    -- PROPERTY signal (no `provides`) reads "the <name> <verb> <value>"
    ok(rules.sentence({
        on = { type = "state", signal = "powerSource", becomes = "battery" },
        effect = { kind = "solidWallpaper", color = "#000000", display = "all" } })
        == "When the power source becomes battery, set wallpaper black on all displays.",
        "sentence: property signal reads 'the X becomes Y'")
    -- PROPERTY signal, LEAVE edge -> "is no longer X" (a bare "leaves battery" is
    -- ungrammatical for a subject-less property; see signals.lua leaveVerb).
    ok(rules.sentence({
        on = { type = "state", signal = "powerSource", leaves = "battery" },
        effect = { kind = "lockScreen" } })
        == "When the power source is no longer battery, lock the screen.",
        "sentence: property leave edge reads 'is no longer'")
    -- a CHAIN effect reads as one flowing line ("..., then ..."), not "N steps: ..."
    ok(rules.sentence({
        on = { type = "state", signal = "frontmostApp", leaves = "Slack" },
        effect = { kind = "chain", effects = {
            { kind = "minimizeApp", app = effects.TRIGGER_APP }, { kind = "notify", title = "Done" } } } })
        == 'When Slack loses focus, minimize it, then notify "Done".',
        "sentence: a chain reads as one flowing line")
    -- event
    ok(rules.sentence({
        on = { type = "event", event = "wake" }, effect = { kind = "notify", title = "Hi" } })
        == 'When the Mac wakes, notify "Hi".', "sentence: event clause")
    -- schedule LEADS the line (no "When") -- both the daily-at and every-N forms
    ok(rules.sentence({
        on = { type = "schedule", at = "18:00" }, effect = { kind = "lockScreen" } })
        == "Every day at 18:00, lock the screen.", "sentence: schedule (at) leads the line")
    ok(rules.sentence({
        on = { type = "schedule", everyMin = 25 }, effect = { kind = "lockScreen" } })
        == "Every 25 minutes, lock the screen.", "sentence: schedule (everyMin) -- the %d branch")
    -- incomplete (no value) -> empty, so the host shows its placeholder
    ok(rules.sentence({
        on = { type = "state", signal = "frontmostApp" }, effect = { kind = "lockScreen" } }) == "",
        "sentence: a missing trigger value -> empty")
    -- the JSON wrapper the host calls
    ok(rules.sentenceJSON('{"on":{"type":"event","event":"sleep"},"effect":{"kind":"lockScreen"}}')
        == "When the Mac sleeps, lock the screen.", "sentenceJSON decodes + composes")
    ok(rules.sentenceJSON("not json") == "", "sentenceJSON: bad input -> empty")

    -- pronoun mode is OPT-IN: the default describe (list row / log) is unchanged.
    ok(effects.describe({ kind = "minimizeApp", app = effects.TRIGGER_APP }) == "Minimize the triggering app",
        "describe default keeps 'the triggering app'")
    ok(effects.describe({ kind = "minimizeApp", app = effects.TRIGGER_APP }, { pronoun = true }) == "Minimize it",
        "describe pronoun mode renders the from-trigger app as 'it'")
end

-- T41: notify delivery channel (M3) -- a notify can target the macOS Notification
-- Center ("system") or the in-app banner ("app", default), with a toast fallback --
do
    local effects = require("platform.effects")

    -- validate: channel is optional, "system" | "app"
    ok(pcall(effects.validate, { kind = "notify", title = "hi", channel = "system" }) == true,
        "notify accepts channel = system")
    ok(pcall(effects.validate, { kind = "notify", title = "hi", channel = "app" }) == true,
        "notify accepts channel = app")
    ok(pcall(effects.validate, { kind = "notify", title = "hi" }) == true,
        "notify channel is optional")
    ok(pcall(effects.validate, { kind = "notify", title = "hi", channel = "pigeon" }) == false,
        "notify rejects an unknown channel")

    -- a system notify is still context-free (safe on automated triggers)
    ok(effects.requiresContext({ kind = "notify", title = "hi", channel = "system" }) == false,
        "a system notify is still context-free")

    -- channel = system -> Notification Center, NOT the in-app banner
    fake.systemNotifyDelivers = true
    local nSys, nApp = #fake.systemNotifications, #fake.notifications
    ok(effects.dispatch({ kind = "notify", title = "sys", channel = "system" }) == true
        and #fake.systemNotifications == nSys + 1 and #fake.notifications == nApp,
        "channel=system delivers to the Notification Center, not the in-app banner")

    -- channel = app (and absent) -> the in-app banner, NOT the system center
    nSys, nApp = #fake.systemNotifications, #fake.notifications
    effects.dispatch({ kind = "notify", title = "app", channel = "app" })
    effects.dispatch({ kind = "notify", title = "default" })
    ok(#fake.notifications == nApp + 2 and #fake.systemNotifications == nSys,
        "channel=app (and absent) shows the in-app banner")

    -- system unavailable (no app bundle, e.g. dev `swift run`) -> falls back + a note
    fake.systemNotifyDelivers = false
    nApp = #fake.notifications
    local okF, noteF = effects.dispatch({ kind = "notify", title = "fb", channel = "system" })
    ok(okF == true and #fake.notifications == nApp + 1
        and type(noteF) == "string" and noteF:find("in-app", 1, true) ~= nil,
        "an undeliverable system notify falls back to the in-app banner with a note")
    fake.systemNotifyDelivers = true
end

print("OK -- " .. passed .. " assertions passed (" .. _VERSION .. ")")
