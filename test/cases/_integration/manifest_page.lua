-- test/cases/_integration/manifest_page.lua -- the manifest `page` contract: a feature may
-- declare page = { title, icon? } to dock a native Homepage view (usage_stats' report page is
-- the shipped user). manifest.validate enforces the shape (title required; icon optional and,
-- if present, a string; page itself must be a table), and describe() passes it through --
-- defaulting the icon -- so the host's sidebar is fully data-driven, no per-feature host code.
--
-- Migrated from run.lua T33 (RUN_LUA_SPLIT_SPEC). Integration of a core contract (not a
-- feature): it validates literal manifest tables and registers a throwaway `page_probe` on the
-- real registry to read it back through describe(). Hermetic -- freshWorld's registry.reset()
-- clears page_probe before the next case, and the probe binds nothing (never enabled), so the
-- handle tripwire is trivially clean.

return {
    id = "manifest_page",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, rejects, manifest = t.ok, t.rejects, t.manifest

        local mok = manifest.validate({ api = 1, id = "p1", name = "P1",
            action = function() end, page = { title = "Usage", icon = "chart.bar.xaxis" } })
        ok(mok.page.title == "Usage" and mok.page.icon == "chart.bar.xaxis",
            "valid page declaration accepted")
        -- icon is optional (host defaults it)
        ok(pcall(manifest.validate, { api = 1, id = "p2", name = "P2",
            action = function() end, page = { title = "Just Title" } }),
            "page.icon is optional")
        rejects({ api = 1, id = "p3", name = "P3", action = function() end, page = {} },
            "page without a title")
        rejects({ api = 1, id = "p4", name = "P4", action = function() end,
            page = { title = "X", icon = 42 } }, "page.icon must be a string")
        rejects({ api = 1, id = "p5", name = "P5", action = function() end, page = "Usage" },
            "page must be a table")

        -- describe() surfaces it (with the icon defaulted) so the sidebar is data-driven
        local reg2 = require("platform.registry")
        reg2.register({ api = 1, id = "page_probe", name = "Page Probe",
            action = function() end, page = { title = "Probe" } })
        local found
        for _, row in ipairs(reg2.describe()) do
            if row.id == "page_probe" then found = row end
        end
        ok(found and found.page and found.page.title == "Probe" and found.page.icon == "doc",
            "describe() emits page with a defaulted icon")
    end,
}
