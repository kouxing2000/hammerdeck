-- test/cases/_integration/platform/notify_on_automated_run.lua -- the notify-on-automated-run preference -- an action fired from an
-- AUTOMATED trigger toasts (naming the feature) ONLY while notify_on_trigger
-- is on; manual/menubar runs never notify; a crashed automated run does not
-- report a clean success.
--
-- Migrated from run.lua T7c (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "notify_on_automated_run",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

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
    end,
}
