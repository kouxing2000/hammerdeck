-- features/text_actions
--
-- Act on the currently SELECTED text in any app (ported from myHammerSpoon
-- modules/input/textActions.lua): synthesize cmd+C to capture the selection,
-- then either open it (URLs) or offer a picker of transforms that paste the
-- result back over the selection (cmd+V).
--
-- Ported actions: open URL, lowercase, UPPERCASE, calculate (evaluates the
-- selection as a Lua expression in a math-only sandbox), and the Youdao
-- dictionary lookup (activate the app, type the phrase, hit return).
-- DEFERRED to #13 (ai_actions): refine/enrich/complete/translate/summary/
-- freeAsk and the donor's separate "quick refine" hotkey -- they all call the
-- GPT module, which is not ported yet. They will join this picker.
--
-- Donor semantics kept: the clipboard is NOT saved/restored -- transforms
-- intentionally leave the result on the clipboard, and pastes are async.
-- Requires the Accessibility permission (keystroke synthesis); without it
-- macOS silently drops the synthesized cmd+C and the selection stays empty.

local COPY_SETTLE_SECONDS = 0.15   -- let the copied selection reach the clipboard
local YOUDAO_SETTLE_SECONDS = 0.75 -- donor's pause for the dict app to focus

return {
    api         = 1,
    id          = "text_actions",
    name        = "Text Actions",
    description = "Act on the selected text anywhere: open URLs, change case, "
        .. "calculate, look up in a dictionary. Transforms paste back in place.",
    version     = "1.0.0",
    category    = "productivity",

    options = {
        { key = "dictApp", type = "string", default = "网易有道词典",
          label = "Dictionary app (must be running)" },
    },

    actions = {
        {
            id = "quick_open",
            label = "Act on selected text",
            defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "o" },
            run = function(ctx)
                ctx.keyStroke({ "cmd" }, "c")
                ctx.afterSeconds(COPY_SETTLE_SECONDS, function()
                    local raw = ctx.pasteboardRead()
                    local content = raw and raw:match("^%s*(.-)%s*$") or ""
                    if content == "" then
                        if not ctx.axTrusted() then
                            ctx.axPrompt()
                            ctx.alert("Selection Actions needs the Accessibility "
                                .. "permission to read the selection -- grant it "
                                .. "in System Settings, then try again")
                        else
                            ctx.alert("Nothing selected")
                        end
                        return
                    end

                    -- URL: open it directly, no picker.
                    if content:lower():find("^https?://") then
                        ctx.openURL(content)
                        return
                    end

                    local snippet = content:sub(1, 24)
                    local function pasteBack(text)
                        ctx.pasteboardWrite(text)
                        ctx.keyStroke({ "cmd" }, "v")
                    end

                    ctx.askChoice {
                        title = "Action for [" .. snippet .. "]",
                        infos = { snippet },
                        actions = { "Dictionary", "lowercase", "UPPERCASE", "Calculate" },
                        onChoose = function(choice)
                            if choice == "lowercase" then
                                pasteBack(content:lower())
                            elseif choice == "UPPERCASE" then
                                pasteBack(content:upper())
                            elseif choice == "Calculate" then
                                -- Evaluate as a Lua expression in a math-only
                                -- sandbox (the donor used the full globals).
                                local fn, loadErr = load("return " .. content,
                                    "calc", "t", { math = math })
                                if not fn then
                                    ctx.alert("Not an expression: " .. tostring(loadErr))
                                    return
                                end
                                local okEval, result = pcall(fn)
                                if not okEval then
                                    ctx.alert("Calculation failed: " .. tostring(result))
                                    return
                                end
                                pasteBack(content .. "=" .. tostring(result))
                            elseif choice == "Dictionary" then
                                local app = ctx.opt("dictApp")
                                if not ctx.activateApp(app) then
                                    ctx.alert(app .. " is not running")
                                    return
                                end
                                ctx.afterSeconds(YOUDAO_SETTLE_SECONDS, function()
                                    ctx.keyStroke({ "cmd" }, "a")
                                    ctx.typeText(content)
                                    ctx.keyStroke({}, "return")
                                end)
                            end
                        end,
                    }
                end)
            end,
        },
    },
}
