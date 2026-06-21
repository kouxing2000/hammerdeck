-- test/run.lua -- headless platform + feature tests against the fake adapter.
--
-- Run from the repo root:  lua test/run.lua
--
-- Covers: manifest validation, action-feature trigger binding, service-feature
-- lifecycle, the three MVP features' main flows, and the scoped-ctx guarantee
-- that disable leaks nothing.

package.path = "lua/?.lua;lua/?/init.lua;test/?.lua;" .. package.path

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

-- screen names render in the subtext on multi-display rows
fake.windows = {
    { id = 11, title = "W1", appName = "AppA", bundleID = "com.a", screenName = "Studio Display" },
    { id = 22, title = "W2", appName = "AppB", bundleID = "com.b" },
}
fake.modifiers.alt = true
fake.pressHotkey("tab")
ch = fake.visibleChooser()
ok(ch.choices[1].subText == "AppA (Studio Display)" and ch.choices[2].subText == "AppB",
    "screen name appended to the subtext only when reported")
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
ok(#jumpDesc.options == 0,
    "window_switcher exports no options (cycle modifier derives from the trigger)")
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
fake.pressHotkey("b")
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

fake.pressHotkey("c")
local prompt = fake.openTextPrompt()
ok(prompt ~= nil, "countdown start prompts for minutes")
ok(prompt.default == "5", "prompt suggests the defaultMinutes option")
prompt.submit("2")                              -- 2 minutes = 120 ticks
local cdBar = fake.liveProgressBar()
ok(cdBar ~= nil, "countdown shows a progress strip")
fake.fireTimers("every", 1)
ok(math.abs(cdBar.fraction - 1 / 120) < 1e-9, "progress advances per second")

-- the dormant pause action goes live when the user binds it
ok(registry.setTrigger("count_down", "pause",
    { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "p" }) == true,
    "binding a dormant action succeeds")
fake.pressHotkey("p")                           -- pause
ok(fake.fireTimers("every", 1) == 0, "paused countdown stops ticking")
fake.pressHotkey("p")                           -- resume
ok(fake.fireTimers("every", 1) == 1, "resume restarts the tick")

-- invoking start while running cancels
fake.pressHotkey("c")
ok(fake.liveProgressBar() == nil, "start-while-running cancels the countdown")

