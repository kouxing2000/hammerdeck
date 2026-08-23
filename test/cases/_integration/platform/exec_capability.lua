-- test/cases/_integration/platform/exec_capability.lua -- the `exec` tier and the
-- raw-stdlib reach capscan learned alongside it.
--
-- Why this exists. `luaL_openlibs` hands every feature the whole Lua standard
-- library, so `os.execute` was always a way to run a program with no declaration
-- in feature.json, no line in the daily log, and no timeout -- synchronously, on
-- the main thread. The gate could not see it because capscan only ever matched
-- `ctx%.`, and the gate can only withhold what it hands out.
--
-- Two halves, and BOTH are needed for the claim to hold:
--   1. `ctx.run` -- a declared, async, logged, scope-tracked way to run a program,
--      so there is a supported route to point authors at.
--   2. capscan sees raw stdlib reach -- so an extension that goes around ctx is
--      REPORTED rather than silently unaccounted for.
--
-- The embedded state additionally replaces os.execute / io.popen with raising
-- stubs (LuaState.installSubprocessStubs) -- that half is Swift-side and is
-- covered by LuaStateTests, because this suite runs on a plain `lua` binary
-- where those functions legitimately still exist (the harness itself shells out
-- with io.popen to enumerate files).

return {
    id = "exec_capability",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry
        local capscan  = require("platform.capscan")
        local manifest = require("platform.manifest")

        -- ---------------------------------------------------------------
        -- The tier exists and is wired to exactly one ctx method.
        -- ---------------------------------------------------------------
        ok(manifest.KNOWN_CAPABILITIES.exec == true, "'exec' is a declarable capability")
        ok(capscan.capabilityOf().run == "exec", "ctx.run is gated by 'exec'")

        -- ---------------------------------------------------------------
        -- Withheld by default: the stub raises and names what to add. A
        -- missing key would be indistinguishable from a typo, which is why
        -- the gate replaces rather than deletes.
        -- ---------------------------------------------------------------
        local bareRan
        registry.register({
            api = 1, id = "bare_probe", name = "Bare probe",
            action = function(ctx)
                bareRan = select(2, pcall(ctx.run, "/bin/echo", { "hi" }, function() end))
            end,
        })
        registry.setEnabled("bare_probe", true)
        registry.runAction("bare_probe")
        -- Match the QUOTED capability, not the bare word: the stub message also
        -- carries the feature id, so a fixture called `exec_bare` would satisfy
        -- this assertion without the gate saying anything at all.
        ok(type(bareRan) == "string" and bareRan:find("'exec'", 1, true) ~= nil,
            "an undeclared ctx.run raises an error naming the 'exec' capability -- got: "
            .. tostring(bareRan))
        ok(#fake.runs == 0, "and never reached the seam")

        local surface = registry.apiSurface("bare_probe")
        ok(surface.withheld.run == "exec", "list_api reports run as withheld by 'exec'")

        -- ---------------------------------------------------------------
        -- Declared: it reaches the adapter with an argv ARRAY (no shell
        -- string anywhere in the path), and the callback carries the three
        -- values a caller needs to tell success from failure.
        -- ---------------------------------------------------------------
        local got
        registry.register({
            api = 1, id = "exec_ok", name = "Exec ok",
            capabilities = { "exec" },
            action = function(ctx)
                ctx.run("/usr/bin/git", { "status", "--porcelain" }, function(code, out, err)
                    got = { code = code, out = out, err = err }
                end)
            end,
        })
        fake.runResults["/usr/bin/git"] = { status = 0, stdout = " M a.lua\n", stderr = "" }
        registry.setEnabled("exec_ok", true)
        registry.runAction("exec_ok")

        ok(#fake.runs == 1, "a declared ctx.run reaches the seam")
        ok(fake.runs[1].path == "/usr/bin/git", "with the absolute path it was given")
        ok(#fake.runs[1].args == 2 and fake.runs[1].args[1] == "status",
            "and the arguments as an array, never joined into a command line")
        ok(got ~= nil and got.code == 0 and got.out == " M a.lua\n",
            "the callback receives (status, stdout, stderr)")

        ok(registry.apiSurface("exec_ok").withheld.run == nil,
            "list_api no longer withholds run once 'exec' is declared")

        -- ---------------------------------------------------------------
        -- Scope-tracked like every other async one-shot: a feature disabled
        -- mid-run must not hear back. Same guarantee async_teardown proves
        -- for httpGet -- asserted here too because ctx.run is the one whose
        -- callback could act on a command that already changed the machine.
        -- ---------------------------------------------------------------
        local late = 0
        registry.register({
            api = 1, id = "exec_slow", name = "Exec slow",
            capabilities = { "exec" },
            start = function(ctx)
                ctx.run("/bin/sleep", { "5" }, function() late = late + 1 end)
            end,
        })
        fake.deferAsync = true
        registry.setEnabled("exec_slow", true)
        ok(fake.liveHandles == 1, "an in-flight ctx.run is a live tracked handle")
        registry.setEnabled("exec_slow", false)
        ok(fake.liveHandles == 0, "teardown released it")
        fake.deliverAsync()
        ok(late == 0, "a run that lands after disable is dropped")
        fake.deferAsync = false

        registry.setEnabled("bare_probe", false)
        registry.setEnabled("exec_ok", false)

        -- ---------------------------------------------------------------
        -- capscan: raw stdlib reach counts as the tier it goes around.
        -- ---------------------------------------------------------------
        local capOf = capscan.capabilityOf()
        local _, _, raw = capscan.scanSource([[
            local x = os.execute("ls")
            local f = io.open("/etc/hosts", "r")
        ]], capOf)
        ok(raw["io.open"] ~= nil and raw["io.open"].cap == "files",
            "io.open is reported as files-tier reach")
        -- A WITHDRAWN name carries a replacement, not a capability: declaring
        -- something cannot make a raising stub run.
        ok(raw["os.execute"] ~= nil and raw["os.execute"].cap == nil
            and raw["os.execute"].use == "ctx.run",
            "os.execute is reported as withdrawn, pointing at ctx.run")

        -- `_G.io.open` is the standard library reached the long way round -- the
        -- preceding-dot rule that rejects `self.io.open` must not reject it.
        -- Scanned ALONE, or a bare `io.open` on another line would carry it.
        local _, _, viaG = capscan.scanSource('local g = _G.io.open(p, "r")', capOf)
        ok(viaG["io.open"] ~= nil, "`_G.` prefixed stdlib reach is still reach")

        -- The BRACKET form is the same call. If quoting the key hid it, quoting
        -- the key would be the way around every check in this module -- and the
        -- string-blanking that kills prose false positives is exactly what would
        -- have eaten it, so the normalization has to run first.
        local _, _, viaBracket = capscan.scanSource('os["execute"]("ls")', capOf)
        ok(viaBracket["os.execute"] ~= nil, [[os["execute"] is seen as os.execute]])
        local _, _, viaBracket2 = capscan.scanSource("local f = io['open'](p)", capOf)
        ok(viaBracket2["io.open"] ~= nil, "single quotes too")

        -- Reads a file from any path and RUNS it. The path is `files`-tier reach;
        -- what the chunk then does is past any static scan, which is the limit
        -- this module states rather than hides.
        local _, _, viaDofile = capscan.scanSource('dofile("/tmp/x.lua")', capOf)
        ok(viaDofile["dofile"] ~= nil and viaDofile["dofile"].cap == "files",
            "dofile is files-tier reach")

        -- Withdrawn for BLAST RADIUS, not reach: os.exit takes the host down from
        -- inside a callback, so it carries no capability to declare.
        local _, _, viaExit = capscan.scanSource("os.exit(0)", capOf)
        ok(viaExit["os.exit"] ~= nil and viaExit["os.exit"].cap == nil,
            "os.exit is withdrawn, and is not offered as a tier to declare")

        -- THE SEAM TABLE. `native` is a plain Lua global, so calling it directly
        -- skips the gate with no declaration to check -- which would make every
        -- verdict this module gives meaningless. It is the widest thing the scan
        -- has to see, and it saw nothing at all until this was added.
        local _, _, viaNative =
            capscan.scanSource('native.run_process("/bin/sh", {"-c","x"}, f)', capOf)
        ok(viaNative["native.run_process"] ~= nil
            and viaNative["native.run_process"].cap == nil,
            "a direct native.* call is reported, and as withdrawn-kind (no tier legitimises it)")
        -- ...but a field called `native` on someone's own table is not the seam.
        local _, _, notNative = capscan.scanSource("self.native.foo()", capOf)
        ok(next(notNative) == nil, "self.native.foo is not the seam -- got: "
            .. tostring(next(notNative)))

        local _, _, commented = capscan.scanSource("-- calls os.execute somewhere", capOf)
        ok(next(commented) == nil, "prose in a comment does not fabricate reach")

        -- A plain substring search matches the TAIL of an unrelated name --
        -- `studio.open` ends in "io.open", `myos.execute` in "os.execute" -- and a
        -- guard that cries wolf is one authors learn to ignore.
        local _, _, lookalikes = capscan.scanSource([[
            local s = studio.open(path)
            audio.popen()
            chaos.rename(a, b)
            myos.execute(1)
            self.io.open(p)
        ]], capOf)
        ok(next(lookalikes) == nil,
            "a name merely ENDING in a stdlib call is not reach -- got: "
            .. tostring(next(lookalikes)))

        -- A string literal or a trailing comment mentioning a stdlib name is not
        -- reach. This direction matters MORE than a missed call: a phantom
        -- requirement is silenced by DECLARING the capability, and once declared
        -- the over-declaration check can no longer fire -- so an over-eager
        -- scanner talks authors into claiming privilege they never use.
        local _, _, prose = capscan.scanSource([[
            local msg = "use io.open for that"
            local n = 1   -- os.remove is the other one
        ]], capOf)
        ok(next(prose) == nil,
            "a stdlib name inside a string or a trailing comment is not reach -- got: "
            .. tostring(next(prose)))
        -- This module's own RAW_REACH table is the worked example, so scan it.
        -- Located through appdir and asserted UNCONDITIONALLY: guarding the
        -- assertion behind `if fh` made the whole check vanish from any cwd
        -- where a relative path missed, and the suite still reported green.
        local capscanPath = require("loader").appdir .. "/platform/lua/capscan.lua"
        local capscanSrc = io.open(capscanPath, "r")
        ok(capscanSrc ~= nil, "the capscan source is readable at " .. capscanPath)
        if capscanSrc then
            local text = capscanSrc:read("*a")
            capscanSrc:close()
            local _, _, selfScan = capscan.scanSource(text, capOf)
            ok(next(selfScan) == nil,
                "capscan does not report its OWN pattern table as reach -- got: "
                .. tostring(next(selfScan)))
        end

        -- Under-declared: a declarable raw call needs the tier just as ctx would.
        local under = capscan.compare({}, {}, capOf, { ["io.open"] = { cap = "files" } })
        ok(#under == 1 and under[1] == "files", "raw reach with no declaration is under-declared")

        -- ...and satisfies it, so declaring `files` for a raw call is not "unused".
        local under2, over2 =
            capscan.compare({}, { "files" }, capOf, { ["io.open"] = { cap = "files" } })
        ok(#under2 == 0 and #over2 == 0, "and a matching declaration is neither under nor over")

        -- The over-declaration check still bites when nothing reaches the tier --
        -- the half that keeps the labels from rotting into decoration.
        local _, over3 = capscan.compare({}, { "exec" }, capOf, {})
        ok(#over3 == 1 and over3[1] == "exec", "a declared-but-unreached 'exec' is over-declared")

        -- THE VERDICT FIX. A withdrawn name is not satisfiable by declaring
        -- anything: the code raises whatever feature.json says, so counting the
        -- declaration would report an extension that cannot run as honest.
        local under4, over4, gone =
            capscan.compare({}, { "exec" }, capOf, { ["os.execute"] = { use = "ctx.run" } })
        ok(#gone == 1 and gone[1] == "os.execute -> ctx.run",
            "a withdrawn call is reported on its own, with its replacement")
        ok(#under4 == 0 and #over4 == 0,
            "ONE finding, one fix: the replacement's tier is already declared, so the "
            .. "author is not also told to remove a declaration the rewrite will need")

        -- Undeclared, the same call earns exactly one more finding: the tier the
        -- rewrite lands on.
        local under5, over5 = capscan.compare({}, {}, capOf, { ["os.execute"] = { use = "ctx.run" } })
        ok(#under5 == 1 and under5[1] == "exec" and #over5 == 0,
            "and undeclared, it asks for the tier ctx.run needs -- nothing else")

        -- A withdrawn name with NO ctx replacement (the seam table, os.exit)
        -- carries no tier at all, so it can never make one look needed.
        local under6, over6, gone6 = capscan.compare({}, {}, capOf,
            { ["native.run_process"] = { use = "the matching ctx method" } })
        ok(#gone6 == 1 and #under6 == 0 and #over6 == 0,
            "a replacement that is not a ctx method implies no capability")
    end,
}
