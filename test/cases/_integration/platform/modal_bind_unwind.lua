-- test/cases/_integration/platform/modal_bind_unwind.lua -- a modal's key
-- registration is all-or-nothing. The seam RAISES when a combo is already held
-- (Carbon's eventHotKeyExistsErr), and modal.enter used to die part-way, leaving
-- every key bound before the failure live with no handle anyone held: bare
-- letters swallowed system-wide until a restart.
--
-- Integration (platform core). Hermetic: fake.rejectHotkey is reset per world,
-- and the runner's per-case handle tripwire is itself the proof that nothing the
-- failed enter bound survives it.

return {
    id = "modal_bind_unwind",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
        local modal = require("platform.modal")

        local function live(key)
            for _, h in ipairs(fake.hotkeys) do
                if not h.stopped and h.key == key then return true end
            end
            return false
        end

        -- The THIRD binding's combo is refused, after two have registered.
        fake.rejectHotkey = function(mods, key) return key == "c" and #mods == 0 end
        local entered, err = pcall(modal.enter, {
            name = "Test", stickyMods = { "cmd", "alt", "ctrl" },
            bindings = { { key = "a", fn = function() end }, { key = "b", fn = function() end },
                         { key = "c", fn = function() end } },
        })
        ok(not entered and tostring(err):find("could not register", 1, true) ~= nil,
            "a refused combo still fails the enter loudly")
        ok(not live("a") and not live("b"),
            "the keys bound before the refusal are released, not left captured")
        ok(#fake.banners == 1 and fake.banners[1].stopped, "and the mode's banner is taken down")
        fake.rejectHotkey = nil

        -- A clean enter afterwards binds normally (nothing stale in the way).
        local h = modal.enter({ bindings = { { key = "a", fn = function() end } } })
        ok(live("a"), "a later enter binds normally")
        h.stop()
        ok(not live("a"), "and releases on exit")
    end,
}
