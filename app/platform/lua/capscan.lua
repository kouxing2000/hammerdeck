-- app/platform/lua/capscan.lua -- the capability DECLARATION rule, in one place.
--
-- "Which capabilities does this code actually need, and does its feature.json
-- say so?" is asked from two places that cannot share a caller: the build guard
-- (test/cases/_integration/platform/feature_capabilities.lua, over the
-- first-party catalog) and the running app (registry.validateExtension, over a
-- user extension an agent just wrote). Answering it twice would let the two
-- answers drift, and a guard that disagrees with the app it guards is worse than
-- no guard -- so the RULE lives here and the callers differ only in how they
-- hand over source text.
--
-- Nothing here touches the adapter, the filesystem, or native: it is text in,
-- verdict out. That is what lets the build guard read files with `find` while
-- the runtime walks the require graph through the seam.
--
-- Source-scanning, so it cannot see dynamic dispatch (`ctx[name]()`); the
-- runtime stub in ctx.make stays the backstop for that.

local manifest = require("platform.manifest")

local M = {}

---Inverted view of manifest.CAPABILITY_METHODS: gated ctx method -> capability.
---Derived from the same table ctx.make gates on, so the check cannot drift from
---the gate it describes.
---@return table<string,string>
function M.capabilityOf()
    local capOf = {}
    for cap, methods in pairs(manifest.CAPABILITY_METHODS) do
        for _, name in ipairs(methods) do capOf[name] = cap end
    end
    return capOf
end

---Standard-library calls that reach the OS WITHOUT going through ctx, mapped to
---the capability the equivalent ctx method is gated by. `luaL_openlibs` hands
---every feature the whole stdlib, so these are real reach the `ctx%.` scan below
---cannot see -- and a declaration that ignores them is not honest.
---
---Two kinds of entry, and the difference decides the VERDICT:
---  `cap` -- the tier to declare. The call works; the declaration must say so.
---  `use` -- WITHDRAWN from the embedded interpreter (LuaState installs a raising
---           stub). No declaration can make it work, so it is reported on its own
---           and never satisfies one. Listed here so an author is told before
---           running the code rather than after.
---@type table<string,{cap: string?, use: string?}>
M.RAW_REACH = {
    ["io.open"]  = { cap = "files" },
    ["io.lines"] = { cap = "files" },
    ["os.remove"] = { cap = "files" },
    ["os.rename"] = { cap = "files" },
    -- Read a file from any path and RUN it. `files` is the honest tier for the
    -- path; what the loaded chunk then reaches is beyond any static scan, which
    -- is the standing limit this module documents rather than papers over.
    ["dofile"]   = { cap = "files" },
    ["loadfile"] = { cap = "files" },
    ["os.execute"]      = { use = "ctx.run" },
    ["io.popen"]        = { use = "ctx.run" },
    ["package.loadlib"] = { use = "ctx.run" },
    -- Withdrawn for blast radius rather than reach: it takes the host down from
    -- inside a feature callback, skipping every teardown, and there is no ctx
    -- equivalent because quitting the app is not a feature's decision.
    ["os.exit"] = { use = "nothing -- a feature cannot quit the app" },
}

---Does `line` call the stdlib function `name` (e.g. "io.open")?
---
---A plain substring search is wrong at both ends of the name: `studio.open` ends
---in "io.open" and `myos.execute` ends in "os.execute", so the frontier
---`%f[%w_]` pins the start to a real word boundary. A preceding DOT then has to
---be rejected separately -- `.` is outside `[%w_]`, so it satisfies the frontier
---and `self.io.open` would read as the standard library when it is a field on
---someone's table. `_G.` is the one prefix that IS the standard library.
---@param line string
---@param name string
---@return boolean
local function callsStdlib(line, name)
    local pat = "%f[%w_]" .. name:gsub("%.", "%%.")
    local at = line:find(pat)
    while at do
        local before = line:sub(1, at - 1)
        if not before:match("%.%s*$") or before:match("%f[%w_]_G%s*%.%s*$") then
            return true
        end
        at = line:find(pat, at + 1)
    end
    return false
end

