-- test/cases/_integration/platform/manifest_contract.lua -- manifest.validate enforces the plugin contract -- api version,
-- action-vs-service shape, option types, enum labels, automatable +
-- automated-trigger policy, context/requires/recommended/mnemonic fields,
-- and that schedule must be a function.
--
-- Migrated from run.lua T2 (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "manifest_contract",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, rejects, manifest = t.ok, t.rejects, t.manifest

        rejects({ api = 99, id = "x", name = "X", action = function() end }, "wrong api version")
        rejects({ api = 1, id = "x", name = "X" }, "neither action nor start")
        rejects({ api = 1, id = "x", name = "X", action = function() end, start = function() end },
            "both action and start")
        rejects({ api = 1, id = "x", name = "X", start = function() end,
            defaultTrigger = { type = "hotkey" } }, "defaultTrigger on a service")
        rejects({ api = 1, id = "x", name = "X", action = function() end,
            options = { { key = "k", type = "nope" } } }, "unknown option type")
        rejects({ api = 1, id = "x", name = "X", action = function() end,
            options = { { key = "m", type = "enum", values = { "a" }, valuesFrom = "ghost" } } },
            "valuesFrom names no validate-able option")
        rejects({ api = 1, id = "x", name = "X", action = function() end,
            options = { { key = "b", type = "bool", default = true, gatedBy = "ghost" } } },
            "gatedBy names no validate-able option")
        -- labels must be a list parallel to values (and enum-only)
        ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
            options = { { key = "m", type = "enum", values = { "a", "b" }, labels = { "Only one" } } } }),
            "enum labels length must match values")
        ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
            options = { { key = "m", type = "string", labels = { "a" } } } }),
            "labels are rejected on a non-enum option")
        -- multiline is a string-only boolean flag
        ok(pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
            options = { { key = "s", type = "string", multiline = true } } }),
            "multiline accepted on a string option")
        ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
            options = { { key = "n", type = "int", multiline = true } } }),
            "multiline is rejected on a non-string option")
        -- automatable: optional per-action boolean; default false; an automated
        -- defaultTrigger implies it must be true.
        do
            local m = manifest.validate({ api = 1, id = "x", name = "X", action = function() end })
            ok(m.actions[1].automatable == false, "automatable defaults to false")
            local m2 = manifest.validate({ api = 1, id = "y", name = "Y",
                actions = { { id = "a", run = function() end, automatable = true } } })
            ok(m2.actions[1].automatable == true, "automatable carried through when declared")
        end
        ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X",
            actions = { { id = "a", run = function() end, automatable = "yes" } } }),
            "automatable must be a boolean")
        ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
            defaultTrigger = { type = "schedule", everyMin = 5 } }),
            "an automated defaultTrigger on a non-automatable action is rejected")
        ok(pcall(manifest.validate, { api = 1, id = "x", name = "X",
            actions = { { id = "a", run = function() end, automatable = true,
                defaultTrigger = { type = "schedule", everyMin = 5 } } } }),
            "an automated defaultTrigger is fine when automatable = true")
        -- context: optional grouping axis (when the feature applies); controlled vocab;
        -- defaults to "anywhere".
        do
            local m = manifest.validate({ api = 1, id = "ctxd", name = "Ctxd", action = function() end })
            ok(m.context == "anywhere", "context defaults to anywhere")
            local m2 = manifest.validate({ api = 1, id = "ctxw", name = "Ctxw", context = "window",
                action = function() end })
            ok(m2.context == "window", "context carried through when declared")
        end
        ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", context = "nope",
            action = function() end }), "an unknown context value is rejected")
        -- requires: optional OS-precondition list; controlled vocab; defaults to {}.
        do
            local m = manifest.validate({ api = 1, id = "reqd", name = "Reqd", action = function() end })
            ok(type(m.requires) == "table" and #m.requires == 0, "requires defaults to an empty list")
            local m2 = manifest.validate({ api = 1, id = "reqa", name = "Reqa",
                requires = { "accessibility" }, action = function() end })
            ok(m2.requires[1] == "accessibility", "requires carried through when declared")
        end
        ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X",
            requires = { "telepathy" }, action = function() end }),
            "an unknown requirement token is rejected")
        ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X",
            requires = "accessibility", action = function() end }),
            "requires must be a list, not a bare string")
        -- recommended: optional boolean; the curated Essentials starter set.
        do
            local m = manifest.validate({ api = 1, id = "recd", name = "Recd", action = function() end })
            ok(m.recommended == false, "recommended defaults to false")
            local m2 = manifest.validate({ api = 1, id = "rece", name = "Rece",
                recommended = true, action = function() end })
            ok(m2.recommended == true, "recommended carried through when declared")
        end
        ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X",
            recommended = "yes", action = function() end }), "recommended must be a boolean")
        -- mnemonic: optional per-action "why this key" string; carried through the
        -- single-action sugar; rejected if not a string.
        do
            local m = manifest.validate({ api = 1, id = "mn", name = "Mn", action = function() end,
                mnemonic = "P for Password" })
            ok(m.actions[1].mnemonic == "P for Password", "mnemonic flows through the single-action sugar")
            local m2 = manifest.validate({ api = 1, id = "mn2", name = "Mn2",
                actions = { { id = "a", run = function() end, mnemonic = "H for History" } } })
            ok(m2.actions[1].mnemonic == "H for History", "mnemonic carried through on an actions entry")
        end
        ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X",
            actions = { { id = "a", run = function() end, mnemonic = 42 } } }),
            "mnemonic must be a string")
    end,
}
