-- test/cases/_integration/platform/validate_extension.lua -- the RUNTIME half of
-- the capability-declaration check: registry.validateExtension, the MCP tool an
-- agent calls after reload to find out whether the extension it just wrote
-- declared itself honestly.
--
-- Why a runtime check exists at all. The build guards
-- (feature_capabilities.lua) cover the first-party catalog only -- an extension
-- is the user's own code and never passes through our CI. The runtime capability
-- gate still fires, but only on the branch that REACHES the gated call, so an
-- under-declared capability can ship and surface at a user; an over-declared one
-- is invisible forever. Both are answered here before the code runs.
--
-- The two halves share platform.capscan, so what is really under test is the
-- part that differs: walking the REQUIRE GRAPH (init.lua -> its siblings -> the
-- platform modules it pulls in) instead of listing a folder.
--
-- Source text is read through adapter.fileRead, which the fake serves from
-- fake.files -- so a case can state the exact source it wants scanned, rather
-- than encoding assertions about a fixture's wording.

local EXT_DIR = "test/fixtures/extensions"

return {
    id = "validate_extension",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        fake.settings["hammerdeck.extensionsDir"] = EXT_DIR
        fake.featuresByDir[EXT_DIR] = { "ext_caps" }
        ok(registry.loadExtensions() == 1, "the mis-declaring fixture loads")

        local INIT = EXT_DIR .. "/ext_caps/lua/init.lua"

        -- ---------------------------------------------------------------
        -- Both directions at once: the fixture declares "power" and uses
        -- none of it, and calls a network method it never declared.
        -- ---------------------------------------------------------------
        do
        fake.files[INIT] = [[
return { api = 1, id = "ext_caps",
    action = function(ctx) ctx.httpGet("https://example.invalid", function() end) end }
]]
        local r = registry.validateExtension("ext_caps")
        ok(r.ok == false, "a mis-declaring extension does not pass")
        ok(#r.underDeclared == 1 and r.underDeclared[1] == "network",
            "the network call it never declared is reported as under-declared")
        ok(#r.overDeclared == 1 and r.overDeclared[1] == "power",
            "the 'power' it declares but never uses is reported as over-declared")
        ok(r.gatedCallsUsed[1] == "httpGet",
            "the report names the CALL, not just the capability (so it can be found)")
        end

        -- ---------------------------------------------------------------
        -- Honest code passes. Same fixture, source that uses exactly what
        -- the feature.json claims -- proving the verdict tracks the source
        -- and is not a property of the fixture's name.
        -- ---------------------------------------------------------------
        do
        fake.files[INIT] = [[
return { api = 1, id = "ext_caps",
    action = function(ctx) ctx.lockScreen() end }
]]
        local r = registry.validateExtension("ext_caps")
        ok(r.ok == true, "code matching its declaration passes")
        ok(#r.underDeclared == 0 and #r.overDeclared == 0, "and reports nothing to fix")
        end

        -- ---------------------------------------------------------------
        -- The require graph is walked, not just init.lua. A gated call in a
        -- SIBLING module is the extension's reach too -- and a folder listing
        -- would find it by accident where this has to follow the require.
        -- ---------------------------------------------------------------
        do
        fake.files[INIT] = [[
local helper = require("extensions.ext_caps.helper")
return { api = 1, id = "ext_caps", action = function(ctx) helper.go(ctx) end }
]]
        fake.files[EXT_DIR .. "/ext_caps/lua/helper.lua"] = [[
return { go = function(ctx) ctx.typeText("hi") end }
]]
        local r = registry.validateExtension("ext_caps")
        local found = false
        for _, cap in ipairs(r.underDeclared) do if cap == "input" then found = true end end
        ok(found, "a gated call in a required SIBLING module counts as the extension's reach")
        local sawHelper = false
        for _, name in ipairs(r.scanned) do
            if name == "extensions.ext_caps.helper" then sawHelper = true end
        end
        ok(sawHelper, "the report lists the sibling among the files it scanned")
        end

        -- ---------------------------------------------------------------
        -- TRANSITIVE reach through a platform module. A feature that requires
        -- platform.favicons genuinely reaches the network -- favicons calls
        -- ctx.downloadFile through the ctx it is handed -- so the walk must
        -- follow into platform/ and attribute what it finds.
        -- ---------------------------------------------------------------
        do
        fake.files[INIT] = [[
local favicons = require("platform.favicons")
return { api = 1, id = "ext_caps",
    action = function(ctx) favicons.new(ctx) end }
]]
        fake.files[EXT_DIR .. "/ext_caps/lua/helper.lua"] = nil
        -- The REAL platform source, so this tracks favicons as it actually is.
        local fh = io.open("app/platform/lua/favicons.lua", "r")
        ok(fh ~= nil, "the favicons source is readable (no false green)")
        if fh then
            fake.files["app/platform/lua/favicons.lua"] = fh:read("*a")
            fh:close()
        end
        local r = registry.validateExtension("ext_caps")
        local caps = {}
        for _, c in ipairs(r.underDeclared) do caps[c] = true end
        ok(caps.network == true,
            "requiring platform.favicons attributes its network reach to the extension")
        end

        -- ---------------------------------------------------------------
        -- Refusals. Both are the CALLER's mistake, and each must say which.
        -- ---------------------------------------------------------------
        do
        local r = registry.validateExtension("no_such_thing")
        ok(r.ok == false and r.error ~= nil, "an unknown id is refused, with a reason")

        registry.register({ api = 1, id = "vx_builtin", name = "VX Builtin",
                            action = function() end })
        local b = registry.validateExtension("vx_builtin")
        ok(b.ok == false and b.error ~= nil and b.error:match("built%-in") ~= nil,
            "a BUILT-IN is refused by name -- this tool is for user extensions")
        end
    end,
}
