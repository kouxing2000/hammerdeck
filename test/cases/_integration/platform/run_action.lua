-- test/cases/_integration/platform/run_action.lua -- registry.runAction -- the menubar's quick triggers. Fires an
-- enabled action, refuses an unknown action (with a reason), a disabled
-- feature, and an unknown feature.
--
-- Migrated from run.lua T27 (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "run_action",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        do
        registry.register(require("features.plain_paste"))   -- fresh register (freshWorld cleared the catalog)
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

        end
    end,
}
