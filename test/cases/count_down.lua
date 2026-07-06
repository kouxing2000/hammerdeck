-- test/cases/count_down.lua -- count_down (multi-action spoon port: prompt for
-- minutes -> progress strip -> pause/resume -> completion notify).
--
-- Migrated from run.lua T16 (RUN_LUA_SPLIT_SPEC Phase 2). Hermetic: registers its
-- own feature and drives its own chord/prompt/timer timeline; freshWorld() before +
-- handle tripwire after keep it isolated. (The old monolith's stray
-- optionChanged("count_down", ...) no-op probe in T20 was repointed at an absent
-- feature name -- it never needed count_down registered.)

return {
    id = "count_down",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

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
    end,
}
