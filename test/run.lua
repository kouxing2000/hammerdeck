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
local pin = os.date("*t")
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

-- screen name IS the subtext (app name dropped -- the icon carries it), and
-- only when the display is reported (native reports it only on multi-display)
fake.windows = {
    { id = 11, title = "W1", appName = "AppA", bundleID = "com.a", screenName = "Studio Display" },
    { id = 22, title = "W2", appName = "AppB", bundleID = "com.b" },
}
fake.modifiers.alt = true
fake.pressHotkey("tab")
ch = fake.visibleChooser()
ok(ch.choices[1].subText == "Studio Display" and ch.choices[2].subText == nil,
    "screen name is the subtext when reported; nil collapses the row to one line")
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

-- validate rejects malformed specs
ok(not pcall(triggers.validate, { type = "hotkey" }), "validate rejects a hotkey with no key")
ok(not pcall(triggers.validate, { type = "event", event = "nope" }), "validate rejects an unknown event")
ok(not pcall(triggers.validate, { type = "schedule" }), "validate rejects a schedule with no when")

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
local relabelled = jsonlib.asObject(jd("[]")); relabelled.k = 1
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

-- T19: chord triggers -- prefix hotkey arms a follow-key sequence -------------
-- (`triggers` is the file-scope local from T10.)

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
registry.register(require("features.usage_stats"))

-- Re-pin the clock to a fresh morning so this test owns its day arithmetic.
local pin20 = os.date("*t")
pin20.hour, pin20.min, pin20.sec = 9, 0, 0
fake.clockOffset = os.time(pin20) - os.time()
fake.idle = 0

-- pin the storage folder to an absolute path (no ~ expansion) so the CSV
-- paths below stay deterministic; the months live directly under it
fake.settings["hammerdeck.opt.usage_stats.dir"] = "/fake/data/usage"
local day20 = os.date("%Y-%m-%d", fake.now())
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
-- context enrichment: browser domain + editor project fill the CSV column
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

registry.setEnabled("usage_stats", false)
fake.settings["hammerdeck.opt.usage_stats.dir"] = nil
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after usage_stats test")

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

-- T23: site_switcher / "Quick Sites" (a list of favorite sites in a searchable
-- chooser; pick a row -- click, Enter, or cmd+<n> -- to focus that site's tab,
-- open it, or open it as a standalone app window) ----------------------------
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
ok(fake.mousePos.x == 1150 and fake.mousePos.y == 200, "pointer carried at its offset")
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

-- no focused window -> plain alert (trusted)
fake.focusedWindow = nil
fake.pressHotkey("left", AC)
ok(fake.alerts[#fake.alerts]:match("No focused window") ~= nil, "no window alerts plainly")

registry.setEnabled("window_snap", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after window_snap test")

-- T24b: pointer_follows_window (a window move carries the pointer, relative pos) --
-- Reuses window_snap (already registered above) as the mover under test: the
-- follow lives at the ctx.setFocusedWindowFrame seam, so ANY window feature
-- exercises it. Screen 1 = {0,0,1000,800}; "left" snaps to {0,0,500,800}.
registry.register(require("features.pointer_follows_window"))
registry.setEnabled("window_snap", true)
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

registry.setEnabled("pointer_follows_window", false)
registry.setEnabled("window_snap", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after pointer_follows_window test")

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

-- T26: tab_switcher (cross-browser tab switcher, MRU-first) ----------------------
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

-- T29: command_palette (fuzzy launcher over every enabled feature) -------------
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
    ok(r.dayCount == 3, "dayCount counts every day in the range")
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

    ok(r.busiestDay and r.busiestDay.date == "2026-06-20" and r.busiestDay.secs == 5400,
        "busiestDay is the highest-total day")

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
    local rules = require("platform.rules")
    local json  = require("platform.json")

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
        and d[1].triggerDesc:find("wake") and d[1].effectDesc:find("Run m1_auto"),
        "describe() yields {id, enabled, triggerDesc, effectDesc} for the UI")

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

    -- (b) runningApps: a membership set signal, "launches"/"quits"
    rules.load({})
    fake.runningAppList = { "Finder" }
    ok(signals.get("runningApps").match({ "Finder", "Safari" }, "Safari") == true,
        "runningApps uses membership match")
    local nL = #fake.notifications
    rules.add({ on = { type = "state", signal = "runningApps", becomes = "Slack" },
                effect = { kind = "notify", title = "Slack up" } })
    fake.runningAppList = { "Finder", "Slack" }
    fake.systemEvent("appsChanged")
    ok(#fake.notifications == nL + 1, "Slack launches -> the runningApps rule fires")
    fake.runningAppList = { "Finder" }
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
    ok(type(fo.signalCandidates.powerSource) == "table"
        and fo.signalCandidates.powerSource[1] == "ac",
        "powerSource offers ac/battery as candidates")

    -- cleanup
    rules.load({})
    fake.settings["hammerdeck.rules"] = nil
    fake.appearance = "light"; fake.runningAppList = {}; fake.power = "ac"
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

    rules.load({}); fake.settings["hammerdeck.rules"] = nil
    ok(fake.liveHandles == 0, "no native handle leaked across the effect tests")
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

    -- describe lists the steps
    ok(effects.describe({ kind = "chain", effects = {
        { kind = "notify", title = "hi" }, { kind = "runShortcut", name = "DND" } } })
        == '2 steps: Notify "hi" -> Run Shortcut "DND"', "describe lists the chain steps")

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
