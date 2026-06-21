-- features/plain_paste
--
-- "Paste as Plain Text" (id plain_paste; renamed from the old clipboard_clean
-- id, which read like it cleared clipboard history and collided with the
-- clipboard_history feature): rewrites the clipboard as trimmed plain text
-- (which also
-- strips any rich RTF/HTML formatting, since we read and write the *string*
-- representation), optionally turning newlines into commas. Ported from
-- myHammerSpoon modules/input/clipboardActions.lua -- now in FULL:
--
--   main  (ctrl+cmd+v)  paste as plain text: clean the clipboard, then a
--                       synthesized cmd+v pastes it (the donor's "paste
--                       simple format" -- one behavior, no switches).
--   type  (ctrl+cmd+b)  TYPE the cleaned clipboard as keystrokes instead of
--                       pasting (the donor's "type simple format" -- for
--                       paste-blocking password fields and the like).
--
-- The donor's "format" binding (newlines -> commas + paste) is the
-- mode=newlinesToCommas option. Pasting/typing synthesize keystrokes, which
-- needs the Accessibility permission.

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
    id          = "plain_paste",
    name        = "Paste as Plain Text",
    description = "Paste without formatting: strips fonts/colors/links from "
        .. "the copied text and pastes it (or types it as keystrokes).",
    version     = "1.2.0",
    category    = "productivity",

    options = {
        { key = "mode", type = "enum", default = "plainText",
          values = { "plainText", "newlinesToCommas" },
          labels = { "Plain text", "Newlines to commas" },
          label = "Transform" },
    },

    actions = {
        -- id "main" keeps the pre-multi-action stored trigger keys valid.
        { id = "main", label = "Paste as plain text",
          description = "Strip formatting from the clipboard text, then paste it "
              .. "with a synthesized cmd+v.",
          defaultTrigger = { type = "hotkey", mods = { "ctrl", "cmd" }, key = "v" },
          run = function(ctx)
              local text = cleaned(ctx)
              if not text then return end
              ctx.pasteboardWrite(text)
              -- Without the Accessibility grant macOS silently drops the
              -- synthesized cmd+v; the clipboard IS cleaned, so say so
              -- instead of appearing dead (and fire the system prompt).
              if not ctx.axTrusted() then
                  ctx.axPrompt()
                  ctx.alert("Clipboard cleaned -- paste with cmd+v "
                      .. "(grant Accessibility to paste automatically)")
                  return
              end
              -- The settle wait is load-bearing: the user is still holding
              -- ctrl+cmd from the trigger; synthesizing cmd+v immediately
              -- would merge into ctrl+cmd+v and re-trigger this action.
              ctx.afterSeconds(PASTE_SETTLE_SECONDS, function()
                  ctx.keyStroke({ "cmd" }, "v")
              end)
          end },
        { id = "type", label = "Type clipboard as keystrokes",
          description = "Type the stripped clipboard text as keystrokes instead "
              .. "of pasting -- works in paste-blocking fields.",
          defaultTrigger = { type = "hotkey", mods = { "ctrl", "cmd" }, key = "b" },
          run = function(ctx)
              local text = cleaned(ctx)
              if not text then return end
              if not ctx.axTrusted() then
                  ctx.axPrompt()
                  ctx.alert("Typing needs the Accessibility permission -- "
                      .. "grant Hammerdeck in System Settings, then try again")
                  return
              end
              ctx.typeText(text)
          end },
    },
}
