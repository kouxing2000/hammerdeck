-- features/media_keys
--
-- Play/pause, next, and previous track for whatever app is currently playing
-- (Music, Spotify, a browser) -- the same keys a keyboard's media row sends.
-- Context-free state-changers, so each action is automatable: bind to a hotkey
-- or chord, or to a schedule/event ("at bedtime -> pause"). Posts a system-
-- defined media key (NX_KEYTYPE_*) at the seam, which -- like type_text/
-- key_stroke -- needs the Accessibility grant on first use.

return {
    api = 1,
    id  = "media_keys",

    actions = {
        { id = "playpause", label = "Play / Pause", automatable = true,
          run = function(ctx) ctx.mediaKey("playpause") end },
        { id = "next", label = "Next track", automatable = true,
          run = function(ctx) ctx.mediaKey("next") end },
        { id = "previous", label = "Previous track", automatable = true,
          run = function(ctx) ctx.mediaKey("previous") end },
    },
}
