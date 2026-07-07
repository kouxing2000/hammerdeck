-- test/cases/_integration/platform/hyper_legend.lua -- registry.hyperLegend() -- the which-key legend of enabled Hyper
-- bindings: lists a Hyper binding as { key, label }, excludes non-Hyper
-- bindings, and drops a disabled feature's bindings.
--
-- Migrated from run.lua T19b (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "hyper_legend",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, registry = t.ok, t.registry

        do
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

        end
    end,
}
