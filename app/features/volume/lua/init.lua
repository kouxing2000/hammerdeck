-- features/volume
--
-- Nudge the system output volume or toggle mute. Context-free state-changers,
-- so each action is automatable: bind "up"/"down" to a hotkey or chord, or
-- "mute" to a schedule / system event ("on wake -> unmute"). Sets the volume via
-- AppleScript (the public path) -- no Accessibility grant needed.
--
-- Note: the macOS volume HUD does NOT appear for an AppleScript volume change
-- (that needs a hardware media-key event, which the media_keys feature posts);
-- the change is still applied and audible. An on-screen confirmation HUD is a
-- deferred follow-up that rides the media-key work.

return {
    api = 1,
    id  = "volume",

    options = {
        { key = "step", type = "int", label = "Step size", default = 10, min = 1, max = 50,
          hint = "How much each Up / Down press changes the volume (on the 0-100 scale)." },
    },

    actions = {
        { id = "up", label = "Volume up", automatable = true,
          run = function(ctx) ctx.adjustVolume(ctx.opt("step")) end },
        { id = "down", label = "Volume down", automatable = true,
          run = function(ctx) ctx.adjustVolume(-ctx.opt("step")) end },
        { id = "mute", label = "Toggle mute", automatable = true,
          run = function(ctx) ctx.toggleMute() end },
    },
}
