-- test/cases/_integration/platform/adapter_surface_parity.lua -- the fake adapter must export exactly the real seam's function
-- surface -- every real adapter.lua function has a fake counterpart and
-- vice versa (no dead/renamed reimplementations). Shape parity only, not
-- behavior (behavior is covered per-function by the feature cases + the
-- real-bridge Swift suite).
--
-- Migrated from run.lua T0 (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "adapter_surface_parity",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake

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
    end,
}
