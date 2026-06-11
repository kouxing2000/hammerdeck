-- features/clipboard_clean
--
-- "Clean Clipboard": rewrites the clipboard as trimmed plain text (which also
-- strips any rich RTF/HTML formatting, since we read and write the *string*
-- representation), optionally turning newlines into commas. Paste as usual
-- afterwards. Ported from myHammerSpoon modules/input/clipboardActions.lua.
--
-- Deliberately NOT ported yet (deferred until Accessibility onboarding, queue
-- item #6): the donor's auto-paste (synthesize Cmd-V) and "type clipboard as
-- keystrokes" actions. Simulating keystrokes into other apps requires the
-- Accessibility permission, which hammerdeck does not request yet -- so this
-- transforms the clipboard in place and lets you paste with your own Cmd-V.
--
-- ACTION feature: one trigger -> one action. Want both transforms on separate
-- hotkeys? Enable two copies once feature instances land; for now the `mode`
-- option picks the transform.

local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

return {
    api         = 1,
    id          = "clipboard_clean",
    name        = "Clean Clipboard",
    description = "Rewrites the clipboard as trimmed plain text (strips "
        .. "formatting); optionally turns newlines into commas. Then paste as usual.",
    version     = "1.0.0",
    category    = "productivity",

    options = {
        { key = "mode", type = "enum", default = "plainText",
          values = { "plainText", "newlinesToCommas" },
          label = "Transform" },
    },

    -- ctrl+cmd+v: the donor's "paste simple format" combo (cmd+alt+ctrl+c
    -- belongs to the countdown feature, donor parity).
    defaultTrigger = { type = "hotkey", mods = { "ctrl", "cmd" }, key = "v" },

    action = function(ctx)
        local text = ctx.pasteboardRead()
        if not text or text == "" then
            ctx.alert("Clipboard is empty")
            return
        end

        local cleaned = trim(text)
        if ctx.opt("mode") == "newlinesToCommas" then
            cleaned = cleaned:gsub("\r", ""):gsub("\n", ",")
        end

        ctx.pasteboardWrite(cleaned)
        ctx.notify("Clipboard cleaned", "Plain text ready -- paste with Cmd-V")
    end,
}
