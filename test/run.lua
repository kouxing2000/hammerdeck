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

-- T1: all manifests register + validate --------------------------------------
registry.register(require("features.sleep_schedule"))
registry.register(require("features.rest_timer"))
registry.register(require("features.window_jump"))
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

-- T3: window_jump (action feature: open, select; cycle on repeat) -------------
fake.windows = {
    { id = 11, title = "Current Window",  appName = "AppA", bundleID = "com.a" },
    { id = 22, title = "Previous Window", appName = "AppB", bundleID = "com.b" },
    { id = 33, title = "Older Window",    appName = "AppC", bundleID = "com.c" },
}
registry.setEnabled("window_jump", true)
fake.pressHotkey("tab")
local ch = fake.visibleChooser()
ok(ch ~= nil, "window_jump opened a chooser")
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

registry.setEnabled("window_jump", false)
ok(registry.liveHandleCount() == 0, "window_jump disable left no live handles")

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

-- T5: rest_timer (service feature: cycle, busy-retry, dialog, lock/unlock) -----
local notificationsBefore = #fake.notifications
registry.setEnabled("rest_timer", true)
ok(#fake.notifications == notificationsBefore + 1, "rest_timer announces the cycle")
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
local stateBefore = tonumber(fake.settings["hammerdeck.state.rest_timer.workSeconds"] or 0)
fake.fireTimers("every", 5)
local stateAfter = tonumber(fake.settings["hammerdeck.state.rest_timer.workSeconds"] or 0)
ok(stateAfter == stateBefore + 5, "active tick accrues persisted work stats")

fake.idle = 6 * 60                             -- long idle pauses
fake.fireTimers("every", 5)
ok(fake.fireTimers("after") == 0, "long idle cancelled the rest timer")

registry.setEnabled("rest_timer", false)
ok(registry.liveHandleCount() == 0, "rest_timer disable left no live handles")

-- T6: nothing leaks globally ----------------------------------------------------
ok(fake.liveHandles == 0, "fake adapter reports zero live native resources")

-- T7: catalog description for the config UI --------------------------------------
local desc = registry.describe()
ok(#desc == 3, "describe lists all 3 features")
ok(desc[1].id == "rest_timer" and desc[1].kind == "service", "describe is sorted by id")
local jumpDesc = desc[3]
ok(jumpDesc.id == "window_jump" and jumpDesc.kind == "action", "window_jump is an action")
ok(jumpDesc.triggerDesc == "hotkey: alt+tab", "action trigger described")
ok(jumpDesc.options[1].key == "cycleModifier" and jumpDesc.options[1].type == "enum"
    and #jumpDesc.options[1].values == 3,
    "typed options (incl. enum values) exported for the form generator")
local sleepDesc = desc[2]
ok(sleepDesc.kind == "service" and sleepDesc.triggerDesc == "always-on service",
    "service features described as always-on")
ok(#sleepDesc.options == 6, "sleep_schedule exports all 6 options")
ok(sleepDesc.enabled == false, "describe reflects enabled state")

-- T8: re-enable works with fresh state ------------------------------------------
registry.setEnabled("window_jump", true)
fake.pressHotkey("tab")
ok(fake.visibleChooser() ~= nil, "re-enabled feature works with a fresh ctx")
registry.setEnabled("window_jump", false)
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

print("OK -- " .. passed .. " assertions passed")