---`src` with every comment -- and, unless `keepStrings`, every string literal --
---blanked to spaces, newlines kept so line numbers and line structure survive.
---
---The reach patterns match bare prose, so a docstring or an error message
---containing the literal "io.open" would otherwise fabricate `files` reach. That
---is the worst direction to err in: for a `cap` kind the author silences the
---phantom by DECLARING the capability, after which the over-declaration check
---can never fire again -- an over-eager scanner in a declare-what-you-reach
---system talks authors into claiming privilege they do not use. For a `use` kind
---it is worse still: nothing silences it, so a header comment saying "never call
---os.execute here" fails the build with no available fix.
---
---Which is why this is a real scan and not three `gsub`s. A line-at-a-time
---version handled `"..."` and a trailing `--` and missed the two commonest
---shapes of the very thing it exists to stop -- a `--[[ ]]` block comment and a
---`[[ ]]` help string -- plus any `\"` escape inside a quoted span.
---
---`keepStrings` is for the require pass, whose subject (`require "platform.json"`)
---IS a string literal; it still wants comments gone, so a commented-out require
---is not followed.
---@param src string
---@param keepStrings boolean?
---@return string
local function stripLiterals(src, keepStrings)
    local out, i, n = {}, 1, #src
    local function blanked(s) return (s:gsub("[^\n]", " ")) end
    while i <= n do
        local c = src:sub(i, i)
        local comment = src:sub(i, i + 1) == "--"
        -- A long bracket opens a comment when it follows `--`, and a string
        -- otherwise; both run to the matching `]=*]` and both end the scan's
        -- interest in what is between.
        local eq = src:match("^%[(=*)%[", comment and i + 2 or i)
        if eq and (comment or not keepStrings) then
            local close = "]" .. eq .. "]"
            local stop = src:find(close, (comment and i + 2 or i) + #eq + 2, true)
            local finish = stop and (stop + #close - 1) or n
            out[#out + 1] = blanked(src:sub(i, finish))
            i = finish + 1
        elseif comment then
            local stop = (src:find("\n", i, true) or n + 1) - 1
            out[#out + 1] = blanked(src:sub(i, stop))
            i = stop + 1
        elseif (c == '"' or c == "'") and not keepStrings then
            local j = i + 1
            while j <= n do
                local ch = src:sub(j, j)
                if ch == "\\" then j = j + 2          -- `\"` does not close the span
                elseif ch == c or ch == "\n" then break
                else j = j + 1 end
            end
            out[#out + 1] = blanked(src:sub(i, math.min(j, n)))
            i = j + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

---Gated ctx.* calls, raw stdlib reach, and platform/extension requires in ONE
---file's text. Comment lines are skipped so prose in a header ("calls
---ctx.httpGet") never fabricates a requirement.
---
---Static, so it cannot see dynamic dispatch -- `ctx[name]()`, or code built at
---runtime and handed to `load()`. Detecting `load` is deliberately NOT attempted:
---a local helper named `load` is ordinary Lua, common enough that the catalog
---already contains one, so the pattern's catches here are false. The runtime stub in
---ctx.make stays the backstop, and the honest claim is that an accurate
---declaration is easy and an inaccurate one is conspicuous -- not that lying is
---impossible.
---@param src string             file contents
---@param capOf table<string,string>
---@return table<string,boolean> calls     gated ctx method names
---@return table<string,boolean> requires  required module paths, whole and dotted
---        ("platform.json", "extensions.my_feature.helper") -- the caller splits
---        them, because the namespaces have different depths.
---@return table<string,{cap: string?, use: string?}> raw  reach around ctx -- a
---        stdlib name mapped through RAW_REACH, or a `native.<field>` call, which
---        is `use`-kind because the seam table is a plain Lua global and reaching
---        it directly skips the gate entirely.
function M.scanSource(src, capOf)
    local calls, requires, raw = {}, {}, {}

    -- `os["execute"]` is the same call as `os.execute`, so normalize the bracket
    -- form BEFORE the literals go: stripping first would eat the key and leave
    -- `os[" "]`, making quotes the way to hide from this scan. The key class
    -- excludes `.`, so a table literal like `["io.open"] = ...` (this module's
    -- own RAW_REACH) is untouched.
    local normalized = (src or ""):gsub('([%w_])%s*%[%s*["\']([%w_]+)["\']%s*%]', "%1.%2")

    for line in stripLiterals(normalized):gmatch("[^\n]*") do
        for name in line:gmatch("ctx%.(%w+)") do
            if capOf[name] then calls[name] = true end
        end
        for name, reach in pairs(M.RAW_REACH) do
            if callsStdlib(line, name) then raw[name] = reach end
        end
        -- The seam table itself. `native` is installed with lua_setglobal, so
        -- nothing stops a feature calling native.run_process directly -- and that
        -- route has no declaration to check, which would make every verdict this
        -- module gives meaningless. Reported as `use`-kind: there is no
        -- capability that legitimises it, only the ctx method.
        local at = 1
        while true do
            local s, e, field = line:find("%f[%w_]native%s*%.%s*([%w_]+)", at)
            if not s then break end
            -- Same preceding-dot rule as the stdlib names: `self.native.x` is a
            -- field on someone's table, `_G.native.x` is the seam.
            local before = line:sub(1, s - 1)
            if not before:match("%.%s*$") or before:match("%f[%w_]_G%s*%.%s*$") then
                raw["native." .. field] = { use = "the matching ctx method" }
            end
            at = e + 1
        end
    end

    -- Requires read from the COMMENT-stripped source with strings intact: the
    -- module name is itself a string literal, so this pass cannot use the text
    -- the others do.
    for line in stripLiterals(src or "", true):gmatch("[^\n]*") do
        -- The WHOLE dotted path: platform.* is two segments while
        -- extensions.<id>.* and features.<id>.* are three, so a fixed-arity
        -- pattern silently truncates the deeper ones and the sibling module is
        -- never followed.
        local mod = line:match("require%s*%(?%s*[\"']([%w_%.]+)[\"']")
        if mod and mod:find("%.") then requires[mod] = true end
    end

    return calls, requires, raw
end

---Compare what the code reaches against what feature.json claims.
---@param calls table<string,boolean>     gated ctx methods actually called
---@param declared string[]               the feature.json `capabilities` list
---@param capOf table<string,string>
---@param raw table<string,{cap: string?, use: string?}>|nil  scanSource's 3rd result
---@return string[] under  needed but not declared -- a latent crash
---@return string[] over   declared but unused -- a label rotting into decoration
---@return string[] withdrawn  calls to a name the interpreter no longer has, as
---        "os.execute -> ctx.run". NOT satisfiable by declaring anything: the
---        code raises whatever feature.json says, so a verdict that counted a
---        declaration here would call an extension honest AND unrunnable.
function M.compare(calls, declared, capOf, raw)
    local needed, have = {}, {}
    for name in pairs(calls) do needed[capOf[name]] = true end
    -- Raw stdlib reach counts as needing the same tier: `io.open` addresses any
    -- path exactly as ctx.fileRead does, so a feature doing it undeclared is
    -- under-declared, and one declaring `files` and only doing it is NOT
    -- over-declared.
    local withdrawn = {}
    for name, reach in pairs(raw or {}) do
        if reach.cap then needed[reach.cap] = true end
        if reach.use then
            withdrawn[#withdrawn + 1] = name .. " -> " .. reach.use
            -- The REPLACEMENT's tier counts as needed. An author who wrote
            -- os.execute and declared `exec` would otherwise be told both
            -- "rewrite to ctx.run" and "you over-declared exec" -- so they drop
            -- the declaration, rewrite the call, and are then told
            -- "under-declared: exec". One finding deserves one fix.
            local method = reach.use:match("^ctx%.(%w+)$")
            if method and capOf[method] then needed[capOf[method]] = true end
        end
    end
    for _, cap in ipairs(declared or {}) do have[cap] = true end

    local under, over = {}, {}
    for cap in pairs(needed) do
        if not have[cap] then under[#under + 1] = cap end
    end
    for cap in pairs(have) do
        -- `commands` is ADDITIVE (ctx.commands/runCommand are INJECTED, not
        -- gated), so it never appears in the map and is never "unused".
        if cap ~= "commands" and not needed[cap] then over[#over + 1] = cap end
    end
    table.sort(under)
    table.sort(over)
    table.sort(withdrawn)
    return under, over, withdrawn
end

return M
