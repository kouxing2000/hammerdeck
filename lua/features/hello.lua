-- features/hello.lua
--
-- Example feature -- the smallest thing that exercises the whole framework:
-- a manifest with a typed option, a default trigger, and an action that uses
-- ctx.opt() + ctx.adapter. Copy this as the template for real features.
--
-- A feature NEVER requires hs.* or platform internals -- it only receives `ctx`.

return {
    id          = "hello",
    name        = "Hello World",
    description = "Shows a notification. Proof that manifest -> trigger -> action works.",
    category    = "demo",

    options = {
        { key = "greeting", type = "string", default = "Hello from Hammerdeck", label = "Greeting text" },
    },

    -- Cmd+Alt+Ctrl+H by default; the user can rebind to a schedule/event in the UI.
    defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "h" },

    action = function(ctx)
        ctx.adapter.notify("Hammerdeck", ctx.opt("greeting"))
        ctx.log("fired")
    end,
}
