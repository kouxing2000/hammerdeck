-- test/cases/_integration/rules/rules_run_command.lua -- the runCommand effect: the
-- user's command line through `zsh -lc` (so the ~/.zprofile PATH resolves),
-- fire-and-forget like runShortcut, with every outcome the seam can report --
-- exit 0, a non-zero exit with its stderr, a signal kill (the 60s cap), a launch
-- that never happened -- reaching the daily log. The real seam hands every one of
-- them back asynchronously, so the effect only reports that it started one; the async
-- delivery is asserted under fake.deferAsync, which is how the real bridge behaves.
--
-- Also the RISK label it carries ("exec"), inherited by any chain containing it,
-- and offered to the form through the catalog.
--
-- Integration: platform subsystem. Hermetic -- freshWorld() runs registry.reset()
-- + rules.load({}) before the case.

return {
    id = "rules_run_command",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
        local rules   = require("platform.rules")
        local effects = require("platform.effects")

        local function loggedSince(from, needle)
            for i = from + 1, #fake.logs do
                if fake.logs[i]:find(needle, 1, true) then return true end
            end
            return false
        end

        -- Shape ----------------------------------------------------------------
        ok(pcall(effects.validate, { kind = "runCommand" }) == false, "a command is required")
        ok(pcall(effects.validate, { kind = "runCommand", command = "  \n " }) == false,
            "a whitespace-only command is refused")
        ok(pcall(effects.validate, { kind = "runCommand", command = "say hi" }) == true,
            "a real command validates")
        ok(effects.requiresContext({ kind = "runCommand", command = "x" }) == false,
            "runCommand is context-free, so it may sit on an automated trigger")

        -- Risk -----------------------------------------------------------------
        ok(effects.risk({ kind = "runCommand", command = "x" }) == "exec", "runCommand is an exec risk")
        ok(effects.risk({ kind = "chain", effects = { { kind = "notify", title = "a" },
                                                      { kind = "runCommand", command = "x" } } }) == "exec",
            "a chain inherits the risk of its risky step")
        ok(effects.risk({ kind = "chain", effects = { { kind = "runCommand", command = "x" },
                                                      { kind = "lockScreen" } } }) == "lockout",
            "a chain takes its MOST severe risk: a lock anywhere in it makes it a lockout")
        ok(effects.risk({ kind = "notify", title = "a" }) == nil, "an ordinary effect has no risk")
        ok(effects.risk({ kind = "lockScreen" }) == "lockout"
            and effects.risk({ kind = "emptyTrash" }) == "destructive",
            "lock is a lockout, empty Trash is destructive")
        local inCatalog
        for _, e in ipairs(effects.catalog(true)) do
            if e.kind == "runCommand" then inCatalog = e end
        end
        ok(inCatalog and inCatalog.risk == "exec", "the catalog offers runCommand, badged exec")

        -- Describe: one line, clipped ----------------------------------------------
        ok(effects.describe({ kind = "runCommand", command = "echo hi" }) == 'Run "echo hi"',
            "describe quotes the command")
        local long = effects.describe({ kind = "runCommand",
            command = "rsync -a --delete ~/Documents/\n  /Volumes/Backup/Documents/ && say done" })
        ok(not long:find("\n", 1, true) and #long <= #'Run ""' + 40,
            "a long, multi-line command is clipped to one line: " .. long)

        -- Dispatch: argv, and each outcome in the log ------------------------------
        fake.runs = {}
        local marker = #fake.logs
        local fired, note = effects.dispatch({ kind = "runCommand", command = "brew update" })
        ok(fired == true and note == nil,
            "a started command is a plain success -- no note, which would read as a partial one")
        local r = fake.runs[#fake.runs]
        ok(r and r.path == "/bin/zsh" and r.args[1] == "-lc" and r.args[2] == "brew update"
            and #r.args == 2, "it runs as /bin/zsh -lc <command>, the command one argument")
        ok(loggedSince(marker, "exited 0"), "exit 0 reaches the log")

        fake.runResults["/bin/zsh"] = { status = 2, stderr = "zsh: command not found: brw\nmore" }
        marker = #fake.logs
        fired = effects.dispatch({ kind = "runCommand", command = "brw update" })
        ok(fired == true, "a non-zero exit is known only later -- the effect itself launched")
        ok(loggedSince(marker, "exited 2: zsh: command not found: brw more"),
            "a non-zero exit logs its code and stderr, on one line")

        fake.runResults["/bin/zsh"] = { status = -15 }
        marker = #fake.logs
        effects.dispatch({ kind = "runCommand", command = "sleep 999" })
        ok(loggedSince(marker, "killed by signal 15"), "a killed command is logged as killed, not as exit 15")

        -- The real seam delivers every outcome later, a failed launch included: the
        -- effect has already returned "launched" by then, and the log carries the rest.
        fake.runResults["/bin/zsh"] = { status = nil }
        fake.deferAsync = true
        marker = #fake.logs
        fired, note = effects.dispatch({ kind = "runCommand", command = "x" })
        ok(fired == true and note == nil, "the effect returns before any outcome is known")
        ok(not loggedSince(marker, "could not start"), "nothing is logged until the seam answers")
        ok(fake.deliverAsync() == 1 and loggedSince(marker, "could not start /bin/zsh"),
            "a launch that never happened reaches the log when the seam answers")
        fake.deferAsync = false
        fake.runResults["/bin/zsh"] = nil

        -- A clip never cuts inside a UTF-8 character.
        local zh = effects.describe({ kind = "runCommand", command = string.rep("备份", 30) })
        ok(utf8.len(zh) ~= nil, "a long non-ASCII command is clipped on a character boundary")

        -- Through a rule: the fire line, then the outcome on its own line -----------
        rules.load({})
        local _, rid = rules.add({ on = { type = "event", event = "wake" },
                                   effect = { kind = "runCommand", command = "echo morning" } })
        rules.startAll()
        marker = #fake.logs
        fake.systemEvent("wake")
        ok(loggedSince(marker, "fired -> Run \"echo morning\"")
            and loggedSince(marker, "runCommand 'echo morning' exited 0"),
            "the rule's fire line is followed by the command's own exit line")

        -- Inside a chain it runs in order with the other steps.
        fake.runs = {}
        local okC = effects.dispatch({ kind = "chain", effects = {
            { kind = "runCommand", command = "a" }, { kind = "notify", title = "b" } } })
        ok(okC == true and #fake.runs == 1, "runCommand works as a chain step")

        -- cleanup
        rules.stopAll(); rules.load({})
        fake.settings["hammerdeck.rules"] = nil
        ok(rid ~= nil and fake.liveHandles == 0, "no native handle leaked across the runCommand test")
    end,
}
