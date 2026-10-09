-- test fixture: a USER EXTENSION holding the `commands` capability. It runs a
-- built-in through ctx.runCommand, which an extension may do on its own schedule,
-- so that run must never count toward the opt-in feature statistics.
return {
    api = 1,
    id  = "ext_cmd",
    defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "shift" }, key = "8" },
    action = function(ctx)
        ctx.runCommand("plain_paste", "main")
    end,
}
