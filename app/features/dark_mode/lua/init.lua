-- features/dark_mode
--
-- Switch macOS between Dark and Light appearance. Context-free state-changers,
-- so each action is automatable: bind "toggle" to a hotkey, or "dark" / "light"
-- to a schedule ("at sunset -> dark", "at sunrise -> light"). Sets the SYSTEM
-- appearance via System Events, so the first run prompts for Automation.

return {
    api  = 1,
    id   = "dark_mode",

    actions = {
        { id = "toggle", label = "Toggle dark mode", automatable = true,
          run = function(ctx) ctx.setAppearance("toggle") end },
        { id = "dark", label = "Switch to dark", automatable = true,
          run = function(ctx) ctx.setAppearance("dark") end },
        { id = "light", label = "Switch to light", automatable = true,
          run = function(ctx) ctx.setAppearance("light") end },
    },
}
