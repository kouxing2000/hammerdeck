-- test/cases/_integration/rules/rules_notify_delivery.lua -- notify delivery channel (M3) -- a notify can target the macOS Notification
-- Center ("system") or the in-app banner ("app", default), with a toast fallback --
--
-- Migrated from run.lua T41 (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration: platform subsystem, driven by throwaway features/effects. Hermetic --
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so the catalog
-- and the rules singleton both start empty.

return {
    id = "rules_notify_delivery",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
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
    end,
}
