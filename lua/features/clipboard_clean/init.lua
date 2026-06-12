-- features/clipboard_clean
--
-- "Clean Clipboard": rewrites the clipboard as trimmed plain text (which also
-- strips any rich RTF/HTML formatting, since we read and write the *string*
-- representation), optionally turning newlines into commas. Ported from
-- myHammerSpoon modules/input/clipboardActions.lua -- now in FULL:
--
--   main  (ctrl+cmd+v)  clean the clipboard; with the autoPaste option ON it
--                       then pastes for you (the donor's "paste simple
--                       format" -- synthesized cmd+v after a short settle).
--   type  (ctrl+cmd+b)  TYPE the cleaned clipboard as keystrokes instead of
--                       pasting (the donor's "type simple format" -- for
--                       paste-blocking password fields and the like).
--
-- The donor's "format" binding (newlines -> commas + paste) is the
-- mode=newlinesToCommas option + autoPaste. Auto-paste/typing synthesize
-- keystrokes, which needs the Accessibility permission; autoPaste defaults
-- OFF so the zero-permission behavior is unchanged until you opt in.

local PASTE_SETTLE_SECONDS = 0.5   -- donor's pause before the synthesized cmd+v

local function cleaned(ctx)
    local text = ctx.pasteboardRead()
    if not text or text == "" then
        ctx.alert("Clipboard is empty")
        return nil
    end
    local out = text:match("^%s*(.-)%s*$")
    if ctx.opt("mode") == "newlinesToCommas" then
        out = out:gsub("\r", ""):gsub("\n", ",")
    end
    return out
end

return {
    api         = 1,
    id          = "clipboard_clean",
    name        = "Clean Clipboard",
    description = "Rewrites the clipboard as trimmed plain text (strips "
        .. "formatting); can paste it for you, or type it as keystrokes.",
    version     = "1.1.0",
    category    = "productivity",

    options = {
        { key = "mode", type = "enum", default = "plainText",
          values = { "plainText", "newlinesToCommas" },
          label = "Transform" },
        { key = "autoPaste", type = "bool", default = false,
          label = "Paste automatically after cleaning" },
    },

    actions = {
        -- id "main" keeps the pre-multi-action stored trigger keys valid.
        { id = "main", label = "Clean clipboard",
          defaultTrigger = { type = "hotkey", mods = { "ctrl", "cmd" }, key = "v" },
          run = function(ctx)
              local text = cleaned(ctx)
              if not text then return end
              ctx.pasteboardWrite(text)
              if ctx.opt("autoPaste") then
                  ctx.afterSeconds(PASTE_SETTLE_SECONDS, function()
                      ctx.keyStroke({ "cmd" }, "v")
                  end)
              else
                  ctx.notify("Clipboard cleaned", "Plain text ready -- paste with Cmd-V")
              end
          end },
        { id = "type", label = "Type clipboard as keystrokes",
          defaultTrigger = { type = "hotkey", mods = { "ctrl", "cmd" }, key = "b" },
          run = function(ctx)
              local text = cleaned(ctx)
              if not text then return end
              ctx.typeText(text)
          end },
    },
}
