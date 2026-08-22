-- test/cases/_integration/platform/api_surface.lua -- registry.apiSurface, the
-- MCP `list_api` tool's answer: what does THIS feature's ctx actually contain?
--
-- Why the question needs a tool at all. A withheld capability method is replaced
-- by a raising STUB, not deleted, so the table still has the key -- an agent
-- cannot probe `ctx.httpGet ~= nil` and learn anything. And the surface is built
-- inline in ctx.make rather than declared as a list, so there is nothing to read
-- either. Without this, a wrong ctx member is discovered at runtime, on whichever
-- branch reaches it.
--
-- The last block is the load-bearing one: a user extension and a built-in that
-- declare the same capabilities must receive the SAME surface. bindFeature
-- branches on declared capabilities and never on m.extension, so that holds by
-- construction -- this is what turns "by construction" into something an
-- extension author can be shown.

local EXT_DIR = "test/fixtures/extensions"

---@param list string[]
---@return table<string, boolean>
local function asSet(list)
    local s = {}
    for _, v in ipairs(list) do s[v] = true end
    return s
end

return {
    id = "api_surface",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        -- ---------------------------------------------------------------
        -- Declaring nothing: the gated methods are named as withheld, with
        -- the capability that would unlock each.
        -- ---------------------------------------------------------------
        registry.register({ api = 1, id = "as_bare", name = "AS Bare",
                            action = function() end })
        local bare = registry.apiSurface("as_bare")
        ok(bare.withheld.httpGet == "network",
            "a withheld method is named with the capability that unlocks it")
        ok(asSet(bare.available).httpGet == nil,
            "and is kept OUT of available -- the raising stub is not a member")
        ok(asSet(bare.available).alert == true,
            "an ungated method is available with nothing declared")
        ok(#bare.granted == 0, "nothing declared, nothing granted")

        -- ---------------------------------------------------------------
        -- Declaring the capability moves the method across, and only that
        -- capability's methods.
        -- ---------------------------------------------------------------
        registry.register({ api = 1, id = "as_net", name = "AS Net",
                            capabilities = { "network" }, action = function() end })
        local net = registry.apiSurface("as_net")
        ok(asSet(net.available).httpGet == true, "a declared capability's method is available")
        ok(net.withheld.httpGet == nil, "and no longer withheld")
        ok(net.withheld.typeText == "input", "an UNdeclared tier is still withheld")
        ok(net.granted[1] == "network", "the report echoes what feature.json declared")

        -- ---------------------------------------------------------------
        -- The domain sub-tables are expanded. ctx.window alone carries a
        -- large share of the surface; reporting the parent would hide it.
        -- ---------------------------------------------------------------
        do
        local avail = asSet(net.available)
        ok(avail["window.setFrame"] == true, "ctx.window.* members are named individually")
        ok(avail.window == nil, "and the bare parent table is not passed off as a member")
        end

        -- ---------------------------------------------------------------
        -- `commands` is ADDITIVE -- injected, never gated -- so it shows up
        -- as extra members rather than as one fewer withheld entry.
        -- ---------------------------------------------------------------
        do
        ok(asSet(bare.available).runCommand == nil,
            "an ordinary feature does not get the cross-feature reach")
        registry.register({ api = 1, id = "as_cmd", name = "AS Cmd",
                            capabilities = { "commands" }, action = function() end })
        local cmd = registry.apiSurface("as_cmd")
        local avail = asSet(cmd.available)
        ok(avail.commands == true and avail.runCommand == true,
            "declaring 'commands' injects both palette methods onto ctx")
        end

        -- ---------------------------------------------------------------
        -- PARITY. A user extension and a built-in declaring the same thing
        -- receive the same ctx -- the claim an extension author has to take
        -- on trust otherwise.
        -- ---------------------------------------------------------------
        do
        fake.settings["hammerdeck.extensionsDir"] = EXT_DIR
        fake.featuresByDir[EXT_DIR] = { "ext_caps" }
        ok(registry.loadExtensions() == 1, "the extension fixture loads")

        -- ext_caps/feature.json declares exactly {"power"}.
        registry.register({ api = 1, id = "as_power", name = "AS Power",
                            capabilities = { "power" }, action = function() end })
        local ext = registry.apiSurface("ext_caps")
        local built = registry.apiSurface("as_power")
        ok(ext.extension == true and built.extension == false,
            "the report says which is which")
        ok(table.concat(ext.available, ",") == table.concat(built.available, ","),
            "an extension receives exactly the built-in surface for the same declaration")
        local function withheldKeys(r)
            local ks = {}
            for name, cap in pairs(r.withheld) do ks[#ks + 1] = name .. "=" .. cap end
            table.sort(ks)
            return table.concat(ks, ",")
        end
        ok(withheldKeys(ext) == withheldKeys(built),
            "and exactly the same withholding -- both halves, or the claim is half-checked")
        ok(asSet(ext.available).lockScreen == true,
            "including the gated methods it declared -- no extension-only withholding")
        end

        ok(registry.apiSurface("no_such_thing").error ~= nil,
            "an unknown id is refused, with a reason")
    end,
}
