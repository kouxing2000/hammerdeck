-- test/cases/_integration/platform/agent_guide.lua -- the agent extension guide
-- (app/docs/hammerdeck-extension-skill.md -- the SKILL.md Settings exports and
-- the MCP server serves) must not drift from the code it teaches. The code
-- checks the doc, per the repo's README-catalog precedent: every capability
-- tier and every option type the platform actually implements must be named in
-- the guide, and the skill frontmatter must stay valid.

return {
    id = "agent_guide",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, manifest = t.ok, t.manifest

        local path = require("loader").appdir .. "/docs/hammerdeck-extension-skill.md"
        local f = io.open(path, "r")
        ok(f ~= nil, "agent guide exists at " .. path)
        if not f then return end
        local text = f:read("*a")
        f:close()

        -- A Claude Code skill needs frontmatter with name + description.
        ok(text:match("^%-%-%-\n") ~= nil, "guide starts with skill frontmatter")
        ok(text:find("\nname: ", 1, true) ~= nil or text:find("---\nname: ", 1, true) ~= nil,
            "frontmatter declares a name")
        ok(text:find("description: ", 1, true) ~= nil, "frontmatter declares a description")

        -- Every capability tier the gate implements (plus the additive
        -- `commands`) must be named -- an undocumented tier means an agent
        -- writes a feature that dies on a raising stub it was never told about.
        for cap in pairs(manifest.KNOWN_CAPABILITIES) do
            ok(text:find("`" .. cap .. "`", 1, true) ~= nil,
                "guide names capability '" .. cap .. "'")
        end

        -- Every option type the settings form can render must be named, or an
        -- agent invents its own vocabulary and validate() rejects it.
        for opt in pairs(manifest.VALID_OPTION_TYPES) do
            ok(text:find("`" .. opt .. "`", 1, true) ~= nil,
                "guide names option type '" .. opt .. "'")
        end

        -- Load-bearing phrases: the layout anchor, the wall-clock rule, and
        -- the positional-slot localization rule.
        for _, phrase in ipairs({ "lua/init.lua", "ctx.now()", "%1$s" }) do
            ok(text:find(phrase, 1, true) ~= nil,
                "guide keeps the '" .. phrase .. "' rule")
        end
    end,
}
