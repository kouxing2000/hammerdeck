-- test/cases/_integration/platform/hyper_legend.lua -- registry.hyperLegend() -- the which-key legend of enabled Hyper
-- bindings: lists a Hyper binding as { key, label }, carries the runAction pair
-- a click on the HUD key fires, excludes non-Hyper bindings, and drops a
-- disabled feature's bindings.
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
            api = 1, id = "hyperprobe", name = "Hyper Probe", icon = "star.fill",
            actions = {
                { id = "go", label = "Go",   -- no per-action icon: falls back to the feature glyph
                  description = "Jump to it",
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
        local function legendField(rows, key, field)
            for _, it in ipairs(rows) do if it.key == key then return it[field] end end
        end
        local legend = registry.hyperLegend()
        ok(legendHas(legend, "h", "Go"), "hyperLegend lists a Hyper binding as { key, label }")
        ok(legendField(legend, "h", "icon") == "star.fill",
            "hyperLegend row carries the action glyph (feature icon when no per-action icon)")
        ok(legendField(legend, "h", "desc") == "Jump to it",
            "hyperLegend row carries the action description (for the keyboard HUD's hover hint)")
        ok(legendField(legend, "h", "featureId") == "hyperprobe"
            and legendField(legend, "h", "actionId") == "go",
            "hyperLegend row carries the runAction pair (so clicking the HUD key runs it)")
        ok(not legendHasLabel(legend, "NotHyper"), "hyperLegend excludes non-Hyper bindings")
        registry.setEnabled("hyperprobe", false)
        ok(not legendHasLabel(registry.hyperLegend(), "Go"),
            "hyperLegend drops a disabled feature's bindings")

        end

        -- A chord PREFIX shared by several actions gets ONE cap, named for the
        -- feature -- never one arbitrary member. The board has a single cap per
        -- key, and clicking a prefix ARMS the chord rather than running any one
        -- action, so a member's label there would name something the click is
        -- guaranteed not to do.
        do
        package.loaded["features._chordprobe"] = {
            api = 1, id = "chordprobe", name = "Chord Probe", icon = "star.fill",
            actions = {
                { id = "one", label = "First", description = "does one",
                  defaultTrigger = { type = "chord", mods = { "cmd", "alt", "ctrl" },
                                     key = "y", follows = { "a" } },
                  run = function() end },
                { id = "two", label = "Second", description = "does two",
                  defaultTrigger = { type = "chord", mods = { "cmd", "alt", "ctrl" },
                                     key = "y", follows = { "b" } },
                  run = function() end },
                { id = "three", label = "Third", description = "does three",
                  defaultTrigger = { type = "chord", mods = { "cmd", "alt", "ctrl" },
                                     key = "y", follows = { "c" } },
                  run = function() end },
            },
        }
        registry.load("features._chordprobe")
        registry.setEnabled("chordprobe", true)

        local rows = registry.hyperLegend()
        local n, row = 0, nil
        for _, it in ipairs(rows) do
            if it.key == "y" then n = n + 1; row = it end
        end
        ok(n == 1, "a shared chord prefix collapses to exactly ONE cap (got " .. n .. ")")
        ok(row ~= nil and row.label == "Chord Probe",
            "the collapsed cap is named for the FEATURE, not one arbitrary action")
        ok(row ~= nil and row.chord == true, "the collapsed cap is still marked as a chord")
        -- The members do not vanish: the hover line is where they fit.
        ok(row ~= nil and row.desc == "First, Second, Third",
            "the collapsed cap lists its members in the hover description")
        registry.setEnabled("chordprobe", false)
        end

        -- The MULTI-FEATURE branch of the collapse. Two shapes, and only one of
        -- them is representable on a single cap.
        do
        local function chordAction(id, label, follow)
            return { id = id, label = label,
                     defaultTrigger = { type = "chord", mods = { "cmd", "alt", "ctrl" },
                                        key = "k", follows = { follow } },
                     run = function() end }
        end
        package.loaded["features._sharedA"] = {
            api = 1, id = "shared_a", name = "Shared A", icon = "a.circle",
            actions = { chordAction("go", "Alpha", "a") },
        }
        package.loaded["features._sharedB"] = {
            api = 1, id = "shared_b", name = "Shared B", icon = "b.circle",
            actions = { chordAction("go", "Bravo", "b") },
        }
        registry.load("features._sharedA"); registry.setEnabled("shared_a", true)
        registry.load("features._sharedB"); registry.setEnabled("shared_b", true)

        local function capFor(key)
            local found
            for _, it in ipairs(registry.hyperLegend()) do
                if it.key == key then
                    ok(found == nil, "still exactly one cap for '" .. key .. "'")
                    found = it
                end
            end
            return found
        end

        -- (a) ALL chords on one prefix, spanning features: representable. The
        --     click arms the prefix, which offers every member -- so the cap
        --     counts rather than naming one feature, and stays live.
        local cap = capFor("k")
        ok(cap ~= nil and cap.chord == true, "a cross-feature chord prefix is still a chord cap")
        ok(cap ~= nil and cap.label == "2 actions",
            "and counts instead of naming one of the two features")
        ok(cap ~= nil and cap.icon == nil, "with no icon, since neither feature owns the cap")
        ok(cap ~= nil and cap.failed ~= true, "and stays live -- arming offers both")

        -- (b) Add a PLAIN HOTKEY on the same cap. Now two different bindings
        --     claim one physical key, at most one can win at the OS level, and
        --     no single cap can honestly say which. It must go inert rather
        --     than silently representing one member.
        package.loaded["features._sharedC"] = {
            api = 1, id = "shared_c", name = "Shared C", icon = "c.circle",
            actions = { { id = "go", label = "Charlie",
                          defaultTrigger = { type = "hotkey",
                                             mods = { "cmd", "alt", "ctrl" }, key = "k" },
                          run = function() end } },
        }
        registry.load("features._sharedC"); registry.setEnabled("shared_c", true)

        cap = capFor("k")
        ok(cap ~= nil and cap.failed == true,
            "a cap claimed by both a chord prefix and a plain hotkey goes inert")
        ok(cap ~= nil and cap.chord == false,
            "and is NOT dressed as a chord -- clicking must not arm one")
        -- Pin the BRANCH, not just "some reason": a start failure would also
        -- set `failed`, and this must be the conflict path.
        ok(cap ~= nil and type(cap.failReason) == "string"
            and cap.failReason:find("claim") ~= nil,
            "and says why -- the CONFLICT reason, not a start failure")

        -- The collapse reads scratch fields off each member; none may cross the
        -- seam into the row the Swift side decodes.
        local leaked = false
        for _, it in ipairs(registry.hyperLegend()) do
            if it.featureName ~= nil or it.ord ~= nil then leaked = true end
        end
        ok(not leaked, "collapse-only scratch fields never reach an emitted row")

        registry.setEnabled("shared_a", false)
        registry.setEnabled("shared_b", false)
        registry.setEnabled("shared_c", false)
        end

        -- A feature whose start THREW keeps its enabled flag (registry's
        -- "enabled but failed"), so its Hyper binding is still configured and
        -- simply cannot fire. The cap stays on the board, MARKED -- dropping it
        -- would hide the only on-screen evidence that something the user set up
        -- is broken, and the HUD renders a marked cap inert so clicking it is
        -- not a silent no-op.
        do
        package.loaded["features._failprobe"] = {
            api = 1, id = "failprobe", name = "Fail Probe", icon = "star.fill",
            start = function() error("boom in start") end,
            actions = {
                { id = "go", label = "Go",
                  defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "u" },
                  run = function() end },
            },
        }
        registry.load("features._failprobe")
        ok(pcall(registry.setEnabled, "failprobe", true), "enabling a broken feature does not throw")

        local row
        for _, it in ipairs(registry.hyperLegend()) do if it.key == "u" then row = it end end
        ok(row ~= nil, "a failed feature's Hyper binding stays ON the board")
        ok(row ~= nil and row.failed == true, "and is marked failed, so the HUD renders it inert")
        ok(row ~= nil and type(row.failReason) == "string" and row.failReason ~= "",
            "the row carries the reason, for the HUD's hover hint")
        registry.setEnabled("failprobe", false)
        end
    end,
}