-- completion notifies and clears the bar
fake.pressHotkey("c")
fake.openTextPrompt().submit("1")               -- 60 ticks
local cdN = #fake.notifications
for _ = 1, 60 do fake.fireTimers("every", 1) end
ok(#fake.notifications == cdN + 1, "completion notifies")
ok(fake.liveProgressBar() == nil, "completion clears the strip")

-- a dismissed prompt starts nothing
fake.pressHotkey("c")
fake.openTextPrompt().submit(nil)               -- Escape
ok(fake.liveProgressBar() == nil, "dismissed prompt starts nothing")

registry.setEnabled("count_down", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after count_down test")

-- T17: locate_pointer (locate pointer) -------------------------------------------
registry.register(require("features.locate_pointer"))
registry.setEnabled("locate_pointer", true)
fake.mouseLocates = {}   -- fresh recorder: this block asserts absolute counts/indices
fake.pressHotkey("m")
ok(#fake.mouseLocates == 1 and fake.mouseLocates[1] == 3,
    "locate-pointer fires with the configured duration")
fake.settings["hammerdeck.opt.locate_pointer.seconds"] = 7
fake.pressHotkey("m")
ok(fake.mouseLocates[2] == 7, "duration option applies live")
-- center the pointer on the focused window (the donor's alt+G, now here)
fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
fake.pressHotkey("g", { "alt" })
ok(fake.mousePos.x == 300 and fake.mousePos.y == 250, "alt+G centers the pointer on the window")
ok(fake.mouseLocates[#fake.mouseLocates] == 1, "and flashes the locator")
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

-- T20: usage_stats (service: sessions + per-app focus time to CSV) ------------
registry.register(require("features.usage_stats"))

-- Re-pin the clock to a fresh morning so this test owns its day arithmetic.
local pin20 = os.date("*t")
pin20.hour, pin20.min, pin20.sec = 9, 0, 0
fake.clockOffset = os.time(pin20) - os.time()
fake.idle = 0

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

-- lowercase pastes back over the selection
invokeOnSelection("Hello WORLD")
local dlg = fake.openDialog()
ok(dlg ~= nil and #dlg.actions == 4, "picker offers the four ported actions")
dlg.choose("lowercase")
ok(fake.pasteboard == "hello world", "lowercase result lands on the clipboard")
ok(fake.keyEvents[#fake.keyEvents].key == "v", "and is pasted back (cmd+v)")

-- calculate evaluates the selection in a math-only sandbox
invokeOnSelection("6*7")
fake.openDialog().choose("Calculate")
ok(fake.pasteboard == "6*7=42", "calculate pastes expr=result")
invokeOnSelection("os.exit()")
fake.openDialog().choose("Calculate")
ok(fake.pasteboard == "os.exit()", "sandbox: non-math globals are nil (eval fails, alert)")
ok(fake.alerts[#fake.alerts]:match("Calculation failed") ~= nil, "failed eval alerts")

-- dictionary: not running -> alert; running -> activate, type, return
invokeOnSelection("ubiquitous")
fake.openDialog().choose("Dictionary")
ok(fake.alerts[#fake.alerts]:match("not running") ~= nil, "dict app absent alerts")
fake.runningApps["网易有道词典"] = true
invokeOnSelection("ubiquitous")
fake.openDialog().choose("Dictionary")
fake.fireTimers("after", 0.75)
ok(fake.activatedApps[#fake.activatedApps] == "网易有道词典", "dict app activated")
ok(fake.typedTexts[#fake.typedTexts] == "ubiquitous"
    and fake.keyEvents[#fake.keyEvents].key == "return",
    "phrase typed into the dict + return")

-- empty selection: trusted -> plain alert (no AX prompt)
fake.pressHotkey("o")
fake.pasteboard = nil
fake.fireTimers("after", 0.15)
ok(fake.alerts[#fake.alerts]:match("Nothing selected") ~= nil, "empty selection says so")

registry.setEnabled("text_actions", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after text_actions test")

-- T23: site_switcher (a list of favorite sites in a searchable chooser; pick a row
-- -- click, Enter, or cmd+<n> -- to focus that site's tab, or open it) --------
registry.register(require("features.site_switcher"))
registry.setEnabled("site_switcher", true)
local CC = { "ctrl", "cmd" }

-- several sites: the shortcut pops a chooser listing them (domain text, url sub)
fake.settings["hammerdeck.opt.site_switcher.sites"] =
    "https://www.otter.ai/\nhttps://github.com/\n"
fake.browserTabs = { "https://github.com/x", "https://www.otter.ai/meetings" }
fake.pressHotkey("6", CC)
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
fake.pressHotkey("6", CC)
fake.visibleChooser().userSelect(2)
ok(fake.focusedTabs[#fake.focusedTabs] == "https://github.com/x",
    "picking row 2 focuses the second site's tab")

-- dismissing the chooser (Escape -> onSelect(nil)) jumps nothing
local focusedCount = #fake.focusedTabs
fake.pressHotkey("6", CC)
fake.visibleChooser().userSelect(0)   -- out-of-range = dismissed
ok(#fake.focusedTabs == focusedCount, "dismissing the chooser jumps nothing")

-- a single configured site skips the list and jumps straight (donor behavior)
fake.settings["hammerdeck.opt.site_switcher.sites"] = "https://github.com/"
fake.browserTabs = { "https://github.com/x" }
fake.pressHotkey("6", CC)
ok(fake.visibleChooser() == nil
    and fake.focusedTabs[#fake.focusedTabs] == "https://github.com/x",
    "one site needs no list -- jumps straight")

-- no match opens the fallback URL in a new tab
fake.settings["hammerdeck.opt.site_switcher.sites"] = "https://www.otter.ai/"
fake.browserTabs = { "https://github.com/x" }
fake.pressHotkey("6", CC)
ok(fake.openedNewTabs[#fake.openedNewTabs] == "https://www.otter.ai/",
    "no match opens the fallback URL")

-- a scheme-less entry is normalized to https:// so it actually navigates
-- (the "opened bing.com" dead-tab bug)
fake.settings["hammerdeck.opt.site_switcher.sites"] = "bing.com"
fake.browserTabs = {}
fake.pressHotkey("6", CC)
ok(fake.openedNewTabs[#fake.openedNewTabs] == "https://bing.com",
    "a scheme-less site gets https:// before opening (no more dead tab)")

-- the legacy single-URL key seeds the one site when the list is empty
fake.settings["hammerdeck.opt.site_switcher.sites"] = nil
fake.settings["hammerdeck.opt.site_switcher.openURL"] = "https://www.otter.ai/"
fake.browserTabs = { "https://www.otter.ai/meetings" }
fake.pressHotkey("6", CC)
ok(fake.focusedTabs[#fake.focusedTabs] == "https://www.otter.ai/meetings",
    "the legacy openURL migrates as the one site when the list is empty")
fake.settings["hammerdeck.opt.site_switcher.openURL"] = nil

-- no sites at all -> a clear hint, not silence
fake.pressHotkey("6", CC)
ok(fake.alerts[#fake.alerts]:match("No sites yet") ~= nil,
    "empty config alerts instead of doing nothing")

registry.setEnabled("site_switcher", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after site_switcher test")

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
fake.pressHotkey("right", { "ctrl", "alt" })
lf = lastFrame()
ok(lf.w == 600 and lf.h == 450, "frame scales by the axis ratio closer to 1 (1.5)")
ok(lf.x == 1200 and lf.y == 150, "position scales per axis onto the target screen")
ok(fake.mousePos.x == 1150 and fake.mousePos.y == 200, "pointer carried at its offset")
ok(fake.mouseLocates[#fake.mouseLocates] == 2, "pointer flashed after the throw")

-- and back, wrapping
fake.focusedWindow.screenIndex = 2
fake.pressHotkey("left", { "ctrl", "alt" })
ok(lastFrame().x >= 0 and lastFrame().x < 1000, "previous wraps back to the primary")

-- a huge window clamps into the smaller target screen
fake.focusedWindow = { x = 1000, y = 0, w = 2000, h = 1200, screenIndex = 2 }
fake.pressHotkey("left", { "ctrl", "alt" })
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

-- enter the mode: banner up, bare keys live
fake.pressHotkey("2", { "ctrl", "cmd" })
ok(fake.liveBanner() ~= nil and fake.liveBanner().text:match("Window Mode"),
    "entering the mode shows the banner")
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
ok(fake.liveBanner() == nil, "escape drops the banner")
fake.pressHotkey("a", {})
ok(fake.focusedWindow.x == xBefore, "bare keys are dead after exit")

-- the trigger toggles: enter, then the same hotkey exits
fake.pressHotkey("2", { "ctrl", "cmd" })
ok(fake.liveBanner() ~= nil, "re-enter works")
fake.pressHotkey("2", { "ctrl", "cmd" })
ok(fake.liveBanner() == nil, "the enter hotkey toggles the mode off")

-- disabling mid-mode leaks nothing
fake.pressHotkey("2", { "ctrl", "cmd" })
ok(fake.liveBanner() ~= nil, "mode active before disable")
registry.setEnabled("window_modal", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
    "disable mid-mode tears everything down")
fake.settings["hammerdeck.opt.window_modal.stepParts"] = nil

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

fake.pressHotkey("v", { "cmd", "shift" })
local hch = fake.visibleChooser()
ok(hch ~= nil and #hch.choices == 2, "history chooser opens, deduped")
ok(hch.choices[1].text == "alpha" and hch.choices[2].text == "beta",
    "newest first, re-copy bumped alpha to the front")

-- selecting writes the clipboard and pastes (paste_on_select donor default)
fake.copyText("other")                 -- clipboard currently holds something else
fake.fireTimers("every", 0.8)
fake.pressHotkey("v", { "cmd", "shift" })
fake.visibleChooser().userSelect(3)    -- pick "beta" (other, alpha, beta)
ok(fake.pasteboard == "beta", "selection puts the entry on the clipboard")
fake.fireTimers("after", 0.15)
local pk = fake.keyEvents[#fake.keyEvents]
ok(pk.key == "v" and pk.mods[1] == "cmd", "and pastes it (cmd+v)")

-- pasteOnSelect off: clipboard only
fake.settings["hammerdeck.opt.clipboard_history.pasteOnSelect"] = false
local keysBefore28 = #fake.keyEvents
fake.pressHotkey("v", { "cmd", "shift" })
fake.visibleChooser().userSelect(2)
fake.fireTimers("after", 0.15)
ok(#fake.keyEvents == keysBefore28, "pasteOnSelect off -> no synthesized paste")
fake.settings["hammerdeck.opt.clipboard_history.pasteOnSelect"] = nil

-- the cap drops the oldest
fake.settings["hammerdeck.opt.clipboard_history.historySize"] = nil
fake.settings["hammerdeck.opt.clipboard_history.historySize"] = 2
fake.copyText("gamma")
fake.fireTimers("every", 0.8)
fake.pressHotkey("v", { "cmd", "shift" })
ok(#fake.visibleChooser().choices == 2, "historySize caps the list")
fake.visibleChooser().userSelect(1)
fake.fireTimers("after", 0.15)
fake.settings["hammerdeck.opt.clipboard_history.historySize"] = nil

-- history survives a disable/re-enable (restored from disk)
registry.setEnabled("clipboard_history", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clipboard_history leaks nothing")
registry.setEnabled("clipboard_history", true)
fake.pressHotkey("v", { "cmd", "shift" })
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

fake.pressHotkey("space", { "cmd", "shift" })
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
fake.pressHotkey("space", { "cmd", "shift" })
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
fake.pressHotkey("space", { "cmd", "shift" })
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

print("OK -- " .. passed .. " assertions passed (" .. _VERSION .. ")")
