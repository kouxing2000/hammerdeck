-- test/cases/_reset.lua -- reset-machinery self-test (RUN_LUA_SPLIT_SPEC §7).
--
-- The FIRST hermetic case, and the guard for the whole split: it exercises the
-- runner pipeline end-to-end (discover -> freshWorld -> run(t) -> handle tripwire)
-- AND catches the two SUBTLE reset bugs that a naive registry.reset() would hit,
-- not just the obvious empty-catalog one. Sorts first (leading `_`) so a broken
-- reset fails loudly before any feature case runs.

return {
    id = "_reset",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry, AC = t.ok, t.fake, t.registry, t.AC

        -- (a) dynamicActions double-append: window_snap's dynamicActions hook appends
        -- placement actions onto its manifest IN PLACE, and require() caches that
        -- mutated table. reset() must purge package.loaded["features.*"] so a
        -- re-register re-reads a pristine manifest -- else its action count grows.
        registry.reset()      -- tear the platform down FIRST (unwinds handle accounting
        fake.resetWorld()     -- through the fake), THEN wipe the fake to pristine
        local snapA = registry.register(require("features.window_snap"))
        local nA = #snapA.actions
        registry.reset()
        local snapB = registry.register(require("features.window_snap"))
        ok(#snapB.actions == nA,
            "reset: window_snap action count stable across re-register (no dynamicActions double-append)")

        -- (b) transitive singleton leak: window_rewind:stop() -> window_history clear().
        -- reset() must route teardown through the real stop path (not a raw table drop),
        -- or window_history keeps a stale pending undo group that leaks into the next case.
        registry.reset()
        fake.resetWorld()
        registry.register(require("features.window_rewind"))
        registry.register(require("features.window_snap"))
        registry.setEnabled("window_rewind", true)   -- recording on
        registry.setEnabled("window_snap", true)     -- a real mover to generate history
        fake.screenList    = { { x = 0, y = 0, w = 1000, h = 800 } }
        fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
        fake.focusedWid    = 111
        fake.windows       = { { id = 11, wid = 111, x = 100, y = 100, w = 400, h = 300 } }
        fake.pressHotkey("left", AC)                 -- snap -> records a pending undo group
        ok(fake.focusedWindow.x == 0, "precondition: the snap moved + recorded a window")

        registry.reset()                             -- MUST clear window_history via stop()

        -- re-register/enable and try to undo: with a correct reset the group is gone,
        -- so undo is a no-op; a leaked group (raw table drop) would still restore.
        registry.register(require("features.window_rewind"))
        registry.register(require("features.window_snap"))
        registry.setEnabled("window_rewind", true)
        fake.windows = { { id = 11, wid = 111, x = 0, y = 0, w = 500, h = 800 } } -- listable: a leak WOULD restore
        fake.windowFrameSets = {}
        assert(registry.runAction("window_rewind", "undo"))
        ok(#fake.windowFrameSets == 0,
            "reset: window_history's pending undo group was cleared (no transitive singleton leak)")

        -- (c) the obvious postconditions: empty catalog, no live native handles.
        registry.reset()
        fake.resetWorld()
        ok(#registry.describe() == 0, "reset: catalog is empty")
        ok(fake.liveHandles == 0 and registry.liveHandleCount() == 0, "reset: no live native handles")
    end,
}
